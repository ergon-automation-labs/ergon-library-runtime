import Config

# Test-specific Ecto configuration
# Uses NodePort PostgreSQL like production
config :bot_army_runtime, BotArmyRuntime.Ecto.Repo,
  database: "bot_army_test",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 30004,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 1

# Test NATS on non-standard port
config :bot_army_runtime, :nats,
  servers: [{"localhost", 4223}],
  ping_interval: 5000,
  max_reconnect_attempts: 3,
  reconnect_delay_ms: 100

# Log level for tests
config :logger,
  level: :warning

# Disable password hashing in tests for speed (if applicable)
config :bcrypt_elixir, :log_rounds, 4

# Disable starting bot_army_runtime application in test environment
# Individual bot repos will start their own Repos
config :bot_army_runtime, :auto_start_services, false
