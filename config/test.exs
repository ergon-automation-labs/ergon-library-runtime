import Config

# Test-specific Ecto configuration
# Uses NodePort PostgreSQL like production
config :bot_army_library_runtime, BotArmyRuntime.Ecto.Repo,
  database: "bot_army_test",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  port: 30004,
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 1

# Hermetic by default: tests must not touch any live army broker. The default
# port 42991 is expected to be dead, so Connection degrades to :not_connected
# and Registry/heartbeat tests run purely in-process. Set NATS_PORT=4222 (or
# a TestHelpers nats-server) to opt INTO broker-backed runs — never rely on
# the default pointing at something live.
#
# NOTE: We force hermetic mode in test.exs (always use 42991) rather than reading
# NATS_PORT env var, which would accidentally connect tests to live brokers when
# NATS_PORT is set in the shell environment. Tests that need live NATS must
# explicitly opt-in via test helper setup, not via environment variables.
test_nats_port = 42991

config :bot_army_library_runtime, :nats,
  servers: [{"localhost", test_nats_port}],
  ping_interval: 5000,
  max_reconnect_attempts: 3,
  reconnect_delay_ms: 100

# Test NATS connection timeout
config :bot_army_library_runtime, :nats_connection_timeout, 5000

# Log level for tests
config :logger,
  level: :warning

# Disable password hashing in tests for speed (if applicable)
config :bcrypt_elixir, :log_rounds, 4

# Disable starting bot_army_runtime application in test environment
# Individual bot repos will start their own Repos
# Set to true to run tests that need the metrics endpoint (rare)
config :bot_army_library_runtime, :auto_start_services, false

# Use alternative port for tests if metrics endpoint is started
config :bot_army_library_runtime, :metrics_port, 19090
