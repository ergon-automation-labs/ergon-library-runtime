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
      ),
      Event.build(
        :personality_soul_metrics,
        [
          Telemetry.Metrics.counter(
            [:bot_army, :personality, :soul, :get, :total],
            event_name: [:bot_army, :personality, :soul, :get],
            measurement: :count,
            tags: [:outcome],
            description: "Soul row reads by outcome (found = persisted row hit)"
          ),
          Telemetry.Metrics.distribution(
            [:bot_army, :personality, :soul, :get, :duration, :milliseconds],
            event_name: [:bot_army, :personality, :soul, :get],
            measurement: :duration,
            unit: {:native, :millisecond},
            tags: [:outcome],
            description: "Soul get duration",
            reporter_options: [buckets: [0.1, 0.5, 1, 2, 5, 10, 25, 50, 100, 250, 500]]
          ),
          Telemetry.Metrics.counter(
            [:bot_army, :personality, :soul, :upsert, :total],
            event_name: [:bot_army, :personality, :soul, :upsert],
            measurement: :count,
            tags: [:outcome],
            description: "Soul upserts (ok = JSONB write path)"
          ),
          Telemetry.Metrics.distribution(
            [:bot_army, :personality, :soul, :upsert, :duration, :milliseconds],
            event_name: [:bot_army, :personality, :soul, :upsert],
            measurement: :duration,
            unit: {:native, :millisecond},
            tags: [:outcome],
            description: "Soul upsert duration",
            reporter_options: [buckets: [0.1, 0.5, 1, 2, 5, 10, 25, 50, 100, 250, 500]]
          ),
          Telemetry.Metrics.counter(
            [:bot_army, :personality, :soul, :publish, :total],
            event_name: [:bot_army, :personality, :soul, :publish],
            measurement: :count,
            tags: [:outcome],
            description: "Soul NATS fan-out publishes"
          ),
          Telemetry.Metrics.counter(
            [:bot_army, :personality, :pulse, :publish, :total],
            event_name: [:bot_army, :personality, :pulse, :publish],
            measurement: :count,
            tags: [:outcome],
            description: "Pulse NATS publishes (persistence signal for live state)"
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
