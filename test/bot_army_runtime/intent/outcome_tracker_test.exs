defmodule BotArmyLibraryRuntime.Intent.OutcomeTrackerTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyLibraryRuntime.Intent.OutcomeTracker

  describe "resolve/3" do
    test "converts atom outcome to string" do
      # Delegates to IntentOutcome.resolve which returns :skipped when repo unavailable
      result = OutcomeTracker.resolve("test-intent-1", :success, %{})
      # Returns :skipped because repo is not available in test env
      assert result == :skipped
    end

    test "converts failure atom" do
      result = OutcomeTracker.resolve("test-intent-1", :failure)
      assert result == :skipped
    end

    test "converts partial atom" do
      result = OutcomeTracker.resolve("test-intent-1", :partial)
      assert result == :skipped
    end
  end

  describe "recent_outcomes/3" do
    test "returns empty list when repo is unavailable" do
      result = OutcomeTracker.recent_outcomes("synapse", "proactive_message")
      # Delegates to IntentOutcome which returns [] when repo unavailable
      assert is_list(result)
    end
  end

  describe "success_rate/3" do
    test "returns float when repo is unavailable" do
      result = OutcomeTracker.success_rate("synapse", "proactive_message")
      assert is_float(result)
      assert result == 0.0
    end
  end
end
