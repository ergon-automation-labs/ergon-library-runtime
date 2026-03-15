defmodule BotArmyRuntime.Personality.IdentityTest do
  use ExUnit.Case
  doctest BotArmyRuntime.Personality.Identity

  alias BotArmyRuntime.Personality.Identity

  describe "symbol/1" do
    test "returns GTD bot symbol" do
      assert Identity.symbol(:gtd_bot) == "◉"
    end

    test "returns Fitness bot symbol" do
      assert Identity.symbol(:fitness_bot) == "▲"
    end

    test "returns Job bot symbol" do
      assert Identity.symbol(:job_bot) == "◆"
    end

    test "returns Advocacy bot symbol" do
      assert Identity.symbol(:advocacy_bot) == "◄"
    end

    test "returns Chore bot symbol" do
      assert Identity.symbol(:chore_bot) == "⟳"
    end

    test "returns Learning bot symbol" do
      assert Identity.symbol(:learning_bot) == "✦"
    end

    test "returns SRE terminal symbol" do
      assert Identity.symbol(:sre_terminal) == "▸"
    end

    test "returns Calendar bot symbol" do
      assert Identity.symbol(:calendar_bot) == "◷"
    end

    test "returns Wakeword bot symbol" do
      assert Identity.symbol(:wakeword_bot) == "◎"
    end

    test "returns Trading bot symbol" do
      assert Identity.symbol(:trading_bot) == "●"
    end

    test "raises KeyError for unknown bot" do
      assert_raise KeyError, fn ->
        Identity.symbol(:unknown_bot)
      end
    end
  end

  describe "all_symbols/0" do
    test "returns all symbols as a map" do
      symbols = Identity.all_symbols()

      assert is_map(symbols)
      assert map_size(symbols) == 10
      assert symbols[:gtd_bot] == "◉"
      assert symbols[:fitness_bot] == "▲"
    end
  end

  describe "registered?/1" do
    test "returns true for registered bots" do
      assert Identity.registered?(:gtd_bot)
      assert Identity.registered?(:fitness_bot)
      assert Identity.registered?(:job_bot)
    end

    test "returns false for unregistered bots" do
      refute Identity.registered?(:unknown_bot)
      refute Identity.registered?(:nonexistent_bot)
    end
  end
end
