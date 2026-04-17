import Config

# Configure Ecto
config :bot_army_runtime, BotArmyRuntime.Ecto.Repo,
  pool_size: 10,
  queue_target: 500,
  queue_interval: 1000

# Configure NATS
nats_host = System.get_env("NATS_HOST", "localhost")
nats_port = System.get_env("NATS_PORT", "4222") |> String.to_integer()

config :bot_army_runtime, :nats,
  servers: [{nats_host, nats_port}],
  ping_interval: 30_000,
  max_reconnect_attempts: 10,
  reconnect_delay_ms: 1000

# NATS connection timeout for GenServer calls
config :bot_army_runtime, :nats_connection_timeout, 5000

# Metrics endpoint port (matches Prometheus scrape config)
config :bot_army_runtime,
       :metrics_port,
       System.get_env("METRICS_PORT", "9090") |> String.to_integer()

# Configure Sentry (only active in :prod when SENTRY_DSN is set)
config :sentry,
  dsn: System.get_env("SENTRY_DSN"),
  environment_name: config_env(),
  included_environments: [:prod],
  enable_source_code_context: true,
  root_source_code_path: File.cwd!()

# Configure Logger
config :logger,
  level: :info,
  format: "[$level] $message\n"

# JSON Logger for structured logs in production
if config_env() == :prod do
  config :logger,
    backends: [{LoggerJSON.Backends.GoogleCloudLogging, {}}],
    level: :info
end

# Import environment-specific config
import_config "#{config_env()}.exs"
