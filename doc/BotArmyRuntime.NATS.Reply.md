# `BotArmyRuntime.NATS.Reply`

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

# `error`

Build an error response.

code is optional and should be an atom (e.g., :validation_error, :not_found).

# `ok`

Build a success response.

Returns JSON-encoded binary ready to send via Gnat.pub/3.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
