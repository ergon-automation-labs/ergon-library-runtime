defmodule BotArmyRuntime.Personality.Identity do
  @moduledoc """
  Bot Army personality symbols registry.

  Each bot has a single Unicode symbol for instant recognition across all surfaces.
  Symbols are the one non-negotiable identity element — preserved regardless of surface constraints.

  Reference: `/docs/north_star_docs/BOT_ARMY_PERSONALITY_NORTH_STAR.md`
  """

  @symbols %{
    gtd_bot: "◉",
    fitness_bot: "▲",
    job_bot: "◆",
    advocacy_bot: "◄",
    chore_bot: "⟳",
    learning_bot: "✦",
    sre_terminal: "▸",
    calendar_bot: "◷",
    wakeword_bot: "◎",
    trading_bot: "●"
  }

  @doc """
  Get the symbol for a given bot.

  ## Examples

      iex> BotArmyRuntime.Personality.Identity.symbol(:gtd_bot)
      "◉"

      iex> BotArmyRuntime.Personality.Identity.symbol(:fitness_bot)
      "▲"
  """
  def symbol(bot_name) when is_atom(bot_name) do
    Map.fetch!(@symbols, bot_name)
  end

  @doc """
  Get all symbols as a map.
  """
  def all_symbols, do: @symbols

  @doc """
  Check if a bot has a registered symbol.
  """
  def registered?(bot_name) when is_atom(bot_name) do
    Map.has_key?(@symbols, bot_name)
  end
end
