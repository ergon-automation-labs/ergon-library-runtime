# `BotArmyRuntime.NATS.Connection`

Manages the connection to the NATS message bus.

Responsibilities:
- Establishing and maintaining a connection to NATS
- Handling reconnection with exponential backoff
- Managing the connection state
- Providing a connection handle for publishers

## Configuration

Configure in `config.exs`:

    config :bot_army_runtime, :nats,
      servers: [{"localhost", 4222}],
      ping_interval: 30_000,
      max_reconnect_attempts: 10,
      reconnect_delay_ms: 1000

## Connection Handle

The connection is stored in a named GenServer under `:gnat` key.
Publishers access it via `GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection)`.

## Error Handling

Connection failures are logged and recovery is attempted automatically.
If max reconnect attempts are exceeded, the application is halted.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `start_link`

# `subscribe_to_status`

# `unsubscribe_from_status`

---

*Consult [api-reference.md](api-reference.md) for complete listing*
