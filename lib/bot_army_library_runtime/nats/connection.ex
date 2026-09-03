defmodule BotArmyLibraryRuntime.NATS.Connection do
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

      config :bot_army_library_runtime, :nats,
        servers: [{"localhost", 4223}],
        ping_interval: 30_000,
        max_reconnect_attempts: 10,
        reconnect_delay_ms: 1000

  ### Multi-Cluster via Environment

  NOTE: `NATS_SERVERS` is accepted for compatibility, but **only the first
  server is used** — Gnat connections are single-server. Multi-server
  failover must be provided at the network level (e.g. HAProxy) or by
  migrating to Gnat.ConnectionSupervisor.

  Fallback: If `NATS_SERVERS` is not set, uses `NATS_HOST` (default: localhost) and `NATS_PORT` (default: 4223 — the dev broker; production 4222 is set explicitly via plist env).

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
  Publishers access it via `GenServer.call(BotArmyLibraryRuntime.NATS.Connection, :get_connection)`.

  Only the first configured server is used (Gnat connections are single-server).

  ## Error Handling

  Connection failures are logged and recovery is attempted automatically.
  - If all servers are down, retries with exponential backoff (max 10 attempts by default)
  - If max reconnect attempts are exceeded, the application is halted
  - Status is broadcast via Registry so supervisors can react to connection state changes

  ## Multi-Cluster Failover

  For HA setup (e.g., 4222 + 14223 behind HAProxy), the runtime doesn't need to know about failover—HAProxy handles it at the network level. Point NATS_SERVERS at the HAProxy address.
  """

  use GenServer

  require Logger

  @name __MODULE__
  # Fail-safe default: an unconfigured or misconfigured bot lands on the dev
  # broker (4223, idle) — it runs but does not touch production data, which
  # makes the misconfiguration visible instead of silently posting bad data
  # to the production broker. Production access is explicit: deploy plists
  # set NATS_PORT=4222. (Tests stay hermetic via config/test.exs = 42991.)
  # Historical note: 0.14.68 briefly aligned this default with 4222, but that
  # made a missing plist env silently join production; policy since is that
  # only explicit env opts a bot into prod.
  @default_servers [{"localhost", 4223}]
  @default_ping_interval 30_000
  @default_max_reconnect_attempts 10
  @default_reconnect_delay_ms 1000
  @registry BotArmyLibraryRuntime.NATS.ConnectionRegistry

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
    # Trap exits: Gnat.start_link delivers connection failures as exit signals
    # from the linked Gnat process (its init returns {:stop, reason}). Without
    # trapping, one refused TCP connection would kill this GenServer and churn
    # the whole supervision tree.
    Process.flag(:trap_exit, true)

    nats_env = Application.get_env(:bot_army_library_runtime, :nats, []) || []

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
  # The linked Gnat process died (crash, ping timeout, refused connect). Treat
  # it as a disconnect when it's our connection; ignore unrelated exits.
  def handle_info({:EXIT, pid, reason}, %{connection: pid} = state) do
    Logger.warning("[NATS] Linked Gnat connection died: #{inspect(reason)}")
    broadcast_status(:disconnected)
    {:noreply, %{state | connection: nil}}
  end

  def handle_info({:EXIT, _pid, _reason}, state) do
    {:noreply, state}
  end

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
    case gnat_settings(servers, ping_interval) do
      {:ok, settings} ->
        # Gnat's init returns {:stop, reason} when TCP connect fails, which
        # surfaces as an EXIT (not {:error, reason}) in the calling process.
        # Catch it so the Connection GenServer can degrade + retry instead of
        # crashing its supervision tree.
        case safe_gnat_start(settings) do
          {:ok, pid} ->
            # Monitor the Gnat process so we detect crashes and handle reconnection
            Process.monitor(pid)
            {:ok, pid}

          {:error, reason} ->
            {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp safe_gnat_start(settings) do
    Gnat.start_link(settings)
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:gnat_start_exit, reason}}
  end

  # Gnat.start_link/1 takes a SINGLE %{host:, port:} settings map, NOT a
  # :servers list. Passing %{servers: [...]} made Gnat merge the unknown key
  # over its @default_connection_settings and silently connect to
  # localhost:4222 regardless of configuration — which is how test runs
  # (and any misconfigured bot) joined the live army broker.
  # Only the first server is used; a real multi-server failover needs
  # Gnat.ConnectionSupervisor (future work).
  defp gnat_settings([{host, port} | rest], ping_interval)
       when is_integer(port) do
    warn_extra_servers(rest)

    {:ok,
     %{host: host, port: port, ping_interval: ping_interval, no_responders: true}}
  end

  defp gnat_settings([%{host: host, port: port} | rest], ping_interval) do
    warn_extra_servers(rest)

    {:ok,
     %{host: host, port: port, ping_interval: ping_interval, no_responders: true}}
  end

  defp gnat_settings([], _ping_interval), do: {:error, :no_servers}

  defp gnat_settings(other, _ping_interval) do
    Logger.error("[NATS] Unparseable servers config, not connecting",
      servers: inspect(other)
    )

    {:error, {:invalid_servers, other}}
  end

  defp warn_extra_servers([]), do: :ok

  defp warn_extra_servers(rest) do
    Logger.warning(
      "[NATS] #{length(rest) + 1} servers configured but Gnat connects to one; " <>
        "using the first, ignoring: #{inspect(rest)}"
    )
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

  @doc """
  Calculate exponential backoff delay with jitter for retry attempts.

  Used by the connection module and by consumers retrying subscriptions.
  Returns milliseconds to wait before the next attempt.

  ## Parameters
  - `attempt`: 0-indexed retry attempt number
  - `base_delay`: base delay in milliseconds (typically 1000)

  ## Examples
      iex> BotArmyLibraryRuntime.NATS.Connection.calculate_backoff(0, 1000)
      # Returns ~1000-1999ms
      iex> BotArmyLibraryRuntime.NATS.Connection.calculate_backoff(3, 1000)
      # Returns ~9000-9999ms (1000 * 2^3 + jitter)
  """
  def calculate_backoff(attempt, base_delay) do
    # Exponential backoff with jitter: base_delay * 2^min(attempt,5) + random jitter
    delay = base_delay * Integer.pow(2, min(attempt, 5))
    jitter = :rand.uniform(1000)
    delay + jitter
  end
end
