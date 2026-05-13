defmodule BotArmyRuntime.Intent.ReflectionJob do
  @moduledoc """
  Periodic analysis of intent outcomes that proposes threshold weight adjustments.

  Scans recent outcomes for each active (bot_name, action) pair, detects patterns
  (consecutive failures, low/high success rates), and writes adjustments to
  `intent_threshold_adjustments`. ThresholdModel reads these alongside static
  config and applies them as multipliers.

  ## Pattern Detection Rules

    - **Consecutive failures**: 3+ vetoed or failed outcomes in a row for the
      same bot+action → reduce weight by 30% (factor 0.7)
    - **Low success rate**: success_rate < 0.3 over the window → factor = success_rate
    - **High success rate**: success_rate > 0.9 with 5+ resolved outcomes → factor 1.1

  ## Configuration

      config :bot_army_runtime, :reflection_job,
        interval_ms: 30 * 60 * 1000,   # 30 minutes
        window_hours: 24,                # look at last 24h of outcomes
        min_sample_size: 3              # need at least 3 resolved outcomes
  """

  use GenServer

  require Logger

  alias BotArmy.IntentOutcome
  alias BotArmy.IntentThresholdAdjustment
  alias BotArmyRuntime.NATS.Publisher

  @default_interval_ms 30 * 60 * 1000
  @default_window_hours 24
  @default_min_sample_size 3

  # ───────────────────────────────────────────────────────────────────────────
  # Client API
  # ───────────────────────────────────────────────────────────────────────────

  @doc """
  Start the ReflectionJob GenServer.
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Force an immediate reflection cycle. Returns the reflection results.
  """
  @spec reflect() :: {:ok, map()} | {:error, term()}
  def reflect do
    GenServer.call(__MODULE__, :reflect)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # GenServer Callbacks
  # ───────────────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    interval_ms = Keyword.get(opts, :interval_ms, config_interval())

    state = %{
      interval_ms: interval_ms,
      last_run_at: nil
    }

    schedule_tick(interval_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:reflect, _from, state) do
    result = do_reflect()
    {:reply, result, state}
  end

  @impl true
  def handle_info(:tick, state) do
    _result = do_reflect()
    new_state = %{state | last_run_at: DateTime.utc_now()}
    schedule_tick(state.interval_ms)
    {:noreply, new_state}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Reflection Logic
  # ───────────────────────────────────────────────────────────────────────────

  defp do_reflect do
    window_hours = config_window_hours()
    min_sample = config_min_sample_size()

    case IntentOutcome.active_pairs(window_hours: window_hours) do
      [] ->
        Logger.debug("[ReflectionJob] No active pairs found, skipping")
        {:ok, %{pairs: [], adjustments: []}}

      pairs ->
        adjustments =
          pairs
          |> Enum.flat_map(fn %{bot_name: bot_name, action: action} ->
            analyze_pair(bot_name, action, window_hours, min_sample)
          end)

        emit_reflection_event(adjustments)

        Logger.info(
          "[ReflectionJob] Reflected on #{length(pairs)} pairs, wrote #{length(adjustments)} adjustments"
        )

        {:ok, %{pairs: length(pairs), adjustments: adjustments}}
    end
  rescue
    e ->
      Logger.warning("[ReflectionJob] Reflection failed: #{inspect(e)}")
      {:error, e}
  end

  defp analyze_pair(bot_name, action, window_hours, min_sample) do
    outcomes = IntentOutcome.recent_outcomes(bot_name, action, limit: 50)
    rate = IntentOutcome.success_rate(bot_name, action, window_hours: window_hours)

    resolved = Enum.filter(outcomes, &(&1.outcome not in [nil, "unknown"]))

    if length(resolved) < min_sample do
      []
    else
      rules = [
        consecutive_failures_rule(outcomes),
        low_success_rate_rule(rate, resolved),
        high_success_rate_rule(rate, resolved)
      ]

      rules
      |> Enum.filter(& &1)
      |> Enum.flat_map(fn rule ->
        apply_rule(rule, bot_name, action, outcomes)
      end)
    end
  end

  defp consecutive_failures_rule(outcomes) do
    consecutive_failures =
      outcomes
      |> Enum.take_while(fn o -> o.decision == "vetoed" or o.outcome == "failure" end)
      |> length()

    if consecutive_failures >= 3 do
      %{rule: :consecutive_failures, count: consecutive_failures, factor: 0.7}
    else
      nil
    end
  end

  defp low_success_rate_rule(rate, resolved) do
    if rate < 0.3 and length(resolved) >= 3 do
      %{rule: :low_success_rate, rate: rate, factor: max(rate, 0.1)}
    else
      nil
    end
  end

  defp high_success_rate_rule(rate, resolved) do
    if rate > 0.9 and length(resolved) >= 5 do
      %{rule: :high_success_rate, rate: rate, factor: 1.1}
    else
      nil
    end
  end

  defp apply_rule(rule, bot_name, action, outcomes) do
    observation_types =
      outcomes
      |> Enum.flat_map(fn o ->
        Map.get(o, :outcome_metadata, %{}) |> Map.get("observation_types", [])
      end)
      |> Enum.uniq()

    observation_types =
      if observation_types == [] do
        ["default"]
      else
        observation_types
      end

    results =
      for obs_type <- observation_types do
        original_weight = get_original_weight(obs_type, outcomes)

        attrs = %{
          bot_name: bot_name,
          action: action,
          observation_type: obs_type,
          original_weight: original_weight,
          adjusted_weight: Float.round(original_weight * rule.factor, 4),
          adjustment_reason: "#{rule.rule} (factor=#{rule.factor})",
          source: "reflection"
        }

        case IntentThresholdAdjustment.record(attrs) do
          {:ok, record} ->
            record

          :skipped ->
            Logger.debug("[ReflectionJob] Skipped adjustment write (repo unavailable)")
            nil

          {:error, reason} ->
            Logger.warning("[ReflectionJob] Failed to write adjustment: #{inspect(reason)}")
            nil
        end
      end

    Enum.filter(results, & &1)
  end

  defp get_original_weight(_obs_type, _outcomes), do: 1.0

  defp emit_reflection_event([]) do
    :ok
  end

  defp emit_reflection_event(adjustments) do
    event = %{
      "event_id" => UUID.uuid4(),
      "event" => "events.bot_army.intent.reflection",
      "schema_version" => "1.0",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_runtime",
      "source_node" => Atom.to_string(node()),
      "payload" => %{
        "adjustments_count" => length(adjustments),
        "adjustments" =>
          Enum.map(adjustments, fn adj ->
            %{
              "bot_name" => adj.bot_name,
              "action" => adj.action,
              "observation_type" => adj.observation_type,
              "original_weight" => adj.original_weight,
              "adjusted_weight" => adj.adjusted_weight,
              "adjustment_reason" => adj.adjustment_reason
            }
          end)
      }
    }

    Task.start(fn ->
      Publisher.publish("events.bot_army.intent.reflection", event)
    end)

    :ok
  end

  defp schedule_tick(interval_ms) do
    Process.send_after(self(), :tick, interval_ms)
  end

  defp config_interval do
    Application.get_env(:bot_army_runtime, :reflection_job, [])
    |> Keyword.get(:interval_ms, @default_interval_ms)
  end

  defp config_window_hours do
    Application.get_env(:bot_army_runtime, :reflection_job, [])
    |> Keyword.get(:window_hours, @default_window_hours)
  end

  defp config_min_sample_size do
    Application.get_env(:bot_army_runtime, :reflection_job, [])
    |> Keyword.get(:min_sample_size, @default_min_sample_size)
  end
end
