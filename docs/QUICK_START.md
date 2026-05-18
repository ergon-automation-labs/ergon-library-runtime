# Quick Start

Get bot_army_runtime up and running in 5 minutes.

## Installation

Add to your `mix.exs`:

```elixir
def deps do
  [
    {:bot_army_runtime, "~> 0.14"}
  ]
end
```

Run `mix deps.get`.

## Basic Setup

1. **Start your app with the runtime supervision tree:**

```elixir
# config/config.exs
config :bot_army_runtime,
  nats_servers: System.get_env("NATS_SERVERS", "nats://localhost:4222")

# lib/my_bot/application.ex
defmodule MyBot.Application do
  use Application

  def start(_type, _args) do
    children = [
      BotArmyRuntime.Application  # Includes NATS, Registry, Telemetry
    ]

    opts = [strategy: :one_for_one, name: MyBot.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
```

2. **Publish a message:**

```elixir
# Get the NATS connection
{:ok, conn} = GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection)

# Publish
Gnat.pub(conn, "my.subject", Jason.encode!(%{"key" => "value"}))
```

3. **Subscribe to messages:**

```elixir
{:ok, sub} = Gnat.sub(conn, self(), "my.subject")

# In handle_info:
def handle_info({:msg, msg}, state) do
  {:ok, payload} = Jason.decode(msg.body)
  # Process payload
  {:noreply, state}
end
```

4. **Request/reply pattern:**

```elixir
# Client: send request
{:ok, response} = Gnat.request(conn, "service.endpoint", Jason.encode!(%{"query" => "data"}), timeout: 5000)

# Server: subscribe and reply
def handle_info({:msg, msg}, state) do
  reply_payload = Jason.encode!(%{"result" => "data"})
  Gnat.pub(conn, msg.reply_to, reply_payload)
  {:noreply, state}
end
```

5. **Register your bot in the service registry:**

```elixir
BotArmyRuntime.Registry.register("my_bot", [
  %{subject: "my.service.request", type: :request_reply},
  %{subject: "my.service.publish", type: :publish}
], "1.0.0")
```

That's it! Your bot can now:
- Publish and subscribe to NATS subjects
- Register itself in the service registry
- Emit telemetry events for observability
- Handle request/reply patterns reliably

## Next Steps

- Read [ARCHITECTURE.md](../ARCHITECTURE.md) for deeper understanding
- Check [API_REFERENCE.md](API_REFERENCE.md) for all available functions
- See [EXAMPLES.md](EXAMPLES.md) for more code samples
