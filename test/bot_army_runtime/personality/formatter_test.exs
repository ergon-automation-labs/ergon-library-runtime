defmodule BotArmyRuntime.Personality.FormatterTest do
  use ExUnit.Case
  @moduletag :format
  alias BotArmyRuntime.Personality.Formatter

  describe "with_symbol/2" do
    test "prepends GTD bot symbol" do
      result = Formatter.with_symbol(:gtd_bot, "Inbox cleared")
      assert result == "◉ Inbox cleared"
    end

    test "prepends Fitness bot symbol" do
      result = Formatter.with_symbol(:fitness_bot, "4-day streak")
      assert result == "▲ 4-day streak"
    end

    test "prepends Job bot symbol" do
      result = Formatter.with_symbol(:job_bot, "3 new matches")
      assert result == "◆ 3 new matches"
    end

    test "prepends Advocacy bot symbol" do
      result = Formatter.with_symbol(:advocacy_bot, "Bill status updated")
      assert result == "◄ Bill status updated"
    end

    test "prepends Chore bot symbol" do
      result = Formatter.with_symbol(:chore_bot, "Task due today")
      assert result == "⟳ Task due today"
    end

    test "handles empty message" do
      result = Formatter.with_symbol(:gtd_bot, "")
      assert result == "◉ "
    end

    test "returns original message for unknown bot" do
      result = Formatter.with_symbol(:unknown_bot, "Some message")
      assert result == "Some message"
    end

    test "returns original message for nil message" do
      result = Formatter.with_symbol(:gtd_bot, nil)
      assert result == nil
    end

    test "returns original message for non-atom bot name" do
      result = Formatter.with_symbol("gtd_bot", "Some message")
      assert result == "Some message"
    end
  end

  describe "symbol/1" do
    test "returns symbol for GTD bot" do
      assert Formatter.symbol(:gtd_bot) == "◉"
    end

    test "returns symbol for Fitness bot" do
      assert Formatter.symbol(:fitness_bot) == "▲"
    end

    test "returns empty string for unknown bot" do
      assert Formatter.symbol(:unknown_bot) == ""
    end
  end
end
