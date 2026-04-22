# `BotArmyRuntime.Personality.Identity`

Bot Army personality symbols registry.

Each bot has a single Unicode symbol for instant recognition across all surfaces.
Symbols are the one non-negotiable identity element — preserved regardless of surface constraints.

Reference: `/docs/north_star_docs/BOT_ARMY_PERSONALITY_NORTH_STAR.md`

# `all_bots`

Get all bots as a map.

# `name`

Get the name for a given bot.

## Examples

    iex> BotArmyRuntime.Personality.Identity.name(:gtd_bot)
    "Morgan"

    iex> BotArmyRuntime.Personality.Identity.name(:trading_bot)
    nil

# `registered?`

Check if a bot has a registered symbol.

# `symbol`

Get the symbol for a given bot.

## Examples

    iex> BotArmyRuntime.Personality.Identity.symbol(:gtd_bot)
    "◉"

    iex> BotArmyRuntime.Personality.Identity.symbol(:fitness_bot)
    "▲"

---

*Consult [api-reference.md](api-reference.md) for complete listing*
