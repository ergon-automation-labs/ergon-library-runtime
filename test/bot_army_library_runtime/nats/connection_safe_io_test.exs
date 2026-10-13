defmodule BotArmyLibraryRuntime.NATS.ConnectionSafeIoTest do
  use ExUnit.Case, async: true

  @moduletag :nats

  alias BotArmyLibraryRuntime.NATS.Connection

  # Regression guards for the bridge crash-loop measured 2026-10-13 (launchd
  # last exit status 1, four responders terminating per flap, ~5 exits in the
  # error log). The fatal step was always the same shape:
  #
  #     ** (MatchError) no match of right hand side value: {:error, :einval}
  #         (gnat 1.13.1) lib/gnat.ex:492: Gnat.handle_call/3
  #
  # `Gnat.handle_call({:pub, …})` matches its socket write as `:ok`, and a write
  # over a socket the broker just dropped returns `{:error, :einval}`. The Gnat
  # connection process therefore crashed *inside* the call, and every caller
  # blocked in `GenServer.call/3` — ProjectSnapshotResponder among them — went
  # with it. The `{:nats, :disconnected}` handlers then called `Gnat.unsub/3` on
  # that dead pid and got `** (EXIT) no process`.
  #
  # A dead connection must be a returned error, never an exit. These tests stand
  # a connection up, kill it, and assert the wrappers survive.

  describe "publish/4 against a dead connection" do
    test "returns {:error, :not_connected} for a dead pid instead of exiting" do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      assert Connection.publish(pid, "bridge.pulse", "{}") == {:error, :not_connected}
    end

    test "returns {:error, :not_connected} for nil and for an unregistered name" do
      assert Connection.publish(nil, "bridge.pulse", "{}") == {:error, :not_connected}

      assert Connection.publish(:no_such_gnat_process_here, "bridge.pulse", "{}") ==
               {:error, :not_connected}
    end

    test "survives a connection that dies mid-call" do
      # A process that accepts the call and then dies. This is the closest the
      # suite can get to gnat's own crash without a broker: the caller is
      # blocked in GenServer.call/3 when the target goes away.
      pid =
        spawn(fn ->
          receive do
            {:"$gen_call", _from, _msg} -> exit(:simulated_gnat_crash)
          end
        end)

      assert {:error, _reason} = Connection.publish(pid, "bridge.pulse", "{}")
      refute Process.alive?(pid)
    end
  end

  describe "unsub/3 against a dead connection" do
    test "returns {:error, :not_connected} for a dead pid instead of exiting" do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      assert Connection.unsub(pid, 1) == {:error, :not_connected}
    end

    test "survives a connection that dies mid-call" do
      pid =
        spawn(fn ->
          receive do
            {:"$gen_call", _from, _msg} -> exit(:simulated_gnat_crash)
          end
        end)

      assert {:error, _reason} = Connection.unsub(pid, 7)
    end
  end

  describe "safe_sub/3 against a dead connection" do
    test "returns {:error, :not_connected} for a dead pid instead of exiting" do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      assert Connection.safe_sub(pid, self(), "bridge.test") == {:error, :not_connected}
    end

    test "survives a connection that dies mid-call" do
      pid =
        spawn(fn ->
          receive do
            {:"$gen_call", _from, _msg} -> exit(:simulated_gnat_crash)
          end
        end)

      assert {:error, _reason} = Connection.safe_sub(pid, self(), "bridge.test")
    end
  end

  describe "the wrappers as a class" do
    # The point is not any one call site. It is that no publish, unsubscribe or
    # subscribe can exit, so the supervisor's restart budget is never spent and
    # the application is never terminated by a dropped socket.
    test "not one of them raises or exits for a dead connection" do
      pid = spawn(fn -> :ok end)
      ref = Process.monitor(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, _}

      assert {:error, :not_connected} = Connection.publish(pid, "s", "{}")
      assert {:error, :not_connected} = Connection.unsub(pid, 1)
      assert {:error, :not_connected} = Connection.safe_sub(pid, self(), "s")
    end
  end
end
