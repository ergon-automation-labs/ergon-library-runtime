# Architecture

## Overview

`bot_army_runtime` is the foundation library for the Bot Army ecosystem. It provides:

- **NATS Connection Management**: Robust connection pooling, automatic reconnection, and supervision
- **Service Registry**: Bot discovery and capability advertisement via NATS
- **Telemetry**: OpenTelemetry integration for observability
- **Ecto Persistence**: Database schema utilities and patterns
- **Structured Logging**: Telemetry-backed logging with correlation IDs

## Design Goals

1. **Minimal boilerplate**: Bots inherit NATS, registry, telemetry out of the box
2. **Fault tolerance**: Connection failures are handled transparently with backoff
3. **Observability**: Every operation emits telemetry events for monitoring
4. **Decoupling**: Bots don't need to know about NATS internals
5. **Extensibility**: Custom handlers, middleware, and adapters bolt on cleanly

## Core Modules

### `BotArmyRuntime.NATS.Connection`
GenServer that manages a single NATS connection with:
- Automatic reconnection with exponential backoff
- Health status tracking
- Request/reply timeout handling
- Subscription management

### `BotArmyRuntime.Registry`
Lightweight registry that:
- Publishes bot identity and capabilities to a NATS subject
- Queries other bots' capabilities
- Stores bot version and supported subjects

### `BotArmyRuntime.Telemetry`
Telemetry event definitions:
- `[:nats, :publish, :start|:stop|:exception]`
- `[:nats, :request, :start|:stop|:exception]`
- `[:ecto, :query, :start|:stop|:exception]`

Handlers attach to these to emit logs, metrics, traces.

### `BotArmyRuntime.Application`
Supervision tree that:
- Starts NATS connection
- Starts registry
- Initializes telemetry
- Manages lifecycle

## Data Flow

**Publishing a message:**
```
Bot code
  → Gnat.pub(conn, subject, payload)
  → NATS broker receives
  → Other bots subscribed to subject receive
  → Telemetry event [:nats, :publish, :stop]
```

**Request/reply:**
```
Client bot
  → Gnat.request(conn, subject, payload, timeout: 5000)
  → Server bot subscribed to subject receives
  → Server responds via Gnat.pub(conn, msg.reply_to, response)
  → Client receives response
  → Telemetry events emitted
```

**Registry discovery:**
```
Bot A initializes
  → Publishes {bot_name, version, subjects} to bot_army.registry.announce
  → Registry stores in memory
  → Bot B calls bot_army.registry.capabilities.list
  → Gets {Bot A → subjects}
```

## Testing

- **Unit tests**: Mock `Gnat` module, test business logic
- **Integration tests**: Use real NATS (test environment)
- **Test fixtures**: Use `@moduletag :integration` to skip in CI unless requested

Test environment uses NATS on port 4224 (separate cluster).

## Error Handling

- Connection failures: Automatic reconnect with backoff (initial 100ms, max 30s)
- Timeout on request/reply: Return `{:error, :timeout}` to caller
- Health check failures: Emits alert via telemetry, allows graceful shutdown

## Performance Considerations

- Connections are pooled per NATS cluster (typically 1 per bot)
- In-memory registry: O(1) lookups
- Telemetry event emission: Minimal overhead (nanoseconds), can be disabled
- Ecto queries: Database connection pool configured per app
