defmodule BotArmyLibraryRuntime.Personality.Identity do
  @moduledoc """
  Bot Army personality symbols registry.

  Each bot has a single Unicode symbol for instant recognition across all surfaces.
  Symbols are the one non-negotiable identity element — preserved regardless of surface constraints.

  Reference: `/docs/north_star_docs/BOT_ARMY_PERSONALITY_NORTH_STAR.md`
  """

  @bots %{
    gtd_bot: %{symbol: "◉", name: "Morgan"},
    fitness_bot: %{symbol: "▲", name: "Jordan"},
    job_bot: %{symbol: "◆", name: "Quinn"},
    advocacy_bot: %{symbol: "◄", name: "Riley"},
    chore_bot: %{symbol: "⟳", name: "Taylor"},
    learning_bot: %{symbol: "✦", name: "Kit"},
    sre_terminal: %{symbol: "▸", name: "Casey"},
    calendar_bot: %{symbol: "◷", name: "Alex"},
    wakeword_bot: %{symbol: "◎", name: "Sam"},
    rpg_bot: %{symbol: "⚔", name: "Vex"},
    trading_bot: %{symbol: "●", name: nil}
  }

  @doc """
  Get the symbol for a given bot.

  ## Examples

      iex> BotArmyLibraryRuntime.Personality.Identity.symbol(:gtd_bot)
      "◉"

      iex> BotArmyLibraryRuntime.Personality.Identity.symbol(:fitness_bot)
      "▲"
  """
  def symbol(bot_name) when is_atom(bot_name) do
    case Map.fetch(@bots, bot_name) do
      {:ok, %{symbol: symbol}} -> symbol
      :error -> raise ArgumentError, "Unknown bot: #{bot_name}"
    end
  end

  @doc """
  Get the name for a given bot.

  ## Examples

      iex> BotArmyLibraryRuntime.Personality.Identity.name(:gtd_bot)
      "Morgan"

      iex> BotArmyLibraryRuntime.Personality.Identity.name(:trading_bot)
      nil
  """
  def name(bot_name) when is_atom(bot_name) do
    case Map.fetch(@bots, bot_name) do
      {:ok, %{name: name}} -> name
      :error -> raise ArgumentError, "Unknown bot: #{bot_name}"
    end
  end

  @doc """
  Get all bots as a map.
  """
  def all_bots, do: @bots

  @doc """
  Check if a bot has a registered symbol.
  """
  def registered?(bot_name) when is_atom(bot_name) do
    Map.has_key?(@bots, bot_name)
  end
end
