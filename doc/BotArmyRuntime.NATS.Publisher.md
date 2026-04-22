# `BotArmyRuntime.NATS.Publisher`

Publishes messages to NATS.

Handles JSON serialization, error handling, and logging for all message publishing.

## Usage

    {:ok, _} = BotArmyRuntime.NATS.Publisher.publish("bot.task.created", event_data)

## Configuration

Uses NATS configuration from `:bot_army_runtime, :nats` (same as `BotArmyRuntime.NATS.Connection`).

## Error Handling

Returns `{:ok, subject}` on success or `{:error, reason}` on failure.
Logs all publishing attempts for debugging.

# `publish`

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

# `request`

Publishes a message and waits for a reply (request-reply pattern).

Useful for synchronous operations that expect a response from a service.

## Arguments

  - `subject` - NATS subject to publish to
  - `payload` - Message payload
  - `timeout_ms` - Time to wait for a reply (default: 5000)

## Returns

  - `{:ok, reply_payload}` - Reply received (decoded as map)
  - `{:error, :timeout}` - No reply received within timeout
  - `{:error, reason}` - Publishing or connection failed

---

*Consult [api-reference.md](api-reference.md) for complete listing*
