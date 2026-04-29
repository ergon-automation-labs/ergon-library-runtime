# `BotArmyRuntime.NATS.Conversation.Manager`

Manages cross-bot conversations.

Tracks active conversations, routes responses to callers, enforces timeouts,
supports multi-turn dialogues, and publishes lifecycle events.

## Conversation Lifecycle

1. `start_conversation/5` — Bot A asks Bot B a question
   - Publishes `conv.request.<bot>.<id>`
   - Subscribes to `conv.response.<id>`
   - Sets timeout
2. Bot B replies via `reply/4`
   - Publishes `conv.response.<id>`
   - Manager delivers to caller
   - If `conversation_complete=true`, marks done
3. Optionally: `followup/6` for multi-turn
4. Timeout or completion cleans up state

## Event Publishing

Every state transition publishes an `events.conversation.*` event.

# `cancel`

Cancel a conversation.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `followup`

Send a follow-up turn in an ongoing conversation.

# `get_conversation`

Get conversation state by ID.

# `list_active`

List active conversations, optionally filtered by status.

# `reply`

Reply to an ongoing conversation.

Called by the responding bot's handler. Publishes the response on
`conv.response.<conversation_id>` and marks the conversation as
completed if `conversation_complete` is true in opts.

## Options
  - `:conversation_complete` — Whether this reply ends the conversation (default: true)
  - `:message_type` — Type of response (default: "result")

# `start_conversation`

Start a new conversation with another bot.

Returns `{:ok, conversation_id}` immediately. The response is delivered
as a message to the calling process: `{:conv_reply, conversation_id, body}`

## Options
  - `:timeout_ms` — How long to wait before timing out (default: 30_000)
  - `:max_turns` — Maximum follow-up exchanges (default: 5)
  - `:tenant_id` — Tenant context
  - `:user_id` — User context
  - `:context` — Extra context merged into body.context
  - `:priority` — Message priority (default: "normal")

# `start_link`

---

*Consult [api-reference.md](api-reference.md) for complete listing*
