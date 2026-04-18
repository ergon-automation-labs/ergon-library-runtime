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

# Test NATS on configurable port (default 4223, can override with NATS_PORT)
test_nats_port = System.get_env("NATS_PORT", "4223") |> String.to_integer()

config :bot_army_runtime, :nats,
  servers: [{"localhost", test_nats_port}],
  ping_interval: 5000,
  max_reconnect_attempts: 3,
  reconnect_delay_ms: 100

# Test NATS connection timeout
config :bot_army_runtime, :nats_connection_timeout, 5000

# Log level for tests
config :logger,
  level: :warning

# Disable password hashing in tests for speed (if applicable)
config :bcrypt_elixir, :log_rounds, 4

# Disable starting bot_army_runtime application in test environment
# Individual bot repos will start their own Repos
# Set to true to run tests that need the metrics endpoint (rare)
config :bot_army_runtime, :auto_start_services, false

# Use alternative port for tests if metrics endpoint is started
config :bot_army_runtime, :metrics_port, 19090
