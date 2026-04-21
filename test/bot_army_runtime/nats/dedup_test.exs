defmodule BotArmyRuntime.NATS.DedupTest do
  use ExUnit.Case, async: false
  @moduletag :nats

  alias BotArmyRuntime.NATS.Dedup

  # Dedup is started by the application supervisor, so we don't need
  # to start_supervised! it. We clear the table between tests instead.

  setup do
    # Clear the ETS table between tests
    :ets.delete_all_objects(:nats_event_dedup)
    :ok
  end

  describe "seen?/1 and mark_seen/1" do
    test "returns false for unseen event" do
      assert Dedup.seen?("event-123") == false
    end

    test "returns true after marking as seen" do
      Dedup.mark_seen("event-456")
      assert Dedup.seen?("event-456") == true
    end

    test "different event_ids are independent" do
      Dedup.mark_seen("event-a")
      assert Dedup.seen?("event-a") == true
      assert Dedup.seen?("event-b") == false
    end

    test "handles non-binary input gracefully" do
      assert Dedup.seen?(nil) == false
      assert Dedup.seen?(123) == false
      assert Dedup.mark_seen(nil) == :ok
      assert Dedup.mark_seen(123) == :ok
    end
  end

  describe "check_and_mark/1" do
    test "returns :new for first occurrence" do
      assert Dedup.check_and_mark("event-new") == :new
    end

    test "returns :duplicate for second occurrence" do
      Dedup.check_and_mark("event-dup")
      assert Dedup.check_and_mark("event-dup") == :duplicate
    end

    test "marking as seen makes subsequent calls return :duplicate" do
      Dedup.mark_seen("event-premarked")
      assert Dedup.check_and_mark("event-premarked") == :duplicate
    end
  end

  describe "sliding window expiry" do
    test "entries expire after the window" do
      Dedup.mark_seen("short-lived")

      # Immediately after marking, it should be seen
      assert Dedup.seen?("short-lived") == true

      # Manually insert an expired entry (timestamp in the past)
      expired_ts = System.monotonic_time(:millisecond) - 61_000
      :ets.insert(:nats_event_dedup, {"expired-event", expired_ts})

      # The expired entry should not be seen
      assert Dedup.seen?("expired-event") == false
    end

    test "prune removes expired entries" do
      expired_ts = System.monotonic_time(:millisecond) - 61_000
      :ets.insert(:nats_event_dedup, {"expired-1", expired_ts})
      :ets.insert(:nats_event_dedup, {"expired-2", expired_ts})

      # Trigger prune by sending the message directly
      send(Dedup, :prune)
      Process.sleep(100)

      # Expired entries should be gone from ETS
      assert :ets.lookup(:nats_event_dedup, "expired-1") == []
      assert :ets.lookup(:nats_event_dedup, "expired-2") == []
    end
  end

  describe "concurrent access" do
    test "ETS supports concurrent reads" do
      Dedup.mark_seen("concurrent-event")

      tasks =
        for _ <- 1..10 do
          Task.async(fn -> Dedup.seen?("concurrent-event") end)
        end

      results = Task.await_many(tasks, 1000)
      assert Enum.all?(results, &(&1 == true))
    end
  end
end
