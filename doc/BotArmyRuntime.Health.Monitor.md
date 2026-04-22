# `BotArmyRuntime.Health.Monitor`

Monitors bot heartbeats and publishes alerts when bots go stale.

Subscribes to `bot.army.health.>` on NATS, tracks last-seen timestamps
in ETS, and checks every 30s for entries older than 60s. Stale bots
get an alert published to `bot.army.health.stale`; recovery events
go to `bot.army.health.recovered`.

Public ETS reads via `get_status/1`, `list_bots/0`, `list_stale/0`
don't require GenServer calls.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `get_status`

Returns `{:ok, {last_seen_at, status}}` or `:unknown`.

# `list_bots`

Lists all tracked bots as `[{bot_id, last_seen_at, status}]`.

# `list_stale`

Lists stale bots as `[{bot_id, last_seen_at, stale_for_sec}]`.

# `start_link`

---

*Consult [api-reference.md](api-reference.md) for complete listing*
