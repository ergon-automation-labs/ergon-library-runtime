defmodule BotArmyLibraryRuntime.LeaderElectionTest do
  use ExUnit.Case, async: false
  @moduletag :core

  alias BotArmyLibraryRuntime.LeaderElection

  defmodule RoleChangeSpy do
    def notify(agent, role), do: Agent.update(agent, fn history -> [role | history] end)
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

      # heartbeat_timeout_ms: 50, check_interval_ms: 20 — give it a couple of ticks
      Process.sleep(120)

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
  end

  describe "on_role_change" do
    test "fires only on actual transitions, not on every unrelated 20ms tick", %{agent: agent} do
      start_election("test_callback", [default_role: :standby], agent)
      Process.sleep(120)

      assert LeaderElection.leader?("test_callback") == true
      # 6 ticks elapse in 120ms at a 20ms interval; only the startup announcement
      # and the single real promotion should have fired the callback.
      assert Agent.get(agent, & &1) == [:primary, :standby]
    end
  end
end
