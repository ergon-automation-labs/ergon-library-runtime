# `BotArmy.Soul`

Soul storage and retrieval module.

The soul is the personality identity of a bot - its character voice, tone,
priorities, and refusal rules. Stored as JSONB in PostgreSQL.

## Soul Schema

```json
{
  "identity": {
    "name": "GTD Bot",
    "symbol": "◉",
    "role": "Surface the next right action"
  },
  "tone": "conversational",
  "verbosity": "medium",
  "priorities": ["actionability", "clarity", "warmth"],
  "refusals": ["judgmental", "saccharine", "overly technical"],
  "failure_behavior": "honest but kind"
}
```

## Storage

Soul configs are stored in PostgreSQL using the `souls` table:

```sql
CREATE TABLE souls (
  id UUID PRIMARY KEY,
  bot_id TEXT NOT NULL,
  tenant_id UUID NOT NULL,
  config JSONB NOT NULL,
  version INTEGER DEFAULT 1,
  active BOOLEAN DEFAULT true,
  inserted_at TIMESTAMPTZ,
  updated_at TIMESTAMPTZ
);
```

## Usage

```elixir
# Get the current soul for a bot
soul = BotArmy.Soul.get(:gtd_bot)

# Get soul for a specific tenant
soul = BotArmy.Soul.get(:gtd_bot, tenant_id: "uuid-here")

# Update soul config
{:ok, _} = BotArmy.Soul.update(:gtd_bot, %{tone: "more sarcastic"})
```

# `changeset`

Returns a changeset for soul creation/update.

# `get`

```elixir
@spec get(atom() | String.t(), opts :: [tenant_id: String.t(), repo: module()]) ::
  %BotArmy.Soul{
    __meta__: term(),
    active: term(),
    bot_id: term(),
    config: term(),
    id: term(),
    inserted_at: term(),
    tenant_id: term(),
    updated_at: term(),
    version: term()
  }
  | nil
```

Get the current soul for a bot.

Returns the active soul with the highest version for the given bot and tenant.

## Examples

    iex> BotArmy.Soul.get(:gtd_bot)
    %BotArmy.Soul{config: %{"identity" => %{...}}}

    iex> BotArmy.Soul.get(:gtd_bot, tenant_id: "uuid")
    %BotArmy.Soul{config: %{"identity" => %{...}}}

# `publish`

```elixir
@spec publish(atom() | String.t(), opts :: [tenant_id: String.t(), repo: module()]) ::
  :ok | {:error, String.t()}
```

Publish soul to NATS for the given bot.

Publishes to `bot.army.soul.<bot_id>` with the current soul config.

# `upsert`

```elixir
@spec upsert(
  atom() | String.t(),
  map(),
  opts :: [tenant_id: String.t(), repo: module()]
) ::
  {:ok,
   %BotArmy.Soul{
     __meta__: term(),
     active: term(),
     bot_id: term(),
     config: term(),
     id: term(),
     inserted_at: term(),
     tenant_id: term(),
     updated_at: term(),
     version: term()
   }}
  | {:error, Ecto.Changeset.t()}
```

Create or update a soul configuration.

Uses INSERT ... ON CONFLICT to handle upserts.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
