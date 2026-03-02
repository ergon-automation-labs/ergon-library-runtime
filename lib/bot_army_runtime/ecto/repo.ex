defmodule BotArmyRuntime.Ecto.Repo do
  @moduledoc """
  Base Ecto Repository for Bot Army services.

  All bot services inherit from this module to get database access. It handles:

  - Connection pooling and supervision
  - Runtime configuration
  - Migration support
  - Error handling

  ## Configuration

  Configure in `config.exs`:

      config :bot_army_runtime, BotArmyRuntime.Ecto.Repo,
        database: "bot_army_dev",
        username: "postgres",
        password: "postgres",
        hostname: "localhost",
        port: 5432,
        pool_size: 10,
        queue_target: 500,
        queue_interval: 1000

  For production, pass these via runtime configuration or environment variables:

      config :bot_army_runtime, BotArmyRuntime.Ecto.Repo,
        database: {:system, "DB_NAME"},
        username: {:system, "DB_USER"},
        password: {:system, "DB_PASSWORD"},
        hostname: {:system, "DB_HOST"},
        pool_size: {:system, "DB_POOL_SIZE", "10"}

  ## Usage in Bot Services

  A bot service would define:

      defmodule BotArmyGTD.Repo do
        use BotArmyRuntime.Ecto.Repo
      end

  Then configure:

      config :bot_army_gtd, BotArmyGTD.Repo,
        database: "bot_army_gtd_dev"
  """

  use Ecto.Repo,
    otp_app: :bot_army_runtime,
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

      BotArmyRuntime.Ecto.Repo.migrate_up()
      BotArmyRuntime.Ecto.Repo.migrate_up(:down)
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
    # Bot services will provide their own migrations path
    # This is a default that can be overridden
    Application.app_dir(:bot_army_runtime, "priv/repo/migrations")
  end
end
