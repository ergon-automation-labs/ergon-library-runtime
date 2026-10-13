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

  Fallback: If `NATS_SERVERS` is not set, uses `NATS_HOST` (default: localhost)
  and `NATS_PORT` (default: 4223 — the dev broker; production 4222 is set
  explicitly via plist env).

  ### Resolution Order (runtime)

  Servers resolve, in order: the `start_link` `:servers` option → the
  `:nats, :servers` app config → the environment → `localhost:4223`.

  **The environment step is runtime-only, and `config/config.exs` is not.** A
  release evaluates `config/config.exs` when it is *built*, so the
  `NATS_SERVERS`/`NATS_HOST`/`NATS_PORT` reads in that file bake whatever the
  build machine's environment happened to be. A release that takes its
  `:nats, :servers` from that baked config therefore ignores its plist's
  `NATS_PORT` and sits on the build-time broker (4223) however the deployment is
  configured — the exact failure mode that left a deployed bot silent while its
  plist said 4222.

  A deployed bot must either:

  1. set the `:nats` block in its own `config/runtime.exs` (evaluated at boot),
     which is the fleet convention — see `bot_army_gtd/config/runtime.exs`; or
  2. leave `:servers` unset, so this module's runtime fallback reads the env.

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

  ## Subscriptions that survive a reconnect

  `subscribe/1` is the supported way for a process to declare the subjects it
  answers. It subscribes now (if the link is up) **and** re-subscribes them on
  every link this module starts, so a responder cannot go dark because the
  Gnat process was replaced underneath it.

  This exists because `Gnat.sub(conn, self(), subject)` is not durable: the
  subscription belongs to the Gnat connection process, so when that process
  dies and the Connection starts a new one, every raw `Gnat.sub` sid goes with
  it. The pid holding them stays alive and looks healthy while its subjects
  silently stop answering. Measured on `claude_bridge` (2026-10-12): one Gnat
  crash took 28 declared bridge subjects dark for 1d19h, including the
  documented `bridge.chat` and `system.right_turns.log`.

  A responder that uses `subscribe/1` needs no `{:nats, :connected}` handler of
  its own — the Connection re-subscribes on its behalf.

      BotArmyLibraryRuntime.NATS.Connection.subscribe(["bridge.quest.>"])

  Registering via `subscribe_to_status/0` is the older, narrower API: it only
  delivers `{:nats, status}` messages and leaves the re-subscription to the
  caller. Prefer `subscribe/1`.

  ## Publishing and unsubscribing that cannot take the daemon down

  `publish/4`, `unsub/3` and `safe_sub/3` exist because gnat 1.13 matches its
  socket writes as `{:ok, _}` inside its own `handle_call/3`: a write over a
  socket the broker just dropped returns `{:error, :einval}` and **crashes the
  Gnat connection process**, taking every caller blocked in `GenServer.call/3`
  with it. Each of these asks whether the connection is alive and catches the
  exit, so a dead socket is a returned error. Prefer them over bare `Gnat.pub`,
  `Gnat.unsub` and `Gnat.sub`.

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
  @default_port 4223
  @default_servers [{"localhost", @default_port}]
  @default_ping_interval 30_000
  @default_max_reconnect_attempts 10
  @default_reconnect_delay_ms 1000
  # Once the attempt budget is spent the Connection keeps trying at this slow
  # fixed interval. Giving up permanently means a bot that outlived a
  # multi-minute broker outage never rejoins without a restart — it looks alive
  # and fails every publish with :not_connected.
  @degraded_retry_ms 30_000
  @registry BotArmyLibraryRuntime.NATS.ConnectionRegistry

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, @name))
  end

  @doc """
  Declare the `subjects` the calling process answers, and keep answering them
  across reconnects.

  Registers the subjects against the calling pid and asks the Connection to
  subscribe them. Every link started by the Connection re-subscribes the whole
  registry, so a replaced Gnat process no longer takes a responder's subjects
  with it. Registration is what survives, not the sid: a responder may call this
  before the link is up, and the subjects are subscribed when it comes up.

  The messages still arrive as `{:msg, msg}`, unchanged.

  Returns `:ok`. It never fails on "not connected" — not being connected yet is
  not an error, it is the case this exists for.

  ## Examples

      BotArmyLibraryRuntime.NATS.Connection.subscribe(["bridge.timer.>"])
  """
  @spec subscribe([String.t()], GenServer.name()) :: :ok
  def subscribe(subjects, connection \\ @name) when is_list(subjects) do
    subjects = Enum.map(subjects, &to_string/1)
    Registry.register(@registry, :nats_resubscribe, subjects)

    try do
      GenServer.call(connection, {:subscribe, self(), subjects})
    catch
      :exit, {:noproc, _} ->
        # No Connection process (not started, or restarting). The registration
        # stands, so the next connect subscribes these subjects anyway.
        :ok

      :exit, reason ->
        Logger.warning("[NATS] subscribe/1 could not reach the Connection: #{inspect(reason)}")
        :ok
    end
  end

  @doc """
  Publish a message without letting a dying link take the caller with it.

  `Gnat.pub/4` sends the payload and then matches the socket write as `{:ok, _}`
  **inside its own `handle_call/3`** (gnat 1.13.1, `lib/gnat.ex:492`, after
  `socket_write/2`). A broker that has just dropped the socket makes that write
  return `{:error, :einval}`, so Gnat's connection process crashes on the
  match — and every caller blocked in `GenServer.call/3` exits with it. Nothing
  about a send over a dead socket is worth a terminated daemon; this wrapper
  turns both the error and the exit into a returned value.

  Returns `:ok`, or `{:error, reason}` where `reason` is `:not_connected` (the
  pid is gone), `{:exit, _}` (Gnat died mid-call), or whatever the socket
  reported. A publisher that does not care can ignore the error; a publisher
  that does care no longer has to survive an exit to find out.

  ## Examples

      BotArmyLibraryRuntime.NATS.Connection.publish(conn, "bridge.pulse", "{}")
  """
  @spec publish(pid() | atom() | nil, String.t(), binary(), keyword()) :: :ok | {:error, term()}
  def publish(conn, subject, payload, opts \\ []) do
    if connection_alive?(conn) do
      case Gnat.pub(conn, subject, payload, opts) do
        :ok -> :ok
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected, other}}
      end
    else
      {:error, :not_connected}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc """
  Unsubscribe without letting a dying link take the caller with it.

  Same defect as `publish/4`, reached from the other side: a responder's
  `{:nats, :disconnected}` handler calling `Gnat.unsub/3` on the Gnat process
  that just died gets `** (EXIT) no process`. Three of those inside the default
  supervisor budget is enough to terminate the whole application.

  Returns `:ok` or `{:error, reason}`. An unsubscribe that was never going to
  happen is not worth a crash — the subscription is gone either way, because the
  connection it belonged to is.
  """
  @spec unsub(pid() | atom() | nil, non_neg_integer() | String.t(), keyword()) ::
          :ok | {:error, term()}
  def unsub(conn, sid, opts \\ []) do
    if connection_alive?(conn) do
      case Gnat.unsub(conn, sid, opts) do
        :ok -> :ok
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected, other}}
      end
    else
      {:error, :not_connected}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  @doc """
  Subscribe a pid to one subject, tolerating a dying link.

  The same match that makes `publish/4` necessary is in gnat's `{:sub, …}`
  clause (`:ok = socket_write(state, sub)`), so a subscribe over a dead socket
  crashes the connection too. Prefer `subscribe/1` — it is durable, because the
  registration survives the link — and reach for this only when a raw sid is
  genuinely needed.

  Returns `{:ok, sid}` or `{:error, reason}`; the shape is `Gnat.sub/3`'s, minus
  the exit.
  """
  @spec safe_sub(pid() | atom() | nil, pid(), String.t()) :: {:ok, term()} | {:error, term()}
  def safe_sub(conn, pid, subject) do
    if connection_alive?(conn) do
      case Gnat.sub(conn, pid, subject) do
        {:ok, sid} -> {:ok, sid}
        {:error, reason} -> {:error, reason}
        other -> {:error, {:unexpected, other}}
      end
    else
      {:error, :not_connected}
    end
  rescue
    error -> {:error, error}
  catch
    :exit, reason -> {:error, {:exit, reason}}
  end

  defp connection_alive?(nil), do: false
  defp connection_alive?(pid) when is_pid(pid), do: Process.alive?(pid)
  defp connection_alive?(name) when is_atom(name), do: Process.whereis(name) != nil
  defp connection_alive?(_other), do: false

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
      # Injectable transport (tests drive the link lifecycle without a broker).
      gnat_starter:
        Keyword.get(
          opts,
          :gnat_starter,
          Application.get_env(:bot_army_library_runtime, :gnat_starter, &Gnat.start_link/1)
        ),
      # Injectable subscription transport, for the same reason: re-subscribing
      # is the behaviour under test, and it must be observable without a broker.
      gnat_sub:
        Keyword.get(
          opts,
          :gnat_sub,
          Application.get_env(:bot_army_library_runtime, :gnat_sub, &Gnat.sub/3)
        ),
      connection: nil,
      reconnect_attempts: 0
    }

    {:ok, state, {:continue, :connect}}
  end

  @doc false
  # Resolution order: explicit opts -> app config -> environment -> default.
  #
  # The environment step is deliberately last so it can never override a
  # deliberate configuration, and it is read here — at runtime — because
  # config/config.exs is evaluated when the release is BUILT. See the moduledoc
  # section "Resolution Order (runtime)".
  def pick_servers(opts, nats_env) do
    explicit_servers(Keyword.get(opts, :servers)) ||
      explicit_servers(Keyword.get(nats_env, :servers)) ||
      servers_from_env() ||
      @default_servers
  end

  defp explicit_servers(list) when is_list(list) and list != [], do: list
  defp explicit_servers(_other), do: nil

  @doc false
  # `NATS_SERVERS` (space- or comma-separated; only the first entry is used,
  # because Gnat is single-server), else `NATS_HOST`/`NATS_PORT`. Returns nil
  # when the environment names no broker, so the caller can fall through to the
  # built-in default.
  def servers_from_env do
    case server_from_env() do
      {host, port} -> [{host, port}]
      nil -> nil
    end
  end

  defp server_from_env do
    case System.get_env("NATS_SERVERS") do
      value when is_binary(value) ->
        case value |> String.split([",", " "], trim: true) do
          [first | _] -> parse_server(first) || host_port_from_env()
          [] -> host_port_from_env()
        end

      _ ->
        host_port_from_env()
    end
  end

  defp host_port_from_env do
    host = System.get_env("NATS_HOST")
    port = System.get_env("NATS_PORT")

    cond do
      is_binary(host) and host != "" -> {host, env_port()}
      is_binary(port) and port != "" -> {"localhost", env_port()}
      true -> nil
    end
  end

  defp env_port do
    case System.get_env("NATS_PORT") do
      nil ->
        @default_port

      value ->
        case Integer.parse(value) do
          {port, ""} when port > 0 -> port
          _ -> @default_port
        end
    end
  end

  defp parse_server(spec) do
    spec = spec |> String.trim() |> String.replace_prefix("nats://", "")

    case String.split(spec, ":", parts: 2) do
      [host, ""] when host != "" ->
        {host, env_port()}

      [host, port] when host != "" ->
        case Integer.parse(port) do
          {port_number, ""} -> {host, port_number}
          _ -> nil
        end

      [host] when host != "" ->
        {host, env_port()}

      _ ->
        nil
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
    case connect(state) do
      {:ok, conn} ->
        Logger.info("[NATS] Connection established", servers: inspect(state.servers))
        resubscribe_all(conn, state.gnat_sub)
        broadcast_status(:connected)
        {:noreply, %{state | connection: conn, reconnect_attempts: 0}}

      {:error, reason} ->
        {:noreply, retry_later(state, reason)}
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

  # A responder declaring its subjects. Registering is what makes them durable;
  # this call only saves it the wait until the next connect.
  @impl true
  def handle_call({:subscribe, _pid, _subjects}, _from, %{connection: nil} = state) do
    {:reply, :ok, state}
  end

  def handle_call({:subscribe, pid, subjects}, _from, state) do
    subscribe_each(state.connection, pid, subjects, state.gnat_sub)
    {:reply, :ok, state}
  end

  @impl true
  # The linked Gnat process died (crash, ping timeout, refused connect). Treat
  # it as a disconnect when it's our connection; ignore unrelated exits.
  def handle_info({:EXIT, pid, reason}, %{connection: pid} = state) do
    Logger.warning("[NATS] Linked Gnat connection died: #{inspect(reason)}")
    broadcast_status(:disconnected)
    # An exited Gnat never sends {:gnat, :disconnected}, so the EXIT itself has
    # to schedule the recovery. Clearing the slot without a retry left the
    # Connection nil forever while the bot looked healthy (reconnect_attempts: 0)
    # and every publish failed with a bare :not_connected until a restart.
    {:noreply, retry_later(%{state | connection: nil}, {:connection_died, reason})}
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
    case connect(state) do
      {:ok, conn} ->
        Logger.info("[NATS] Reconnected successfully")
        resubscribe_all(conn, state.gnat_sub)
        broadcast_status(:connected)
        {:noreply, %{state | connection: conn, reconnect_attempts: 0}}

      {:error, reason} ->
        {:noreply, retry_later(state, reason)}
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

  defp connect(%{servers: servers, ping_interval: ping_interval, gnat_starter: starter}) do
    case gnat_settings(servers, ping_interval) do
      {:ok, settings} ->
        # Gnat's init returns {:stop, reason} when TCP connect fails, which
        # surfaces as an EXIT (not {:error, reason}) in the calling process.
        # Catch it so the Connection GenServer can degrade + retry instead of
        # crashing its supervision tree.
        case safe_gnat_start(settings, starter) do
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

  defp safe_gnat_start(settings, starter) do
    starter.(settings)
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

    {:ok, %{host: host, port: port, ping_interval: ping_interval, no_responders: true}}
  end

  defp gnat_settings([%{host: host, port: port} | rest], ping_interval) do
    warn_extra_servers(rest)

    {:ok, %{host: host, port: port, ping_interval: ping_interval, no_responders: true}}
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

  # One retry policy for every path that lost a connection: the initial connect
  # failing, a failed reconnect, a Gnat EXIT, and {:gnat, :disconnected}. Inside
  # the attempt budget it backs off with jitter; past it, it keeps trying at the
  # slow degraded interval. `reconnect_attempts` is reset by the next successful
  # connect, so a recovered link reclaims the fast budget.
  defp retry_later(state, reason) do
    attempts = state.reconnect_attempts + 1
    delay = next_retry_delay(attempts, state.max_reconnect_attempts, state.reconnect_delay_ms)

    if attempts >= state.max_reconnect_attempts do
      Logger.error("[NATS] Max reconnect attempts exceeded, retrying every #{delay}ms",
        attempts: attempts,
        reason: inspect(reason)
      )
    else
      Logger.warning("[NATS] Reconnection failed, retrying in #{delay}ms",
        attempt: attempts,
        max_attempts: state.max_reconnect_attempts,
        reason: inspect(reason)
      )
    end

    Process.send_after(self(), :retry_connect, delay)
    %{state | reconnect_attempts: attempts}
  end

  defp reconnect(state) do
    case connect(state) do
      {:ok, conn} ->
        Logger.info("[NATS] Reconnected successfully")
        resubscribe_all(conn, state.gnat_sub)
        broadcast_status(:connected)
        {:ok, %{state | connection: conn, reconnect_attempts: 0}}

      {:error, reason} ->
        {:ok, retry_later(state, reason)}
    end
  end

  # Everything that called subscribe/1, on a link this module just started. The
  # registry is keyed by pid and drops entries when a process dies, so a
  # responder that restarted is simply absent — it re-registers on its own
  # connect. Called BEFORE broadcast_status/1 so a subscriber that also has a
  # {:nats, :connected} handler never gets there first and double-subscribes.
  defp resubscribe_all(conn, sub_fun) do
    Registry.dispatch(@registry, :nats_resubscribe, fn entries ->
      for {pid, subjects} <- entries do
        subscribe_each(conn, pid, subjects, sub_fun)
      end
    end)
  end

  defp subscribe_each(conn, pid, subjects, sub_fun) do
    for subject <- subjects do
      subscribe_one(conn, pid, subject, sub_fun)
    end

    :ok
  end

  # A subscription attempt must never take the Connection down: Gnat.sub on a
  # dying link exits, and an uncaught exit here would kill the process that is
  # meant to be reconnecting.
  defp subscribe_one(conn, pid, subject, sub_fun) do
    case sub_fun.(conn, pid, subject) do
      {:ok, _sid} ->
        Logger.debug("[NATS] Subscribed #{inspect(pid)} to #{subject}")
        :ok

      {:error, reason} ->
        Logger.warning("[NATS] Subscribe failed for #{subject}: #{inspect(reason)}")
        :error
    end
  rescue
    error ->
      Logger.warning("[NATS] Subscribe raised for #{subject}: #{inspect(error)}")
      :error
  catch
    :exit, reason ->
      Logger.warning("[NATS] Subscribe exited for #{subject}: #{inspect(reason)}")
      :error
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
  Delay before the next reconnect attempt.

  Exponential backoff with jitter while inside the attempt budget; a slow fixed
  interval once the budget is spent. Retrying keeps going forever on purpose —
  the next successful connect resets the budget, and a bot that never retries is
  a bot that silently stays off the bus.

  ## Examples
      iex> BotArmyLibraryRuntime.NATS.Connection.next_retry_delay(99, 10, 1000)
      30000
      iex> BotArmyLibraryRuntime.NATS.Connection.next_retry_delay(0, 10, 1000) in 1000..2000
      true
  """
  def next_retry_delay(attempts, max_attempts, base_delay) do
    if attempts >= max_attempts do
      @degraded_retry_ms
    else
      calculate_backoff(attempts, base_delay)
    end
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
