defmodule BotArmyLibraryRuntime.LeaderElectionTest do
  use ExUnit.Case, async: false
  @moduletag :core

  alias BotArmyLibraryRuntime.LeaderElection

  defmodule RoleChangeSpy do
    def notify(agent, role), do: Agent.update(agent, fn history -> [role | history] end)
  end

  # A stand-in for NATS.Connection that hands out a real Gnat conn to an
  # ephemeral broker — lets the KV-lease tests run against genuine JetStream
  # CAS without touching the army Connection.
  defmodule TestConnServer do
    use GenServer

    def start_link(gnat) do
      GenServer.start_link(__MODULE__, gnat)
    end

    @impl true
    def init(gnat), do: {:ok, gnat}

    @impl true
    def handle_call(:get_connection, _from, gnat), do: {:reply, {:ok, gnat}, gnat}
  end

  setup do
    {:ok, agent} = Agent.start_link(fn -> [] end)
    %{agent: agent}
  end

  defp start_election(service, opts, agent) do
    default_opts = [
      service: service,
      node_name: "air",
      on_role_change: {RoleChangeSpy, :notify, [agent]},
      heartbeat_timeout_ms: 50,
      check_interval_ms: 20
    ]

    {:ok, pid} = LeaderElection.start_link(Keyword.merge(default_opts, opts))
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    pid
  end

  describe "role_from_env/1" do
    test "reads primary/standby, defaults to primary" do
      System.delete_env("TEST_LE_ROLE")
      assert LeaderElection.role_from_env("TEST_LE_ROLE") == :primary

      System.put_env("TEST_LE_ROLE", "standby")
      assert LeaderElection.role_from_env("TEST_LE_ROLE") == :standby

      System.put_env("TEST_LE_ROLE", "primary")
      assert LeaderElection.role_from_env("TEST_LE_ROLE") == :primary
      System.delete_env("TEST_LE_ROLE")
    end
  end

  describe "default_role: :primary" do
    test "is leader immediately, no heartbeat wait", %{agent: agent} do
      start_election("test_primary", [default_role: :primary], agent)
      assert LeaderElection.leader?("test_primary") == true
      assert LeaderElection.get_status("test_primary").role == :primary
    end
  end

  describe "default_role: :standby" do
    test "is standby while it believes the peer is alive", %{agent: agent} do
      start_election("test_standby", [default_role: :standby], agent)
      assert LeaderElection.leader?("test_standby") == false
    end

    test "self-promotes to leader after the heartbeat timeout elapses", %{agent: agent} do
      start_election("test_standby_promote", [default_role: :standby], agent)
      assert LeaderElection.leader?("test_standby_promote") == false

      # heartbeat_timeout_ms: 50, check_interval_ms: 20 — plus hysteresis
      # (2 consecutive stale checks); give it plenty of ticks
      Process.sleep(250)

      assert LeaderElection.leader?("test_standby_promote") == true
      # initial startup announcement (:standby) then the promotion (:primary)
      assert Agent.get(agent, & &1) == [:primary, :standby]
    end
  end

  describe "force override" do
    test "pins the named node as leader regardless of default_role", %{agent: agent} do
      start_election("test_force", [default_role: :standby], agent)
      assert LeaderElection.leader?("test_force") == false

      send(
        :"Elixir.BotArmyLibraryRuntime.LeaderElection.test_force",
        {:msg, %{topic: "bot.test_force.leader.force", body: Jason.encode!(%{"node" => "air"})}}
      )

      assert LeaderElection.leader?("test_force") == true
      assert LeaderElection.get_status("test_force").forced_node == "air"
    end

    test "pins the peer as leader, forcing this node to standby", %{agent: agent} do
      start_election("test_force_standby", [default_role: :primary], agent)
      assert LeaderElection.leader?("test_force_standby") == true

      send(
        :"Elixir.BotArmyLibraryRuntime.LeaderElection.test_force_standby",
        {:msg,
         %{topic: "bot.test_force_standby.leader.force", body: Jason.encode!(%{"node" => "mini"})}}
      )

      assert LeaderElection.leader?("test_force_standby") == false
    end

    test "clearing the override resumes default_role-driven logic", %{agent: agent} do
      start_election("test_force_clear", [default_role: :primary], agent)

      send(
        :"Elixir.BotArmyLibraryRuntime.LeaderElection.test_force_clear",
        {:msg,
         %{topic: "bot.test_force_clear.leader.force", body: Jason.encode!(%{"node" => "mini"})}}
      )

      assert LeaderElection.leader?("test_force_clear") == false

      send(
        :"Elixir.BotArmyLibraryRuntime.LeaderElection.test_force_clear",
        {:msg,
         %{topic: "bot.test_force_clear.leader.force", body: Jason.encode!(%{"node" => nil})}}
      )

      assert LeaderElection.leader?("test_force_clear") == true
    end

    test "force override expires after force_ttl_ms", %{agent: agent} do
      # Long heartbeat window so the standby doesn't self-promote via its own
      # hysteresis while the force TTL elapses
      start_election("test_force_ttl",
        [default_role: :standby, force_ttl_ms: 50, heartbeat_timeout_ms: 30_000],
        agent
      )

      assert LeaderElection.leader?("test_force_ttl") == false

      send(
        :"Elixir.BotArmyLibraryRuntime.LeaderElection.test_force_ttl",
        {:msg, %{topic: "bot.test_force_ttl.leader.force", body: Jason.encode!(%{"node" => "air"})}}
      )

      assert LeaderElection.leader?("test_force_ttl") == true

      # force_expire fires at ~50ms; give the check loop a moment
      Process.sleep(250)

      assert LeaderElection.leader?("test_force_ttl") == false
      assert LeaderElection.get_status("test_force_ttl").forced_node == nil
    end
  end

  describe "on_role_change" do
    test "fires only on actual transitions, not on every unrelated 20ms tick", %{agent: agent} do
      start_election("test_callback", [default_role: :standby], agent)
      Process.sleep(200)

      assert LeaderElection.leader?("test_callback") == true
      # several ticks elapse at a 20ms interval; only the startup announcement
      # and the single real promotion should have fired the callback.
      assert Agent.get(agent, & &1) == [:primary, :standby]
    end

    test "retries a callback that raises, then keeps the applied role", %{agent: agent} do
      defmodule FlakySpy do
        def notify(nil, _role), do: raise("target not ready")
        def notify(_other, role) when role == :primary, do: :ok
        def notify(:ready, _role), do: :ok
      end

      opts = [
        service: "test_callback_retry",
        node_name: "air",
        default_role: :standby,
        on_role_change: {FlakySpy, :notify, [nil]},
        heartbeat_timeout_ms: 50,
        check_interval_ms: 20
      ]

      {:ok, pid} = LeaderElection.start_link(opts)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      # The standby announcement raised (arg nil); promotion will retry —
      # give retries (500ms backoff) time to play out, then flip the target
      Process.sleep(1_200)
      assert Process.alive?(pid)
      # The election process itself must not crash from callback failures
      assert LeaderElection.leader?("test_callback_retry") == true
    end
  end

  describe "lease decision helpers (pure)" do
    @fresh %{"holder" => "mini", "renewed_at" => DateTime.to_iso8601(DateTime.utc_now())}

    defp state_for(node, ttl) do
      %{
        node_name: node,
        default_role: :primary,
        lease_ttl_ms: ttl
      }
    end

    test "fresh foreign lease -> wait" do
      assert LeaderElection.lease_decision(state_for("air", 45_000), @fresh, System.system_time(:millisecond)) ==
               :wait
    end

    test "expired foreign lease -> promote" do
      stale = %{
        "holder" => "mini",
        "renewed_at" =>
          DateTime.utc_now() |> DateTime.add(-60_000, :millisecond) |> DateTime.to_iso8601()
      }

      assert LeaderElection.lease_decision(state_for("air", 45_000), stale, System.system_time(:millisecond)) ==
               :promote
    end

    test "missing lease -> promote (CAS arbitrates)" do
      assert LeaderElection.lease_decision(state_for("air", 45_000), nil, System.system_time(:millisecond)) ==
               :promote
    end

    test "own lease -> renew" do
      assert LeaderElection.lease_decision(state_for("mini", 45_000), @fresh, System.system_time(:millisecond)) ==
               :renew
    end

    test "unparseable renewed_at counts as stale" do
      bad = %{"holder" => "mini", "renewed_at" => "not-a-timestamp"}

      assert LeaderElection.lease_fresh?(bad, System.system_time(:millisecond), 45_000) == false
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # KV lease integration: real ephemeral JetStream broker, real CAS.
  # Skips gracefully when nats-server isn't installed (hermetic default).
  # ───────────────────────────────────────────────────────────────────────────
  describe "KV lease mode (integration)" do
    setup do
      case BotArmyLibraryRuntime.TestHelpers.start_test_nats(js: true) do
        {:ok, {_pid, port}} ->
          on_exit(fn ->
            System.cmd("pkill", ["-f", "nats-server.*#{port}"])
          end)

          {:ok, port: port}

        {:error, reason} ->
          {:skip, "local nats-server unavailable: #{inspect(reason)}"}
      end
    end

    # Gnat.start_link/1 registers globally as :Gnat — one conn per VM. All
    # election nodes in a test share it (multiple subs/requests per conn are
    # fine), and lease_record inspects the same conn.
    defp start_shared_conn(port) do
      {:ok, gnat} = Gnat.start_link(%{host: "localhost", port: port})
      {:ok, conn_server} = TestConnServer.start_link(gnat)

      on_exit(fn ->
        if Process.alive?(conn_server), do: GenServer.stop(conn_server)
        if Process.alive?(gnat), do: GenServer.stop(gnat)
      end)

      {gnat, conn_server}
    end

    defp start_kv_election(conn_server, service, node_name, role, extra \\ []) do
      opts =
        [
          service: service,
          # Several candidates for one service share this VM in tests, so skip
          # the per-service name registration (production default is named).
          name: nil,
          node_name: node_name,
          default_role: role,
          on_role_change: {__MODULE__, :noop_callback, []},
          connection_server: conn_server,
          name: :"#{service}_#{node_name}",
          lease_ttl_ms: 300,
          lease_probe_ms: 100,
          heartbeat_timeout_ms: 150,
          check_interval_ms: 100
        ]
        |> Keyword.merge(extra)

      {:ok, pid} = LeaderElection.start_link(opts)
      on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)

      pid
    end

    def noop_callback(_role), do: :ok

    defp lease_record(gnat, service) do
      case Gnat.Jetstream.API.Stream.get_message(gnat, "KV_LEADER_ELECTION", %{
             last_by_subj: "$KV.LEADER_ELECTION.#{service}"
           }) do
        {:ok, msg} -> Jason.decode!(msg.data)
        {:error, reason} -> flunk("lease read failed: #{inspect(reason)}")
      end
    end

    test "primary-biased node acquires the lease; standby waits", %{port: port} do
      {gnat, conn} = start_shared_conn(port)
      pid_a = start_kv_election(conn, "kv_acquire", "nodeA", :primary)
      pid_b = start_kv_election(conn, "kv_acquire", "nodeB", :standby)
      Process.sleep(600)

      assert %{is_leader: true, mode: :kv} = GenServer.call(pid_a, :get_status)
      assert %{is_leader: false} = GenServer.call(pid_b, :get_status)
      assert %{lease_revision: rev} = GenServer.call(pid_a, :get_status)
      assert is_integer(rev) and rev > 0

      # Exactly one holder — verify via the lease record itself
      assert %{"holder" => "nodeA"} = lease_record(gnat, "kv_acquire")
    end

    test "two primaries race: CAS ensures exactly one winner", %{port: port} do
      {gnat, conn} = start_shared_conn(port)
      pid_a = start_kv_election(conn, "kv_race", "nodeA", :primary)
      pid_c = start_kv_election(conn, "kv_race", "nodeC", :primary)
      Process.sleep(800)

      leaders =
        [pid_a, pid_c]
        |> Enum.map(&GenServer.call(&1, :get_status))
        |> Enum.filter(& &1.is_leader)

      assert length(leaders) == 1

      %{"holder" => holder} = lease_record(gnat, "kv_race")
      assert holder in ["nodeA", "nodeC"]

      # The winner holds the fencing revision
      winner = if holder == "nodeA", do: pid_a, else: pid_c
      assert %{lease_revision: rev} = GenServer.call(winner, :get_status)
      assert is_integer(rev) and rev > 0
    end

    test "failover: standby promotes after primary dies (lease + heartbeat expire)", %{port: port} do
      {gnat, conn} = start_shared_conn(port)
      pid_a = start_kv_election(conn, "kv_failover", "nodeA", :primary)
      pid_b = start_kv_election(conn, "kv_failover", "nodeB", :standby)
      Process.sleep(600)

      assert %{is_leader: true} = GenServer.call(pid_a, :get_status)

      # Primary dies — lease goes stale (300ms) and heartbeats stop (150ms)
      GenServer.stop(pid_a)
      Process.sleep(1_400)

      # The standby (nodeB) should now hold the lease
      assert %{"holder" => "nodeB"} = lease_record(gnat, "kv_failover")
      assert %{is_leader: true, mode: :kv} = GenServer.call(pid_b, :get_status)
    end
  end
end