defmodule BotArmyLibraryRuntime.Personality.Formatter do
  @moduledoc """
  Message formatter with bot personality symbols.

  Prepends a bot's symbol to outbound messages for consistent visual identity across all surfaces.
  The symbol is always preserved regardless of surface constraints.

  Reference: `/docs/north_star_docs/BOT_ARMY_PERSONALITY_NORTH_STAR.md`
  """

  require Logger
  alias BotArmyLibraryRuntime.Personality.Identity

  @doc """
  Format a message with the bot's symbol.

  The symbol is always prepended, making the bot instantly recognizable
  across all surfaces (G2 glasses, Watch, LiveView, Terminal, etc).

  ## Parameters

  - `bot_name` - Atom identifying the bot (e.g., :gtd_bot, :fitness_bot)
  - `message` - String message to format

  ## Examples

      iex> BotArmyLibraryRuntime.Personality.Formatter.with_symbol(:gtd_bot, "Inbox cleared")
      "◉ Inbox cleared"

      iex> BotArmyLibraryRuntime.Personality.Formatter.with_symbol(:fitness_bot, "4-day streak")
      "▲ 4-day streak"

  Returns the message with symbol prepended, or the original message if the bot is not registered.
  """
  def with_symbol(bot_name, message) when is_atom(bot_name) and is_binary(message) do
    case Identity.registered?(bot_name) do
      true ->
        symbol = Identity.symbol(bot_name)
        "#{symbol} #{message}"

      false ->
        Logger.warning("Unknown bot #{bot_name} in formatter — skipping symbol")
        message
    end
  end

  def with_symbol(_bot_name, message), do: message

  @doc """
  Get just the symbol for a bot (useful for surfaces with extreme character constraints).

  ## Examples

      iex> BotArmyLibraryRuntime.Personality.Formatter.symbol(:gtd_bot)
      "◉"
  """
  def symbol(bot_name) when is_atom(bot_name) do
    Identity.symbol(bot_name)
  rescue
    ArgumentError ->
      Logger.warning("Unknown bot #{bot_name} in symbol lookup")
      ""
  end
end
