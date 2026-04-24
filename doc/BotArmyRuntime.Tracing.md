# `BotArmyRuntime.Tracing`

OpenTelemetry distributed tracing integration for NATS message flows.

Provides helpers for:
- Injecting trace context into outgoing NATS messages (publisher side)
- Extracting trace context from incoming NATS messages (consumer side)
- Creating spans around NATS publish and consume operations

## Configuration

Set `OTEL_EXPORTER_OTLP_ENDPOINT` env var (e.g., `http://localhost:4318`)
to enable trace export. If unset, the noop exporter is used.

## Usage (Publisher)

    headers = BotArmyRuntime.Tracing.inject_trace_context([])
    Gnat.pub(conn, subject, payload, headers: headers)

## Usage (Consumer)

    BotArmyRuntime.Tracing.with_consumer_span(msg.topic, Map.get(msg, :headers), fn ->
      # process message
    end)

# `add_trace_context_to_envelope`

Adds trace context to a NATS envelope payload map.

Injects a `_trace_context` field containing the current `traceparent`
string. This is a secondary propagation mechanism for systems that
read envelope bodies rather than NATS headers.

# `configured?`

Returns whether OpenTelemetry is configured with a real exporter.

Useful for conditionally enabling tracing overhead only when a backend
is available.

# `extract_trace_context`

Extracts W3C trace context from NATS message headers.

Sets the extracted context in the process dictionary so subsequent
`start_span` calls become children of the extracted trace.

Returns `:ok` regardless — extraction is best-effort.

# `extract_trace_context_from_envelope`

Extracts trace context from a NATS envelope payload map.

Reads `_trace_context.traceparent` from the envelope body and sets
the process context so subsequent spans link correctly.

# `inject_trace_context`

Injects W3C trace context into a list of NATS headers.

Returns a new headers list with `traceparent` and `tracestate` added
if there's an active span. If no span is active, returns headers unchanged.

NATS headers are `[{key, value}]` tuples.

# `with_consumer_span`

Wraps a function in a consumer span, extracting trace context from headers.

Creates a child span linked to the parent trace (if present in headers),
executes the function, and ends the span. Records exceptions as span events.

## Arguments

  - `subject` - NATS subject the message arrived on
  - `headers` - NATS message headers (list of `{key, value}` tuples)
  - `fun` - 0-arity function to execute within the span

---

*Consult [api-reference.md](api-reference.md) for complete listing*
