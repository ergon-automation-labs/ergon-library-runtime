defmodule BotArmyLibraryRuntime.LeaderElectionStatusTest do
  use ExUnit.Case, async: false

  @moduletag :core

  alias BotArmyLibraryRuntime.LeaderElection
  alias BotArmyLibraryRuntime.NATS.ConnectionRegistry

  defmodule RoleSpy do
    def notify(role), do: role
  end

  # Regression guard: LeaderElection has handled {:nats, :disconnected} since
  # the broker-outage work, but nothing ever subscribed it to the Connection's
  # status registry — so the handler was dead code and the election kept
  # calling a dead Gnat pid (observed live 2026-10-01 as
  # "lease renew failed: {:noproc, ...}" every tick, long after the connection
  # had been re-established).
  test "subscribes to NATS connection status broadcasts" do
    {:ok, pid} =
      LeaderElection.start_link(
        service: "status_wiring_test",
        node_name: "air",
        default_role: :primary,
        on_role_change: {RoleSpy, :notify, []},
        check_interval_ms: 60_000
      )

    on_exit(fn -> if Process.alive?(pid), do: Process.exit(pid, :kill) end)

    subscribers = Registry.lookup(ConnectionRegistry, :nats_status) |> Enum.map(&elem(&1, 0))

    assert pid in subscribers,
           "LeaderElection must register for {:nats, :disconnected} so a dead " <>
             "connection pid is dropped, not reused"
  end
end
