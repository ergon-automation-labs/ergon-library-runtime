# `BotArmyRuntime.Logging`

Helper for any bot to record structured activity entries to the GTD daily log.

This module provides a simple interface for bots to publish log entries without
knowing about GTD internals. Entries are published to `gtd.log.create` where
the GTD bot processes them.

## Usage

```elixir
BotArmyRuntime.Logging.record("Task completed successfully", source: "advocacy_bot")
BotArmyRuntime.Logging.record("New bill found", source: "advocacy_bot", category: "work", tags: ["bill", "federal"])
```

## Options

- `source` (required) - Bot or component name (e.g., "advocacy_bot", "liveview")
- `category` - One of: work, personal, health, learning, care, admin, social (default: "personal")
- `task_id` - Optional link to a GTD task ID
- `tags` - List of string tags for categorization

# `record`

Record a log entry.

The `body` is required and should be a brief description of what occurred.

Returns `:ok` or `{:error, reason}`.

## Options

- `source` - Bot or component name (required)
- `category` - work | personal | health | learning | care | admin | social
- `task_id` - Link to a task ID
- `tags` - List of string tags

---

*Consult [api-reference.md](api-reference.md) for complete listing*
