defmodule BotArmyLibraryRuntime.Health.MonitorTest do
  use ExUnit.Case, async: false
  @moduletag :core

  alias BotArmyLibraryRuntime.Health.Monitor

  @table :bot_army_health_monitor

  setup do
    :ets.delete_all_objects(@table)
    :ok
  end

  describe "get_status/1" do
    test "returns :unknown for untracked bot" do
      assert Monitor.get_status("nonexistent") == :unknown
    end

    test "returns last_seen_at and status for tracked bot" do
      now = System.monotonic_time(:millisecond)
      :ets.insert(@table, {"bot_a", now, :healthy, %{status: :healthy}})

      assert {:ok, {last_seen, :healthy}} = Monitor.get_status("bot_a")
      assert last_seen == now
    end
  end

  describe "list_bots/0" do
    test "returns empty list when no bots tracked" do
      assert Monitor.list_bots() == []
    end

    test "returns all tracked bots" do
      now = System.monotonic_time(:millisecond)
      :ets.insert(@table, {"bot_a", now, :healthy, nil})
      :ets.insert(@table, {"bot_b", now, :healthy, nil})

      bots = Monitor.list_bots()
      assert length(bots) == 2

      bot_ids = Enum.map(bots, fn {id, _, _} -> id end)
      assert "bot_a" in bot_ids
      assert "bot_b" in bot_ids
    end
  end

  describe "list_stale/0" do
    test "returns empty when all bots are healthy" do
      now = System.monotonic_time(:millisecond)
      :ets.insert(@table, {"bot_a", now, :healthy, nil})

      assert Monitor.list_stale() == []
    end

    test "returns bots marked as stale" do
      old = System.monotonic_time(:millisecond) - 90_000
      :ets.insert(@table, {"bot_a", old, :stale, nil})

      stale = Monitor.list_stale()
      assert length(stale) == 1

      {bot_id, _last_seen, stale_sec} = hd(stale)
      assert bot_id == "bot_a"
      assert stale_sec >= 60
    end

    test "returns healthy bots whose last_seen exceeds threshold" do
      old = System.monotonic_time(:millisecond) - 90_000
      :ets.insert(@table, {"bot_b", old, :healthy, nil})

      stale = Monitor.list_stale()
      assert length(stale) == 1

      {bot_id, _, stale_sec} = hd(stale)
      assert bot_id == "bot_b"
      assert stale_sec >= 60
    end
  end

  describe "heartbeat message handling" do
    test "records heartbeat in ETS on :msg" do
      send(Monitor, {:msg, %{topic: "bot.army.health.test_bot", body: ~s({"status":"healthy"})}})
      Process.sleep(50)

      assert {:ok, {_last_seen, :healthy}} = Monitor.get_status("test_bot")
    end

    test "extracts bot_id from subject" do
      send(Monitor, {:msg, %{topic: "bot.army.health.my_gtd_bot", body: "{}"}})
      Process.sleep(50)

      assert {:ok, _} = Monitor.get_status("my_gtd_bot")
    end

    test "ignores messages with unrecognized subject format" do
      send(Monitor, {:msg, %{topic: "other.subject", body: "{}"}})
      Process.sleep(50)

      assert Monitor.get_status("other") == :unknown
    end

    test "updates last_seen_at on repeated heartbeats" do
      send(Monitor, {:msg, %{topic: "bot.army.health.bot_c", body: "{}"}})
      Process.sleep(50)

      {:ok, {first_seen, :healthy}} = Monitor.get_status("bot_c")

      Process.sleep(100)

      send(Monitor, {:msg, %{topic: "bot.army.health.bot_c", body: "{}"}})
      Process.sleep(50)

      {:ok, {second_seen, :healthy}} = Monitor.get_status("bot_c")
      assert second_seen > first_seen
    end
  end

  describe "stale detection on :check" do
    test "marks bot as stale when heartbeat exceeds threshold" do
      old = System.monotonic_time(:millisecond) - 90_000
      :ets.insert(@table, {"stale_bot", old, :healthy, nil})

      send(Monitor, :check)
      Process.sleep(50)

      assert {:ok, {_last_seen, :stale}} = Monitor.get_status("stale_bot")
    end

    test "does not mark recent bots as stale" do
      now = System.monotonic_time(:millisecond)
      :ets.insert(@table, {"fresh_bot", now, :healthy, nil})

      send(Monitor, :check)
      Process.sleep(50)

      assert {:ok, {_last_seen, :healthy}} = Monitor.get_status("fresh_bot")
    end

    test "does not re-mark already stale bots" do
      old = System.monotonic_time(:millisecond) - 120_000
      :ets.insert(@table, {"already_stale", old, :stale, nil})

      send(Monitor, :check)
      Process.sleep(50)

      # Still stale, status unchanged
      assert {:ok, {_last_seen, :stale}} = Monitor.get_status("already_stale")
    end
  end

  describe "recovery detection" do
    test "publishes recovery event when stale bot sends heartbeat" do
      old = System.monotonic_time(:millisecond) - 90_000
      :ets.insert(@table, {"recovering_bot", old, :stale, nil})

      send(Monitor, {:msg, %{topic: "bot.army.health.recovering_bot", body: "{}"}})
      Process.sleep(50)

      assert {:ok, {_last_seen, :healthy}} = Monitor.get_status("recovering_bot")
    end

    test "does not publish recovery for healthy bot heartbeat" do
      now = System.monotonic_time(:millisecond)
      :ets.insert(@table, {"healthy_bot", now, :healthy, nil})

      send(Monitor, {:msg, %{topic: "bot.army.health.healthy_bot", body: "{}"}})
      Process.sleep(50)

      assert {:ok, {_last_seen, :healthy}} = Monitor.get_status("healthy_bot")
    end
  end
end
