defmodule BotArmy.IntentOutcomeTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyLibraryRuntime.IntentOutcome

  describe "record/2" do
    test "returns :skipped when repo is unavailable" do
      attrs = %{
        bot_name: "test_bot",
        action: "nudge",
        intent_id: "test-intent-1",
        decision: "act",
        score: 0.85,
        reason: "threshold_met",
        observed_at: DateTime.utc_now() |> DateTime.truncate(:second)
      }

      result = IntentOutcome.record(attrs, repo: nil)
      assert result == :skipped
    end

    test "returns error with missing bot_name" do
      attrs = %{
        action: "nudge",
        intent_id: "test-intent-1",
        decision: "act"
      }

      assert {:error, :missing_bot_name} = IntentOutcome.record(attrs, repo: nil)
    end

    test "returns error with missing action" do
      attrs = %{
        bot_name: "test_bot",
        intent_id: "test-intent-1",
        decision: "act"
      }

      assert {:error, :missing_action} = IntentOutcome.record(attrs, repo: nil)
    end

    test "returns error with missing intent_id" do
      attrs = %{
        bot_name: "test_bot",
        action: "nudge",
        decision: "act"
      }

      assert {:error, :missing_intent_id} = IntentOutcome.record(attrs, repo: nil)
    end
  end

  describe "resolve/4" do
    test "returns :skipped when repo is unavailable" do
      result = IntentOutcome.resolve("nonexistent-intent", "success", %{}, repo: nil)
      assert result == :skipped
    end
  end

  describe "recent_outcomes/3" do
    test "returns empty list when repo is unavailable" do
      result = IntentOutcome.recent_outcomes("test_bot", "nudge", repo: nil)
      assert result == []
    end
  end

  describe "success_rate/3" do
    test "returns 0.0 when repo is unavailable" do
      result = IntentOutcome.success_rate("test_bot", "nudge", repo: nil)
      assert result == 0.0
    end
  end

  describe "active_pairs/1" do
    test "returns empty list when repo is unavailable" do
      result = IntentOutcome.active_pairs(repo: nil)
      assert result == []
    end
  end
end
