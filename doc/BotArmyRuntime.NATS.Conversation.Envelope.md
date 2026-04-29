# `BotArmyRuntime.NATS.Conversation.Envelope`

Build and validate conversation envelopes for cross-bot communication.

Provides constructors for the three conversation patterns:
- `build_request/5` — Start a new conversation (expects response)
- `build_response/6` — Reply to an ongoing conversation
- `build_followup/6` — Continue a multi-turn conversation
- `build_mailbox/5` — Async message (no response expected)

All functions inject standard envelope fields (event_id, timestamp, schema_version)
and accept optional overrides via opts.

# `build_followup`

Build a follow-up turn in a multi-turn conversation.

# `build_mailbox`

Build a mailbox message (async, no response expected).

# `build_request`

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

# `build_response`

Build a response payload for an ongoing conversation.

The `original_envelope` is the request being responded to.
Extracts conversation_id and from_bot for response routing.

# `extract_conversation_id`

Extract the conversation_id from a decoded message.

# `extract_message_type`

Extract the message_type from a decoded message.

# `extract_turn_number`

Extract the turn_number from a decoded message.

# `valid_envelope?`

Validate that a map has the required conversation fields.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
