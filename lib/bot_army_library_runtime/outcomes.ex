defmodule BotArmyLibraryRuntime.Outcomes do
  @moduledoc """
  Standardized outcome event publishing for cross-bot observability.

  Publishes to `outcomes.<bot_name>.<category>` so consumers like
  GTD's OutcomesConsumer and AnomalyAlerter can adjust scoring,
  detect trends, and trigger alerts.

  ## Usage

      BotArmyLibraryRuntime.Outcomes.emit("advocacy", "decision", "proposal_approved", 1,
        metadata: %{proposal_id: "abc", bill_id: "123"}
      )

      BotArmyLibraryRuntime.Outcomes.emit("notification_router", "routing", "route_to_discord", 1,
        metadata: %{notification_id: "n1", priority: "high"}
      )

  Payload format matches what GTD OutcomesIntegratorHandler expects:
  - metric_name — what is being measured
  - value — numeric or boolean result
  - trend_pct — optional percentage change
  - metadata — free-form context
  - bot_name / source — self-identifying
  - recorded_at — ISO8601 timestamp
  """

  require Logger

  alias BotArmyLibraryRuntime.NATS.Publisher

  @doc """
  Emit an outcome event to NATS.

  ## Options

    - `:trend_pct` — percentage change (default 0)
    - `:metadata` — extra context map (default %{})
    - `:subject_override` — custom NATS subject (default `outcomes.<bot>.<category>`)

  ## Returns

    - `{:ok, subject}` — published successfully
    - `{:error, reason}` — publishing failed (logged, non-blocking)
  """
  @spec emit(String.t(), String.t(), String.t(), number(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def emit(bot_name, category, metric_name, value, opts \\ [])
      when is_binary(bot_name) and is_binary(category) and is_binary(metric_name) do
    subject = Keyword.get(opts, :subject_override, "outcomes.#{bot_name}.#{category}")

    payload = %{
      "metric_name" => metric_name,
      "value" => value,
      "bot_name" => bot_name,
      "source" => bot_name,
      "category" => category,
      "trend_pct" => Keyword.get(opts, :trend_pct, 0),
      "metadata" => Keyword.get(opts, :metadata, %{}),
      "recorded_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    case Publisher.publish(subject, payload) do
      {:ok, _} = ok ->
        ok

      {:error, reason} = err ->
        Logger.warning("[Outcomes] Failed to publish outcome event",
          bot: bot_name,
          category: category,
          metric: metric_name,
          reason: inspect(reason)
        )

        err
    end
  end

  @doc """
  Convenience for recording a decision + result pair.

  Emits two events:
  1. `outcomes.<bot>.<category>.decision` with the decision taken
  2. `outcomes.<bot>.<category>.result` with the result

  This is the canonical pattern for bots that need feedback-loop learning.
  """
  @spec record_decision(String.t(), String.t(), String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def record_decision(bot_name, category, item_id, decision, actual_result, opts \\ [])
      when is_binary(bot_name) and is_binary(category) and is_binary(item_id) do
    metadata =
      opts
      |> Keyword.get(:metadata, %{})
      |> Map.put("item_id", item_id)
      |> Map.put("decision", decision)
      |> Map.put("actual_result", actual_result)

    emit(bot_name, category, "#{decision}_#{actual_result}", 1, metadata: metadata)
  end
end
