defmodule BotArmyRuntime.NATS.Conversation.Mailbox do
  @moduledoc """
  Async mailbox messaging between bots.

  Unlike conversations (which expect responses), mailbox messages are
  fire-and-forget. The receiving bot picks them up on its own schedule.

  ## Patterns

  - `send/4` — Leave a message for another bot (publishes to `conv.mailbox.<bot>`)
  - `subscribe/2` — Subscribe to incoming mailbox messages
  - `ack/2` — Publish a read receipt

  No response is expected, though the receiving bot may optionally start
  a conversation in response to a mailbox message.
  """

  require Logger

  @doc """
  Send a mailbox message to a bot.

  This is fire-and-forget. The sender does not wait for a response.

  ## Options
    - `:tenant_id` — Tenant context
    - `:user_id` — User context
    - `:priority` — Message priority (default: "normal")
    - `:expires_at` — ISO8601 timestamp when the message expires
  """
  def send(from_bot, to_bot, message_type, body, opts \\ []) do
    envelope =
      BotArmyRuntime.NATS.Conversation.Envelope.build_mailbox(
        from_bot,
        to_bot,
        message_type,
        body,
        opts
      )

    subject = "conv.mailbox.#{to_bot}"

    case get_nats_connection() do
      {:ok, conn} ->
        try do
          json = Jason.encode!(envelope)

          headers =
            []
            |> BotArmyRuntime.Tracing.inject_trace_context()
            |> BotArmyRuntime.Correlation.inject_into_headers()

          Gnat.pub(conn, subject, json, headers: headers)

          Logger.info("[Mailbox] #{from_bot} -> #{to_bot}: #{message_type}")

          # Fire notification event
          notify_event(from_bot, to_bot, envelope)

          {:ok, subject}
        rescue
          e ->
            Logger.error("[Mailbox] Failed to send: #{inspect(e)}")
            {:error, Exception.message(e)}
        end

      {:error, reason} ->
        Logger.error("[Mailbox] No NATS connection: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Subscribe to mailbox messages for a given bot.

  Returns `{:ok, subscription_ref}` on success.
  The caller receives `{:msg, %{topic:, body:, ...}}` messages.

  When processing, check `topic` ends with your bot name, then
  decode and handle. Use `BotArmyCore.NATS.Decoder.decode/1` or
  `Jason.decode/2` to parse the body.
  """
  def subscribe(conn, bot_name, pid \\ self()) do
    subject = "conv.mailbox.#{bot_name}"

    case Gnat.sub(conn, pid, subject, queue_group: "mailbox.responders.#{bot_name}") do
      {:ok, ref} ->
        Logger.info("[Mailbox] Subscribed to #{subject}")
        {:ok, ref}

      {:error, reason} ->
        Logger.error("[Mailbox] Failed to subscribe to #{subject}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Publish a read receipt for a mailbox message.

  Optional — helps with observability.
  """
  def ack(conn, conversation_id, bot_name) do
    receipt = %{
      "event_id" => UUID.uuid4(),
      "event" => "events.conversation.mailbox.read",
      "schema_version" => "1.0",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => bot_name,
      "source_node" => Atom.to_string(node()),
      "triggered_by" => "bot_conversation",
      "payload" => %{
        "conversation_id" => conversation_id,
        "read_by" => bot_name,
        "read_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
    }

    try do
      Gnat.pub(conn, "events.conversation.mailbox.read", Jason.encode!(receipt))
      :ok
    rescue
      _ -> :ok
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Private
  # ───────────────────────────────────────────────────────────────────────────

  defp notify_event(from_bot, to_bot, envelope) do
    payload = %{
      "conversation_id" => envelope["payload"]["conversation_id"],
      "from_bot" => from_bot,
      "to_bot" => to_bot,
      "message_type" => envelope["payload"]["message_type"],
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    event = %{
      "event_id" => UUID.uuid4(),
      "event" => "events.conversation.mailbox.new",
      "schema_version" => "1.0",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => "bot_army_runtime",
      "source_node" => Atom.to_string(node()),
      "triggered_by" => "bot_conversation",
      "payload" => payload
    }

    # Best-effort fire-and-forget
    Task.start(fn ->
      case get_nats_connection() do
        {:ok, conn} ->
          try do
            Gnat.pub(conn, "events.conversation.mailbox.new", Jason.encode!(event))
          rescue
            _ -> :ok
          end

        _ ->
          :ok
      end
    end)
  end

  defp get_nats_connection do
    timeout_ms = Application.get_env(:bot_army_runtime, :nats_connection_timeout, 1000)

    BotArmyRuntime.NATS.Connection
    |> GenServer.call(:get_connection, timeout_ms)
  rescue
    _e -> {:error, :no_connection_manager}
  end
end
