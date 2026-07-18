defmodule BotArmyLibraryRuntime.Intent.ActionHandler do
  @moduledoc """
  Handles post-intent actions when ThresholdModel decides to act and
  Publisher.publish_intent returns {:proceed, intent_id, endorsements}.

  Each bot configures per-action handlers via act_config/1 in their
  IntentEvaluator module, mirroring the defer_config/1 pattern.

  ## Flow

  1. ThresholdModel returns {:ok, :act, details}
  2. Publisher.publish_intent returns {:proceed, intent_id, endorsements}
  3. IntentEvaluator calls ActionHandler.execute_action/6
  4. ActionHandler calls the configured handler_fn
  5. ActionHandler publishes events.bot_army.intent.acted for observability
  """

  require Logger

  alias BotArmyLibraryRuntime.NATS.Publisher

  @doc """
  Execute an action handler after intent proceeds.

  Config is a keyword list from act_config/1:
    - :handler_fn — (required) fn(bot_name, action, intent_id, details, endorsements) -> :ok | {:error, term()}

  Returns {:ok, result} or {:error, reason}.
  If no config is found for the action, returns :no_handler (backward compatible).
  """
  @spec execute_action(String.t(), String.t(), String.t(), map(), list(), keyword() | nil) ::
          {:ok, any()} | {:error, term()} | :no_handler
  def execute_action(_bot_name, action, _intent_id, _details, _endorsements, nil) do
    Logger.debug("[ActionHandler] No act config for action=#{action}, skipping")
    :no_handler
  end

  def execute_action(bot_name, action, intent_id, details, endorsements, config) do
    handler_fn = Keyword.fetch!(config, :handler_fn)

    Logger.info("[ActionHandler] Executing #{action} for #{bot_name} (intent_id=#{intent_id})")

    result = handler_fn.(bot_name, action, intent_id, details, endorsements)

    publish_acted_event(bot_name, action, intent_id, details, endorsements)

    {:ok, result}
  rescue
    e ->
      Logger.warning("[ActionHandler] Failed to execute #{action} for #{bot_name}: #{inspect(e)}")
      {:error, e}
  end

  defp publish_acted_event(bot_name, action, intent_id, details, endorsements) do
    endorsers = Enum.map(endorsements, fn {bot, _corr_id} -> bot end)

    event = %{
      "event_id" => UUID.uuid4(),
      "event" => "events.bot_army.intent.acted",
      "schema_version" => "1.0",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_runtime",
      "source_node" => Atom.to_string(node()),
      "payload" => %{
        "bot_name" => bot_name,
        "action" => action,
        "intent_id" => intent_id,
        "score" => Map.get(details, :score, 0),
        "reason" => Map.get(details, :reason, "threshold_met") |> to_string(),
        "endorsed_by" => endorsers
      }
    }

    Task.start(fn ->
      Publisher.publish("events.bot_army.intent.acted", event)
    end)
  end
end