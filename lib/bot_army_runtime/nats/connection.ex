defmodule BotArmyRuntime.NATS.Connection do
  @moduledoc """
  Manages the connection to the NATS message bus with multi-cluster support.

  Responsibilities:
  - Establishing and maintaining a connection to NATS
  - Handling reconnection with exponential backoff (tries all servers in list)
  - Managing the connection state
  - Providing a connection handle for publishers

  ## Configuration

  ### Single Cluster (Default)

  Configure in `config.exs`:

      config :bot_army_runtime, :nats,
        servers: [{"localhost", 4223}],
        ping_interval: 30_000,
        max_reconnect_attempts: 10,
        reconnect_delay_ms: 1000

  ### Multi-Cluster via Environment

  Set `NATS_SERVERS` as space-separated "host:port" list:

      export NATS_SERVERS="localhost:4222 localhost:14223"  # Primary + HA failover
      export NATS_SERVERS="localhost:14224"                  # Background cluster

  Fallback: If `NATS_SERVERS` is not set, uses `NATS_HOST` (default: localhost) and `NATS_PORT` (default: 4223).

  ### Cluster Selection Strategy

  **Hot-path bots (user-facing):**
  ```bash
  export NATS_SERVERS="localhost:4222 localhost:14223"
  ```
  Tries 4222 first, falls back to 14223 if 4222 is down (HA pair).

  **Background bots (long-running):**
  ```bash
  export NATS_SERVERS="localhost:14224"
  ```
  Dedicated background cluster, no failover needed.

  **Dev/test:**
  ```bash
  export NATS_SERVERS="localhost:4223"  # dev
  export NATS_SERVERS="localhost:4224"  # test
  ```

  ## Connection Handle

  The connection is stored in a named GenServer under `:gnat` key.
  Publishers access it via `GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection)`.

  When given multiple servers, Gnat tries them in order and uses the first available one.

  ## Error Handling

  Connection failures are logged and recovery is attempted automatically.
  - If all servers are down, retries with exponential backoff (max 10 attempts by default)
  - If max reconnect attempts are exceeded, the application is halted
  - Status is broadcast via Registry so supervisors can react to connection state changes

  ## Multi-Cluster Failover

  For HA setup (e.g., 4222 + 14223 behind HAProxy), the runtime doesn't need to know about failover—HAProxy handles it at the network level. Just list both servers in NATS_SERVERS and Gnat will try the first one; if it fails, it automatically tries the next.
  """

  use GenServer

  require Logger

  @name __MODULE__
  @default_servers [{"localhost", 4223}]
  @default_ping_interval 30_000
  @default_max_reconnect_attempts 10
  @default_reconnect_delay_ms 1000
  @registry BotArmyRuntime.NATS.ConnectionRegistry

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  def subscribe_to_status do
    Registry.register(@registry, :nats_status, [])
  end

  def unsubscribe_from_status do
    Registry.unregister(@registry, :nats_status)
  end

  @impl true
  def init(opts) do
    nats_env = Application.get_env(:bot_army_runtime, :nats, []) || []

    state = %{
      servers: pick_servers(opts, nats_env),
      ping_interval: pick_opt(opts, nats_env, :ping_interval, @default_ping_interval),
      max_reconnect_attempts:
        pick_opt(opts, nats_env, :max_reconnect_attempts, @default_max_reconnect_attempts),
      reconnect_delay_ms:
        pick_opt(opts, nats_env, :reconnect_delay_ms, @default_reconnect_delay_ms),
      connection: nil,
      reconnect_attempts: 0
    }

    {:ok, state, {:continue, :connect}}
  end

  defp pick_servers(opts, nats_env) do
    case Keyword.get(opts, :servers) do
      nil ->
        case Keyword.get(nats_env, :servers) do
          nil -> @default_servers
          list when is_list(list) and list != [] -> list
          _ -> @default_servers
        end

      list when is_list(list) and list != [] ->
        list

      _ ->
        @default_servers
    end
  end

  defp pick_opt(opts, nats_env, key, default) do
    case Keyword.get(opts, key) do
      nil -> Keyword.get(nats_env, key, default)
      v -> v
    end
  end

  @impl true
  def handle_continue(:connect, state) do
    case connect(state.servers, state.ping_interval) do
      {:ok, conn} ->
        Logger.info("[NATS] Connection established", servers: inspect(state.servers))
        broadcast_status(:connected)
        {:noreply, %{state | connection: conn, reconnect_attempts: 0}}

      {:error, reason} ->
        handle_connection_error(state, reason)
    end
  end

  @impl true
  def handle_call(:get_connection, _from, %{connection: nil} = state) do
    {:reply, {:error, :not_connected}, state}
  end

  @impl true
  def handle_call(:get_connection, _from, state) do
    {:reply, {:ok, state.connection}, state}
  end

  @impl true
  def handle_info({:gnat, :disconnected}, state) do
    Logger.warning("[NATS] Connection lost, attempting reconnect")
    broadcast_status(:disconnected)
    {:ok, new_state} = reconnect(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info({:gnat, :connected}, state) do
    Logger.info("[NATS] Gnat reports connected")
    {:noreply, state}
  end

  @impl true
  def handle_info(:retry_connect, %{connection: nil} = state) do
    case connect(state.servers, state.ping_interval) do
      {:ok, conn} ->
        Logger.info("[NATS] Reconnected successfully")
        broadcast_status(:connected)
        {:noreply, %{state | connection: conn, reconnect_attempts: 0}}

      {:error, reason} ->
        new_attempts = state.reconnect_attempts + 1

        if new_attempts >= state.max_reconnect_attempts do
          Logger.error("[NATS] Max reconnect attempts exceeded, degrading",
            attempts: new_attempts,
            reason: inspect(reason)
          )

          {:noreply, %{state | reconnect_attempts: new_attempts}}
        else
          delay = calculate_backoff(new_attempts, state.reconnect_delay_ms)

          Logger.warning("[NATS] Reconnection failed, retrying in #{delay}ms",
            attempt: new_attempts,
            reason: inspect(reason)
          )

          Process.send_after(self(), :retry_connect, delay)
          {:noreply, %{state | reconnect_attempts: new_attempts}}
        end
    end
  end

  @impl true
  def handle_info(:retry_connect, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp connect(servers, ping_interval) do
    case Gnat.start_link(%{
           servers: servers,
           ping_interval: ping_interval,
           no_responders: true
         }) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_connection_error(state, reason) do
    if state.reconnect_attempts >= state.max_reconnect_attempts do
      Logger.error("[NATS] Max reconnect attempts exceeded, degrading",
        attempts: state.reconnect_attempts,
        reason: inspect(reason)
      )

      {:noreply, state}
    else
      delay = calculate_backoff(state.reconnect_attempts, state.reconnect_delay_ms)

      Logger.warning("[NATS] Connection failed, retrying in #{delay}ms",
        attempt: state.reconnect_attempts + 1,
        max_attempts: state.max_reconnect_attempts,
        reason: inspect(reason)
      )

      Process.send_after(self(), :retry_connect, delay)

      {:noreply, %{state | reconnect_attempts: state.reconnect_attempts + 1}}
    end
  end

  defp reconnect(state) do
    new_attempts = state.reconnect_attempts + 1

    case connect(state.servers, state.ping_interval) do
      {:ok, conn} ->
        Logger.info("[NATS] Reconnected successfully")
        broadcast_status(:connected)
        {:ok, %{state | connection: conn, reconnect_attempts: 0}}

      {:error, reason} ->
        if new_attempts >= state.max_reconnect_attempts do
          Logger.error("[NATS] Max reconnect attempts exceeded",
            attempts: new_attempts,
            reason: inspect(reason)
          )

          {:ok, %{state | reconnect_attempts: new_attempts}}
        else
          delay = calculate_backoff(new_attempts, state.reconnect_delay_ms)

          Logger.warning("[NATS] Reconnection failed, retrying in #{delay}ms",
            attempt: new_attempts,
            reason: inspect(reason)
          )

          Process.send_after(self(), :retry_connect, delay)
          {:ok, %{state | reconnect_attempts: new_attempts}}
        end
    end
  end

  defp broadcast_status(status) do
    Registry.dispatch(@registry, :nats_status, fn entries ->
      for {pid, _} <- entries, do: send(pid, {:nats, status})
    end)

    :telemetry.execute(
      [:nats, :connection, :status],
      %{status: if(status == :connected, do: 1, else: 0)},
      %{status: status}
    )
  end

  @doc false
  defp calculate_backoff(attempt, base_delay) do
    # Exponential backoff with jitter: base_delay * 2^attempt + random jitter
    delay = base_delay * Integer.pow(2, min(attempt, 5))
    jitter = :rand.uniform(1000)
    delay + jitter
  end
end
