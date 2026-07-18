defmodule BotArmyLibraryRuntime.Ecto.Repo do
  @moduledoc """
  Base Ecto Repository for Bot Army services.

  All bot services inherit from this module to get database access. It handles:

  - Connection pooling and supervision
  - Runtime configuration
  - Migration support
  - Error handling

  ## Configuration

  Configure in the bot's runtime.exs:

      config :bot_army_library_runtime, BotArmyLibraryRuntime.Ecto.Repo,
        database: "bot_army_dev",
        username: "postgres",
        password: "postgres",
        hostname: "localhost",
        port: 5432,
        pool_size: 10,
        queue_target: 500,
        queue_interval: 1000

  For production, pass these via runtime configuration or environment variables:

      config :bot_army_library_runtime, BotArmyLibraryRuntime.Ecto.Repo,
        database: {:system, "DB_NAME"},
        username: {:system, "DB_USER"},
        password: {:system, "DB_PASSWORD"},
        hostname: {:system, "DB_HOST"},
        pool_size: {:system, "DB_POOL_SIZE", "10"}

  ## Usage in Bot Services

  A bot service would define:

      defmodule BotArmyGTD.Repo do
        use BotArmyLibraryRuntime.Ecto.Repo
      end

  Then configure:

      config :bot_army_gtd, BotArmyGTD.Repo,
        database: "bot_army_gtd_dev"

  Migrations are run from the bot's own Release module, not from this Repo.
  Each bot calls Ecto.Migrator.run with its own migrations_path.
  """

  use Ecto.Repo,
    otp_app: :bot_army_library_runtime,
    adapter: Ecto.Adapters.Postgres

  @doc """
  Dynamically loads the repository url from the DATABASE_URL environment variable.

  This allows migrations and runtime configuration without hardcoding database credentials.
  """
  def init(_, opts) do
    {:ok, Keyword.merge(opts, parse_runtime_config())}
  end

  @doc """
  Runs all pending migrations in the given direction.

  Used for database setup and schema updates.

  ## Examples

      BotArmyLibraryRuntime.Ecto.Repo.migrate_up()
      BotArmyLibraryRuntime.Ecto.Repo.migrate_up(:down)
  """
  def migrate_up(direction \\ :up) do
    Ecto.Migrator.run(__MODULE__, migrations_path(), direction, all: true)
  end

  @doc false
  defp parse_runtime_config do
    case System.get_env("DATABASE_URL") do
      nil ->
        []

      url ->
        case Ecto.Repo.Supervisor.parse_url(url) do
          {:ok, config} -> config
          :error -> raise "Invalid DATABASE_URL: #{url}"
        end
    end
  end

  @doc false
  defp migrations_path do
    # Each bot runs migrations from its own priv/repo/migrations.
    # This fallback points to the library's own priv dir.
    Application.app_dir(:bot_army_library_runtime, "priv/repo/migrations")
  end
end
