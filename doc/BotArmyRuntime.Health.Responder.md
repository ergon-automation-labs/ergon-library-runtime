# `BotArmyRuntime.Health.Responder`

Shared health check responder for Bot Army services.

Subscribes to `bot.<bot_name>.health` on NATS (request/reply pattern).
Reports NATS connectivity, database connectivity, key process liveness, and version.

Re-registers with ConnectionRegistry on reconnect so the health subscription
is always active.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `start_link`

---

*Consult [api-reference.md](api-reference.md) for complete listing*
