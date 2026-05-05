# `BotArmyRuntime.Personality.Observability`

Telemetry and structured logging for soul (tenant DB) and pulse (NATS) paths.

## Telemetry event names

All use the `[:bot_army, :personality, ...]` prefix for PromEx and ad-hoc handlers.

| Event | Measurements | Metadata |
|-------|--------------|----------|
| `[:bot_army, :personality, :soul, :get]` | `duration` (native), `count` | `outcome`, `bot_id`, `tenant_id`, optional `soul_version` |
| `[:bot_army, :personality, :soul, :upsert]` | `duration` (native), `count` | `outcome`, `bot_id`, `tenant_id`, optional `soul_version` |
| `[:bot_army, :personality, :soul, :publish]` | `count` | `outcome`, `bot_id`, `tenant_id`, optional `error` |
| `[:bot_army, :personality, :pulse, :publish]` | `count` | `outcome`, `bot_id`, `tenant_id`, `subject`, optional `error` |

Attach handlers with `:telemetry.attach/4` or scrape via `BotArmyRuntime.Metrics.PromExPlugin`.

# `soul_outcome`

```elixir
@type soul_outcome() :: :found | :missing | :error
```

---

*Consult [api-reference.md](api-reference.md) for complete listing*
