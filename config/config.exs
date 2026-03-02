import Config

# Configure Ecto
config :bot_army_runtime, BotArmyRuntime.Ecto.Repo,
  pool_size: 10,
  queue_target: 500,
  queue_interval: 1000

# Configure NATS
config :bot_army_runtime, :nats,
  servers: [{"localhost", 4222}],
  ping_interval: 30_000,
  max_reconnect_attempts: 10,
  reconnect_delay_ms: 1000

# Configure Logger
config :logger,
  level: :info,
  format: "[$level] $message\n"

# JSON Logger for structured logs in production
# Uncomment to enable:
# config :logger,
#   backends: [{LoggerJSON.Backends.GoogleCloudLogging, {}}],
#   level: :info

# Import environment-specific config
import_config "#{config_env()}.exs"
