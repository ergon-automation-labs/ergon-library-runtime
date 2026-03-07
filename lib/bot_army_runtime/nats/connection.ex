defmodule BotArmyRuntime.NATS.Connection do
  @moduledoc """
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
  """

  use GenServer

  require Logger

  @name __MODULE__
  @default_servers [{"localhost", 4222}]
  @default_ping_interval 30_000
  @default_max_reconnect_attempts 10
  @default_reconnect_delay_ms 1000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @impl true
  def init(opts) do
    state = %{
      servers: Keyword.get(opts, :servers, @default_servers),
      ping_interval: Keyword.get(opts, :ping_interval, @default_ping_interval),
      max_reconnect_attempts: Keyword.get(opts, :max_reconnect_attempts, @default_max_reconnect_attempts),
      reconnect_delay_ms: Keyword.get(opts, :reconnect_delay_ms, @default_reconnect_delay_ms),
      connection: nil,
      reconnect_attempts: 0
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case connect(state.servers, state.ping_interval) do
      {:ok, conn} ->
        Logger.info("[NATS] Connection established", servers: inspect(state.servers))
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
    {:ok, new_state} = reconnect(state)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  defp connect(servers, ping_interval) do
    case Gnat.start_link(%{
      servers: servers,
      ping_interval: ping_interval
    }) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_connection_error(state, reason) do
    if state.reconnect_attempts >= state.max_reconnect_attempts do
      Logger.error("[NATS] Max reconnect attempts exceeded, shutting down",
        attempts: state.reconnect_attempts,
        reason: inspect(reason)
      )

      {:stop, :max_reconnect_attempts_exceeded, state}
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

  @doc false
  defp calculate_backoff(attempt, base_delay) do
    # Exponential backoff with jitter: base_delay * 2^attempt + random jitter
    delay = base_delay * Integer.pow(2, min(attempt, 5))
    jitter = :rand.uniform(1000)
    delay + jitter
  end
end
