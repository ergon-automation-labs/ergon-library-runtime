# BotArmyRuntime

The shared persistence and messaging foundation for the Bot Army ecosystem.

BotArmyRuntime provides:

- **Ecto Persistence** - Base repository that all Bot Army services inherit from
- **NATS Integration** - Connection management and publishing utilities for the Bot Army messaging bus
- **Telemetry** - Structured logging and metrics collection
- **Application Supervision** - Shared supervision tree setup

## Quick Start

### Installation

```bash
# Clone the repository
git clone <repo-url> /Users/abby/code/elixir_bots/bot_army_runtime
cd /Users/abby/code/elixir_bots/bot_army_runtime

# Install dependencies
make install

# Run tests
make test
```

### Configuration

Configure in your service's `config.exs`:

```elixir
config :bot_army_runtime, BotArmyRuntime.Ecto.Repo,
  database: "bot_army_dev",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  pool_size: 10

config :bot_army_runtime, :nats,
  servers: [{"localhost", 4222}],
  ping_interval: 30_000
```

### Usage in Services

#### Database Access

```elixir
defmodule BotArmyGTD.Repo do
  use BotArmyRuntime.Ecto.Repo
end

# In your service
result = BotArmyGTD.Repo.all(BotArmyGTD.Task)
```

#### Publishing Messages

```elixir
# Publish a message to NATS
{:ok, "subject"} = BotArmyRuntime.NATS.Publisher.publish(
  "bot.task.created",
  %{"task_id" => 123, "title" => "New Task"}
)

# Request-reply pattern
{:ok, reply} = BotArmyRuntime.NATS.Publisher.request(
  "bot.command.process",
  %{"command" => "status"}
)
```

## Development

### Available Commands

```bash
# Install dependencies
make install

# Compile the project
make compile

# Run tests
make test

# Watch tests during development
make test-watch

# Run linter
make lint

# Format code
make format

# Check formatting without changing files
make format-check

# Run type checker
make dialyze

# Run all checks (compile + lint + test)
make check

# Generate documentation
make docs

# Clean build artifacts
make clean
```

### Running Tests

```bash
# Run all tests
mix test

# Run specific test file
mix test test/bot_army_runtime_test.exs

# Run with coverage
mix test --cover
```

### Database Setup (for local testing)

```bash
# Create test database
make db-setup

# Drop test database
make db-drop
```

## Architecture

### Core Modules

- `BotArmyRuntime` - Main entry point and documentation
- `BotArmyRuntime.Application` - Supervision tree
- `BotArmyRuntime.Ecto.Repo` - Base repository for all services
- `BotArmyRuntime.NATS.Connection` - NATS connection management with reconnection logic
- `BotArmyRuntime.NATS.Publisher` - Message publishing and request-reply patterns
- `BotArmyRuntime.Telemetry` - Logging and metrics collection

### Supervision Tree

```
BotArmyRuntime.Supervisor
├── BotArmyRuntime.Ecto.Repo (database connection pool)
├── BotArmyRuntime.NATS.Connection (message bus connection)
└── BotArmyRuntime.Telemetry (observability handlers)
```

## Related Repositories

- `bot_army_core` - Main Elixir library and NATS decoder
- `bot_army_schemas` - Shared message contracts and envelope definitions
- `bot_army_schemas_<bot>` - Per-bot message schemas
- `bot_army_infra` - Salt states and deployment configuration

## Error Handling

### NATS Connection Errors

NATS connection failures are handled with exponential backoff:

- Initial retry: 1000ms + jitter
- Subsequent retries: base_delay * 2^attempt + jitter
- Max attempts: 10 (configurable)

After max attempts are exceeded, the application is halted.

### Publishing Errors

Publishing errors return `{:error, reason}`:

- `{:error, :not_connected}` - No active NATS connection
- `{:error, {:encode_error, message}}` - JSON encoding failed
- `{:error, {:exception, message}}` - Unexpected exception

All errors are logged for debugging.

## Configuration Examples

### Development

```elixir
config :bot_army_runtime, BotArmyRuntime.Ecto.Repo,
  database: "bot_army_dev",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  pool_size: 10

config :bot_army_runtime, :nats,
  servers: [{"localhost", 4222}],
  ping_interval: 30_000
```

### Production

```elixir
config :bot_army_runtime, BotArmyRuntime.Ecto.Repo,
  database: {:system, "DB_NAME"},
  username: {:system, "DB_USER"},
  password: {:system, "DB_PASSWORD"},
  hostname: {:system, "DB_HOST"},
  port: {:system, "DB_PORT", "5432"},
  pool_size: {:system, "DB_POOL_SIZE", "20"}

config :bot_army_runtime, :nats,
  servers: [
    {"nats1.internal", 4222},
    {"nats2.internal", 4222}
  ],
  ping_interval: 30_000

config :logger,
  backends: [{LoggerJSON.Backends.GoogleCloudLogging, {}}],
  level: :info
```

### Testing

```elixir
config :bot_army_runtime, BotArmyRuntime.Ecto.Repo,
  database: "bot_army_test",
  username: "postgres",
  password: "postgres",
  hostname: "localhost",
  pool: Ecto.Adapters.SQL.Sandbox

config :bot_army_runtime, :nats,
  servers: [{"localhost", 4223}],
  ping_interval: 5000
```

## Deployment

BotArmyRuntime is deployed as part of each Bot Army service. It's not deployed independently.

Services add bot_army_runtime as a dependency and inherit its functionality.

## Contributing

1. Create a feature branch
2. Run `make check` before committing
3. Open a pull request with a clear description

## License

Copyright (c) Bot Army Team. All rights reserved.
