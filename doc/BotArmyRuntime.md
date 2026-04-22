# `BotArmyRuntime`

BotArmyRuntime provides the shared persistence and messaging foundation for the Bot Army ecosystem.

This module serves as the entry point for:

- **Ecto Persistence**: A base `Repo` module that all Bot Army services inherit from for database access
- **NATS Integration**: Connection management and publishing utilities for the Bot Army messaging bus
- **Telemetry**: Structured logging and metrics collection across all services
- **Supervision**: Application supervision tree setup

## Core Components

### Ecto Persistence (`BotArmyRuntime.Ecto.Repo`)
Provides a shared database repository that:
- Manages connections to PostgreSQL
- Handles connection pooling and supervision
- Supports migrations
- Provides runtime configuration for all bot services

### NATS Messaging (`BotArmyRuntime.NATS.Connection` and `BotArmyRuntime.NATS.Publisher`)
Manages connections to the NATS message bus:
- Maintains persistent connections with reconnection logic
- Publishes messages to NATS subjects
- Handles backpressure and connection errors

### Telemetry (`BotArmyRuntime.Telemetry`)
Provides structured observability:
- Logging in JSON format
- Metrics collection hooks
- Performance monitoring

## Configuration

Configure in your application's `config.exs`:

    config :bot_army_runtime, BotArmyRuntime.Ecto.Repo,
      database: "bot_army_dev",
      username: "postgres",
      password: "postgres",
      hostname: "localhost",
      pool_size: 10

    config :bot_army_runtime, :nats,
      servers: [{"localhost", 4222}],
      ping_interval: 30_000

## Usage

Most applications will use this through the generated bot service schemas
(e.g., `bot_army_schemas_gtd`). Direct usage is minimal:

    # Publishing a message
    {:ok, _} = BotArmyRuntime.NATS.Publisher.publish("subject", %{"event" => "data"})

    # Querying the database
    result = BotArmyRuntime.Ecto.Repo.all(MySchema)

# `version`

Returns the version of bot_army_runtime.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
