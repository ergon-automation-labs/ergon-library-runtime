# bot_army_runtime v0.9.2 - API Reference

## Modules

- [BotArmy.Pulse](BotArmy.Pulse.md): Pulse publishing module.
- [BotArmy.Soul](BotArmy.Soul.md): Soul storage and retrieval module.
- [BotArmyRuntime](BotArmyRuntime.md): BotArmyRuntime provides the shared persistence and messaging foundation for the Bot Army ecosystem.
- [BotArmyRuntime.Application](BotArmyRuntime.Application.md): Supervision tree for BotArmyRuntime.
- [BotArmyRuntime.Correlation](BotArmyRuntime.Correlation.md): Correlation ID propagation for distributed request tracing.
- [BotArmyRuntime.Ecto.Repo](BotArmyRuntime.Ecto.Repo.md): Base Ecto Repository for Bot Army services.
- [BotArmyRuntime.Health.Monitor](BotArmyRuntime.Health.Monitor.md): Monitors bot heartbeats and publishes alerts when bots go stale.
- [BotArmyRuntime.Health.Responder](BotArmyRuntime.Health.Responder.md): Shared health check responder for Bot Army services.
- [BotArmyRuntime.Logging](BotArmyRuntime.Logging.md): Helper for any bot to record structured activity entries to the GTD daily log.
- [BotArmyRuntime.Metrics.Endpoint](BotArmyRuntime.Metrics.Endpoint.md): HTTP endpoint serving Prometheus metrics at /metrics on port 9090.

- [BotArmyRuntime.Metrics.PromExPlugin](BotArmyRuntime.Metrics.PromExPlugin.md): Custom PromEx plugin for Bot Army NATS and connection metrics.

- [BotArmyRuntime.NATS.CircuitBreaker](BotArmyRuntime.NATS.CircuitBreaker.md): Generic circuit breaker for NATS inter-bot request-reply calls.
- [BotArmyRuntime.NATS.Connection](BotArmyRuntime.NATS.Connection.md): Manages the connection to the NATS message bus.
- [BotArmyRuntime.NATS.Conversation.Envelope](BotArmyRuntime.NATS.Conversation.Envelope.md): Build and validate conversation envelopes for cross-bot communication.
- [BotArmyRuntime.NATS.Conversation.Gossip](BotArmyRuntime.NATS.Conversation.Gossip.md): Gossip/icebreaker engine for bot-to-bot conversation.
- [BotArmyRuntime.NATS.Conversation.Mailbox](BotArmyRuntime.NATS.Conversation.Mailbox.md): Async mailbox messaging between bots.
- [BotArmyRuntime.NATS.Conversation.Manager](BotArmyRuntime.NATS.Conversation.Manager.md): Manages cross-bot conversations.
- [BotArmyRuntime.NATS.Dedup](BotArmyRuntime.NATS.Dedup.md): ETS-based sliding window deduplication for NATS events.
- [BotArmyRuntime.NATS.JetStream](BotArmyRuntime.NATS.JetStream.md): JetStream stream and consumer management for Bot Army services.
- [BotArmyRuntime.NATS.Publisher](BotArmyRuntime.NATS.Publisher.md): Publishes messages to NATS.
- [BotArmyRuntime.NATS.Reply](BotArmyRuntime.NATS.Reply.md): Standardized response format for NATS request/reply handlers.
- [BotArmyRuntime.Personality.Formatter](BotArmyRuntime.Personality.Formatter.md): Message formatter with bot personality symbols.
- [BotArmyRuntime.Personality.Identity](BotArmyRuntime.Personality.Identity.md): Bot Army personality symbols registry.
- [BotArmyRuntime.PromEx](BotArmyRuntime.PromEx.md): PromEx module for Bot Army metrics collection.
- [BotArmyRuntime.Registry](BotArmyRuntime.Registry.md): In-memory service discovery registry for the Bot Army ecosystem.
- [BotArmyRuntime.Telemetry](BotArmyRuntime.Telemetry.md): Sets up telemetry handlers for observability across Bot Army services.
- [BotArmyRuntime.Tenant](BotArmyRuntime.Tenant.md): Tenant management utilities for multi-tenancy support.
- [BotArmyRuntime.Tracing](BotArmyRuntime.Tracing.md): OpenTelemetry distributed tracing integration for NATS message flows.

