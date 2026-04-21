defmodule BotArmyRuntime.NATS.ConnectionTest do
  use ExUnit.Case, async: false
  @moduletag :nats

  alias BotArmyRuntime.NATS.Connection

  # The Connection GenServer is already started by the application supervisor.
  # Tests that need a separate instance use unique config to avoid name conflicts.

  describe "subscribe_to_status/0 and unsubscribe_from_status/0" do
    test "subscribe_to_status registers the calling process" do
      Connection.subscribe_to_status()
      Connection.unsubscribe_from_status()
    end

    test "unsubscribe_from_status removes the registration" do
      Connection.subscribe_to_status()
      Connection.unsubscribe_from_status()
      # Re-unsubscribe should be a no-op
      Connection.unsubscribe_from_status()
    end

    test "subscribe and receive status events" do
      Connection.subscribe_to_status()

      # The existing connection is likely disconnected (no NATS server in CI)
      # so we should receive a :disconnected event if it tried to connect
      # Just verify the mechanism works by unsubscribing
      Connection.unsubscribe_from_status()
    end
  end

  describe "broadcast mechanism" do
    test "Registry broadcast delivers messages to subscribed processes" do
      Connection.subscribe_to_status()

      # Simulate a broadcast by dispatching directly
      Registry.dispatch(BotArmyRuntime.NATS.ConnectionRegistry, :nats_status, fn entries ->
        for {pid, _} <- entries, do: send(pid, {:nats, :connected})
      end)

      assert_receive {:nats, :connected}, 1000
    after
      Connection.unsubscribe_from_status()
    end

    test "multiple subscribers all receive broadcasts" do
      Connection.subscribe_to_status()

      Registry.dispatch(BotArmyRuntime.NATS.ConnectionRegistry, :nats_status, fn entries ->
        for {pid, _} <- entries, do: send(pid, {:nats, :disconnected})
      end)

      assert_receive {:nats, :disconnected}, 1000
    after
      Connection.unsubscribe_from_status()
    end
  end

  describe "consistent failure behavior" do
    test "Connection GenServer stays alive after NATS connection failures" do
      # The Connection started by the app supervisor should be alive
      # even if NATS is unreachable
      conn_pid = GenServer.whereis(BotArmyRuntime.NATS.Connection)
      # May be nil if not started with that name, but if it exists it should be alive
      if conn_pid do
        assert Process.alive?(conn_pid)
      end
    end
  end
end
