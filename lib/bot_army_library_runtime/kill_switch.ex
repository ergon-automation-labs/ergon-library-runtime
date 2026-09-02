defmodule BotArmyLibraryRuntime.KillSwitch do
  @moduledoc """
  Army-wide kill switch: one command halts all autonomous bot action.

  ## Why

  The army is autonomous enough to need a "stop the world" breaker. When
  something goes wrong — a loop, a bad deploy, runaway LLM spend — an
  operator should be able to halt every bot's outgoing actions with a single
  command, without SSH-ing into hosts or restarting services.

  ## How

  Each bot's runtime starts a `KillSwitch` GenServer that:

  1. Loads persisted state from a local file (survives NATS outages and
     restarts — a halted army stays halted across restarts).
  2. Subscribes to `army.killswitch.control.>` (halt/resume commands) and
     `army.killswitch.state` (convergence broadcasts).
  3. Answers `army.killswitch.get` (queue group `killswitch`) so operators
     can confirm fleet-wide state.

  Enforcement lives in `BotArmyLibraryRuntime.NATS.Publisher`: when halted,
  `publish/3` and `request/3` return `{:error, {:kill_switch_engaged, info}}`
  for non-exempt subjects. Exempt subjects keep observability and control
  alive while the army is halted:

  - `army.killswitch.>`            — the switch itself must always work
  - `bot.army.pulse.>`             — heartbeats (monitoring sees alive-but-halted)
  - `system.health.>` / `*.health` — health checks
  - config extras: `Application.get_env(:bot_army_library_runtime, :kill_switch_allow, [])`
    (prefix-matched subject strings)

  ## Safety

  Halts auto-expire (default 8h) so an accidentally-left halt cannot silently
  strand the army. Pass `expires_in_minutes` to extend, e.g. `"1440"` for 24h.

  ## Control plane

  ```bash
  # Operator (monorepo root):
  make army-halt REASON="runaway loop in factory" TTL_MINUTES=60
  make army-status
  make army-resume

  # Or directly on NATS:
  nats req 'army.killswitch.get' '{}'
  nats pub 'army.killswitch.control.halt' '{"reason":"deploy incident","expires_in_minutes":30}'
  nats pub 'army.killswitch.control.resume' '{}'
  ```

  ## State file

  Default: `/etc/bot_army/killswitch.json` (override via
  `:bot_army_library_runtime, :kill_switch_file`). Written on every state
  change and read on boot. The file is per-host truth; NATS commands keep
  hosts converged.
  """

  use GenServer
  require Logger

  alias BotArmyLibraryRuntime.NATS.Publisher

  @name __MODULE__
  @pstate_key {:bot_army_library_runtime, KillSwitch, :state}

  @control_halt "army.killswitch.control.halt"
  @control_resume "army.killswitch.control.resume"
  @control_state "army.killswitch.state"
  @control_get "army.killswitch.get"
  @queue_group "killswitch"
  @default_ttl_minutes 8 * 60
  @retry_connect_ms 5_000
  @default_state_file "/etc/bot_army/killswitch.json"

  @fresh_state %{
    halted: false,
    reason: nil,
    halted_at: nil,
    expires_at: nil
  }

  # ---------------------------------------------------------------------------
  # Client API (lock-free: reads the :persistent_term mirror)
  # ---------------------------------------------------------------------------

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: @name)
  end

  @doc "Is the army currently halted? (halts auto-expire)"
  @spec halted?() :: boolean()
  def halted? do
    case effective_state() do
      %{halted: true} -> true
      _ -> false
    end
  end

  @doc """
  May the given subject be published right now?

  Returns `:ok` or `{:halted, info}` where info describes the active halt.
  """
  @spec allowed?(String.t()) :: :ok | {:halted, map()}
  def allowed?(subject) when is_binary(subject) do
    if exempt_subject?(subject) do
      :ok
    else
      case effective_state() do
        %{halted: true} = info -> {:halted, Map.take(info, [:reason, :expires_at, :halted_at])}
        _ -> :ok
      end
    end
  end

  @doc "Current (effective) kill switch state."
  @spec state() :: map()
  def state, do: effective_state()

  @doc """
  Force the in-memory mirror back to a fresh (non-halted) state.

  Test utility: the mirror outlives the GenServer (intentionally, so the
  publisher gate is lock-free), so tests must clear it after halting.
  """
  @spec force_fresh_mirror() :: :ok
  def force_fresh_mirror do
    :persistent_term.put(@pstate_key, @fresh_state)
    :ok
  end

  @doc "Apply a halt locally and persist it. Also used by control handling and tests."
  @spec apply_halt(map()) :: map()
  def apply_halt(%{} = params) do
    GenServer.call(@name, {:apply, :halt, params})
  end

  @doc "Apply a resume locally and persist it."
  @spec apply_resume() :: map()
  def apply_resume do
    GenServer.call(@name, {:apply, :resume, %{}})
  end

  @doc "Telemetry + log for a publisher denial. Called by the Publisher gate."
  @spec report_blocked(String.t(), map()) :: :ok
  def report_blocked(subject, info \\ %{}) do
    :telemetry.execute(
      [:bot_army_library_runtime, :kill_switch, :blocked],
      %{count: 1},
      %{subject: subject}
    )

    Logger.warning(
      "[KillSwitch] Blocked publish to #{subject} — army is halted " <>
        "(reason: #{Map.get(info, :reason, "unknown")})"
    )

    :ok
  end

  # ---------------------------------------------------------------------------
  # Subject exemption
  # ---------------------------------------------------------------------------

  @exempt_prefixes ["army.killswitch.", "bot.army.pulse.", "system.health."]

  @doc false
  def exempt_subject?(subject) when is_binary(subject) do
    exempt_prefixes = @exempt_prefixes ++ extra_allow_list()

    Enum.any?(exempt_prefixes, fn pfx -> String.starts_with?(subject, pfx) end) or
      String.ends_with?(subject, ".health")
  end

  defp extra_allow_list do
    Application.get_env(:bot_army_library_runtime, :kill_switch_allow, [])
  end

  # ---------------------------------------------------------------------------
  # GenServer
  # ---------------------------------------------------------------------------

  @impl true
  def init(_opts) do
    state =
      case read_file_state() do
        {:ok, st} -> st
        _ -> @fresh_state
      end

    mirror(state)
    maybe_log_restored(state)

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case get_connection_resilient() do
      {:ok, conn} ->
        BotArmyLibraryRuntime.NATS.Connection.subscribe_to_status()

        {:ok, _sub} =
          Gnat.sub(conn, self(), "army.killswitch.control.>", queue_group: @queue_group)

        {:ok, _sub2} = Gnat.sub(conn, self(), @control_state)

        Logger.info("[KillSwitch] subscribed to army.killswitch.control.> + state broadcast")

        {:noreply, state}

      {:error, _reason} ->
        Logger.warning("[KillSwitch] NATS unavailable, retrying subscription in 5s")
        Process.send_after(self(), :retry_connect, @retry_connect_ms)
        {:noreply, state}
    end
  end

  # The Connection GenServer may not be up (tests, or boot ordering edge);
  # degrade gracefully and retry instead of crashing.
  defp get_connection_resilient do
    GenServer.call(BotArmyLibraryRuntime.NATS.Connection, :get_connection, 3_000)
  catch
    :exit, _ -> {:error, :no_connection_manager}
  end

  @impl true
  def handle_info(:retry_connect, state) do
    {:noreply, state, {:continue, :connect}}
  end

  # Gnat delivers: {:msg, %{topic:, gnat:, body:, reply_to:}}
  @impl true
  def handle_info({:msg, %{topic: topic} = msg}, state) do
    {:noreply, handle_message(topic, msg, state)}
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def handle_call({:apply, :halt, params}, _from, state) do
    {:reply, do_halt(params, state), state}
  end

  def handle_call({:apply, :resume, _}, _from, state) do
    {:reply, do_resume(state), state}
  end

  # ---------------------------------------------------------------------------
  # Message routing
  # ---------------------------------------------------------------------------

  defp handle_message(@control_get, %{reply_to: reply_to} = msg, state)
       when is_binary(reply_to) do
    reply = state |> effective_local() |> public_state() |> Jason.encode!()
    publish_raw(msg.gnat, reply_to, reply)
    state
  end

  defp handle_message(@control_halt, %{body: body} = msg, state) do
    case safe_decode(body) do
      {:ok, params} ->
        new_state = do_halt(params, state)
        publish_state_broadcast(msg[:gnat], new_state)
        new_state

      :error ->
        Logger.error("[KillSwitch] invalid halt payload: #{inspect(body)}")
        state
    end
  end

  defp handle_message(@control_resume, msg, state) do
    new_state = do_resume(state)
    publish_state_broadcast(msg[:gnat], new_state)
    new_state
  end

  defp handle_message(@control_state, %{body: body}, state) do
    # Convergence broadcast from another host/bot: apply locally, no rebroadcast.
    case safe_decode(body) do
      {:ok, remote} ->
        remote_halted = remote["halted"] == true

        cond do
          remote_halted == state.halted ->
            state

          remote_halted ->
            Logger.error(
              "[KillSwitch] converged to HALTED via broadcast — reason: #{remote["reason"]}"
            )

            do_halt(%{"reason" => remote["reason"], "expires_at" => remote["expires_at"]}, state)

          true ->
            do_resume(state)
        end

      :error ->
        state
    end
  end

  defp handle_message(_topic, _msg, state), do: state

  # ---------------------------------------------------------------------------
  # State transitions (called from client API via GenServer, or directly from
  # message handlers with the local state — never call self() from handlers)
  # ---------------------------------------------------------------------------

  defp do_halt(params, _prev_state) do
    now = DateTime.utc_now()

    expires_at = resolve_expires_at(params, now)

    new_state = %{
      halted: true,
      reason: params["reason"] || "unspecified",
      halted_at: DateTime.to_iso8601(now),
      expires_at: expires_at
    }

    persist!(new_state)
    mirror(new_state)

    Logger.error(
      "[KillSwitch] ⛔ ARMY HALTED — reason: #{new_state.reason}" <>
        expiry_suffix(new_state.expires_at)
    )

    :telemetry.execute([:bot_army_library_runtime, :kill_switch, :engaged], %{count: 1}, %{
      reason: new_state.reason
    })

    new_state
  end

  defp do_resume(_prev_state) do
    new_state = @fresh_state

    persist!(new_state)
    mirror(new_state)

    Logger.info("[KillSwitch] ✅ ARMY RESUMED")

    :telemetry.execute([:bot_army_library_runtime, :kill_switch, :released], %{count: 1}, %{})

    new_state
  end

  defp resolve_expires_at(params, now) do
    cond do
      is_binary(params["expires_at"]) ->
        params["expires_at"]

      minutes = parse_minutes(params["expires_in_minutes"]) ->
        DateTime.add(now, minutes * 60, :second) |> DateTime.to_iso8601()

      true ->
        DateTime.add(now, @default_ttl_minutes * 60, :second) |> DateTime.to_iso8601()
    end
  end

  defp parse_minutes(nil), do: nil

  defp parse_minutes(m) when is_integer(m) and m > 0, do: m

  defp parse_minutes(m) when is_binary(m) do
    case Integer.parse(m) do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  defp parse_minutes(_), do: nil

  defp expiry_suffix(t) when is_binary(t), do: " (expires at #{t})"
  defp expiry_suffix(_), do: ""

  defp fresh_state, do: @fresh_state

  # ---------------------------------------------------------------------------
  # Effective state + expiry (reads the mirror; never calls self)
  # ---------------------------------------------------------------------------

  defp effective_state do
    case :persistent_term.get(@pstate_key, fresh_state()) do
      %{halted: true, expires_at: expires} = st when is_binary(expires) ->
        case DateTime.from_iso8601(expires) do
          {:ok, dt, _} ->
            if DateTime.compare(dt, DateTime.utc_now()) == :lt do
              Logger.warning("[KillSwitch] halt expired at #{expires} — auto-resuming")
              apply_resume()
            else
              st
            end

          _ ->
            st
        end

      st ->
        st
    end
  end

  defp effective_local(state), do: state

  defp mirror(state) do
    :persistent_term.put(@pstate_key, state)
  end

  # ---------------------------------------------------------------------------
  # Publishing helpers
  # ---------------------------------------------------------------------------

  # Prefer the raw gnat connection we already hold inside message handlers;
  # fall back to the gated Publisher. Control subjects are always exempt.
  defp publish_state_broadcast(gnat, state)

  defp publish_state_broadcast(nil, state) do
    Publisher.publish(@control_state, public_state(state))
  end

  defp publish_state_broadcast(gnat, state) do
    publish_raw(gnat, @control_state, Jason.encode!(public_state(state)))
  end

  defp publish_raw(nil, _subject, _payload), do: :ok

  defp publish_raw(gnat, subject, payload) do
    Gnat.pub(gnat, subject, payload)
  end

  defp public_state(state) do
    state
    |> Map.drop([:loaded_from_file?])
    |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())
  end

  # ---------------------------------------------------------------------------
  # Persistence
  # ---------------------------------------------------------------------------

  defp state_file do
    Application.get_env(:bot_army_library_runtime, :kill_switch_file, @default_state_file)
  end

  defp read_file_state do
    path = state_file()

    with true <- File.exists?(path),
         {:ok, body} <- File.read(path),
         {:ok, map} <- Jason.decode(body) do
      {:ok,
       %{
         halted: map["halted"] == true,
         reason: map["reason"],
         halted_at: map["halted_at"],
         expires_at: map["expires_at"]
       }}
    else
      _ -> {:error, :no_state}
    end
  end

  defp persist!(state) do
    path = state_file()

    payload =
      state
      |> Map.take([:halted, :reason, :halted_at, :expires_at])
      |> Map.put("updated_at", DateTime.utc_now() |> DateTime.to_iso8601())
      |> Map.put("node", node() |> to_string())

    json = Jason.encode!(payload, pretty: true)

    try do
      File.mkdir_p!(Path.dirname(path))
      File.write!(path, json <> "\n")
      :ok
    rescue
      e ->
        Logger.warning(
          "[KillSwitch] could not persist state file #{path}: #{Exception.message(e)}"
        )

        :error
    end
  end

  defp maybe_log_restored(%{halted: true} = st) do
    Logger.error(
      "[KillSwitch] restored HALTED state from file — reason: #{st.reason}" <>
        expiry_suffix(st.expires_at)
    )
  end

  defp maybe_log_restored(_), do: :ok

  defp safe_decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end

  defp safe_decode(_), do: :error
end