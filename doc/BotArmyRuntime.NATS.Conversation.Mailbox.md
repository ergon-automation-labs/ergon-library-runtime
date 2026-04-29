# `BotArmyRuntime.NATS.Conversation.Mailbox`

Async mailbox messaging between bots.

Unlike conversations (which expect responses), mailbox messages are
fire-and-forget. The receiving bot picks them up on its own schedule.

## Patterns

- `send/4` — Leave a message for another bot (publishes to `conv.mailbox.<bot>`)
- `subscribe/2` — Subscribe to incoming mailbox messages
- `ack/2` — Publish a read receipt

No response is expected, though the receiving bot may optionally start
a conversation in response to a mailbox message.

# `ack`

Publish a read receipt for a mailbox message.

Optional — helps with observability.

# `send`

Send a mailbox message to a bot.

This is fire-and-forget. The sender does not wait for a response.

## Options
  - `:tenant_id` — Tenant context
  - `:user_id` — User context
  - `:priority` — Message priority (default: "normal")
  - `:expires_at` — ISO8601 timestamp when the message expires

# `subscribe`

Subscribe to mailbox messages for a given bot.

Returns `{:ok, subscription_ref}` on success.
The caller receives `{:msg, %{topic:, body:, ...}}` messages.

When processing, check `topic` ends with your bot name, then
decode and handle. Use `BotArmyCore.NATS.Decoder.decode/1` or
`Jason.decode/2` to parse the body.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
