defmodule BotArmyLibraryRuntime.Ecto.RuntimeDbConfig do
  @moduledoc """
  Resolves Ecto Repo connection config from environment variables with one
  consistent precedence, for use from a bot's `config/runtime.exs`:

    1. `<PREFIX>_DB_<FIELD>` — bot-specific override (e.g. `BOT_ARMY_DISPATCHER_DB_HOST`)
    2. `DATABASE_<FIELD>` — fleet-wide default, what Salt's shared
       `launchd.plist.j2` template actually provisions today
    3. the `defaults:` keyword passed in, or a hardcoded fallback

  Every bot's `runtime.exs` used to hand-roll this `||` chain per field, and
  the chains drifted: dispatcher's checked the bot-specific name for
  `database` but skipped straight to the generic name for `hostname`/`port`,
  so a local override of the bot-specific var silently did nothing for those
  fields. One implementation, used the same way everywhere, so the tiers
  can't drift apart again.

  Pool size is resolved separately via `pool_size/2` since its fleet-wide
  fallback name (`BOT_POOL_SIZE`) doesn't follow the `DATABASE_<FIELD>`
  pattern the rest of the fields do.

  ## Usage

      config :bot_army_dispatcher, BotArmyDispatcher.Repo,
        Keyword.merge(
          RuntimeDbConfig.resolve("BOT_ARMY_DISPATCHER",
            database: "bot_army_dispatcher",
            port: 30003
          ),
          pool_size: RuntimeDbConfig.pool_size("BOT_ARMY_DISPATCHER", 5)
        )
  """

  @doc """
  Returns `[database:, hostname:, port:, username:, password:]` resolved
  through the three-tier precedence above.

  `prefix` is the bot's env var namespace, e.g. `"BOT_ARMY_DISPATCHER"` (no
  trailing underscore). `defaults` overrides the built-in fallback for any
  field; unset fields fall back to `localhost` / port `5432` / `postgres`.
  """
  def resolve(prefix, defaults \\ []) do
    [
      database:
        env(
          prefix,
          "DB_NAME",
          "DATABASE_NAME",
          default(defaults, :database, prefix |> String.downcase())
        ),
      hostname:
        env(prefix, "DB_HOST", "DATABASE_HOST", default(defaults, :hostname, "localhost")),
      port: env(prefix, "DB_PORT", "DATABASE_PORT", default(defaults, :port, 5432)) |> to_int(),
      username: env(prefix, "DB_USER", "DATABASE_USER", default(defaults, :username, "postgres")),
      password:
        env(prefix, "DB_PASSWORD", "DATABASE_PASSWORD", default(defaults, :password, "postgres"))
    ]
  end

  @doc """
  Resolves pool size: `<PREFIX>_POOL_SIZE` (bot-specific) then `BOT_POOL_SIZE`
  (fleet-wide, the existing convention) then `default`.
  """
  def pool_size(prefix, default \\ 5) do
    BotArmyLibraryRuntime.ConfigLoader.get(
      "#{prefix}_POOL_SIZE",
      fn -> BotArmyLibraryRuntime.ConfigLoader.get("BOT_POOL_SIZE", to_string(default)) end
    )
    |> to_int()
  end

  defp env(prefix, bot_suffix, generic_name, default) do
    BotArmyLibraryRuntime.ConfigLoader.get(
      "#{prefix}_#{bot_suffix}",
      fn -> BotArmyLibraryRuntime.ConfigLoader.get(generic_name, to_string(default)) end
    )
  end

  defp default(defaults, key, fallback), do: Keyword.get(defaults, key, fallback)

  defp to_int(val) when is_integer(val), do: val
  defp to_int(val) when is_binary(val), do: String.to_integer(val)
end
