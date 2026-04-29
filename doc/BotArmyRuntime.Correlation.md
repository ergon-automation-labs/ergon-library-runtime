# `BotArmyRuntime.Correlation`

Correlation ID propagation for distributed request tracing.

Manages correlation IDs across the bot fleet by storing them in Logger.metadata.
Each incoming request (from a surface, API, or user action) gets a correlation_id
that flows through all subsequent NATS messages and appears in all logs.

## Usage

**Entry point (generate on user request):**
    BotArmyRuntime.Correlation.put(BotArmyRuntime.Correlation.generate())

**Consumer (extract from incoming message):**
    BotArmyRuntime.Correlation.extract_from_headers(msg.headers)
    |> case do
      nil -> BotArmyRuntime.Correlation.put(BotArmyRuntime.Correlation.generate())
      id -> BotArmyRuntime.Correlation.put(id)
    end

**Publisher (auto-injected):**
    headers = BotArmyRuntime.Correlation.inject_into_headers([])
    Gnat.pub(conn, subject, payload, headers: headers)

**Logging (auto-included once set):**
    Logger calls automatically include correlation_id in metadata when present.

# `current`

Returns the current correlation_id from Logger metadata, or nil if not set.

# `extract_from_headers`

Extracts correlation_id from NATS message headers.

Returns the correlation_id string if found, nil otherwise.
Headers are a list of {key, value} tuples (from Gnat).

# `generate`

Generates a new UUID4 correlation ID.

# `inject_into_headers`

Injects current correlation_id into NATS message headers.

If a correlation_id is currently set in Logger.metadata, adds it as
an "x-correlation-id" header. If none is set, generates a new one and
adds it. This ensures every message carries a correlation_id.

Returns the headers list with correlation_id prepended.

# `put`

Sets the correlation_id in Logger metadata for the current process.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
