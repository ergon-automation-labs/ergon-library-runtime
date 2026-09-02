defmodule BotArmyLibraryRuntime.KillSwitchTest do
  use ExUnit.Case, async: false

  alias BotArmyLibraryRuntime.KillSwitch
  alias BotArmyLibraryRuntime.NATS.Publisher

  @moduletag :kill_switch

  setup do
    # Point the state file at a tmp dir and start a fresh KillSwitch per test.
    tmp = Path.join(System.tmp_dir!(), "killswitch-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:bot_army_library_runtime, :kill_switch_file, Path.join(tmp, "ks.json"))
    Application.put_env(:bot_army_library_runtime, :kill_switch_allow, [])

    # In the full suite, some earlier test may boot the whole application,
    # which already runs a named KillSwitch — reuse it in that case.
    case Process.whereis(KillSwitch) do
      nil -> start_supervised!({KillSwitch, []})
      _pid -> KillSwitch.apply_resume()
    end

    on_exit(fn ->
      Application.delete_env(:bot_army_library_runtime, :kill_switch_file)
      Application.delete_env(:bot_army_library_runtime, :kill_switch_allow)
      File.rm_rf!(tmp)
      # The :persistent_term mirror outlives the GenServer and is global to the
      # VM — clear it so parallel/async test files aren't gated by our halts.
      KillSwitch.force_fresh_mirror()
    end)

    :ok
  end

  describe "exempt_subject?/1" do
    test "control plane subjects are always exempt" do
      assert KillSwitch.exempt_subject?("army.killswitch.control.halt")
      assert KillSwitch.exempt_subject?("army.killswitch.state")
      assert KillSwitch.exempt_subject?("army.killswitch.get")
    end

    test "pulse and health subjects are exempt" do
      assert KillSwitch.exempt_subject?("bot.army.pulse.gtd_bot")
      assert KillSwitch.exempt_subject?("system.health.check")
      assert KillSwitch.exempt_subject?("bot.synapse.health")
      assert KillSwitch.exempt_subject?("bot.gtd.health")
    end

    test "normal action subjects are not exempt" do
      refute KillSwitch.exempt_subject?("gtd.task.create")
      refute KillSwitch.exempt_subject?("bridge.chat")
      refute KillSwitch.exempt_subject?("llm.chain.run")
    end

    test "config allow-list adds prefix exemptions" do
      Application.put_env(:bot_army_library_runtime, :kill_switch_allow, ["gtd.task.list"])
      assert KillSwitch.exempt_subject?("gtd.task.list")
      refute KillSwitch.exempt_subject?("gtd.task.create")
    end
  end

  describe "when not halted" do
    test "all subjects are allowed" do
      assert KillSwitch.allowed?("gtd.task.create") == :ok
      assert KillSwitch.allowed?("bridge.chat") == :ok
      refute KillSwitch.halted?()
    end
  end

  describe "when halted" do
    setup do
      KillSwitch.apply_halt(%{"reason" => "test incident", "expires_in_minutes" => 5})
      :ok
    end

    test "action subjects are blocked with info" do
      assert {:halted, info} = KillSwitch.allowed?("gtd.task.create")
      assert info.reason == "test incident"
      assert info.expires_at
      assert KillSwitch.halted?()
    end

    test "exempt subjects still pass" do
      assert KillSwitch.allowed?("army.killswitch.control.resume") == :ok
      assert KillSwitch.allowed?("bot.army.pulse.gtd_bot") == :ok
      assert KillSwitch.allowed?("bot.gtd.health") == :ok
    end

    test "state persists to file across a fresh read" do
      path = Application.get_env(:bot_army_library_runtime, :kill_switch_file)
      assert File.exists?(path)
      {:ok, body} = File.read(path)
      map = Jason.decode!(body)
      assert map["halted"] == true
      assert map["reason"] == "test incident"
      assert map["expires_at"]
    end
  end

  describe "auto-expiry" do
    test "an expired halt auto-resumes" do
      past = DateTime.add(DateTime.utc_now(), -60, :second) |> DateTime.to_iso8601()

      KillSwitch.apply_halt(%{"reason" => "stale halt", "expires_at" => past})

      # effective state check should auto-resume
      refute KillSwitch.halted?()
      assert %{halted: false} = KillSwitch.state()
    end

    test "a future expiry stays halted" do
      future = DateTime.add(DateTime.utc_now(), 3600, :second) |> DateTime.to_iso8601()
      KillSwitch.apply_halt(%{"reason" => "fresh halt", "expires_at" => future})
      assert KillSwitch.halted?()
    end
  end

  describe "publisher gate" do
    setup do
      KillSwitch.apply_halt(%{"reason" => "gate test", "expires_in_minutes" => 5})
      :ok
    end

    test "publish to a blocked subject returns kill_switch_engaged" do
      assert {:error, {:kill_switch_engaged, info}} =
               Publisher.publish("gtd.task.create", %{"title" => "x"})

      assert info.reason == "gate test"
    end

    test "request to a blocked subject returns kill_switch_engaged" do
      assert {:error, {:kill_switch_engaged, _}} =
               Publisher.request("bridge.chat", %{"text" => "hi"})
    end

    test "exempt subject proceeds past the gate (not gated, whatever the connection does)" do
      # With a live broker the publish actually succeeds; without one it fails
      # on the connection. Either way the failure must not be the kill switch.
      result = Publisher.publish("bot.army.pulse.gtd_bot", %{status: "active"})

      case result do
        {:ok, _} -> :ok
        {:error, reason} -> refute match?({:kill_switch_engaged, _}, reason)
      end
    end
  end
end