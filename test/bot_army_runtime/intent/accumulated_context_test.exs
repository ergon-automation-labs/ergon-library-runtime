defmodule BotArmyLibraryRuntime.Intent.AccumulatedContextTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyLibraryRuntime.Intent.AccumulatedContext

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

  describe "latest_value/3" do
    test "reads the value out of the summary aggregate (the live fitness crash shape)" do
      # This is the exact aggregate that reached `trunc/1` on air 2026-10-13.
      context = %{
        summary: %{
          idle_minutes: %{
            count: 1,
            values: [60],
            latest: %{
              type: :idle_minutes,
              value: 60,
              metadata: %{source: "pulse"},
              observed_at: ~U[2026-10-13 12:35:32.992898Z]
            }
          }
        }
      }

      assert AccumulatedContext.latest_value(context, :idle_minutes) == 60
      assert AccumulatedContext.latest_value(context.summary, :idle_minutes) == 60
    end

    test "accepts a plain scalar (so a caller may pass either shape)" do
      assert AccumulatedContext.latest_value(%{idle_minutes: 90}, :idle_minutes) == 90
    end

    test "returns the default for an absent type, a nil value, or a non-numeric value" do
      assert AccumulatedContext.latest_value(%{}, :idle_minutes) == 0
      assert AccumulatedContext.latest_value(%{idle_minutes: nil}, :idle_minutes, 7) == 7

      assert AccumulatedContext.latest_value(
               %{idle_minutes: %{count: 1, values: ["x"], latest: %{value: "x"}}},
               :idle_minutes,
               7
             ) == 7
    end

    test "does not mistake a snapshot's own keys for an observation type" do
      # A snapshot has no :summary key when it was never populated; the aggregate
      # for a type must never be confused with the snapshot itself.
      assert AccumulatedContext.latest_value(%{summary: %{}, entry_count: 0}, :entry_count) == 0
    end
  end

  describe "observation_count/3" do
    test "reads count from the aggregate (the dispatcher convention)" do
      summary = %{bot_stale: %{count: 3, values: [1, 1, 1], latest: %{value: 1}}}

      assert AccumulatedContext.observation_count(summary, :bot_stale) == 3
      assert AccumulatedContext.observation_count(%{summary: summary}, :bot_stale) == 3
    end

    test "returns the default for an absent type or a malformed aggregate" do
      assert AccumulatedContext.observation_count(%{}, :bot_stale) == 0
      assert AccumulatedContext.observation_count(%{bot_stale: %{count: nil}}, :bot_stale, 5) == 5
    end
  end
end
