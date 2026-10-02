defmodule BotArmyLibraryRuntime.NATS.ConnectionReconnectTest do
  # The Connection GenServer is a process-wide singleton started by the
  # application supervisor, and this module swaps its process-wide config —
  # so it must not run concurrently with anything that reads either.
  use ExUnit.Case, async: false

  @moduletag :nats

  alias BotArmyLibraryRuntime.NATS.Connection

  # Regression guard for a live fleet bug (found 2026-10-01 on companion_bot):
  # when the linked Gnat process died, handle_info({:EXIT, pid, reason},
  # %{connection: pid}) cleared the slot and scheduled NOTHING. An exited Gnat
  # never sends {:gnat, :disconnected}, so the bot stayed up with
  # connection: nil, reconnect_attempts: 0 (which reads as healthy) and failed
  # every publish with a bare :not_connected until someone restarted it.
  # See docs/runbooks/KNOWN_ISSUE_NATS_CONNECTION_NEVER_RETRIES_AFTER_EXIT.md.

  setup do
    test_pid = self()

    starter = fn settings ->
      # Runs inside the Connection GenServer, exactly where Gnat.start_link/1
      # runs, so spawn_link/1 links the fake to the Connection just like a real
      # Gnat process would.
      pid = spawn_link(fn -> Process.sleep(30_000) end)
      send(test_pid, {:gnat_start, pid, settings})
      {:ok, pid}
    end

    # A private instance: the application's Connection singleton stays untouched
    # (its state is process-wide and other tests read it).
    {:ok, connection} =
      Connection.start_link(
        name: :connection_reconnect_test,
        servers: [{"localhost", 42_991}],
        reconnect_delay_ms: 50,
        max_reconnect_attempts: 3,
        gnat_starter: starter
      )

    on_exit(fn -> if Process.alive?(connection), do: Process.exit(connection, :kill) end)

    %{connection: connection}
  end

  describe "a dead Gnat link" do
    test "schedules its own reconnect instead of sitting disconnected forever", %{
      connection: connection
    } do
      {:ok, pid1} = wait_for_link(connection)
      flush_start_notifications()

      # The link dies the way a real Gnat does: an EXIT, with no
      # {:gnat, :disconnected} to follow it.
      Process.exit(pid1, :kill)

      # A retry must be scheduled off the EXIT itself — this assertion failed
      # before the fix (no second link was ever started).
      assert_receive {:gnat_start, pid2, _settings}, 3_000
      assert pid2 != pid1
      assert wait_for_connection(connection, pid2) == {:ok, pid2}
    end
  end

  describe "the reconnect budget" do
    test "degrades to a slow permanent retry instead of giving up" do
      # Past the attempt budget the delay is the slow fixed interval: a bot that
      # outlived a multi-minute broker outage must still rejoin on its own.
      assert Connection.next_retry_delay(99, 3, 100) == 30_000
    end

    test "backs off with jitter while inside the budget" do
      assert Connection.next_retry_delay(0, 3, 100) in 100..1_100
      assert Connection.next_retry_delay(1, 3, 100) in 200..1_200
    end
  end

  # The Connection connects on start and again on every retry, so a link is
  # either already there or arrives within the backoff window.
  defp wait_for_link(connection) do
    case GenServer.call(connection, :get_connection) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, _reason} ->
        receive do
          {:gnat_start, pid, _settings} -> {:ok, pid}
        after
          3_000 -> :no_link
        end
    end
  end

  # A start notification for the link we already hold may still be in flight.
  defp flush_start_notifications do
    receive do
      {:gnat_start, _pid, _settings} -> flush_start_notifications()
    after
      0 -> :ok
    end
  end

  defp wait_for_connection(connection, expected, attempts \\ 20) do
    case GenServer.call(connection, :get_connection) do
      {:ok, ^expected} = ok ->
        ok

      _other when attempts > 0 ->
        Process.sleep(25)
        wait_for_connection(connection, expected, attempts - 1)

      other ->
        other
    end
  end
end
