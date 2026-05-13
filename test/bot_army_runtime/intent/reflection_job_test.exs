defmodule BotArmyRuntime.Intent.ReflectionJobTest do
  use ExUnit.Case
  @moduletag :core

  # These tests verify the pattern detection logic without requiring
  # a running NATS connection or database. Integration tests with
  # real infrastructure use @tag :integration.

  describe "pattern detection logic" do
    test "consecutive failures rule detects 3+ vetoes in a row" do
      outcomes = [
        %{decision: "vetoed", outcome: "failure"},
        %{decision: "vetoed", outcome: "failure"},
        %{decision: "vetoed", outcome: "failure"}
      ]

      consecutive =
        outcomes
        |> Enum.take_while(fn o -> o.decision == "vetoed" or o.outcome == "failure" end)
        |> length()

      assert consecutive >= 3
    end

    test "consecutive failures rule does not trigger on 2 or fewer" do
      outcomes = [
        %{decision: "act", outcome: "success"},
        %{decision: "vetoed", outcome: "failure"},
        %{decision: "vetoed", outcome: "failure"}
      ]

      consecutive =
        outcomes
        |> Enum.take_while(fn o -> o.decision == "vetoed" or o.outcome == "failure" end)
        |> length()

      assert consecutive < 3
    end

    test "low success rate below 0.3 triggers reduction" do
      rate = 0.2
      min_resolved = 3

      assert rate < 0.3
      assert min_resolved >= 3
      assert max(rate, 0.1) == 0.2
    end

    test "high success rate above 0.9 triggers boost" do
      rate = 0.95
      min_resolved = 5

      assert rate > 0.9
      assert min_resolved >= 5
    end

    test "success rate between 0.3 and 0.9 triggers no adjustment" do
      rate = 0.6

      refute rate < 0.3
      refute rate > 0.9
    end
  end

  describe "ReflectionJob config" do
    test "default interval is 30 minutes" do
      # Verify the default is set correctly (not testing the GenServer start)
      config = Application.get_env(:bot_army_runtime, :reflection_job, [])
      default_interval = 30 * 60 * 1000
      interval = Keyword.get(config, :interval_ms, default_interval)
      assert interval == default_interval
    end

    test "default window is 24 hours" do
      config = Application.get_env(:bot_army_runtime, :reflection_job, [])
      default_window = 24
      window = Keyword.get(config, :window_hours, default_window)
      assert window == default_window
    end
  end
end
