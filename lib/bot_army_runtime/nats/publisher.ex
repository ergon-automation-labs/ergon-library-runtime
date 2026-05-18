defmodule BotArmyRuntime.NATS.Publisher do
  @moduledoc """
  Publishes messages to NATS.

  Handles JSON serialization, error handling, and logging for all message publishing.

  ## Usage

      {:ok, _} = BotArmyRuntime.NATS.Publisher.publish("bot.task.created", event_data)

  ## Configuration

  Uses NATS configuration from `:bot_army_runtime, :nats` (same as `BotArmyRuntime.NATS.Connection`).

  ## Error Handling

  Returns `{:ok, subject}` on success or `{:error, reason}` on failure.
  Logs all publishing attempts for debugging.
  """

  require Logger

  alias BotArmyRuntime.NATS.CircuitBreaker
  alias BotArmyRuntime.Tracing
  alias BotArmyRuntime.Correlation

  @doc """
  Publishes a message to a NATS subject.

  The payload is JSON-encoded and published with the NATS envelope structure.

  ## Arguments

    - `subject` - NATS subject as a string, e.g., "bot.task.created"
    - `payload` - Map or any JSON-serializable data
    - `opts` - Optional keyword list with:
      - `:reply_to` - Subject to expect a reply on (optional)
      - `:timeout_ms` - Timeout for the operation (default: 5000)

  ## Returns

    - `{:ok, subject}` - Message published successfully
    - `{:error, reason}` - Publishing failed with reason

  ## Examples

      {:ok, "bot.task.created"} = Publisher.publish("bot.task.created", %{"task_id" => 123})

      {:ok, _} = Publisher.publish("bot.task.updated", data, reply_to: "my.reply.subject")
  """
  def publish(subject, payload, opts \\ []) when is_binary(subject) and is_map(payload) do
    timeout = Keyword.get(opts, :timeout_ms, 5000)

    case get_connection() do
      {:ok, conn} ->
        do_publish(conn, subject, payload, opts, timeout)

      {:error, reason} ->
        log_publish_failure(subject, reason)
        {:error, reason}
    end
  end

  @doc """
  Publishes a message and waits for a reply (request-reply pattern).

  Useful for synchronous operations that expect a response from a service.
  Supports optional retry with exponential backoff and circuit breaker protection.

  ## Arguments

    - `subject` - NATS subject to publish to
    - `payload` - Message payload
    - `opts` - Optional keyword list with:
      - `:timeout_ms` - Timeout for reply (default: 5000)
      - `:max_retries` - Max retries on timeout/transient errors (default: 0)
      - `:retry_base_ms` - Base delay for exponential backoff (default: 100)
      - `:circuit_breaker_key` - Key for circuit breaker (optional, no CB if not set)

  ## Returns

    - `{:ok, reply_payload}` - Reply received (decoded as map)
    - `{:error, :timeout}` - No reply received within timeout
    - `{:error, {:circuit_open, retry_after_ms}}` - Circuit breaker is open
    - `{:error, reason}` - Publishing or connection failed
  """
  def request(subject, payload, opts \\ []) when is_binary(subject) and is_map(payload) do
    timeout_ms = Keyword.get(opts, :timeout_ms, 5000)
    max_retries = Keyword.get(opts, :max_retries, 0)
    retry_base_ms = Keyword.get(opts, :retry_base_ms, 100)
    cb_key = Keyword.get(opts, :circuit_breaker_key)

    case get_connection() do
      {:ok, conn} ->
        do_request_with_retry(
          conn,
          subject,
          payload,
          timeout_ms,
          max_retries,
          retry_base_ms,
          cb_key,
          0
        )

      {:error, reason} ->
        log_request_failure(subject, reason)
        {:error, reason}
    end
  end

  defp do_publish(conn, subject, payload, _opts, _timeout) do
    try do
      json_payload = Jason.encode!(payload)

      headers =
        []
        |> Tracing.inject_trace_context()
        |> Correlation.inject_into_headers()

      Gnat.pub(conn, subject, json_payload, headers: headers)

      log_publish_success(subject, payload)
      {:ok, subject}
    rescue
      e in Jason.EncodeError ->
        log_encode_error(subject, payload, e)
        {:error, {:encode_error, e.message}}

      e ->
        log_publish_exception(subject, e)
        {:error, {:exception, Exception.message(e)}}
    end
  end

  defp do_request_with_retry(
         conn,
         subject,
         payload,
         timeout_ms,
         max_retries,
         retry_base_ms,
         cb_key,
         attempt
       ) do
    # Check circuit breaker before attempting
    if cb_key && attempt == 0 do
      case CircuitBreaker.allow?(cb_key) do
        :ok ->
          do_try_request(
            conn,
            subject,
            payload,
            timeout_ms,
            max_retries,
            retry_base_ms,
            cb_key,
            attempt
          )

        {:open, retry_after} ->
          log_circuit_open(subject, retry_after)
          {:error, {:circuit_open, retry_after}}
      end
    else
      do_try_request(
        conn,
        subject,
        payload,
        timeout_ms,
        max_retries,
        retry_base_ms,
        cb_key,
        attempt
      )
    end
  end

  defp do_try_request(
         conn,
         subject,
         payload,
         timeout_ms,
         max_retries,
         retry_base_ms,
         cb_key,
         attempt
       ) do
    case do_request(conn, subject, payload, timeout_ms) do
      {:ok, reply} ->
        if cb_key, do: CircuitBreaker.record_success(cb_key)
        {:ok, reply}

      {:error, :timeout} = err ->
        if cb_key, do: CircuitBreaker.record_failure(cb_key, :timeout)

        if attempt < max_retries do
          backoff = backoff_delay(retry_base_ms, attempt)

          Logger.debug(
            "[NATS] Request timeout, retrying in #{backoff}ms (attempt #{attempt + 1}/#{max_retries})",
            subject: subject
          )

          Process.sleep(backoff)

          do_request_with_retry(
            conn,
            subject,
            payload,
            timeout_ms,
            max_retries,
            retry_base_ms,
            cb_key,
            attempt + 1
          )
        else
          if cb_key, do: CircuitBreaker.record_failure(cb_key, :timeout)
          err
        end

      {:error, reason} = err ->
        if cb_key, do: CircuitBreaker.record_failure(cb_key, reason)
        err
    end
  end

  defp do_request(conn, subject, payload, timeout_ms) do
    try do
      json_payload = Jason.encode!(payload)

      headers =
        []
        |> Tracing.inject_trace_context()
        |> Correlation.inject_into_headers()

      case Gnat.request(conn, subject, json_payload,
             receive_timeout: timeout_ms,
             headers: headers
           ) do
        {:ok, reply} ->
          case decode_reply_payload(reply) do
            {:ok, decoded} ->
              log_request_success(subject, payload)
              {:ok, decoded}

            {:error, e} ->
              log_decode_error(subject, reply, e)
              {:error, {:decode_error, e.message}}
          end

        {:error, :timeout} ->
          log_request_timeout(subject)
          {:error, :timeout}

        {:error, reason} ->
          log_request_error(subject, reason)
          {:error, reason}
      end
    rescue
      e in Jason.EncodeError ->
        log_encode_error(subject, payload, e)
        {:error, {:encode_error, e.message}}

      e ->
        log_request_exception(subject, e)
        {:error, {:exception, Exception.message(e)}}
    end
  end

  defp backoff_delay(base_ms, attempt) do
    # Exponential backoff: base * 2^attempt + jitter
    jitter = :rand.uniform(base_ms)
    trunc(base_ms * :math.pow(2, min(attempt, 5))) + jitter
  end

  defp get_connection do
    timeout_ms = Application.get_env(:bot_army_runtime, :nats_connection_timeout, 1000)

    BotArmyRuntime.NATS.Connection
    |> GenServer.call(:get_connection, timeout_ms)
  rescue
    _e -> {:error, :no_connection_manager}
  end

  # Logging helpers

  defp log_publish_success(subject, _payload) do
    Logger.debug("[NATS] Published message",
      subject: subject,
      correlation_id: Correlation.current()
    )
  end

  defp log_publish_failure(subject, reason) do
    Logger.error("[NATS] Failed to publish message",
      subject: subject,
      reason: inspect(reason)
    )
  end

  defp log_publish_exception(subject, exception) do
    Logger.error("[NATS] Exception while publishing message",
      subject: subject,
      exception: Exception.message(exception)
    )
  end

  defp log_encode_error(subject, _payload, error) do
    Logger.error("[NATS] Failed to encode payload",
      subject: subject,
      error: error.message
    )
  end

  defp log_request_success(subject, _payload) do
    Logger.debug("[NATS] Request-reply completed",
      subject: subject
    )
  end

  defp log_request_failure(subject, reason) do
    Logger.error("[NATS] Failed to send request",
      subject: subject,
      reason: inspect(reason)
    )
  end

  defp log_request_error(subject, reason) do
    Logger.error("[NATS] Request error",
      subject: subject,
      reason: inspect(reason)
    )
  end

  defp log_request_timeout(subject) do
    Logger.warning("[NATS] Request timeout",
      subject: subject
    )
  end

  defp log_request_exception(subject, exception) do
    Logger.error("[NATS] Exception in request",
      subject: subject,
      exception: Exception.message(exception)
    )
  end

  defp log_decode_error(subject, _reply, error) do
    Logger.error("[NATS] Failed to decode reply",
      subject: subject,
      error: error.message
    )
  end

  defp log_circuit_open(subject, retry_after) do
    Logger.error("[NATS] Circuit breaker open",
      subject: subject,
      retry_after_ms: retry_after
    )
  end

  defp decode_reply_payload(reply) do
    reply
    |> extract_reply_body()
    |> Jason.decode()
  end

  # Gnat.request/4 returns a map/struct with a "body" field.
  # Keep this defensive to handle map keys and fallback payload shapes.
  defp extract_reply_body(%{body: body}) when is_binary(body), do: body
  defp extract_reply_body(%{"body" => body}) when is_binary(body), do: body
  defp extract_reply_body(body) when is_binary(body), do: body
  defp extract_reply_body(other), do: other
end
