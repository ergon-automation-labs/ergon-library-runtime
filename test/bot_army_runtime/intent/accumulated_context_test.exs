defmodule BotArmyRuntime.Intent.AccumulatedContextTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyRuntime.Intent.AccumulatedContext

  describe "normalize_entry/1" do
    test "fills in defaults for partial entries" do
      entry = AccumulatedContext.normalize_entry(%{type: :stale_task_count, value: 5})
      assert entry.type == :stale_task_count
      assert entry.value == 5
      assert entry.observed_at != nil
      assert entry.metadata == %{}
    end

    test "preserves all fields when provided" do
      now = DateTime.utc_now()

      entry =
        AccumulatedContext.normalize_entry(%{
          type: :gossip_received,
          value: %{from: "fitness"},
          observed_at: now,
          metadata: %{source: "heartbeat"}
        })

      assert entry.type == :gossip_received
      assert entry.value == %{from: "fitness"}
      assert entry.observed_at == now
      assert entry.metadata == %{source: "heartbeat"}
    end

    test "defaults type to :observation" do
      entry = AccumulatedContext.normalize_entry(%{value: 42})
      assert entry.type == :observation
    end
  end

  describe "compute_summary/1" do
    test "groups entries by type" do
      entries = [
        %{type: :stale_task_count, value: 3, observed_at: DateTime.utc_now(), metadata: %{}},
        %{type: :stale_task_count, value: 5, observed_at: DateTime.utc_now(), metadata: %{}},
        %{
          type: :gossip_received,
          value: %{from: "fitness"},
          observed_at: DateTime.utc_now(),
          metadata: %{}
        }
      ]

      summary = AccumulatedContext.compute_summary(entries)

      assert Map.has_key?(summary, :stale_task_count)
      assert Map.has_key?(summary, :gossip_received)
      assert summary.stale_task_count.count == 2
      assert summary.gossip_received.count == 1
    end

    test "returns empty map for empty entries" do
      assert AccumulatedContext.compute_summary([]) == %{}
    end
  end
end
