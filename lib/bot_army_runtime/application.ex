defmodule BotArmyRuntime.Application do
  @moduledoc """
  Supervision tree for BotArmyRuntime.

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
    # Note: BotArmyRuntime.Ecto.Repo is NOT started here.
    # Each bot service (bot_army_gtd, bot_army_llm, etc.) defines its own Repo
    # and is responsible for starting it. This keeps database configuration
    # independent per bot and allows tests to run without database errors.

    children =
      [
        # Registry for NATS connection status broadcasts
        {Registry, keys: :duplicate, name: BotArmyRuntime.NATS.ConnectionRegistry},

        # PromEx metrics collection
        {BotArmyRuntime.PromEx, []},

        # Telemetry handlers for observability
        {BotArmyRuntime.Telemetry, []},

        # NATS connection (required for message bus communication)
        # Configuration read from :bot_army_runtime, :nats in config/runtime.exs
        {BotArmyRuntime.NATS.Connection, []},

        # NATS message deduplication (ETS sliding window)
        {BotArmyRuntime.NATS.Dedup, []}
      ]
      |> maybe_add_metrics_endpoint()

    opts = [strategy: :one_for_one, name: BotArmyRuntime.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp metrics_endpoint do
    port = Application.get_env(:bot_army_runtime, :metrics_port, 9090)

    {Plug.Cowboy, scheme: :http, plug: BotArmyRuntime.Metrics.Endpoint, options: [port: port]}
  end

  @env Mix.env()

  defp maybe_add_metrics_endpoint(children) do
    if @env == :test do
      children
    else
      children ++ [metrics_endpoint()]
    end
  end
end
