import Config

# Development-specific configuration
# Database connection info comes from environment variables set by Salt or .env file
# Defaults provided for local development convenience (points to postgres-vector NodePort)
config :bot_army_runtime, BotArmyRuntime.Ecto.Repo,
  username: System.get_env("DATABASE_USER", "postgres"),
  password: System.get_env("DATABASE_PASSWORD", "postgres"),
  hostname: System.get_env("DATABASE_HOST", "localhost"),
  port: String.to_integer(System.get_env("DATABASE_PORT", "30003")),
  database: System.get_env("DATABASE_NAME", "bot_army_runtime_dev"),
  stacktrace: true,
  show_sensitive_data_on_error: true,
  pool_size: 10

config :logger, level: :debug
