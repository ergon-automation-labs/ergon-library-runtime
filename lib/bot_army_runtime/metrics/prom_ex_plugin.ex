defmodule BotArmyRuntime.Metrics.PromExPlugin do
  @moduledoc """
  Custom PromEx plugin for Bot Army NATS and connection metrics.
  """

  use PromEx.Plugin

  alias PromEx.MetricTypes.Event

  @impl true
  def event_metrics(_opts) do
    [
      Event.build(
        :nats_pub_metrics,
        [
          Telemetry.Metrics.distribution(
            [:bot_army, :nats, :pub, :duration, :milliseconds],
            event_name: [:nats, :pub],
            measurement: :duration,
            description: "NATS publish duration",
            unit: {:native, :millisecond},
            reporter_options: [buckets: [1, 5, 10, 25, 50, 100, 250, 500, 1000]]
          ),
          Telemetry.Metrics.counter(
            [:bot_army, :nats, :pub, :total],
            event_name: [:nats, :pub],
            description: "NATS publish total count"
          )
        ]
      ),
      Event.build(
        :nats_connection_metrics,
        [
          Telemetry.Metrics.last_value(
            [:bot_army, :nats, :connection, :status],
            event_name: [:nats, :connection, :status],
            description: "NATS connection status (1=connected, 0=disconnected)"
          )
        ]
      )
    ]
  end

  @impl true
  def polling_metrics(_opts) do
    []
  end
end
