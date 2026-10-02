defmodule BotArmyLibraryRuntime.RegistryStatusTest do
  use ExUnit.Case, async: false

  @moduletag :core

  alias BotArmyLibraryRuntime.NATS.ConnectionRegistry

  # Regression guard: Registry has handled {:nats, :disconnected} since the
  # broker-outage work, but nothing ever subscribed it to the Connection's
  # status registry — so the handler was dead code and the registry kept the
  # dead Gnat pid in state.connection.
  #
  # Observed live 2026-10-01 (on the very reconnect that proved the
  # reconnect-after-EXIT fix): killing the connection made the Registry itself
  # terminate one second later — "GenServer BotArmyLibraryRuntime.Registry
  # terminating ... (EXIT) no process" while publishing its presence with the
  # pid of the Gnat process that had just died.
  test "subscribes to NATS connection status broadcasts" do
    pid = Process.whereis(BotArmyLibraryRuntime.Registry)

    assert is_pid(pid), "the Registry singleton should be running under the app supervisor"

    subscribers = Registry.lookup(ConnectionRegistry, :nats_status) |> Enum.map(&elem(&1, 0))

    assert pid in subscribers,
           "Registry must register for {:nats, :disconnected} so it drops the dead " <>
             "connection pid instead of publishing presence through it"
  end
end
