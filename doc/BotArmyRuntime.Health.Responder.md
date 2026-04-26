# `BotArmyRuntime.Health.Responder`

Shared health check responder for Bot Army services.

Subscribes to `bot.<bot_name>.health` on NATS (request/reply pattern).
Reports NATS connectivity, database connectivity, key process liveness, and version.

Also provides subject registry: `bot.<bot_name>.subjects` returns metadata about
what subjects this bot handles (request/reply and subscriptions).

Re-registers with ConnectionRegistry on reconnect so subscriptions are always active.

# `child_spec`

Returns a specification to start this module under a supervisor.

See `Supervisor`.

# `register_subjects`

Register subjects that this bot handles.

subjects should be a list of maps:
```
[
  %{subject: "gtd.task.list", type: :request_reply, description: "List tasks"},
  %{subject: "events.gtd.task.>", type: :subscribe, description: "Task events"}
]
```

# `start_link`

---

*Consult [api-reference.md](api-reference.md) for complete listing*
