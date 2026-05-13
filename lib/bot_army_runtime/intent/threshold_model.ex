defmodule BotArmyRuntime.Intent.ThresholdModel do
  @moduledoc """
  Evaluates accumulated context against configurable thresholds to decide
  whether a bot should publish an intent.

  The ThresholdModel is called from a heartbeat cycle. It reads the
  AccumulatedContext snapshot and checks if conditions cross the threshold
  for action. Combined with the `bridge.random.roll` endpoint for tiebreaking,
  it returns a decision: `:act`, `:defer`, or `:abort`.

  ## Usage

      alias BotArmyRuntime.Intent.{ThresholdModel, AccumulatedContext, Publisher}

      # Define thresholds for a bot (typically in config)
      thresholds = %{
        stale_task_count: %{min: 3, weight: 0.4},
        idle_minutes: %{min: 30, weight: 0.3},
        random_threshold: 0.5
      }

      # Evaluate from heartbeat
      context = AccumulatedContext.snapshot("gtd")
      {:ok, decision, details} = ThresholdModel.evaluate("gtd", "nudge", thresholds, context)

      case decision do
        :act ->
          Publisher.publish_intent("gtd", "nudge", %{
            threshold_result: details,
            context_snapshot: context
          })

        :defer ->
          Logger.debug("[Heartbeat] Deferring nudge intent")

        :abort ->
          Logger.debug("[Heartbeat] Aborting nudge intent, conditions not met")
      end

  ## Threshold Configuration

  Each threshold is a map with:

    - `:min` — minimum value to consider the condition met
    - `:weight` — how much this condition contributes to the overall score (0.0–1.0)
    - `:max` — optional maximum value (caps the contribution)
    - `:invert` — optional boolean, if true the score decreases as the value increases

  The `:random_threshold` key sets the minimum random roll total needed to act
  when conditions are borderline. Uses `bridge.random.roll` with a configured
  dice notation.

  ## Configuration

      config :bot_army_runtime, :threshold_model,
        default_dice: "1d20",
        random_subject: "bridge.random.roll",
        random_timeout_ms: 2_000
  """

  require Logger

  alias BotArmyRuntime.Intent.AccumulatedContext

  @default_dice "1d20"
  @default_random_timeout_ms 2_000

  @type decision :: :act | :defer | :abort
  @type threshold_config :: %{
          required(:min) => number(),
          required(:weight) => float(),
          optional(:max) => number(),
          optional(:invert) => boolean()
        }

  @doc """
  Evaluate whether a bot should publish an intent based on accumulated context
  and thresholds.

  Returns `{:ok, decision, details}` where details contains the full evaluation
  breakdown including scores, random roll, and threshold values.

  The evaluation works in three steps:
  1. Compute a weighted score from context vs thresholds (0.0–1.0)
  2. If score >= 1.0, decide `:act` (no random roll needed)
  3. If score is between `random_threshold` and 1.0, roll the dice:
     - High roll → `:act`
     - Low roll → `:defer`
  4. If score < `random_threshold`, decide `:abort`
  """
  @spec evaluate(String.t(), String.t(), map(), map()) ::
          {:ok, decision(), map()} | {:error, term()}
  def evaluate(bot_name, action, thresholds, context \\ %{}) do
    evaluate(bot_name, action, thresholds, context, %{})
  end

  @doc """
  Evaluate with outcome-based adjustment factors.

  The `adjustments` map has string keys matching observation types, with float
  values as multipliers on the static weight. For example:
  `%{"stale_task_count" => 0.7}` reduces that weight by 30%.

  An empty adjustments map (default) produces identical results to `evaluate/4`.
  """
  @spec evaluate(String.t(), String.t(), map(), map(), map()) ::
          {:ok, decision(), map()} | {:error, term()}
  def evaluate(bot_name, action, thresholds, context, adjustments) do
    context = if context == %{}, do: AccumulatedContext.snapshot(bot_name), else: context

    random_threshold = Map.get(thresholds, :random_threshold, 0.5)

    case compute_weighted_score(context, thresholds, adjustments) do
      {:ok, score, score_details} ->
        decide(bot_name, action, score, random_threshold, score_details, thresholds)

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Evaluate with adjustments loaded from the database.

  Reads the latest adjustments for the given bot+action from
  `intent_threshold_adjustments` and uses them as multipliers on
  the static threshold weights.
  """
  @spec evaluate_with_adjustments(String.t(), String.t(), map(), map(), keyword()) ::
          {:ok, decision(), map()} | {:error, term()}
  def evaluate_with_adjustments(bot_name, action, thresholds, context, opts \\ []) do
    adjustments =
      BotArmy.IntentThresholdAdjustment.latest_adjustments(bot_name, action, opts)
      |> Enum.map(fn adj -> {adj.observation_type, adj.adjusted_weight / adj.original_weight} end)
      |> Map.new()

    evaluate(bot_name, action, thresholds, context, adjustments)
  end

  @doc """
  Compute only the weighted score without making a decision.

  Useful for debugging or logging without triggering action.
  """
  @spec compute_score(map(), map()) :: {:ok, float(), map()} | {:error, term()}
  def compute_score(context, thresholds) do
    compute_weighted_score(context, thresholds)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Private
  # ───────────────────────────────────────────────────────────────────────────

  defp compute_weighted_score(context, thresholds, adjustments \\ %{}) do
    entries = Map.get(context, :entries, [])

    score_details =
      thresholds
      |> Enum.filter(fn {key, _} -> key != :random_threshold end)
      |> Enum.map(fn {key, config} ->
        entry_type = key
        value = extract_value(entries, entry_type)
        adjustment = Map.get(adjustments, Atom.to_string(key), 1.0)
        adjusted_weight = config.weight * adjustment
        contribution = compute_contribution(value, Map.put(config, :weight, adjusted_weight))

        {key,
         %{
           value: value,
           threshold_min: config.min,
           weight: config.weight,
           adjustment: adjustment,
           adjusted_weight: adjusted_weight,
           contribution: contribution
         }}
      end)
      |> Map.new()

    total_weight =
      score_details
      |> Map.values()
      |> Enum.map(& &1.adjusted_weight)
      |> Enum.sum()

    weighted_sum =
      score_details
      |> Map.values()
      |> Enum.map(& &1.contribution)
      |> Enum.sum()

    score = if total_weight > 0, do: weighted_sum / total_weight, else: 0.0

    {:ok, score, score_details}
  end

  defp extract_value(entries, type) do
    case Enum.filter(entries, &(&1.type == type)) do
      [] ->
        0

      matching ->
        case List.first(matching).value do
          nil -> length(matching)
          val when is_number(val) -> val
          val when is_map(val) -> Map.get(val, :count, length(matching))
          _ -> length(matching)
        end
    end
  end

  defp compute_contribution(value, config) do
    min = config.min
    max = Map.get(config, :max, nil)
    invert = Map.get(config, :invert, false)
    weight = config.weight

    normalized =
      cond do
        value < min -> 0.0
        max && value > max -> 1.0
        max -> (value - min) / (max - min)
        true -> 1.0
      end

    contribution = if invert, do: (1.0 - normalized) * weight, else: normalized * weight
    Float.round(contribution, 4)
  end

  defp decide(bot_name, action, score, random_threshold, score_details, _thresholds) do
    cond do
      score >= 1.0 ->
        # Clear threshold — act without random roll
        {:ok, :act, build_details(score, nil, :clear_threshold, score_details)}

      score >= random_threshold ->
        # Borderline — roll the dice
        case roll_random(bot_name, action) do
          {:ok, roll_result} ->
            roll_normalized = roll_result.total / 20.0

            if roll_normalized + score >= 1.0 do
              {:ok, :act, build_details(score, roll_result, :random_boost, score_details)}
            else
              {:ok, :defer, build_details(score, roll_result, :low_roll, score_details)}
            end

          {:error, reason} ->
            Logger.warning("[ThresholdModel] Random roll failed: #{inspect(reason)}, deferring")
            {:ok, :defer, build_details(score, nil, {:random_error, reason}, score_details)}
        end

      true ->
        # Below threshold — abort
        {:ok, :abort, build_details(score, nil, :below_threshold, score_details)}
    end
  end

  defp roll_random(bot_name, action) do
    dice = config_dice()
    timeout = config_random_timeout()

    payload = %{
      "notation" => dice,
      "purpose" => "intent_threshold:#{bot_name}:#{action}"
    }

    case BotArmyRuntime.NATS.Publisher.request("bridge.random.roll", payload, timeout_ms: timeout) do
      {:ok, %{"ok" => true, "data" => data}} ->
        {:ok,
         %{
           notation: Map.get(data, "notation", dice),
           total: Map.get(data, "total", 0),
           rolls: Map.get(data, "rolls", []),
           seed_used: Map.get(data, "seed_used"),
           purpose: Map.get(data, "purpose")
         }}

      {:ok, %{"ok" => false, "error" => error}} ->
        {:error, error}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_details(score, random_roll, reason, score_details) do
    %{
      score: Float.round(score, 4),
      random_roll: random_roll,
      reason: reason,
      threshold_breakdown: score_details
    }
  end

  defp config_dice, do: get_in_config([:dice], @default_dice)
  defp config_random_timeout, do: get_in_config([:random_timeout_ms], @default_random_timeout_ms)

  defp get_in_config(path, default) do
    config = Application.get_env(:bot_army_runtime, :threshold_model, [])
    Keyword.get(config, path, default)
  end
end
