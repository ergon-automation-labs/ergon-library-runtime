defmodule BotArmyLibraryRuntime.Intent.ThresholdModelTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyLibraryRuntime.Intent.ThresholdModel

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

  describe "evaluate/5 with adjustments" do
    test "adjustments with factor 1.0 produce same result as no adjustments" do
      context = %{
        entries: [
          %{type: :stale_task_count, value: 5, observed_at: DateTime.utc_now(), metadata: %{}},
          %{type: :idle_minutes, value: 60, observed_at: DateTime.utc_now(), metadata: %{}}
        ]
      }

      thresholds = %{
        stale_task_count: %{min: 3, weight: 0.6},
        idle_minutes: %{min: 30, weight: 0.4}
      }

      {:ok, decision_no_adj, details_no_adj} =
        ThresholdModel.evaluate("test_bot", "nudge", thresholds, context)

      # Factor 1.0 for everything means no adjustment
      adjustments = %{"stale_task_count" => 1.0, "idle_minutes" => 1.0}

      {:ok, decision_adj, details_adj} =
        ThresholdModel.evaluate("test_bot", "nudge", thresholds, context, adjustments)

      assert decision_no_adj == decision_adj
      assert_in_delta details_no_adj.score, details_adj.score, 0.001

      assert_in_delta details_no_adj.threshold_breakdown[:stale_task_count].contribution,
                      details_adj.threshold_breakdown[:stale_task_count].contribution,
                      0.001
    end

    test "adjustment factor 0.5 reduces contribution proportionally" do
      context = %{
        entries: [
          %{type: :stale_task_count, value: 10, observed_at: DateTime.utc_now(), metadata: %{}},
          %{type: :idle_minutes, value: 60, observed_at: DateTime.utc_now(), metadata: %{}}
        ]
      }

      thresholds = %{
        stale_task_count: %{min: 3, weight: 0.6},
        idle_minutes: %{min: 30, weight: 0.4}
      }

      # No adjustments: both weights meet threshold, score = 1.0
      {:ok, decision_baseline, details_baseline} =
        ThresholdModel.evaluate("test_bot", "nudge", thresholds, context)

      assert decision_baseline == :act
      assert details_baseline.score == 1.0

      # Reduce stale_task_count weight by 50%
      adjustments = %{"stale_task_count" => 0.5}

      {:ok, decision_reduced, details} =
        ThresholdModel.evaluate("test_bot", "nudge", thresholds, context, adjustments)

      # Adjusted weight for stale_task_count should be 0.6 * 0.5 = 0.3
      assert details.threshold_breakdown[:stale_task_count].adjusted_weight == 0.3
      assert details.threshold_breakdown[:stale_task_count].adjustment == 0.5
      # idle_minutes weight unchanged
      assert details.threshold_breakdown[:idle_minutes].adjusted_weight == 0.4
      # Total weight should be 0.3 + 0.4 = 0.7
      # Weighted sum = 0.3 (stale met) + 0.4 (idle met) = 0.7
      # Score = 0.7 / 0.7 = 1.0 (both still meet thresholds)
      assert decision_reduced == :act
      assert details.score == 1.0
    end

    test "adjustment factor 0.0 effectively disables an observation type" do
      context = %{
        entries: [
          %{type: :stale_task_count, value: 10, observed_at: DateTime.utc_now(), metadata: %{}},
          %{type: :idle_minutes, value: 5, observed_at: DateTime.utc_now(), metadata: %{}}
        ]
      }

      thresholds = %{
        stale_task_count: %{min: 3, weight: 0.6},
        idle_minutes: %{min: 30, weight: 0.4}
      }

      # With idle_minutes at 5 (below min 30), it contributes 0.
      # stale_task_count at 10 (above min 3) contributes 0.6.
      # Total weight = 0.6 + 0.4 = 1.0. Score = 0.6 / 1.0 = 0.6.
      {:ok, _decision_baseline, details_baseline} =
        ThresholdModel.evaluate("test_bot", "nudge", thresholds, context)

      assert_in_delta details_baseline.score, 0.6, 0.001

      # Zero out stale_task_count: adjusted weight = 0, contribution = 0
      adjustments = %{"stale_task_count" => 0.0}

      {:ok, decision_zeroed, details} =
        ThresholdModel.evaluate("test_bot", "nudge", thresholds, context, adjustments)

      assert details.threshold_breakdown[:stale_task_count].adjusted_weight == 0.0
      # idle_minutes still 0, stale now 0 contribution with 0 weight
      # Score = 0 / 0.4 = 0.0
      assert decision_zeroed == :abort
      assert details.score == 0.0
    end

    test "empty adjustments map produces same result as evaluate/4" do
      context = %{
        entries: [
          %{type: :stale_task_count, value: 5, observed_at: DateTime.utc_now(), metadata: %{}}
        ]
      }

      thresholds = %{
        stale_task_count: %{min: 3, weight: 0.6},
        random_threshold: 0.5
      }

      {:ok, score_4, _} = ThresholdModel.evaluate("test_bot", "nudge", thresholds, context)
      {:ok, score_5, _} = ThresholdModel.evaluate("test_bot", "nudge", thresholds, context, %{})

      assert score_4 == score_5
    end

    test "adjustment details include adjustment factor and adjusted weight" do
      context = %{
        entries: [
          %{type: :stale_task_count, value: 10, observed_at: DateTime.utc_now(), metadata: %{}}
        ]
      }

      thresholds = %{stale_task_count: %{min: 3, weight: 0.6}}

      adjustments = %{"stale_task_count" => 0.7}

      {:ok, _decision, details} =
        ThresholdModel.evaluate("test_bot", "nudge", thresholds, context, adjustments)

      assert details.threshold_breakdown[:stale_task_count].weight == 0.6
      assert details.threshold_breakdown[:stale_task_count].adjustment == 0.7
      assert details.threshold_breakdown[:stale_task_count].adjusted_weight == 0.42
      assert details.threshold_breakdown[:stale_task_count].contribution == 0.42
    end
  end
end
