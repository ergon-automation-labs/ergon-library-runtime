# Examples

## Publishing a Message

```elixir
defmodule MyBot.Publisher do
  def announce_status do
    {:ok, conn} = GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection)
    
    message = %{
      "bot_name" => "my_bot",
      "status" => "idle",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }
    
    :ok = Gnat.pub(conn, "bot.status.announced", Jason.encode!(message))
  end
end
```

## Subscribing to Messages

```elixir
defmodule MyBot.TaskListener do
  use GenServer

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  def init(_opts) do
    {:ok, conn} = GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection)
    {:ok, _sub} = Gnat.sub(conn, self(), "task.created")
    {:ok, %{}}
  end

  def handle_info({:msg, msg}, state) do
    {:ok, task} = Jason.decode(msg.body)
    IO.puts("New task: #{task["title"]}")
    {:noreply, state}
  end
end
```

## Request/Reply Pattern

**Server (responder):**

```elixir
defmodule MyBot.TaskHandler do
  use GenServer

  def init(_opts) do
    {:ok, conn} = GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection)
    {:ok, _sub} = Gnat.sub(conn, self(), "task.get")
    {:ok, %{conn: conn}}
  end

  def handle_info({:msg, msg}, %{conn: conn} = state) do
    {:ok, request} = Jason.decode(msg.body)
    task_id = request["task_id"]
    
    response = %{
      "task_id" => task_id,
      "title" => "Sample task",
      "status" => "open"
    }
    
    :ok = Gnat.pub(conn, msg.reply_to, Jason.encode!(response))
    {:noreply, state}
  end
end
```

**Client (requester):**

```elixir
defmodule MyBot.TaskClient do
  def get_task(task_id) do
    {:ok, conn} = GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection)
    
    request = %{"task_id" => task_id}
    
    case Gnat.request(conn, "task.get", Jason.encode!(request), receive_timeout: 5000) do
      {:ok, reply} ->
        {:ok, Jason.decode(reply.body)}
      {:error, reason} ->
        {:error, reason}
    end
  end
end
```

## Registering in Service Registry

```elixir
defmodule MyBot.Registry do
  def register do
    subjects = [
      %{
        subject: "my.task.create",
        type: :request_reply,
        description: "Create a new task"
      },
      %{
        subject: "my.task.updated",
        type: :publish,
        description: "Task was updated"
      }
    ]
    
    BotArmyRuntime.Registry.register("my_bot", subjects, "1.0.0")
  end
end
```

## Discovering Other Bots

```elixir
defmodule MyBot.Discovery do
  def find_all_bots do
    case BotArmyRuntime.Registry.list_capabilities(5000) do
      {:ok, capabilities} ->
        Enum.each(capabilities, fn {bot_name, subjects} ->
          IO.puts("Bot: #{bot_name}")
          Enum.each(subjects, fn subject ->
            IO.puts("  - #{subject.subject} (#{subject.type})")
          end)
        end)
      
      {:error, reason} ->
        IO.puts("Error discovering bots: #{inspect(reason)}")
    end
  end
end
```
