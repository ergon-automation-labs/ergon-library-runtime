# `BotArmyRuntime.NATS.JetStream`

JetStream stream and consumer management for Bot Army services.

Provides idempotent creation of streams and durable consumers,
ensuring messages are not lost during consumer disconnects.

Uses the gnat Jetstream API (Gnat.Jetstream.API.Stream and
Gnat.Jetstream.API.Consumer for creation, Gnat.Jetstream for ack/nack).

## Stream Topology

| Stream | Subjects | Retention |
|--------|----------|----------|
| BOT_GTD | gtd.> | 30 days |
| BOT_LLM | llm.> | 7 days |
| BOT_JOBS | job.> | 30 days |
| BOT_EVENTS | events.> | 30 days |
| BOT_CLAUDE | bot_army.claude.> | 7 days |
| BOT_FITNESS | fitness.> | 7 days |
| BOT_CHORE | chore.> | 7 days |
| BOT_SRE | sre.> | 7 days |
| BOT_DLQ | dlq.> | 30 days |

# `ack`

Acknowledge a JetStream message (confirm successful processing).

# `ensure_all_streams`

Ensure all Bot Army streams exist. Idempotent — safe to call on every startup.

# `ensure_consumer`

Ensure a durable JetStream consumer exists. Idempotent.

Options:
- `:deliver_subject` — push delivery subject (required for push consumers)
- `:deliver_policy` — `:last` (default), `:all`, `:new`
- `:max_deliver` — max redelivery attempts (default 3)
- `:ack_policy` — `:explicit` (default), `:all`, `:none`
- `:ack_wait` — ack timeout in nanoseconds (default 30s)

# `ensure_stream`

Ensure a JetStream stream exists. Idempotent — no-op if stream already exists.

# `nack`

Negatively acknowledge a JetStream message (trigger redelivery).

# `stream_configs`

Return the stream configurations for external use (e.g., Salt automation).

---

*Consult [api-reference.md](api-reference.md) for complete listing*
