# `BotArmyRuntime.Personality.Formatter`

Message formatter with bot personality symbols.

Prepends a bot's symbol to outbound messages for consistent visual identity across all surfaces.
The symbol is always preserved regardless of surface constraints.

Reference: `/docs/north_star_docs/BOT_ARMY_PERSONALITY_NORTH_STAR.md`

# `symbol`

Get just the symbol for a bot (useful for surfaces with extreme character constraints).

## Examples

    iex> BotArmyRuntime.Personality.Formatter.symbol(:gtd_bot)
    "◉"

# `with_symbol`

Format a message with the bot's symbol.

The symbol is always prepended, making the bot instantly recognizable
across all surfaces (G2 glasses, Watch, LiveView, Terminal, etc).

## Parameters

- `bot_name` - Atom identifying the bot (e.g., :gtd_bot, :fitness_bot)
- `message` - String message to format

## Examples

    iex> BotArmyRuntime.Personality.Formatter.with_symbol(:gtd_bot, "Inbox cleared")
    "◉ Inbox cleared"

    iex> BotArmyRuntime.Personality.Formatter.with_symbol(:fitness_bot, "4-day streak")
    "▲ 4-day streak"

Returns the message with symbol prepended, or the original message if the bot is not registered.

---

*Consult [api-reference.md](api-reference.md) for complete listing*
