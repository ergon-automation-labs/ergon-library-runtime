defmodule BotArmyLibraryRuntime.Memory do
  @moduledoc """
  Façade for the Bot Army Memory service.

  This module provides a standardized interface for recording and retrieving
  session-based conversation history across the fleet. It delegates all
  operations to the centralized Memory service via NATS.
  """

  alias BotArmyLibraryRuntime.NATS.Publisher

  @doc """
  Records a conversation exchange for a specific session.

  ## Arguments
    - `session_id` - UUID of the conversation session
    - `question` - The user's input
    - `answer` - The bot's response
    - `opts` - Optional keyword list (e.g., `:tenant_id`, `:source`)

  ## Returns
    - `{:ok, subject}` or `{:error, reason}`
  """
  def record_exchange(session_id, question, answer, opts \\ []) do
    payload = %{
      "session_id" => session_id,
      "question" => question,
      "answer" => answer,
      "opts" => filter_json_opts(opts)
    }

    Publisher.publish("memory.record", payload)
  end

  @doc """
  Appends a general piece of information or context to a session.

  ## Arguments
    - `data` - Map of data to append
    - `opts` - Optional keyword list

  ## Returns
    - `{:ok, subject}` or `{:error, reason}`
  """
  def append(data, opts \\ []) do
    if Map.has_key?(data, :session_id) or Map.has_key?(data, "session_id") do
      payload = %{
        "data" => data,
        "opts" => filter_json_opts(opts)
      }

      Publisher.publish("memory.append", payload)
    else
      {:error, :missing_scope}
    end
  end

  @doc """
  Retrieves the conversation history for a session.

  ## Arguments
    - `session_id` - UUID of the conversation session
    - `opts` - Optional keyword list (e.g., `:tenant_id`, `:limit`)

  ## Returns
    - `{:ok, history}` - List of exchanges (maps)
    - `{:error, reason}` - Request failed or timed out
  """
  def list(session_id, opts \\ []) do
    payload = %{
      "session_id" => session_id,
      "opts" => filter_json_opts(opts)
    }

    case Publisher.request("memory.list", payload) do
      {:ok, %{"data" => history}} when is_list(history) ->
        {:ok, history}

      {:ok, data} ->
        # Fallback if the response shape differs but is successful
        {:ok, data}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Clears all conversation history for a session.

  ## Arguments
    - `session_id` - UUID of the conversation session
    - `opts` - Optional keyword list (e.g., `:tenant_id`, `:kind`)

  ## Returns
    - `{:ok, subject}` or `{:error, reason}`
  """
  def clear(session_id, opts \\ []) do
    payload = %{
      "session_id" => session_id,
      "opts" => filter_json_opts(opts)
    }

    Publisher.publish("memory.clear", payload)
  end

  defp filter_json_opts(opts) do
    # Remove non-serializable options like :repo or :telemetry
    # that are used for test mocking/local control
    opts
    |> Enum.reject(fn {k, _v} -> k in [:repo, :telemetry] end)
    |> Enum.into(%{})
  end
end
