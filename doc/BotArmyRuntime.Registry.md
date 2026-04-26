# `BotArmyRuntime.Registry`

In-memory service discovery registry for the Bot Army ecosystem.

Maintains a registry of all active bots and their available NATS subjects,
enabling service discovery and capability introspection.

Bots register themselves on startup via `register/2`, providing:
- Bot name
- Version
- List of subjects with metadata (type, description, timeout)

The registry responds to NATS queries:
- `bot_army.registry.bots.list` - List all registered bots
- `bot_army.registry.bot.get` - Get details for a specific bot

Detects offline bots via periodic heartbeat checks and cleans up stale entries.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `deregister`

Deregister a bot from the registry.

# `get_bot`

Get details for a specific bot.
Returns: {:ok, bot_entry} or {:error, :not_found}

# `list_bots`

Get all registered bots.
Returns: {:ok, [bot_entries]} or {:error, reason}

# `register`

Register a bot with its subjects.

subjects should be a list of maps:
```
[
  %{subject: "gtd.task.create", type: :request_reply, description: "Create task", timeout_ms: 5000},
  %{subject: "gtd.task.list", type: :request_reply, description: "List tasks", timeout_ms: 5000}
]
```

# `start_link`

---

*Consult [api-reference.md](api-reference.md) for complete listing*
