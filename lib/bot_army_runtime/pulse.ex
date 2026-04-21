defmodule BotArmy.Pulse do
  @moduledoc """
  Pulse publishing module.

  The pulse is a bot's current state and activity. It's published periodically
  to `bot.army.pulse.<bot_id>` and provides real-time visibility into what
  each bot is doing.

  ## Pulse Schema

  ```json
  {
    "bot_id": "gtd_bot",
    "timestamp": "2026-04-21T10:30:00Z",
    "status": "active|idle|busy|error",
    "current_task": "processing_inbox",
    "task_count": 14,
    "queue_depth": 5,
    "last_action": "task_created",
    "uptime_seconds": 86400,
    "metrics": {
      "llm_calls_today": 23,
      "tasks_processed": 142,
      "errors_today": 0
    }
  }
  ```

  ## Usage

  ```elixir
  # Publish a pulse for the current bot
  BotArmy.Pulse.publish(:gtd_bot, %{
    status: :active,
    current_task: "processing_inbox",
    task_count: 14
  })
  ```

  ## Subscribers

  The Context Broker subscribes to all `bot.army.pulse.*` subjects to:
  - Build a real-time "army state" dashboard
  - Detect stale bots (no pulse in 60s = potential issue)
  - Coordinate cross-bot activities

  Alerting on stale pulses is handled by `army.health.check` subscriber.
  """

  @doc """
  Publish a pulse for a bot.

  Publishes to `bot.army.pulse.<bot_id>` with the provided state.
  """
  @spec publish(atom() | String.t(), map(), opts :: [tenant_id: String.t()]) :: :ok
  def publish(bot_id, state, opts \\ []) do
    tenant_id = Keyword.get(opts, :tenant_id, BotArmyRuntime.Tenant.default_tenant_id())

    payload = %{
      bot_id: Atom.to_string(bot_id),
      tenant_id: tenant_id,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      status: Map.get(state, :status, :active),
      current_task: Map.get(state, :current_task),
      queue_depth: Map.get(state, :queue_depth),
      last_action: Map.get(state, :last_action),
      uptime_seconds: Map.get(state, :uptime_seconds),
      metrics: Map.get(state, :metrics, %{}),
      heartbeat_count: Map.get(state, :heartbeat_count, 0)
    }

    BotArmyRuntime.NATS.Publisher.publish("bot.army.pulse.#{bot_id}", payload)
    :ok
  end

  @doc """
  Build a pulse state from bot metadata.

  Convenience function for bots to publish their current state.
  """
  @spec build_state(
          atom() | String.t(),
          opts :: [
            task_count: integer,
            queue_depth: integer,
            metrics: map,
            heartbeat_count: integer
          ]
        ) :: map
  def build_state(_bot_id, opts \\ []) do
    uptime =
      case opts[:started_at] do
        nil -> 0
        started_at -> DateTime.diff(DateTime.utc_now(), started_at)
      end

    %{
      status: Map.get(opts, :status, :active),
      current_task: Map.get(opts, :current_task),
      task_count: Map.get(opts, :task_count, 0),
      queue_depth: Map.get(opts, :queue_depth, 0),
      last_action: Map.get(opts, :last_action),
      uptime_seconds: uptime,
      metrics: Map.get(opts, :metrics, %{}),
      heartbeat_count: Map.get(opts, :heartbeat_count, 0)
    }
  end
end
