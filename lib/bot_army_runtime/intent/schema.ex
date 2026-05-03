defmodule BotArmyRuntime.Intent.Schema do
  @moduledoc """
  NATS subject conventions for intent-based decision making.

  ## Intent vs Request/Reply

  **Intent subjects** (async, publish) — a bot decides it might act, publishes
  an intent, waits briefly for vetoes, then acts or aborts. No caller is waiting.

  **Request/reply subjects** — a user or surface asks, a bot responds synchronously.
  These stay unchanged.

  ## Subject Convention

  Intents follow the pattern:

      bot_army.<bot>.intent.<action>

  Examples:

      bot_army.gtd.intent.nudge        # GTD bot may nudge user about stale task
      bot_army.gtd.intent.remind       # GTD bot may remind about upcoming deadline
      bot_army.fitness.intent.suggest  # Fitness bot may suggest a workout
      bot_army.llm.intent.summarize   # LLM bot may summarize recent activity

  Request/reply subjects stay as-is (no change):

      gtd.task.create    # User creates a task
      gtd.task.list      # TUI requests task list
      llm.chat           # Interactive conversation
      llm.decompose      # On-demand decomposition

  ## Intent Envelope

  Every intent publication includes:

      {
        "intent_id": "uuid4",
        "bot_id": "gtd",
        "action": "nudge",
        "subject": "bot_army.gtd.intent.nudge",
        "context_snapshot": { ... },      # AccumulatedContext at decision time
        "threshold_result": { ... },       # ThresholdModel evaluation
        "random_roll": { ... },            # bridge.random.roll result
        "decision": "act|defer|abort",
        "correlation_id": "uuid4",
        "timestamp": "ISO8601"
      }

  ## Veto Window

  After publishing an intent, the bot waits a short window (default 2s) for
  veto responses on `bot_army.<bot>.intent.<action>.response`. If no veto is
  received, the bot proceeds. Veto responses include:

      { "veto": true, "reason": "...", "vetoing_bot": "fitness", "correlation_id": "..." }
  """

  @intent_prefix "bot_army"
  @intent_segment "intent"
  @veto_timeout_ms 2_000

  @doc "Build an intent subject for a bot and action."
  @spec intent_subject(bot_name :: String.t(), action :: String.t()) :: String.t()
  def intent_subject(bot_name, action) do
    "#{@intent_prefix}.#{bot_name}.#{@intent_segment}.#{action}"
  end

  @doc "Build the veto response subject for a bot and action."
  @spec veto_subject(bot_name :: String.t(), action :: String.t()) :: String.t()
  def veto_subject(bot_name, action) do
    "#{@intent_prefix}.#{bot_name}.#{@intent_segment}.#{action}.response"
  end

  @doc "Wildcard subject to subscribe to all intents for a bot."
  @spec all_intents_for(bot_name :: String.t()) :: String.t()
  def all_intents_for(bot_name) do
    "#{@intent_prefix}.#{bot_name}.#{@intent_segment}.>"
  end

  @doc "Wildcard subject to subscribe to all intents across all bots."
  @spec all_intents() :: String.t()
  def all_intents do
    "#{@intent_prefix}.*.#{@intent_segment}.>"
  end

  @doc "Default veto window in milliseconds."
  @spec veto_timeout_ms() :: non_neg_integer()
  def veto_timeout_ms, do: @veto_timeout_ms

  @doc "Parse an intent subject into {bot_name, action}."
  @spec parse_subject(subject :: String.t()) ::
          {:ok, {String.t(), String.t()}} | {:error, :invalid_format}
  def parse_subject(subject) do
    case String.split(subject, ".") do
      [@intent_prefix, bot_name, @intent_segment, action] ->
        {:ok, {bot_name, action}}

      [@intent_prefix, bot_name, @intent_segment, action, "response"] ->
        {:ok, {bot_name, action}}

      _ ->
        {:error, :invalid_format}
    end
  end

  @doc "Check if a subject is an intent subject."
  @spec intent?(subject :: String.t()) :: boolean()
  def intent?(subject) do
    case String.split(subject, ".") do
      [@intent_prefix, _, @intent_segment | _] -> true
      _ -> false
    end
  end

  @doc "Check if a subject is a veto response subject."
  @spec veto_response?(subject :: String.t()) :: boolean()
  def veto_response?(subject) do
    case String.split(subject, ".") do
      [@intent_prefix, _, @intent_segment, _, "response"] -> true
      _ -> false
    end
  end
end
