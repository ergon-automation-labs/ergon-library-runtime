defmodule BotArmyLibraryRuntime.Application do
  @moduledoc """
  Supervision tree for BotArmyLibraryRuntime.

  Starts:
  - Registry for NATS connection status broadcasts
  - PromEx metrics collection
  - Cowboy HTTP endpoint for /metrics (port configurable via METRICS_PORT env, default 9090)
  - Telemetry handlers
  - NATS Connection (message bus connection)
  - NATS Dedup (message deduplication)
  """

  use Application

  @impl true
  def start(_type, _args) do
    # Note: BotArmyLibraryRuntime.Ecto.Repo is NOT started here.
    # Each bot service (bot_army_gtd, bot_army_llm, etc.) defines its own Repo
    # and is responsible for starting it. This keeps database configuration
    # independent per bot and allows tests to run without database errors.

    children =
      [
        # Registries must start first — used by :via tuples in dependent processes
        {Registry, keys: :duplicate, name: BotArmyLibraryRuntime.NATS.ConnectionRegistry},
        {Registry, keys: :unique, name: BotArmyLibraryRuntime.NATS.CircuitBreakerRegistry},
        {Registry, keys: :unique, name: BotArmyLibraryRuntime.AccumulatedContextRegistry},

        # PromEx metrics collection
        {BotArmyLibraryRuntime.PromEx, []},

        # Telemetry handlers for observability
        {BotArmyLibraryRuntime.Telemetry, []},

        # NATS connection (required for message bus communication)
        # Configuration read from :bot_army_library_runtime, :nats in config/runtime.exs
        {BotArmyLibraryRuntime.NATS.Connection, []},

        # Army-wide kill switch (halts outgoing publishes when engaged;
        # must start before bots begin processing so restored halt state applies)
        {BotArmyLibraryRuntime.KillSwitch, []},

        # NATS message deduplication (ETS sliding window)
        {BotArmyLibraryRuntime.NATS.Dedup, []},

        # Subject metrics tracking (counts subject calls across the ecosystem)
        {BotArmyLibraryRuntime.SubjectMetrics, []},

        # Defer rate limiter (ETS-based, prevents spamming LLM on repeated defers)
        {BotArmyLibraryRuntime.Intent.DeferRateLimiter, []},

        # Defer tracker (ETS-based, counts check-in defers per user/task/week)
        {BotArmyLibraryRuntime.DeferTracker, []},

        # NATS circuit breaker (per-key failure tracking for resilience)
        {BotArmyLibraryRuntime.NATS.CircuitBreaker, []},

        # Database circuit breaker (prevents hammering DB during outages)
        {BotArmyLibraryRuntime.Ecto.CircuitBreaker, []},

        # Service discovery registry (in-memory bot registry with heartbeat detection)
        {BotArmyLibraryRuntime.Registry, []},

        # Health monitor (stale bot detection)
        {BotArmyLibraryRuntime.Health.Monitor, []},

        # Conversation manager (cross-bot request/response + mailbox)
        {BotArmyLibraryRuntime.NATS.Conversation.Manager, []},

        # Outcome tracker (captures intent lifecycle events from NATS)
        {BotArmyLibraryRuntime.Intent.OutcomeTracker, []},

        # Reflection job (periodic outcome analysis and weight adjustment)
        {BotArmyLibraryRuntime.Intent.ReflectionJob, []},

        # Dynamic supervisor for per-bot AccumulatedContext processes
        {DynamicSupervisor, strategy: :one_for_one, name: BotArmyLibraryRuntime.DynamicSupervisor}
      ]
      |> maybe_add_metrics_endpoint()

    opts = [strategy: :one_for_one, name: BotArmyLibraryRuntime.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp metrics_endpoint do
    port = Application.get_env(:bot_army_library_runtime, :metrics_port, 9090)

    {Plug.Cowboy,
     scheme: :http, plug: BotArmyLibraryRuntime.Metrics.Endpoint, options: [port: port]}
  end

  @auto_start_services Application.compile_env(
                         :bot_army_library_runtime,
                         :auto_start_services,
                         false
                       )

  defp maybe_add_metrics_endpoint(children) do
    if @auto_start_services do
      children ++ [metrics_endpoint()]
    else
      children
    end
  end
end
