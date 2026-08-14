defmodule BotArmy.IntentThresholdAdjustmentTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyLibraryRuntime.IntentThresholdAdjustment

  defmodule MockThresholdRepo do
    use GenServer

    def start_link(_ \\ []), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)
    def init(_), do: {:ok, []}
    def query(_, _), do: {:ok, %Postgrex.Result{rows: [[]]}}
  end

  setup do
    start_supervised!(MockThresholdRepo)
    :ok
  end

  describe "record/2" do
    test "returns :skipped when repo is unavailable" do
      attrs = %{
        bot_name: "synapse",
        action: "proactive_message",
        observation_type: "pending_context_events",
        original_weight: 0.5,
        adjusted_weight: 0.35,
        adjustment_reason: "consecutive_failures (factor=0.7)",
        source: "reflection"
      }

      result = IntentThresholdAdjustment.record(attrs, repo: nil)
      assert result == :skipped
    end

    test "returns error with missing bot_name" do
      attrs = %{
        action: "nudge",
        observation_type: "stale_task_count",
        original_weight: 0.6,
        adjusted_weight: 0.42
      }

      assert {:error, :missing_bot_name} =
               IntentThresholdAdjustment.record(attrs, repo: MockThresholdRepo)
    end

    test "returns error with missing action" do
      attrs = %{
        bot_name: "test_bot",
        observation_type: "stale_task_count",
        original_weight: 0.6,
        adjusted_weight: 0.42
      }

      assert {:error, :missing_action} =
               IntentThresholdAdjustment.record(attrs, repo: MockThresholdRepo)
    end

    test "returns error with missing observation_type" do
      attrs = %{
        bot_name: "test_bot",
        action: "nudge",
        original_weight: 0.6,
        adjusted_weight: 0.42
      }

      assert {:error, :missing_observation_type} =
               IntentThresholdAdjustment.record(attrs, repo: MockThresholdRepo)
    end
  end

  describe "latest_adjustments/3" do
    test "returns empty list when repo is unavailable" do
      result =
        IntentThresholdAdjustment.latest_adjustments("synapse", "proactive_message", repo: nil)

      assert result == []
    end
  end

  describe "list_adjustments/3" do
    test "returns empty list when repo is unavailable" do
      result =
        IntentThresholdAdjustment.list_adjustments("synapse", "proactive_message", repo: nil)

      assert result == []
    end
  end
end
