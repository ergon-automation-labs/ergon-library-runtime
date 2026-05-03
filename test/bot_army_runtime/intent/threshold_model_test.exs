defmodule BotArmyRuntime.Intent.ThresholdModelTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyRuntime.Intent.ThresholdModel

  describe "compute_score/2" do
    test "computes weighted score from context entries" do
      context = %{
        entries: [
          %{type: :stale_task_count, value: 5, observed_at: DateTime.utc_now(), metadata: %{}},
          %{type: :idle_minutes, value: 120, observed_at: DateTime.utc_now(), metadata: %{}}
        ]
      }

      thresholds = %{
        stale_task_count: %{min: 3, weight: 0.6},
        idle_minutes: %{min: 30, weight: 0.4}
      }

      {:ok, score, details} = ThresholdModel.compute_score(context, thresholds)

      assert is_float(score)
      assert score > 0.0
      assert Map.has_key?(details, :stale_task_count)
      assert Map.has_key?(details, :idle_minutes)
    end

    test "returns 0 score when all values below minimums" do
      context = %{
        entries: [
          %{type: :stale_task_count, value: 1, observed_at: DateTime.utc_now(), metadata: %{}},
          %{type: :idle_minutes, value: 5, observed_at: DateTime.utc_now(), metadata: %{}}
        ]
      }

      thresholds = %{
        stale_task_count: %{min: 3, weight: 0.6},
        idle_minutes: %{min: 30, weight: 0.4}
      }

      {:ok, score, _details} = ThresholdModel.compute_score(context, thresholds)

      assert score == 0.0
    end

    test "returns full score when all values meet threshold" do
      context = %{
        entries: [
          %{type: :stale_task_count, value: 10, observed_at: DateTime.utc_now(), metadata: %{}},
          %{type: :idle_minutes, value: 300, observed_at: DateTime.utc_now(), metadata: %{}}
        ]
      }

      thresholds = %{
        stale_task_count: %{min: 3, weight: 0.6},
        idle_minutes: %{min: 30, weight: 0.4}
      }

      {:ok, score, _details} = ThresholdModel.compute_score(context, thresholds)

      assert score == 1.0
    end

    test "handles empty context" do
      context = %{entries: []}

      thresholds = %{
        stale_task_count: %{min: 3, weight: 0.6}
      }

      {:ok, score, _details} = ThresholdModel.compute_score(context, thresholds)

      assert score == 0.0
    end

    test "respects max threshold" do
      context = %{
        entries: [
          %{type: :stale_task_count, value: 100, observed_at: DateTime.utc_now(), metadata: %{}}
        ]
      }

      thresholds = %{
        stale_task_count: %{min: 3, max: 10, weight: 1.0}
      }

      {:ok, score, details} = ThresholdModel.compute_score(context, thresholds)

      assert score == 1.0
      assert details.stale_task_count.value == 100
    end

    test "inverted threshold decreases score as value increases" do
      context_high = %{
        entries: [
          %{type: :activity_score, value: 100, observed_at: DateTime.utc_now(), metadata: %{}}
        ]
      }

      context_low = %{
        entries: [
          %{type: :activity_score, value: 5, observed_at: DateTime.utc_now(), metadata: %{}}
        ]
      }

      thresholds = %{
        activity_score: %{min: 0, max: 100, weight: 1.0, invert: true}
      }

      {:ok, high_score, _} = ThresholdModel.compute_score(context_high, thresholds)
      {:ok, low_score, _} = ThresholdModel.compute_score(context_low, thresholds)

      assert high_score < low_score
    end
  end

  describe "compute_contribution/2 (via compute_score)" do
    test "contribution is 0 when value is below min" do
      context = %{
        entries: [
          %{type: :stale_task_count, value: 1, observed_at: DateTime.utc_now(), metadata: %{}}
        ]
      }

      thresholds = %{stale_task_count: %{min: 5, weight: 0.5}}

      {:ok, score, details} = ThresholdModel.compute_score(context, thresholds)

      assert details.stale_task_count.contribution == 0.0
      assert score == 0.0
    end

    test "contribution equals weight when value meets or exceeds min without max" do
      context = %{
        entries: [
          %{type: :stale_task_count, value: 10, observed_at: DateTime.utc_now(), metadata: %{}}
        ]
      }

      thresholds = %{stale_task_count: %{min: 3, weight: 0.5}}

      {:ok, score, details} = ThresholdModel.compute_score(context, thresholds)

      assert details.stale_task_count.contribution == 0.5
      assert score == 1.0
    end
  end
end
