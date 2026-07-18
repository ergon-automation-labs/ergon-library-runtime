defmodule BotArmyLibraryRuntime.Tracing do
  @moduledoc """
  OpenTelemetry distributed tracing integration for NATS message flows.

  Provides helpers for:
  - Injecting trace context into outgoing NATS messages (publisher side)
  - Extracting trace context from incoming NATS messages (consumer side)
  - Creating spans around NATS publish and consume operations

  ## Configuration

  Set `OTEL_EXPORTER_OTLP_ENDPOINT` env var (e.g., `http://localhost:4318`)
  to enable trace export. If unset, the noop exporter is used.

  ## Usage (Publisher)

      headers = BotArmyLibraryRuntime.Tracing.inject_trace_context([])
      Gnat.pub(conn, subject, payload, headers: headers)

  ## Usage (Consumer)

      BotArmyLibraryRuntime.Tracing.with_consumer_span(msg.topic, Map.get(msg, :headers), fn ->
        # process message
      end)
  """

  require OpenTelemetry.Tracer, as: Tracer

  @doc """
  Injects W3C trace context into a list of NATS headers.

  Returns a new headers list with `traceparent` and `tracestate` added
  if there's an active span. If no span is active, returns headers unchanged.

  NATS headers are `[{key, value}]` tuples.
  """
  def inject_trace_context(headers) when is_list(headers) do
    :otel_propagator_text_map.inject(headers)
  end

  @doc """
  Extracts W3C trace context from NATS message headers.

  Sets the extracted context in the process dictionary so subsequent
  `start_span` calls become children of the extracted trace.

  Returns `:ok` regardless — extraction is best-effort.
  """
  def extract_trace_context(headers) when is_list(headers) do
    :otel_propagator_text_map.extract(headers)
    :ok
  end

  def extract_trace_context(_), do: :ok

  @doc """
  Wraps a function in a consumer span, extracting trace context from headers.

  Creates a child span linked to the parent trace (if present in headers),
  executes the function, and ends the span. Records exceptions as span events.

  ## Arguments

    - `subject` - NATS subject the message arrived on
    - `headers` - NATS message headers (list of `{key, value}` tuples)
    - `fun` - 0-arity function to execute within the span
  """
  def with_consumer_span(subject, headers, fun) when is_function(fun, 0) do
    headers = headers || []
    extract_trace_context(headers)

    BotArmyLibraryRuntime.Correlation.extract_from_headers(headers)
    |> case do
      nil -> BotArmyLibraryRuntime.Correlation.put(BotArmyLibraryRuntime.Correlation.generate())
      id -> BotArmyLibraryRuntime.Correlation.put(id)
    end

    span =
      Tracer.start_span("nats.consume #{subject}", %{
        kind: :consumer,
        attributes: %{
          "messaging.system" => "nats",
          "messaging.destination" => subject,
          "messaging.operation" => "receive"
        }
      })

    Tracer.set_current_span(span)

    try do
      fun.()
    rescue
      e ->
        Tracer.set_status(:error, Exception.message(e))
        Tracer.record_exception(e, __STACKTRACE__)
        reraise(e, __STACKTRACE__)
    after
      Tracer.end_span()
    end
  end

  @doc """
  Returns whether OpenTelemetry is configured with a real exporter.

  Useful for conditionally enabling tracing overhead only when a backend
  is available.
  """
  def configured? do
    endpoint = System.get_env("OTEL_EXPORTER_OTLP_ENDPOINT")
    endpoint != nil and endpoint != ""
  end

  @doc """
  Adds trace context to a NATS envelope payload map.

  Injects a `_trace_context` field containing the current `traceparent`
  string. This is a secondary propagation mechanism for systems that
  read envelope bodies rather than NATS headers.
  """
  def add_trace_context_to_envelope(envelope) when is_map(envelope) do
    case current_traceparent() do
      nil -> envelope
      traceparent -> Map.put(envelope, "_trace_context", %{"traceparent" => traceparent})
    end
  end

  @doc """
  Extracts trace context from a NATS envelope payload map.

  Reads `_trace_context.traceparent` from the envelope body and sets
  the process context so subsequent spans link correctly.
  """
  def extract_trace_context_from_envelope(envelope) when is_map(envelope) do
    case Map.get(envelope, "_trace_context") do
      %{"traceparent" => traceparent} when is_binary(traceparent) ->
        headers = [{"traceparent", traceparent}]
        extract_trace_context(headers)

      _ ->
        :ok
    end
  end

  defp current_traceparent do
    span_ctx = Tracer.current_span_ctx()

    if OpenTelemetry.Span.is_valid(span_ctx) do
      ctx = OpenTelemetry.Span.hex_span_ctx(span_ctx)

      "00-#{ctx.otel_trace_id}-#{ctx.otel_span_id}-#{ctx.otel_trace_flags}"
    else
      nil
    end
  end
end
