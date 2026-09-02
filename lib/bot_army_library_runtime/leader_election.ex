defmodule BotArmyLibraryRuntime.LeaderElection do
  @moduledoc """
  Distributed leader election for a service that runs on exactly one host at
  a time (e.g. `gtd` on air + mini, one active, one passive).

  Two coordination modes, selected automatically at startup:

  ### KV lease mode (default; requires JetStream)

  Leadership lives in a NATS KV bucket (default `LEADER_ELECTION`, one key
  per service). Every candidate runs the same state machine against it:

    * **Acquire** — CAS-write a lease record `{"holder": node, "renewed_at":
      ..., "expires_at": ...}` using the `Nats-Expected-Last-Subject-Sequence`
      header. The server-side compare-and-swap guarantees exactly one winner
      even if two candidates race. The winning stream sequence is the
      **fencing revision** (`lease_revision` in `get_status/1`).
    * **Renew** — the leader rewrites the lease every `:lease_renew_ms` (CAS
      against its own revision). A confirmed foreign lease → demote.
    * **Failover** — a standby acquires once the lease is expired
      (`:lease_ttl_ms`) AND no fresh foreign heartbeat is flowing. The
      heartbeat gate keeps mixed-version rollouts safe: an old-runtime
      primary (which publishes heartbeats but doesn't write the KV lease)
      still blocks a new-runtime standby from barging in, and a new-runtime
      leader keeps publishing heartbeats so an old-runtime standby stays put.

  Because the lease lives in JetStream, a NATS outage freezes elections
  instead of triggering false promotions — nobody can read or write the lease
  while the broker is down, so roles stay put until it returns. Failover only
  happens when the broker is up but the primary is dead, which is exactly
  when you want it.

  ### Heartbeat lease mode (fallback)

  If JetStream is unavailable (bucket unreadable and uncreatable), the
  process falls back to the legacy heartbeat lease: a `:standby` self-promotes
  after `:heartbeat_timeout_ms` of heartbeat silence, gated by hysteresis
  (`@stale_checks_required` consecutive stale checks) with a jittered check
  interval so two standbys don't promote in lockstep. A `:primary` role bias
  acquires immediately, no heartbeat wait.

  ### Subjects

    * `bot.<service>.leader.heartbeat` — published by the leader every 30s
      regardless of mode.
    * `bot.<service>.leader.force` — publish `{"node": "air" | "mini"}` to
      pin that node as leader, `{"node": null}` to clear. Overrides auto-expire
      after `:force_ttl_ms` (default 15 min) so a lost clear can't strand a
      bad leader forever.
    * `bot.<service>.leader.events` — role transitions are published here
      (`{"node": ..., "role": ..., "reason": ...}`) for ops/health consumers.

  ### Options

      service: "gtd"                      (required)
      node_name: "air"                    (required)
      default_role: :primary | :standby   (required; env-driven per host)
      on_role_change: {Mod, fun, extra}   (required; called as fun.(extra ++ [role]))
      lease_ttl_ms: 45_000                lease expiry window
      lease_renew_ms: 15_000              leader renewal cadence
      lease_probe_ms: 10_000              standby poll cadence
      force_ttl_ms: 900_000               force-override auto-expiry
      kv_bucket: "LEADER_ELECTION"
      heartbeat_timeout_ms: 90_000        fallback heartbeat window
      check_interval_ms: 10_000           base role-check cadence

  `leader?/1` returns the applied role (what callbacks have actually fired
  against), never a live recomputation — consumers and callbacks can't
  disagree. Role transitions fire `on_role_change` immediately (including at
  startup); a callback that raises is retried with backoff instead of
  delaying the role computation itself.
  """

  use GenServer
  require Logger

  alias BotArmyLibraryRuntime.NATS.Connection
  alias BotArmyLibraryRuntime.NATS.Publisher

  @heartbeat_interval_ms 30_000
  @heartbeat_timeout_ms 90_000
  @check_interval_ms 10_000

  # KV lease
  @lease_ttl_ms 45_000
  @lease_probe_ms 10_000
  @acquire_jitter_max_ms 2_000
  @kv_bucket "LEADER_ELECTION"

  # Force override auto-expiry (same philosophy as the army kill switch:
  # a lost "clear" must never strand a bad decision forever)
  @force_ttl_ms 15 * 60_000

  # Heartbeat fallback hysteresis
  @stale_checks_required 2

  # ───────────────────────────────────────────────────────────────────────────
  # Public API (unchanged signatures — consumers depend on these)
  # ───────────────────────────────────────────────────────────────────────────

  def start_link(opts) do
    service = Keyword.fetch!(opts, :service)
    # :name override is a test hook — two nodes of the same service can't
    # share a registered name inside one VM (production runs one per host).
    name = Keyword.get(opts, :name, name_for(service))
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc "Parses a `<SERVICE>_NODE_ROLE` env var (\"primary\"/\"standby\") into `:primary` | `:standby`, defaulting to `:primary`."
  @spec role_from_env(String.t()) :: :primary | :standby
  def role_from_env(env_var) do
    case System.get_env(env_var) do
      "standby" -> :standby
      "primary" -> :primary
      _ -> :primary
    end
  end

  # Returns the APPLIED role (single source of truth — what callbacks fired
  # against), not a live recomputation.
  def leader?(service) do
    GenServer.call(name_for(service), :leader?, 5_000)
  catch
    :exit, _ -> false
  end

  def get_status(service) do
    GenServer.call(name_for(service), :get_status, 5_000)
  catch
    :exit, _ -> %{role: :unknown, is_leader: false, forced_node: nil}
  end

  @doc "Publishes a force-override. `node` is a node-name string (e.g. \"air\") or `nil` to clear. Overrides auto-expire after :force_ttl_ms."
  def force(service, node) when is_binary(node) or is_nil(node) do
    Publisher.publish(force_subject(service), %{"node" => node})
  end

  defp name_for(service), do: :"#{__MODULE__}.#{service}"
  defp heartbeat_subject(service), do: "bot.#{service}.leader.heartbeat"
  defp force_subject(service), do: "bot.#{service}.leader.force"
  defp events_subject(service), do: "bot.#{service}.leader.events"

  # ───────────────────────────────────────────────────────────────────────────
  # GenServer
  # ───────────────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    service = Keyword.fetch!(opts, :service)
    node_name = Keyword.fetch!(opts, :node_name)
    default_role = Keyword.fetch!(opts, :default_role)
    on_role_change = Keyword.fetch!(opts, :on_role_change)

    state = %{
      service: service,
      node_name: node_name,
      default_role: default_role,
      on_role_change: on_role_change,
      lease_ttl_ms: Keyword.get(opts, :lease_ttl_ms, @lease_ttl_ms),
      lease_probe_ms: Keyword.get(opts, :lease_probe_ms, @lease_probe_ms),
      force_ttl_ms: Keyword.get(opts, :force_ttl_ms, @force_ttl_ms),
      kv_bucket: Keyword.get(opts, :kv_bucket, @kv_bucket),
      heartbeat_timeout_ms: Keyword.get(opts, :heartbeat_timeout_ms, @heartbeat_timeout_ms),
      check_interval_ms: Keyword.get(opts, :check_interval_ms, @check_interval_ms),
      # Test hook: where to fetch the Gnat conn from (module or pid answering
      # :get_connection). Defaults to the army Connection.
      connection_server: Keyword.get(opts, :connection_server, Connection),
      mode: nil,
      conn: nil,
      lease_revision: nil,
      last_heartbeat_ms: System.monotonic_time(:millisecond),
      last_heartbeat_node: nil,
      stale_checks: 0,
      forced_node: nil,
      forced_expires_at: nil,
      is_leader: nil,
      pending_callback: nil
    }

    Process.send_after(self(), :setup_nats, 0)
    # Single role-check loop for both modes; the mode is adopted as ticks arrive.
    Process.send_after(self(), :check_role, state.check_interval_ms)

    # Announce the initial role immediately: consumers get a callback with the
    # startup role, and `leader?` is truthful from the first call.
    state = apply_role(state)

    if state.is_leader do
      Process.send_after(self(), :publish_heartbeat, 1_000)
    end

    {:ok, state}
  end

  @impl true
  def handle_call(:leader?, _from, state) do
    {:reply, state.is_leader == true, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply,
     %{
       role: role_atom(state.is_leader == true),
       is_leader: state.is_leader,
       forced_node: state.forced_node,
       last_heartbeat_ms: state.last_heartbeat_ms,
       mode: state.mode,
       lease_revision: state.lease_revision,
       lease_ttl_ms: state.lease_ttl_ms
     }, state}
  end

  @impl true
  def handle_info(:setup_nats, state) do
    case fetch_conn_server(state) do
      :not_started ->
        Process.send_after(self(), :setup_nats, 1_000)
        {:noreply, state}

      conn_server ->
        case GenServer.call(conn_server, :get_connection, 5_000) do
          {:ok, conn} ->
            mode = detect_mode(conn, state)
            {:ok, _} = Gnat.sub(conn, self(), force_subject(state.service))
            # Subscribe to heartbeats in BOTH modes: in KV mode the heartbeat
            # gate is what keeps old-runtime primaries from being displaced.
            {:ok, _} = Gnat.sub(conn, self(), heartbeat_subject(state.service))

            Logger.info("[LeaderElection:#{state.service}] #{state.node_name} on #{mode} mode")

            if mode == :kv do
              # Align with the real lease immediately instead of waiting for
              # the next check tick — the role bias announced at init must
              # not outlive the first look at the lease.
              {:noreply, new_state} = handle_lease_tick(%{state | conn: conn, mode: mode})
              {:noreply, new_state}
            else
              {:noreply, %{state | conn: conn, mode: mode}}
            end

          {:error, reason} ->
            Logger.warning(
              "[LeaderElection:#{state.service}] NATS not ready, retrying in 1s: #{inspect(reason)}"
            )

            Process.send_after(self(), :setup_nats, 1_000)
            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info({:nats, :disconnected}, state) do
    # A broker outage must NOT change roles (nobody can read/write the lease
    # anyway). Wait for the reconnect.
    {:noreply, %{state | conn: nil}}
  end

  @impl true
  def handle_info({:nats, :connected}, state) do
    Process.send_after(self(), :setup_nats, 100)
    {:noreply, state}
  end

  @impl true
  def handle_info({:msg, %{topic: topic} = msg}, state) do
    cond do
      topic == force_subject(state.service) ->
        handle_force_message(msg, state)

      topic == heartbeat_subject(state.service) ->
        {:noreply,
         apply_role(%{
           state
           | last_heartbeat_ms: System.monotonic_time(:millisecond),
             last_heartbeat_node: decode_heartbeat_node(msg.body),
             stale_checks: 0
         })}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:check_role, %{mode: :kv} = state) do
    # One loop: every arrival schedules the next.
    Process.send_after(self(), :check_role, jittered(state.lease_probe_ms))

    if is_nil(state.conn) do
      # Broker down: freeze — no reads, no role changes.
      {:noreply, state}
    else
      handle_lease_tick(state)
    end
  end

  @impl true
  def handle_info(:check_role, state) do
    # Heartbeat-lease fallback (also the pre-setup mode == nil path)
    Process.send_after(self(), :check_role, jittered(state.check_interval_ms))

    stale = heartbeat_stale?(state)
    state = %{state | stale_checks: if(stale, do: state.stale_checks + 1, else: 0)}

    {:noreply, apply_role(state)}
  end

  @impl true
  def handle_info(:publish_heartbeat, %{is_leader: true} = state) do
    # Published in BOTH modes: in KV mode it's the mixed-version bridge (an
    # old-runtime standby stays put as long as it sees our heartbeats).
    Process.send_after(self(), :publish_heartbeat, @heartbeat_interval_ms)

    Publisher.publish(heartbeat_subject(state.service), %{
      "node" => state.node_name,
      "service" => state.service,
      "ts" => DateTime.to_iso8601(DateTime.utc_now())
    })

    {:noreply, state}
  end

  def handle_info(:publish_heartbeat, state), do: {:noreply, state}

  @impl true
  def handle_info(:force_expire, state) do
    if forced_expired?(state) do
      Logger.warning("[LeaderElection:#{state.service}] Force override expired")

      {:noreply,
       apply_role(%{state | forced_node: nil, forced_expires_at: nil, lease_revision: nil})}
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info({:acquire, expected_seq}, state) do
    if state.is_leader do
      {:noreply, state}
    else
      do_acquire(state, expected_seq)
    end
  end

  @impl true
  def handle_info({:retry_callback, role, attempts}, state) when attempts < 3 do
    {:noreply, run_on_role_change(state.on_role_change, role, attempts, state)}
  end

  def handle_info({:retry_callback, role, _attempts}, state) do
    Logger.error(
      "[LeaderElection:#{state.service}] on_role_change callback permanently failed for #{inspect(role)}"
    )

    {:noreply, %{state | pending_callback: nil}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Force override (both modes; TTL-bounded)
  # ───────────────────────────────────────────────────────────────────────────

  defp handle_force_message(msg, state) do
    forced_node =
      case Jason.decode(msg.body) do
        {:ok, %{"node" => node}} -> node
        _ -> state.forced_node
      end

    expires_at =
      if is_binary(forced_node),
        do: System.monotonic_time(:millisecond) + state.force_ttl_ms,
        else: nil

    Logger.warning(
      "[LeaderElection:#{state.service}] Force override #{if forced_node, do: "set", else: "cleared"} on #{state.node_name}: #{inspect(forced_node)}"
    )

    if expires_at do
      Process.send_after(self(), :force_expire, state.force_ttl_ms + 100)
    end

    {:noreply, apply_role(%{state | forced_node: forced_node, forced_expires_at: expires_at})}
  end

  defp forced_expired?(state) do
    state.forced_expires_at &&
      System.monotonic_time(:millisecond) >= state.forced_expires_at
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Mode detection
  # ───────────────────────────────────────────────────────────────────────────

  defp jittered(base) when is_integer(base) and base > 0,
    do: base + :rand.uniform(max(div(base, 5), 1))

  defp jittered(base), do: base

  # KV mode when the lease bucket is readable/creatable; otherwise the legacy
  # heartbeat lease. Never hard-fail on JetStream being unavailable.
  defp detect_mode(conn, state) do
    case lease_get_message(conn, state.kv_bucket, lease_subject(state)) do
      {:ok, _msg} ->
        :kv

      {:error, _reason} ->
        # Either the bucket is missing or the read failed transiently. Try to
        # create it; if the bucket turns out to already exist, that's fine.
        case safe_create_bucket(conn, state.kv_bucket) do
          {:ok, _info} -> :kv
          {:error, reason} -> bucket_probe_fallback(conn, state, reason)
        end
    end
  rescue
    e -> mode_fallback(state, e)
  end

  # create_bucket may have failed because the bucket already exists
  # (acceptable) or because JetStream is unavailable (fall back).
  defp bucket_probe_fallback(conn, state, reason) do
    case lease_get_message(conn, state.kv_bucket, lease_subject(state)) do
      {:ok, _} -> :kv
      {:error, :no_lease} -> :kv
      _ -> mode_fallback(state, reason)
    end
  end

  defp mode_fallback(state, reason) do
    Logger.warning(
      "[LeaderElection:#{state.service}] KV lease unavailable (#{inspect(reason)}), using heartbeat lease"
    )

    :heartbeat
  end

  defp safe_create_bucket(conn, bucket) do
    Gnat.Jetstream.API.KV.create_bucket(conn, bucket, history: 5, storage: :file)
  rescue
    e -> {:error, e}
  catch
    :exit, r -> {:error, r}
  end

  # ───────────────────────────────────────────────────────────────────────────
  # KV lease: read / write (CAS) / tick
  # ───────────────────────────────────────────────────────────────────────────

  defp lease_subject(state), do: lease_key_name(state.kv_bucket, state.service)
  defp lease_key_name(bucket, key), do: "$KV.#{bucket}.#{key}"

  defp lease_get_message(conn, bucket, key) do
    case Gnat.Jetstream.API.Stream.get_message(conn, "KV_#{bucket}", %{last_by_subj: key}) do
      {:ok, %{data: nil}} -> {:error, :no_lease}
      {:ok, msg} -> {:ok, msg}
      {:error, reason} -> {:error, reason}
    end
  rescue
    e -> {:error, e}
  catch
    :exit, r -> {:error, r}
  end

  @doc false
  # Pure decision helper: what should the process do given the observed lease?
  # Returns :renew (lease is ours), :wait (fresh foreign lease), or :promote
  # (no lease / expired lease — the CAS arbitrates among racing candidates).
  def lease_decision(state, lease, now_wall_ms) do
    cond do
      is_nil(lease) -> :promote
      lease["holder"] == state.node_name -> :renew
      lease_fresh?(lease, now_wall_ms, state.lease_ttl_ms) -> :wait
      true -> :promote
    end
  end

  @doc false
  # A lease is fresh if its renewed_at timestamp is within ttl of `now_wall`
  # (wall-clock ms). Unparseable renewed_at counts as stale.
  def lease_fresh?(lease, now_wall_ms, ttl_ms) when is_map(lease) do
    case parse_ts(lease["renewed_at"]) do
      nil -> false
      renewed_ms -> now_wall_ms - renewed_ms < ttl_ms
    end
  end

  def lease_fresh?(_, _, _), do: false

  defp parse_ts(nil), do: nil

  defp parse_ts(iso) when is_binary(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _} -> DateTime.to_unix(dt, :millisecond)
      _ -> nil
    end
  end

  defp parse_ts(_), do: nil

  defp handle_lease_tick(%{is_leader: true} = state) do
    case lease_write(state, state.lease_revision) do
      {:ok, seq} ->
        {:noreply, %{state | lease_revision: seq}}

      {:error, reason} ->
        # Could not renew. Only demote on CONFIRMED foreign ownership — a
        # transient network error must not flip leadership.
        Logger.warning(
          "[LeaderElection:#{state.service}] lease renew failed: #{inspect(reason)}"
        )

        confirm_or_keep(state)
    end
  end

  defp handle_lease_tick(state) do
    case lease_read(state) do
      {:ok, lease, seq} ->
        now_wall = System.system_time(:millisecond)

        case lease_decision(state, lease, now_wall) do
          :renew ->
            # The lease says we hold it (e.g. our revision was lost on reconnect)
            case lease_write(state, seq) do
              {:ok, new_seq} -> {:noreply, promote(state, new_seq)}
              {:error, _} -> {:noreply, demote(state)}
            end

          :wait ->
            {:noreply, state}

          :promote ->
            # Mixed-version gate: a fresh heartbeat from a node other than the
            # expired lease's holder suggests an old-runtime primary that
            # doesn't write the KV lease. Wait for its heartbeats to stop.
            if old_primary_maybe_alive?(state, lease["holder"]) do
              {:noreply, state}
            else
              attempt_acquire(state, seq || 0)
            end
        end

      {:error, :no_lease} ->
        if old_primary_maybe_alive?(state, nil) do
          {:noreply, state}
        else
          attempt_acquire(state, 0)
        end

      {:error, reason} ->
        # Broker trouble: freeze (no role change), probe again on next tick.
        Logger.debug("[LeaderElection:#{state.service}] lease read failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  # Primary bias: primaries attempt acquisition immediately; standbys jitter
  # their attempt so racing candidates don't hammer the CAS at the same
  # instant (the CAS still guarantees exactly one winner either way).
  defp attempt_acquire(state, expected_seq) do
    delay =
      if state.default_role == :primary do
        0
      else
        :rand.uniform(@acquire_jitter_max_ms)
      end

    if delay == 0 do
      do_acquire(state, expected_seq)
    else
      Process.send_after(self(), {:acquire, expected_seq}, delay)
      {:noreply, state}
    end
  end

  defp do_acquire(state, expected_seq) do
    case lease_write(state, expected_seq) do
      {:ok, new_seq} ->
        {:noreply, promote(state, new_seq)}

      {:error, reason} ->
        Logger.debug("[LeaderElection:#{state.service}] acquire failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  defp promote(state, seq) do
    Logger.warning(
      "[LeaderElection:#{state.service}] #{state.node_name} acquired lease (fencing rev #{seq})"
    )

    state = apply_role(%{state | lease_revision: seq})

    if state.is_leader do
      # Kick (or keep) the heartbeat loop — it's the mixed-version bridge.
      Process.send_after(self(), :publish_heartbeat, 500)
    end

    state
  end

  defp demote(state) do
    Logger.warning(
      "[LeaderElection:#{state.service}] #{state.node_name} lost lease (holder changed)"
    )

    apply_role(%{state | lease_revision: nil})
  end

  # Renew failed: re-read the lease and demote only if a fresh foreign lease
  # is confirmed. If we can't read (outage), keep leadership and retry.
  defp confirm_or_keep(state) do
    case lease_read(state) do
      {:ok, lease, _seq} ->
        foreign_fresh? =
          lease["holder"] != state.node_name and
            lease_fresh?(lease, System.system_time(:millisecond), state.lease_ttl_ms)

        if foreign_fresh?, do: {:noreply, demote(state)}, else: {:noreply, state}

      _ ->
        {:noreply, state}
    end
  end

  defp lease_read(state) do
    case lease_get_message(state.conn, state.kv_bucket, lease_subject(state)) do
      {:ok, %{data: data, seq: seq}} ->
        case Jason.decode(data) do
          {:ok, lease} -> {:ok, lease, seq}
          _ -> {:error, :corrupt_lease}
        end

      {:error, :no_lease} ->
        {:error, :no_lease}

      {:error, reason} ->
        # Stream.get_message returns error structs for "no message found" —
        # normalize the common shapes to :no_lease, else propagate.
        if no_message?(reason) do
          {:error, :no_lease}
        else
          {:error, reason}
        end
    end
  end

  defp no_message?(%{response: %{"description" => desc}}) when is_binary(desc),
    do: String.contains?(desc, "No Message")

  defp no_message?(%{response: %{"code" => 404}}), do: true
  defp no_message?(reason) when is_binary(reason), do: String.contains?(reason, "No Message")
  defp no_message?(_), do: false

  # CAS-write the lease with `Nats-Expected-Last-Subject-Sequence`. The server
  # rejects the write if anyone else published since `expected_seq` — that is
  # the whole consensus primitive. Returns {:ok, new_seq} | {:error, reason}.
  defp lease_write(state, expected_seq) do
    payload =
      Jason.encode!(%{
        "holder" => state.node_name,
        "service" => state.service,
        "renewed_at" => DateTime.to_iso8601(DateTime.utc_now()),
        "expires_at" =>
          DateTime.to_iso8601(
            DateTime.add(DateTime.utc_now(), state.lease_ttl_ms, :millisecond)
          )
      })

    headers = [
      {"Nats-Expected-Last-Subject-Sequence", Integer.to_string(expected_seq || 0)}
    ]

    case Gnat.request(state.conn, lease_subject(state), payload,
           headers: headers,
           receive_timeout: 5_000
         ) do
      {:ok, body} ->
        # This gnat version's request/4 returns the full message map; older
        # shapes return the raw body string. Normalize.
        raw = if is_map(body), do: Map.get(body, :body, body), else: body

        case Jason.decode(raw) do
          {:ok, %{"error" => err}} -> {:error, {:cas_rejected, err}}
          {:ok, %{"seq" => seq}} -> {:ok, seq}
          _ -> {:error, {:unexpected_lease_ack, raw}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  rescue
    e -> {:error, e}
  catch
    :exit, r -> {:error, r}
  end

  # Connection fetch: a test hook (pid or module answering :get_connection)
  # or the army Connection by default.
  defp fetch_conn_server(%{connection_server: cs}) when is_pid(cs), do: cs

  defp fetch_conn_server(%{connection_server: cs}) when is_atom(cs) do
    if Process.whereis(cs), do: cs, else: :not_started
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Mixed-version gate
  # ───────────────────────────────────────────────────────────────────────────

  # A heartbeat that is fresh AND was published by a node other than the
  # lease holder suggests an old-runtime primary (heartbeat-only) that may
  # still be alive. With no lease at all, any fresh heartbeat counts. Our
  # own heartbeats (echoed during a brief prior leadership) don't count.
  defp old_primary_maybe_alive?(state, lease_holder) do
    hb = state.last_heartbeat_node

    heartbeat_fresh?(state) and
      not is_nil(hb) and hb != lease_holder and hb != state.node_name
  end

  defp heartbeat_fresh?(state) do
    System.monotonic_time(:millisecond) - state.last_heartbeat_ms <
      state.heartbeat_timeout_ms
  end

  defp decode_heartbeat_node(body) do
    case Jason.decode(body) do
      {:ok, %{"node" => node}} -> node
      _ -> nil
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Role computation & transitions
  # ───────────────────────────────────────────────────────────────────────────

  defp compute_role(state) do
    cond do
      state.forced_node == state.node_name -> :primary
      not is_nil(state.forced_node) -> :standby
      state.mode == :kv -> lease_role(state)
      state.default_role == :primary -> :primary
      promote_after_hysteresis?(state) -> :primary
      true -> :standby
    end
  end

  # In KV mode the lease (held = lease_revision present) is the ONLY source
  # of leadership; default_role is an acquisition-order bias, not a grant.
  defp lease_role(%{lease_revision: revision}) when not is_nil(revision), do: :primary
  defp lease_role(_), do: :standby

  defp promote_after_hysteresis?(state) do
    heartbeat_stale?(state) and state.stale_checks >= @stale_checks_required
  end

  defp heartbeat_stale?(state) do
    System.monotonic_time(:millisecond) - state.last_heartbeat_ms >
      state.heartbeat_timeout_ms
  end

  defp apply_role(state) do
    new_is_leader = compute_role(state) == :primary

    if new_is_leader != state.is_leader do
      new_state = %{state | is_leader: new_is_leader}

      Logger.warning(
        "[LeaderElection:#{state.service}] #{state.node_name} transitioning to #{role_atom(new_is_leader)}"
      )

      publish_event(new_state, "role_change")
      run_on_role_change(new_state.on_role_change, role_atom(new_is_leader), 0, new_state)
    else
      state
    end
  end

  defp role_atom(true), do: :primary
  defp role_atom(false), do: :standby

  defp publish_event(state, reason) do
    Publisher.publish(events_subject(state.service), %{
      "node" => state.node_name,
      "service" => state.service,
      "role" => role_atom(state.is_leader == true),
      "reason" => reason,
      "ts" => DateTime.to_iso8601(DateTime.utc_now())
    })
  end

  # Callback delivery is resilient: the target process may still be starting
  # up. Retry up to 3 times instead of delaying the role computation itself.
  defp run_on_role_change(callback, role, attempt, state) do
    result =
      try do
        {module, function, extra_args} = callback
        apply(module, function, extra_args ++ [role])
      rescue
        error ->
          Logger.error("[LeaderElection] on_role_change callback failed: #{inspect(error)}")
          {:error, :callback_raised}
      end

    case result do
      {:error, :callback_raised} when attempt < 3 ->
        Logger.warning(
          "[LeaderElection] retrying on_role_change (#{role}) in 500ms (attempt #{attempt + 1})"
        )

        Process.send_after(self(), {:retry_callback, role, attempt + 1}, 500)
        %{state | pending_callback: role}

      _ ->
        %{state | pending_callback: nil}
    end
  end
end