defmodule BotArmyRuntime.Intent.DeferHandler do
  @moduledoc """
  Handles deferred intent decisions by starting an LLM conversation
  to compose a softer, context-aware message.

  Called from IntentEvaluator's `:defer` branch. Each bot configures
  per-action defer behavior via keyword lists with `:prompt_builder`
  and `:delivery_fn` callbacks.

  ## Flow

  1. IntentEvaluator gets `{:ok, :defer, details}` from ThresholdModel
  2. Calls `handle_defer(bot_name, action, details, context, config)`
  3. DeferHandler checks rate limit (via DeferRateLimiter)
  4. If allowed, starts conversation with LLM bot via Conversation.Manager
  5. LLM responds → `{:conv_reply, conversation_id, body}` delivered to IntentEvaluator
  6. IntentEvaluator calls `process_reply/5` which invokes the delivery_fn
  """

  require Logger

  alias BotArmyRuntime.Intent.DeferRateLimiter
  alias BotArmyRuntime.NATS.Publisher

  @doc """
  Handle a deferred intent by starting an LLM conversation.

  Returns `{:ok, conversation_id}` if a conversation was started,
  `:rate_limited` if too recent, `:no_handler` if action has no defer config,
  or `{:error, reason}` on failure.

  The `config` is a keyword list per-action configuration:
    - `:prompt_builder` — (required) `fn(action, details, context) -> body_map`
    - `:delivery_fn` — (required) `fn(bot_name, action, llm_response, details) -> :ok | {:error, term}`
    - `:llm_intent` — (optional) intent to send LLM, default: "classify"
    - `:timeout_ms` — (optional) conversation timeout, default: 15_000
  """
  @spec handle_defer(String.t(), String.t(), map(), map(), keyword()) ::
          {:ok, String.t()} | :rate_limited | :no_handler | {:error, term()}
  def handle_defer(bot_name, action, details, context, config) do
    if not enabled?() do
      :no_handler
    else
      do_handle_defer(bot_name, action, details, context, config)
    end
  end

  defp do_handle_defer(bot_name, action, details, context, config) do
    rate_limit_key = Keyword.get(config, :rate_limit_key, "#{bot_name}:#{action}")

    case DeferRateLimiter.check_and_mark(rate_limit_key) do
      :allowed ->
        start_defer_conversation(bot_name, action, details, context, config)

      {:rate_limited, remaining_ms} ->
        Logger.debug(
          "[DeferHandler] Rate limited for #{bot_name}:#{action}, #{div(remaining_ms, 1000)}s remaining"
        )

        publish_defer_event(bot_name, action, details, nil, true)
        :rate_limited
    end
  end

  @doc """
  Process an LLM conversation reply for a defer conversation.

  Called from IntentEvaluator's `handle_info({:conv_reply, ...})`.
  Routes to the action-specific delivery function from config.
  """
  @spec process_reply(String.t(), String.t(), map(), map(), keyword()) ::
          :ok | {:error, term()}
  def process_reply(bot_name, _conversation_id, body, details, config) do
    delivery_fn = Keyword.fetch!(config, :delivery_fn)
    action = Map.get(details, :action, "unknown")
    llm_response = extract_llm_response(body)

    Logger.info("[DeferHandler] Processing defer reply for #{bot_name} action=#{action}")

    case delivery_fn.(bot_name, action, llm_response, details) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("[DeferHandler] Defer delivery failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Default prompt builder. Bots can override with their own function.

  Produces a body map with "intent" and "text" keys suitable for
  the LLM bot's ConversationHandler (intent: "classify" → :fast LLM).
  """
  @spec default_prompt_builder(String.t(), map(), map()) :: map()
  def default_prompt_builder(action, details, context) do
    %{
      "intent" => "classify",
      "text" => build_default_prompt(action, details, context)
    }
  end

  # ─────────────────────────────────────────────────────────────────────────
  # Private
  # ─────────────────────────────────────────────────────────────────────────

  defp start_defer_conversation(bot_name, action, details, context, config) do
    prompt_builder = Keyword.get(config, :prompt_builder, &default_prompt_builder/3)
    body = prompt_builder.(action, details, context)
    llm_intent = Keyword.get(config, :llm_intent, config_default_llm_intent())
    timeout_ms = Keyword.get(config, :timeout_ms, config_default_timeout_ms())

    body = Map.put(body, "intent", llm_intent)

    try do
      case BotArmyRuntime.NATS.Conversation.Manager.start_conversation(
             bot_name,
             "llm",
             "query",
             body,
             timeout_ms: timeout_ms,
             max_turns: 1,
             priority: "low"
           ) do
        {:ok, conversation_id} ->
          publish_defer_event(bot_name, action, details, conversation_id, false)

          Logger.info(
            "[DeferHandler] #{bot_name} started defer conversation for #{action}: #{String.slice(conversation_id, 0..7)}"
          )

          {:ok, conversation_id}

        {:error, reason} ->
          Logger.warning("[DeferHandler] Failed to start defer conversation: #{inspect(reason)}")
          {:error, reason}
      end
    rescue
      UndefinedFunctionError ->
        Logger.debug("[DeferHandler] Conversation system not available, deferring to background")

        publish_defer_event(bot_name, action, details, nil, true)
        {:error, :conversation_unavailable}

      e ->
        Logger.warning("[DeferHandler] Error starting defer conversation: #{inspect(e)}")
        {:error, e}
    end
  end

  defp build_default_prompt(action, details, context) do
    """
    The intent "#{action}" was deferred (score: #{Float.round(details.score, 2)}, reason: #{details.reason}).

    Context: #{format_context_summary(context)}

    Compose a brief, gentle message the user might see as a soft nudge
    instead of a full alert. Keep it under 2 sentences. Be specific but
    not pushy. If there's nothing useful to say, respond with just: skip
    """
    |> String.trim()
  end

  defp format_context_summary(context) do
    entry_count = Map.get(context, :entry_count, 0)
    summary = Map.get(context, :summary, %{})

    if map_size(summary) > 0 do
      entries =
        summary
        |> Enum.take(3)
        |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{inspect(v)}" end)

      "#{entry_count} observations (#{entries})"
    else
      "#{entry_count} observations"
    end
  end

  defp extract_llm_response(%{"response" => _} = body), do: body
  defp extract_llm_response(%{"data" => %{"response" => _} = data}), do: data
  defp extract_llm_response(body), do: body

  defp publish_defer_event(bot_name, action, details, conversation_id, rate_limited) do
    event = %{
      "event_id" => UUID.uuid4(),
      "event" => "events.bot_army.intent.deferred",
      "schema_version" => "1.0",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_runtime",
      "source_node" => Atom.to_string(node()),
      "payload" => %{
        "bot_name" => bot_name,
        "action" => action,
        "score" => details.score,
        "defer_reason" => Atom.to_string(details.reason),
        "conversation_id" => conversation_id,
        "rate_limited" => rate_limited
      }
    }

    Task.start(fn ->
      Publisher.publish("events.bot_army.intent.deferred", event)
    end)
  end

  defp enabled? do
    Application.get_env(:bot_army_library_runtime, :defer_handler, [])
    |> Keyword.get(:enabled, true)
  end

  defp config_default_timeout_ms do
    Application.get_env(:bot_army_library_runtime, :defer_handler, [])
    |> Keyword.get(:timeout_ms, 15_000)
  end

  defp config_default_llm_intent do
    Application.get_env(:bot_army_library_runtime, :defer_handler, [])
    |> Keyword.get(:default_llm_intent, "ask")
  end
end
