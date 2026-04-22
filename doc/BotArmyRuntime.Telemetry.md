# `BotArmyRuntime.Telemetry`

Sets up telemetry handlers for observability across Bot Army services.

Handles:
- Ecto query metrics
- NATS publishing metrics
- Application-level logging
- Error tracking via Sentry (when configured)

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `handle_ecto_error`

# `handle_ecto_query`

# `handle_nats_error`

# `handle_nats_publish`

# `start_link`

---

*Consult [api-reference.md](api-reference.md) for complete listing*
