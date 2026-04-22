# `BotArmyRuntime.NATS.Dedup`

ETS-based sliding window deduplication for NATS events.

Prevents duplicate processing of messages that may be redelivered
by JetStream or retried by publishers. Uses a 1-minute sliding
window with up to 10K entries.

Fast read path via ETS — no GenServer call needed for `seen?/1`.

# `check_and_mark`

Check and mark atomically. Returns `:new` if not seen, `:duplicate` if already seen.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `mark_seen`

Mark an event_id as seen. Fast ETS insert.

# `seen?`

Check if an event_id has been seen within the dedup window.
Fast ETS lookup — no GenServer call.

# `start_link`

---

*Consult [api-reference.md](api-reference.md) for complete listing*
