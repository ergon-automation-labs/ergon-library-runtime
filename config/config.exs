import Config

# Configure auto_start_services (default: false)
# Set to true when starting the application manually (not via supervisor)
# Note: This is set at runtime in bot_army_gtd/config/runtime.exs
# Do NOT set at compile time to avoid runtime vs compile time mismatch in releases

# Configure Ecto
config :bot_army_library_runtime, BotArmyRuntime.Ecto.Repo,
  pool_size: 10,
  queue_target: 500,
  queue_interval: 1000

# Configure Database Circuit Breaker
# Prevents hammering the database during outages and auto-recovers when it comes back online
config :bot_army_library_runtime, :db_circuit_breaker,
  enabled: true,
  failure_threshold: 5,
  half_open_timeout_ms: 30_000

# Configure NATS
# Multi-cluster support: parse NATS_SERVERS as space-separated "host:port" list
# Examples:
#   NATS_SERVERS="localhost:4222 localhost:14223"  # Primary + HA
#   NATS_SERVERS="localhost:14224"                  # Background cluster
#   (falls back to NATS_HOST:NATS_PORT if not set)
nats_servers =
  case System.get_env("NATS_SERVERS") do
    nil ->
      # Fallback: use NATS_HOST and NATS_PORT
      nats_host = System.get_env("NATS_HOST", "localhost")
      nats_port = System.get_env("NATS_PORT", "4223") |> String.to_integer()
      [{nats_host, nats_port}]

    servers_string ->
      # Parse space-separated "host:port" list
      servers_string
      |> String.split()
      |> Enum.map(fn server_spec ->
        case String.split(server_spec, ":") do
          [host, port_str] -> {host, String.to_integer(port_str)}
          # default port
          [host] -> {host, 4223}
          # fallback
          _ -> {"localhost", 4223}
        end
      end)
  end

config :bot_army_library_runtime, :nats,
  servers: nats_servers,
  ping_interval: 30_000,
  max_reconnect_attempts: 10,
  reconnect_delay_ms: 1000

# NATS connection timeout for GenServer calls
config :bot_army_library_runtime, :nats_connection_timeout, 5000

# Defer handler: when intent is deferred, start an LLM conversation
# to compose a softer message instead of doing nothing
config :bot_army_library_runtime, :defer_handler,
  enabled: true,
  min_interval_ms: 30 * 60 * 1000,
  timeout_ms: 15_000,
  default_llm_intent: "classify"

# Metrics endpoint port (matches Prometheus scrape config)
config :bot_army_library_runtime,
       :metrics_port,
       System.get_env("METRICS_PORT", "9090") |> String.to_integer()

# Configure Sentry (only active in :prod when SENTRY_DSN is set)
config :sentry,
  dsn: System.get_env("SENTRY_DSN"),
  environment_name: config_env(),
  json_library: JSON,
  included_environments: [:prod],
  enable_source_code_context: true,
  root_source_code_path: File.cwd!()

# OpenTelemetry distributed tracing
# If OTEL_EXPORTER_OTLP_ENDPOINT is set, traces are exported to that endpoint (e.g. Grafana Tempo).
# If unset, the noop exporter is used (no overhead).
otel_exporter = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")

if otel_exporter do
  config :opentelemetry,
    span_processor: :batch,
    traces_exporter: :otlp,
    text_map_propagators: [:trace_context, :baggage],
    resource: [
      service: [
        name: System.get_env("OTEL_SERVICE_NAME", "bot_army"),
        version: "0.6.0"
      ]
    ]

  config :opentelemetry_exporter,
    otlp_protocol: :http_protobuf,
    otlp_endpoint: otel_exporter
else
  config :opentelemetry,
    traces_exporter: :none,
    text_map_propagators: [:trace_context, :baggage]
end

# Configure Logger
config :logger,
  level: :info,
  backends: [:console]

config :logger, :console,
  format: "[$time] [$level] $message\n",
  metadata: [:correlation_id]
