# API Reference

## BotArmyRuntime.NATS.Connection

**GenServer managing NATS connection and subscriptions.**

### `get_connection(timeout \\ 5000)`

Get the current NATS connection.

```elixir
{:ok, conn} = GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 5000)
# conn is a Gnat connection for use with Gnat.pub, Gnat.sub, etc.
```

**Returns:**
- `{:ok, conn}` - Active NATS connection
- `{:error, :timeout}` - Connection unavailable (reconnecting)

### `subscribe_to_status()`

Subscribe to connection status changes.

```elixir
BotArmyRuntime.NATS.Connection.subscribe_to_status()
# Receive messages: {:nats_status, :connected | :disconnected}
```

## BotArmyRuntime.Registry

**Service registry for bot discovery.**

### `register(bot_name, subjects, version)`

Register this bot in the service registry.

```elixir
BotArmyRuntime.Registry.register("my_bot", [
  %{subject: "my.task.create", type: :request_reply},
  %{subject: "my.event.published", type: :publish}
], "1.0.0")
```

**Args:**
- `bot_name` (string) - Unique bot identifier
- `subjects` (list) - List of subject definitions
- `version` (string) - Bot version (semver)

### `list_capabilities(timeout \\ 5000)`

Query all registered bots and their capabilities.

```elixir
{:ok, capabilities} = BotArmyRuntime.Registry.list_capabilities(5000)
# Returns map: %{"bot_a" => [subjects], "bot_b" => [subjects], ...}
```

## BotArmyRuntime.Telemetry

**Telemetry event definitions and metrics.**

### Events Emitted

- `:nats` `:publish` `:start` - When publishing a message
- `:nats` `:publish` `:stop` - After publish completes
- `:nats` `:request` `:start` - When sending a request
- `:nats` `:request` `:stop` - After request completes (success)
- `:nats` `:subscribe` `:start` - When subscribing to a subject
- `:nats` `:subscribe` `:stop` - After subscription created

### Attaching Handlers

```elixir
defmodule MyBot.Telemetry do
  def setup do
    :telemetry.attach("my-handler", [:nats, :publish, :stop], &handle_publish/4, nil)
  end

  def handle_publish(event, measurements, metadata, _config) do
    IO.inspect({event, measurements, metadata})
  end
end
```

## Gnat (NATS Client)

The runtime provides access to the Gnat NATS client library. Key functions:

### `Gnat.pub(conn, subject, payload, options \\ [])`

Publish a message.

```elixir
:ok = Gnat.pub(conn, "my.subject", Jason.encode!(%{"data" => "value"}))
```

### `Gnat.sub(conn, pid, subject, options \\ [])`

Subscribe to a subject. Messages arrive as `{:msg, %Gnat.Message{}}`.

```elixir
{:ok, sub} = Gnat.sub(conn, self(), "my.subject")
```

### `Gnat.request(conn, subject, payload, options \\ [])`

Send a request and wait for reply.

```elixir
{:ok, reply} = Gnat.request(conn, "service.endpoint", payload, receive_timeout: 5000)
```

See [Gnat documentation](https://hexdocs.pm/gnat) for complete API.
