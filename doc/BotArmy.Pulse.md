# `BotArmy.Pulse`

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

## Observability

Each publish emits `[:bot_army, :personality, :pulse, :publish]` with `outcome` `:ok` or
`:error` (NATS down still surfaces as a metric). See `BotArmyRuntime.Personality.Observability`.

# `build_state`

```elixir
@spec build_state(
  atom() | String.t(),
  opts :: [
    task_count: integer(),
    queue_depth: integer(),
    metrics: map(),
    heartbeat_count: integer()
  ]
) :: map()
```

Build a pulse state from bot metadata.

Convenience function for bots to publish their current state.

# `publish`

```elixir
@spec publish(atom() | String.t(), map(), opts :: [{:tenant_id, String.t()}]) :: :ok
```

Publish a pulse for a bot.

Publishes to `bot.army.pulse.<bot_id>` with the provided state.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
