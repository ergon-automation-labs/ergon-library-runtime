# `BotArmyRuntime.Application`

Supervision tree for BotArmyRuntime.

Starts:
- Registry for NATS connection status broadcasts
- PromEx metrics collection
- Cowboy HTTP endpoint for /metrics (port configurable via METRICS_PORT env, default 9090)
- Telemetry handlers
- NATS Connection (message bus connection)
- NATS Dedup (message deduplication)

---

*Consult [api-reference.md](api-reference.md) for complete listing*
