defmodule BotArmyLibraryRuntime.RegistryTimingTest do
  @moduledoc """
  Time-manipulated regression tests for the registry's stale sweep and
  presence echo handling (P10 phase-04 core-full eviction saga, RERUN15-18).

  The registry reads its sweep/rebroadcast timing from Application env in
  init/1, so this suite shrinks the timers (300ms threshold) and restarts
  the GenServer ONCE for the whole module via setup_all — a per-test kill
  trips the supervisor's max_restarts budget and takes the whole tree down.
  """

  use ExUnit.Case, async: false
  @moduletag :core

  @tiny_threshold 300

  # Runs once for the module; on_exit restores default timing.
  setup_all :shrink_registry_timing

  test "stale sweep keeps locally-registered bots (never evicts local entries)" do
    subjects = [%{subject: "test.task.create", type: :request_reply}]
    BotArmyLibraryRuntime.Registry.register("local_bot", subjects)

    # Wait well past the shrunken threshold + sweep cadence
    Process.sleep(700)

    assert {:ok, bots} = BotArmyLibraryRuntime.Registry.list_bots()
    assert Enum.find(bots, &(&1["name"] == "local_bot")),
           "locally-registered bot must survive the stale sweep"
  end

  test "presence echo does not flip a locally-owned entry to remote" do
    subjects = [%{subject: "test.task.create", type: :request_reply}]
    BotArmyLibraryRuntime.Registry.register("echoed_bot", subjects)

    # Synthesize the bot's own broadcast arriving back (presence sub has no
    # queue group, so self-delivery is guaranteed in production)
    echo = %{
      topic: "bot_army.registry.presence",
      body:
        Jason.encode!(%{
          "bot_name" => "echoed_bot",
          "version" => "0.1.0",
          "subjects" => [%{"subject" => "test.task.create", "type" => "request_reply"}],
          "heartbeat_at" => System.system_time(:millisecond)
        })
    }

    registry_pid = Process.whereis(BotArmyLibraryRuntime.Registry)
    send(registry_pid, {:msg, echo})

    # Let the sweep tick a few times past the threshold
    Process.sleep(700)

    assert {:ok, bots} = BotArmyLibraryRuntime.Registry.list_bots()
    assert Enum.find(bots, &(&1["name"] == "echoed_bot")),
           "self-echo must not flip the local entry to remote (which would stop rebroadcast and get it swept)"
  end

  test "remote entries with no local registration are still swept when stale" do
    # A bot that only ever arrived via presence (never registered here)
    remote_echo = %{
      topic: "bot_army.registry.presence",
      body:
        Jason.encode!(%{
          "bot_name" => "remote_bot",
          "version" => "0.1.0",
          "subjects" => [%{"subject" => "remote.task.create", "type" => "request_reply"}],
          "heartbeat_at" => System.system_time(:millisecond)
        })
    }

    registry_pid = Process.whereis(BotArmyLibraryRuntime.Registry)
    send(registry_pid, {:msg, remote_echo})

    {:ok, bots} = BotArmyLibraryRuntime.Registry.list_bots()
    assert Enum.find(bots, &(&1["name"] == "remote_bot")), "remote arrival should be listed"

    # No further presence arrives -> it goes stale and is evicted
    Process.sleep(700)

    {:ok, bots} = BotArmyLibraryRuntime.Registry.list_bots()
    refute Enum.find(bots, &(&1["name"] == "remote_bot")),
           "genuinely dead remote bots must still be swept"
  end

  defp shrink_registry_timing(_context) do
    Application.put_env(:bot_army_library_runtime, :registry_stale_threshold_ms, @tiny_threshold)
    Application.put_env(:bot_army_library_runtime, :registry_heartbeat_interval_ms, 100)
    Application.put_env(:bot_army_library_runtime, :registry_presence_rebroadcast_ms, 200)

    # The registry reads its timing config in init/1 — restart it so the
    # shrunken values take effect. setup_all runs ONCE for the whole module
    # (a per-test kill trips the supervisor's max_restarts budget and takes
    # the whole tree down).
    restart_registry!()

    on_exit(fn ->
      Application.delete_env(:bot_army_library_runtime, :registry_stale_threshold_ms)
      Application.delete_env(:bot_army_library_runtime, :registry_heartbeat_interval_ms)
      Application.delete_env(:bot_army_library_runtime, :registry_presence_rebroadcast_ms)
      restart_registry!()
    end)

    :ok
  end

  defp restart_registry! do
    case Process.whereis(BotArmyLibraryRuntime.Registry) do
      nil -> :ok
      pid -> GenServer.stop(pid, :kill)
    end

    wait_for_registry(50)
  end

  defp wait_for_registry(0), do: raise("Registry did not restart within timeout")

  defp wait_for_registry(retries) do
    case Process.whereis(BotArmyLibraryRuntime.Registry) do
      nil ->
        Process.sleep(50)
        wait_for_registry(retries - 1)

      pid ->
        try do
          {:ok, _} = BotArmyLibraryRuntime.Registry.list_bots()
          pid
        rescue
          _ ->
            Process.sleep(50)
            wait_for_registry(retries - 1)
        end
    end
  end
end
