# `BotArmyRuntime.GtdPollAllocator`

Converts a GTD poll snapshot into structured vote allocations.

Each bot profile produces different allocation patterns based on its
heuristic preferences. Used when a GTD poll broadcast is received via
`synapse.army_general.poll.broadcast` to determine how a bot should
distribute its vote budget across the poll's items.

# `profile`

```elixir
@type profile() :: :gtd | :synapse | :skills | :llm | :learning
```

# `allocate`

```elixir
@spec allocate(snapshot :: map(), profile :: profile(), budget :: pos_integer()) :: [
  map()
]
```

Allocate vote budget across items in a GTD poll snapshot.

Returns a list of allocations: [%{"item_type" => "task", "item_id" => "...", "votes" => 2}, ...]
Total votes across all allocations will not exceed budget.

## Profiles

- `:gtd` — Prefers task items, uses task count as overload signal
- `:synapse` — Spreads votes across item types for balance
- Others fall through to `:synapse` behavior

---

*Consult [api-reference.md](api-reference.md) for complete listing*
