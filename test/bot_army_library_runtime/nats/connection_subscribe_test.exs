defmodule BotArmyLibraryRuntime.NATS.ConnectionSubscribeTest do
  # The Connection GenServer is a process-wide singleton started by the
  # application supervisor, and this module registers subscriptions in a
  # process-wide Registry — so it must not run concurrently with anything that
  # uses either.
  use ExUnit.Case, async: false

  @moduletag :nats

  alias BotArmyLibraryRuntime.NATS.Connection

  # Regression guard for the live outage measured 2026-10-12: a Gnat process
  # crash took 28 declared bridge subjects dark for 1d19h — `bridge.chat`,
  # `bridge.quest.>`, `bridge.timer.>`, `system.right_turns.log` among them —
  # while every responder pid stayed alive and looked healthy.
  #
  # The cause was not the crash. It was that a subscription made with
  # `Gnat.sub(conn, self(), subject)` belongs to the Gnat process: replacing it
  # replaces nothing, and only the four responders that called
  # `subscribe_to_status/0` ever heard about the new link. `subscribe/1` is the
  # fix — the *declaration* lives in this module's registry, and every link it
  # starts re-subscribes the whole registry.
  #
  # These tests drive the link lifecycle with the injectable transports, so the
  # behaviour is observable without a broker.

  setup do
    test_pid = self()

    # A fake link: it only has to exist, be linkable, and be killable.
    starter = fn _settings ->
      pid = spawn_link(fn -> Process.sleep(30_000) end)
      send(test_pid, {:gnat_start, pid})
      {:ok, pid}
    end

    # Observes subscriptions without a broker. Runs inside the Connection.
    sub = fn conn, pid, subject ->
      send(test_pid, {:sub, conn, pid, subject})
      {:ok, 1}
    end

    # Registered subscribers are re-subscribed by *every* Connection in this VM,
    # so a subscriber left alive past the end of a test would also be handed to
    # another test's Connection (and to the app's real singleton). Registry
    # entries are reaped when the pid dies, so the tracker kills them on exit.
    {:ok, tracker} = Agent.start(fn -> [] end)

    on_exit(fn ->
      for pid <- Agent.get(tracker, & &1), Process.alive?(pid), do: Process.exit(pid, :kill)
      Agent.stop(tracker)
    end)

    {:ok, connection} =
      Connection.start_link(
        name: :connection_subscribe_test,
        servers: [{"localhost", 42_991}],
        reconnect_delay_ms: 50,
        max_reconnect_attempts: 3,
        gnat_starter: starter,
        gnat_sub: sub
      )

    on_exit(fn -> if Process.alive?(connection), do: Process.exit(connection, :kill) end)

    %{connection: connection, sub: sub, tracker: tracker}
  end

  describe "a declared subscription" do
    test "is made now, and made again on every link the Connection starts", %{
      connection: connection,
      tracker: tracker
    } do
      {:ok, pid1} = wait_for_link(connection)
      flush_start_notifications()

      subscriber = start_subscriber(:connection_subscribe_test, ["bridge.quest.>"], tracker)

      # The declaration reaches the live link straight away.
      assert_receive {:sub, ^pid1, ^subscriber, "bridge.quest.>"}, 2_000

      # The link dies the way a real Gnat does: an EXIT, with no
      # {:gnat, :disconnected} to follow it. Nothing about the subscriber
      # changes — only the Connection's link does.
      Process.exit(pid1, :kill)

      pid2 = wait_for_new_link(connection, pid1)

      # The whole point: the declaration outlives the connection process.
      assert_receive {:sub, ^pid2, ^subscriber, "bridge.quest.>"}, 3_000
    end

    test "is not reported as an error when no link ever arrives", %{sub: sub} do
      # A bot whose broker is not up yet: the responder starts, declares its
      # subjects, and the Connection is still disconnected. Registration is what
      # survives, so the subjects are subscribed the moment a link appears — and
      # "not connected yet" must never be the declarer's problem, because a
      # responder that treated it as fatal would take its whole bot down.
      {:ok, connection} =
        Connection.start_link(
          name: :connection_subscribe_no_link_test,
          servers: [{"localhost", 42_991}],
          reconnect_delay_ms: 50,
          max_reconnect_attempts: 2,
          gnat_starter: fn _settings -> {:error, :refused} end,
          gnat_sub: sub
        )

      on_exit(fn -> if Process.alive?(connection), do: Process.exit(connection, :kill) end)

      assert GenServer.call(connection, :get_connection) == {:error, :not_connected}

      assert Connection.subscribe(["bridge.workflow.>"], :connection_subscribe_no_link_test) ==
               :ok

      # Nothing to subscribe to yet, and that is not a failure.
      refute_receive {:sub, _conn, _pid, _subject}, 200
    end
  end

  # A process that declares subjects and then keeps living, like a responder.
  defp start_subscriber(connection, subjects, tracker) do
    parent = self()

    pid =
      spawn(fn ->
        Connection.subscribe(subjects, connection)
        send(parent, {:subscribed, self()})
        Process.sleep(30_000)
      end)

    assert_receive {:subscribed, ^pid}, 2_000
    Agent.update(tracker, &[pid | &1])
    pid
  end

  defp wait_for_link(connection) do
    case GenServer.call(connection, :get_connection) do
      {:ok, pid} ->
        {:ok, pid}

      {:error, _reason} ->
        receive do
          {:gnat_start, pid} -> {:ok, pid}
        after
          3_000 -> :no_link
        end
    end
  end

  # The EXIT has to be *processed* before the slot is cleared, so asking for the
  # link can still hand back the pid we just killed. Wait for a different one.
  defp wait_for_new_link(connection, old_pid, deadline \\ 3_000) do
    started = System.monotonic_time(:millisecond)
    do_wait_for_new_link(connection, old_pid, started + deadline)
  end

  defp do_wait_for_new_link(connection, old_pid, deadline) do
    case GenServer.call(connection, :get_connection) do
      {:ok, pid} when pid != old_pid ->
        pid

      _same_or_none ->
        remaining = deadline - System.monotonic_time(:millisecond)

        if remaining <= 0 do
          flunk("the Connection never started a new link")
        else
          receive do
            {:gnat_start, pid} when pid != old_pid -> pid
          after
            remaining -> flunk("the Connection never started a new link")
          end
        end
    end
  end

  defp flush_start_notifications do
    receive do
      {:gnat_start, _pid} -> flush_start_notifications()
    after
      0 -> :ok
    end
  end
end
