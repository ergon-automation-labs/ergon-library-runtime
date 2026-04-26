# CLAUDE.md - Development Guidelines

This file provides guidance to Claude Code when working with bot_army_runtime.

## Purpose

**bot_army_runtime** is the shared persistence and messaging foundation for the Bot Army ecosystem. It's a library (not an application) that other services depend on.

### What It Does

- Provides a base Ecto Repo that all services inherit from
- Manages NATS connections with automatic reconnection
- Offers publishing and request-reply messaging utilities
- Sets up telemetry and structured logging

### What It Doesn't Do

- This is NOT a deployable service (it's a library)
- Does NOT contain per-service business logic
- Does NOT handle service-specific schemas (those go in `bot_army_schemas_<service>`)
- Does NOT run jobs or scheduled tasks (services do that)

## Architecture Overview

```
BotArmyRuntime (this repo)
├── Ecto.Repo (base repository)
├── NATS.Connection (connection manager)
├── NATS.Publisher (publishing helper)
└── Telemetry (observability)

Each service (e.g., bot_army_gtd) depends on:
├── bot_army_runtime (this library)
├── bot_army_schemas_gtd (service-specific schemas)
└── Its own business logic
```

## File Organization

```
bot_army_runtime/
├── lib/
│   ├── bot_army_runtime.ex           # Main module
│   └── bot_army_runtime/
│       ├── application.ex             # Supervision tree
│       ├── nats/
│       │   ├── connection.ex          # Connection manager
│       │   └── publisher.ex           # Publishing utilities
│       ├── ecto/
│       │   └── repo.ex                # Base repository
│       └── telemetry.ex               # Observability
├── test/
│   ├── support/
│   │   └── test_helpers.ex            # Test utilities
│   └── bot_army_runtime_test.exs      # Basic tests
├── config/
│   ├── config.exs                     # Shared config
│   └── test.exs                       # Test config
├── mix.exs                            # Project manifest
├── CLAUDE.md                          # This file
└── README.md                          # User documentation
```

## Key Concepts

### 1. Base Repo Pattern

Services define their own Repo that "uses" the base:

```elixir
# In bot_army_gtd
defmodule BotArmyGTD.Repo do
  use BotArmyRuntime.Ecto.Repo
end

# In config
config :bot_army_gtd, BotArmyGTD.Repo,
  database: "bot_army_gtd_dev"
```

When working on Repo:
- Keep it simple and generic
- Don't add service-specific migrations
- Support runtime configuration (DATABASE_URL env var)
- Document what services need to override

### 2. NATS Connection Management

Connection lifecycle:
1. `start_link/1` - Creates GenServer
2. `handle_continue(:connect, state)` - Initiates connection
3. On failure - Retries with exponential backoff
4. On success - Stores connection in state
5. Disconnections - Triggers automatic reconnect

When modifying:
- Don't change the public interface (get_connection API)
- Backoff formula: base_delay * 2^attempt + jitter
- Max 5 exponential steps before capping (attempt 5+)
- Log all connection state changes at appropriate levels

### 3. Publishing Patterns

Two patterns supported:

**Publish (fire-and-forget):**
```elixir
{:ok, subject} = Publisher.publish("subject", payload)
{:error, reason} = Publisher.publish("subject", payload)
```

**Request-reply (synchronous):**
```elixir
{:ok, reply} = Publisher.request("subject", payload, timeout_ms)
{:error, :timeout} = Publisher.request("subject", payload, timeout_ms)
```

When modifying:
- Both patterns must use the same connection
- JSON encoding/decoding must be robust
- All paths must log appropriately
- Timeouts must be configurable

### 4. Telemetry

Three categories of events:

1. **Ecto** - Query timing and errors
2. **NATS** - Publishing and errors
3. **Application** - General logging

When modifying:
- Handlers attach at init
- Log levels should match event severity
- Include enough context for debugging

### 5. Service Discovery Registry

In-memory registry of all active bots and their NATS subjects. Enables service discovery so clients can query what endpoints are available.

**How bots register:**
```elixir
# On startup, call:
subjects = [
  %{subject: "gtd.task.create", type: :request_reply, description: "Create task"},
  %{subject: "gtd.task.list", type: :request_reply, description: "List tasks"}
]
BotArmyRuntime.Registry.register("gtd", subjects)
```

**Public API:**
- `register(bot_name, subjects)` - Register or update a bot's subjects
- `deregister(bot_name)` - Deregister a bot
- `list_bots(filter \\ nil)` - Get all registered bots
- `get_bot(bot_name)` - Get details for a specific bot

**NATS Endpoints:**
- `bot_army.registry.bots.list` - Request/reply to list all bots
- `bot_army.registry.bot.get` - Request/reply to get specific bot (requires `bot_name` in JSON body)

**When modifying:**
- Heartbeat detection runs every 30s, removes bots offline for 40s+
- Each subject must have: subject, type (:request_reply or :subscribe), and optional description/timeout_ms
- Responses follow standard JSON envelope: `{ok: bool, ...data, timestamp: ISO8601}`
- All bots should register in their Consumer or HealthResponder on NATS connection

## Development Commands

```bash
# Install deps
mix deps.get

# Compile
mix compile

# Run tests (requires PostgreSQL + nats-server)
mix test

# Format code
mix format

# Lint
mix credo

# Type check
mix dialyzer

# All checks
make check
```

## Testing Strategy

Tests are organized by module:

- `test_helpers.ex` - NATS and DB utilities
- `bot_army_runtime_test.exs` - Basic sanity checks

For integration tests:
- Use `BotArmyRuntime.TestHelpers.with_test_nats/1` for NATS
- Use Ecto.Adapters.SQL.Sandbox for database
- Keep tests isolated and repeatable

## Configuration Hierarchy

### Shared (config/config.exs)
Default values for all environments:
- Pool size
- NATS servers
- Logger format

### Environment-specific (config/test.exs)
Overrides for testing:
- Test database
- Test NATS port
- Sandbox adapter
- Lower log level

### Runtime (env vars)
Highest priority for production:
- DATABASE_URL - Full database connection string
- Environment-specific overrides

## Common Patterns

### Adding a New Module

1. Create file in `lib/bot_army_runtime/`
2. Document with @moduledoc
3. Add tests in `test/`
4. Include error handling
5. Update CLAUDE.md if it's a new concept

### Modifying the Repo

Remember:
- Services inherit from this Repo
- Changes affect all services
- Keep it generic (no service-specific code)
- Document new configuration options

### Changing NATS Connection Behavior

1. Update connection logic in `nats/connection.ex`
2. Update publisher to handle new behavior
3. Add tests for the new behavior
4. Update README with new configuration if needed

## Rules

1. **No Service Code** - Don't add service-specific logic here
2. **Generic First** - Anything added must work for all services
3. **Backward Compatible** - Don't break existing services
4. **Documented** - All public functions must have @doc
5. **Tested** - Add tests for new functionality
6. **Logged** - Significant operations should be logged

## Debugging Tips

### Connection Issues

Check logs for NATS connection errors:
```
[NATS] Connection failed, retrying in Xms
[NATS] Connection established
[NATS] Connection lost, attempting reconnect
```

### Publishing Failures

Check these logs:
```
[NATS] Failed to publish message: subject=X reason=Y
[NATS] Failed to encode payload: error=Z
```

### Repo Issues

Database errors in logs:
```
[Ecto] Slow query detected
[Ecto] Query failed
```

## Related Documentation

- `../README.md` - User documentation
- `../../../bot_army_schemas/CLAUDE.md` - Schema guidelines
- `../bot_army_core` - Uses this repo's Repo and NATS utilities
