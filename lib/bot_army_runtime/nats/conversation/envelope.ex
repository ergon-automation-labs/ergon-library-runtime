defmodule BotArmyRuntime.NATS.Conversation.Envelope do
  @moduledoc """
  Build and validate conversation envelopes for cross-bot communication.

  Provides constructors for the three conversation patterns:
  - `build_request/5` — Start a new conversation (expects response)
  - `build_response/6` — Reply to an ongoing conversation
  - `build_followup/6` — Continue a multi-turn conversation
  - `build_mailbox/5` — Async message (no response expected)

  All functions inject standard envelope fields (event_id, timestamp, schema_version)
  and accept optional overrides via opts.
  """

  @schema_version "1.0"
  @source "bot_army_runtime"

  @valid_message_types ~w(query command clarify confirm result error gossip)
  @valid_conversation_types ~w(request response followup mailbox)

  @doc """
  Build a full NATS envelope for a conversation request.

  ## Options
    - `:tenant_id` — Tenant context (default: "default")
    - `:user_id` — User context (default: nil)
    - `:source` — Override source (default: "bot_army_runtime")
    - `:source_node` — Node name (default: node() atom)
    - `:priority` — Message priority (default: "normal")
    - `:reply_to` — Optional reply target (default: nil)
    - `:correlation_id` — Override correlation ID (default: auto)
    - `:context` — Extra context map merged into body.context
    - `:timeout_ms` — Suggested timeout for the request
  """
  def build_request(from_bot, to_bot, message_type, body, opts \\ []) do
    conversation_id = opts[:conversation_id] || uuid()

    payload = %{
      "conversation_id" => conversation_id,
      "conversation_type" => "request",
      "from_bot" => from_bot,
      "to_bot" => to_bot,
      "message_type" => validate_message_type!(message_type),
      "turn_number" => 1,
      "reply_to" => opts[:reply_to],
      "priority" => opts[:priority] || "normal",
      "body" => build_body(body, opts)
    }

    build_envelope("conv.request.#{to_bot}.#{conversation_id}", payload, opts)
  end

  @doc """
  Build a response payload for an ongoing conversation.

  The `original_envelope` is the request being responded to.
  Extracts conversation_id and from_bot for response routing.
  """
  def build_response(original_envelope, from_bot, body, opts \\ []) do
    payload = original_envelope["payload"] || original_envelope
    conversation_id = payload["conversation_id"]
    to_bot = payload["from_bot"]
    turn_number = (payload["turn_number"] || 1) + 1

    response_body = %{
      "conversation_id" => conversation_id,
      "conversation_type" => "response",
      "from_bot" => from_bot,
      "to_bot" => to_bot,
      "message_type" => opts[:message_type] || "result",
      "turn_number" => turn_number,
      "reply_to" => payload["conversation_id"],
      "priority" => opts[:priority] || "normal",
      "conversation_complete" => opts[:conversation_complete] || true,
      "body" => build_body(body, opts)
    }

    build_envelope("conv.response.#{conversation_id}", response_body, opts)
  end

  @doc """
  Build a follow-up turn in a multi-turn conversation.
  """
  def build_followup(conversation_id, from_bot, to_bot, message_type, body, opts \\ []) do
    turn_number = opts[:turn_number] || 2

    payload = %{
      "conversation_id" => conversation_id,
      "conversation_type" => "followup",
      "from_bot" => from_bot,
      "to_bot" => to_bot,
      "message_type" => validate_message_type!(message_type),
      "turn_number" => turn_number,
      "reply_to" => opts[:reply_to],
      "priority" => opts[:priority] || "normal",
      "body" => build_body(body, opts)
    }

    build_envelope("conv.followup.#{conversation_id}", payload, opts)
  end

  @doc """
  Build a mailbox message (async, no response expected).
  """
  def build_mailbox(from_bot, to_bot, message_type, body, opts \\ []) do
    conversation_id = uuid()

    payload = %{
      "conversation_id" => conversation_id,
      "conversation_type" => "mailbox",
      "from_bot" => from_bot,
      "to_bot" => to_bot,
      "message_type" => validate_message_type!(message_type),
      "turn_number" => 1,
      "priority" => opts[:priority] || "normal",
      "body" => build_body(body, opts)
    }

    build_envelope("conv.mailbox.#{to_bot}", payload, opts)
  end

  @doc """
  Validate that a map has the required conversation fields.
  """
  def valid_envelope?(envelope) when is_map(envelope) do
    payload = envelope["payload"] || envelope

    required = ~w(conversation_id from_bot to_bot message_type body)

    Enum.all?(required, fn field ->
      is_binary(payload[field]) or (field == "body" and is_map(payload[field]))
    end)
  end

  def valid_envelope?(_), do: false

  @doc """
  Extract the conversation_id from a decoded message.
  """
  def extract_conversation_id(envelope) do
    payload = envelope["payload"] || envelope
    payload["conversation_id"]
  end

  @doc """
  Extract the turn_number from a decoded message.
  """
  def extract_turn_number(envelope) do
    payload = envelope["payload"] || envelope
    payload["turn_number"] || 1
  end

  @doc """
  Extract the message_type from a decoded message.
  """
  def extract_message_type(envelope) do
    payload = envelope["payload"] || envelope
    payload["message_type"]
  end

  # Private helpers

  defp build_body(body, opts) when is_map(body) do
    context = opts[:context] || %{}

    if context == %{} do
      body
    else
      Map.put(body, "context", context)
    end
  end

  defp build_body(body, _opts) when is_binary(body) do
    %{"text" => body}
  end

  defp build_envelope(subject, payload, opts) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    correlation_id = opts[:correlation_id] || BotArmyRuntime.Correlation.current()

    envelope = %{
      "event_id" => opts[:event_id] || uuid(),
      "event" => subject,
      "schema_version" => @schema_version,
      "timestamp" => now,
      "source" => opts[:source] || @source,
      "source_node" => opts[:source_node] || Atom.to_string(node()),
      "triggered_by" => "bot_conversation",
      "tenant_id" => opts[:tenant_id] || "default",
      "user_id" => opts[:user_id],
      "payload" => payload
    }

    if correlation_id do
      Map.put(envelope, "correlation_id", correlation_id)
    else
      envelope
    end
  end

  defp validate_message_type!(type) when is_binary(type) do
    if type in @valid_message_types do
      type
    else
      raise ArgumentError,
            "Invalid message_type: #{type}. Valid types: #{inspect(@valid_message_types)}"
    end
  end

  defp validate_message_type!(type) when is_atom(type) do
    validate_message_type!(Atom.to_string(type))
  end

  defp uuid do
    UUID.uuid4()
  end
end
