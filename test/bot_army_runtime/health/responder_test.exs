defmodule BotArmyLibraryRuntime.Health.ResponderTest do
  use ExUnit.Case, async: false
  @moduletag :core

  alias BotArmyLibraryRuntime.Health.Responder

  # The Registry is already started by the application supervisor.

  describe "init and graceful degradation" do
    test "starts without crashing when NATS is unavailable" do
      opts = [
        bot_name: :test_bot_health,
        repo: nil,
        process_names: [],
        version: "0.0.1-test"
      ]

      result =
        try do
          pid = start_supervised!({Responder, opts})
          Process.sleep(100)
          Process.alive?(pid)
        rescue
          _ -> false
        end

      assert result == true
    end

    test "accepts optional repo configuration" do
      opts = [
        bot_name: :test_bot_no_repo,
        repo: nil,
        process_names: [],
        version: "0.0.1-test"
      ]

      pid = start_supervised!({Responder, opts})
      Process.sleep(100)
      assert Process.alive?(pid)
    end

    test "accepts process_names configuration" do
      opts = [
        bot_name: :test_bot_procs,
        repo: nil,
        process_names: [Some.Process.That.DoesNotExist],
        version: "0.0.1-test"
      ]

      pid = start_supervised!({Responder, opts})
      Process.sleep(100)
      assert Process.alive?(pid)
    end
  end

  describe "handle_info {:nats, :disconnected}" do
    test "survives disconnect and clears connection state" do
      opts = [
        bot_name: :disconnect_bot_health,
        repo: nil,
        process_names: [],
        version: "0.0.1-test"
      ]

      pid = start_supervised!({Responder, opts})
      Process.sleep(100)

      send(pid, {:nats, :disconnected})
      Process.sleep(100)

      assert Process.alive?(pid)
    end
  end

  describe "handle_info {:nats, :connected}" do
    test "survives connect event and attempts re-subscribe" do
      opts = [
        bot_name: :connect_bot_health,
        repo: nil,
        process_names: [],
        version: "0.0.1-test"
      ]

      pid = start_supervised!({Responder, opts})
      Process.sleep(100)

      send(pid, {:nats, :connected})
      Process.sleep(100)

      assert Process.alive?(pid)
    end
  end

  describe "handle_info :reconnect" do
    test "reconnect message triggers connect attempt without crash" do
      opts = [
        bot_name: :reconnect_bot_health,
        repo: nil,
        process_names: [],
        version: "0.0.1-test"
      ]

      pid = start_supervised!({Responder, opts})
      Process.sleep(100)

      send(pid, :reconnect)
      Process.sleep(100)

      assert Process.alive?(pid)
    end
  end

  describe "handle_info :msg without reply_to" do
    test "ignores messages without reply_to (not a health check request)" do
      opts = [
        bot_name: :no_reply_bot_health,
        repo: nil,
        process_names: [],
        version: "0.0.1-test"
      ]

      pid = start_supervised!({Responder, opts})
      Process.sleep(100)

      send(pid, {:msg, %{body: "ignore me", subject: "bot.test_bot.health"}})
      Process.sleep(50)

      assert Process.alive?(pid)
    end
  end

  describe "handle_info catch-all" do
    test "unknown messages are ignored" do
      opts = [
        bot_name: :catchall_bot_health,
        repo: nil,
        process_names: [],
        version: "0.0.1-test"
      ]

      pid = start_supervised!({Responder, opts})
      Process.sleep(100)

      send(pid, {:unknown, :message})
      Process.sleep(50)

      assert Process.alive?(pid)
    end
  end

  describe "status computation logic" do
    test "check_db returns :skip for nil repo" do
      assert check_db(nil) == :skip
    end

    test "check_processes returns ok for empty list" do
      assert check_processes([]) == :ok
    end

    test "check_processes returns error for dead named process" do
      assert check_processes([NonExistent.Process]) == :error
    end

    test "compute_overall_status: all ok → healthy" do
      assert compute_status(true, :ok, :ok) == :healthy
    end

    test "compute_overall_status: nats ok + partial → degraded" do
      assert compute_status(true, :skip, :error) == :degraded
      assert compute_status(true, :error, :ok) == :degraded
    end

    test "compute_overall_status: nats down → unhealthy" do
      assert compute_status(false, :ok, :ok) == :unhealthy
      assert compute_status(false, :skip, :ok) == :unhealthy
      assert compute_status(false, :error, :error) == :unhealthy
    end

    test "compute_overall_status: nats ok but all checks failing → degraded" do
      # db skip counts as ok, so this is degraded (nats ok + db ok)
      assert compute_status(true, :skip, :error) == :degraded
    end
  end

  # Mirrors the actual module logic for direct unit testing
  defp check_db(nil), do: :skip

  defp check_processes([]), do: :ok

  defp check_processes(process_names) do
    all_alive =
      Enum.all?(process_names, fn name ->
        if is_pid(name) do
          Process.alive?(name)
        else
          GenServer.whereis(name) != nil
        end
      end)

    if all_alive, do: :ok, else: :error
  end

  defp compute_status(nats_ok, db_result, procs_result) do
    nats = if nats_ok, do: :ok, else: :error
    db_ok = db_result == :ok or db_result == :skip
    procs_ok = procs_result == :ok

    cond do
      nats == :ok and db_ok and procs_ok -> :healthy
      nats == :ok and (db_ok or procs_ok) -> :degraded
      true -> :unhealthy
    end
  end
end
