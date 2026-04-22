# bot_army_runtime v0.7.1 - API Reference

## Modules

- [BotArmy.Pulse](BotArmy.Pulse.md): Pulse publishing module.
- [BotArmy.Soul](BotArmy.Soul.md): Soul storage and retrieval module.
- [BotArmyRuntime](BotArmyRuntime.md): BotArmyRuntime provides the shared persistence and messaging foundation for the Bot Army ecosystem.
- [BotArmyRuntime.Application](BotArmyRuntime.Application.md): Supervision tree for BotArmyRuntime.
- [BotArmyRuntime.Ecto.Repo](BotArmyRuntime.Ecto.Repo.md): Base Ecto Repository for Bot Army services.
- [BotArmyRuntime.Health.Monitor](BotArmyRuntime.Health.Monitor.md): Monitors bot heartbeats and publishes alerts when bots go stale.
- [BotArmyRuntime.Health.Responder](BotArmyRuntime.Health.Responder.md): Shared health check responder for Bot Army services.
- [BotArmyRuntime.Logging](BotArmyRuntime.Logging.md): Helper for any bot to record structured activity entries to the GTD daily log.
- [BotArmyRuntime.Metrics.Endpoint](BotArmyRuntime.Metrics.Endpoint.md): HTTP endpoint serving Prometheus metrics at /metrics on port 9090.

- [BotArmyRuntime.Metrics.PromExPlugin](BotArmyRuntime.Metrics.PromExPlugin.md): Custom PromEx plugin for Bot Army NATS and connection metrics.

- [BotArmyRuntime.NATS.Connection](BotArmyRuntime.NATS.Connection.md): Manages the connection to the NATS message bus.
- [BotArmyRuntime.NATS.Dedup](BotArmyRuntime.NATS.Dedup.md): ETS-based sliding window deduplication for NATS events.
- [BotArmyRuntime.NATS.JetStream](BotArmyRuntime.NATS.JetStream.md): JetStream stream and consumer management for Bot Army services.
- [BotArmyRuntime.NATS.Publisher](BotArmyRuntime.NATS.Publisher.md): Publishes messages to NATS.
- [BotArmyRuntime.Personality.Formatter](BotArmyRuntime.Personality.Formatter.md): Message formatter with bot personality symbols.
- [BotArmyRuntime.Personality.Identity](BotArmyRuntime.Personality.Identity.md): Bot Army personality symbols registry.
- [BotArmyRuntime.PromEx](BotArmyRuntime.PromEx.md): PromEx module for Bot Army metrics collection.
- [BotArmyRuntime.Telemetry](BotArmyRuntime.Telemetry.md): Sets up telemetry handlers for observability across Bot Army services.
- [BotArmyRuntime.Tenant](BotArmyRuntime.Tenant.md): Tenant management utilities for multi-tenancy support.
- [BotArmyRuntime.Tracing](BotArmyRuntime.Tracing.md): OpenTelemetry distributed tracing integration for NATS message flows.

