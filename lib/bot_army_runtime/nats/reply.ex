defmodule BotArmyRuntime.NATS.Reply do
  @moduledoc """
  Standardized response format for NATS request/reply handlers.

  All request/reply handlers should return responses using these helpers
  to ensure consistent format across the fleet:

  ```
  {:ok, Gnat.pub(conn, reply_to, Reply.ok(data))}
  {:ok, Gnat.pub(conn, reply_to, Reply.error("invalid input", :validation_error))}
  ```

  Response format:
  ```json
  {
    "ok": true,
    "data": {...},
    "schema_version": "1.0",
    "timestamp": "2026-04-25T..."
  }
  ```

  or on error:
  ```json
  {
    "ok": false,
    "error": "human readable message",
    "code": "error_code_atom",
    "schema_version": "1.0",
    "timestamp": "2026-04-25T..."
  }
  ```
  """

  @schema_version "1.0"

  @doc """
  Build a success response.

  Returns JSON-encoded binary ready to send via Gnat.pub/3.
  Automatically includes correlation_id if one is set in Logger.metadata.
  """
  def ok(data) do
    response = %{
      "ok" => true,
      "data" => data,
      "schema_version" => @schema_version,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    response =
      case BotArmyRuntime.Correlation.current() do
        nil -> response
        correlation_id -> Map.put(response, "correlation_id", correlation_id)
      end

    Jason.encode!(response)
  end

  @doc """
  Build an error response.

  code is optional and should be an atom (e.g., :validation_error, :not_found).
  Automatically includes correlation_id if one is set in Logger.metadata.
  """
  def error(message, code \\ nil) when is_binary(message) do
    response = %{
      "ok" => false,
      "error" => message,
      "schema_version" => @schema_version,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    response =
      if code do
        Map.put(response, "code", Atom.to_string(code))
      else
        response
      end

    response =
      case BotArmyRuntime.Correlation.current() do
        nil -> response
        correlation_id -> Map.put(response, "correlation_id", correlation_id)
      end

    Jason.encode!(response)
  end

  @doc """
  Build a success response with conversation metadata.

  Includes conversation_id, turn_number, and conversation_complete flag
  so the ConversationManager can track multi-turn state.
  """
  def ok_conversation(data, conversation_id, turn_number, opts \\ []) do
    complete = Keyword.get(opts, :conversation_complete, true)

    response = %{
      "ok" => true,
      "data" => data,
      "schema_version" => @schema_version,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "conversation_id" => conversation_id,
      "turn_number" => turn_number,
      "conversation_complete" => complete
    }

    response =
      case BotArmyRuntime.Correlation.current() do
        nil -> response
        correlation_id -> Map.put(response, "correlation_id", correlation_id)
      end

    Jason.encode!(response)
  end

  @doc """
  Build an error response with conversation metadata.

  The responding bot signals the conversation is complete (errored).
  """
  def error_conversation(message, conversation_id, turn_number, opts \\ []) do
    code = Keyword.get(opts, :code)

    response = %{
      "ok" => false,
      "error" => message,
      "schema_version" => @schema_version,
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "conversation_id" => conversation_id,
      "turn_number" => turn_number,
      "conversation_complete" => true
    }

    response =
      if code do
        Map.put(response, "code", Atom.to_string(code))
      else
        response
      end

    response =
      case BotArmyRuntime.Correlation.current() do
        nil -> response
        correlation_id -> Map.put(response, "correlation_id", correlation_id)
      end

    Jason.encode!(response)
  end
end
