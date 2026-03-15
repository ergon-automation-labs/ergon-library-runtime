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

    test "raises ArgumentError for unknown bot" do
      assert_raise ArgumentError, fn ->
        Identity.symbol(:unknown_bot)
      end
    end
  end

  describe "name/1" do
    test "returns GTD bot name" do
      assert Identity.name(:gtd_bot) == "Morgan"
    end

    test "returns Fitness bot name" do
      assert Identity.name(:fitness_bot) == "Jordan"
    end

    test "returns Job bot name" do
      assert Identity.name(:job_bot) == "Quinn"
    end

    test "returns Advocacy bot name" do
      assert Identity.name(:advocacy_bot) == "Riley"
    end

    test "returns Chore bot name" do
      assert Identity.name(:chore_bot) == "Taylor"
    end

    test "returns Learning bot name" do
      assert Identity.name(:learning_bot) == "Kit"
    end

    test "returns SRE terminal name" do
      assert Identity.name(:sre_terminal) == "Casey"
    end

    test "returns Calendar bot name" do
      assert Identity.name(:calendar_bot) == "Alex"
    end

    test "returns Wakeword bot name" do
      assert Identity.name(:wakeword_bot) == "Sam"
    end

    test "returns nil for Trading bot (no name assigned)" do
      assert Identity.name(:trading_bot) == nil
    end

    test "raises ArgumentError for unknown bot" do
      assert_raise ArgumentError, fn ->
        Identity.name(:unknown_bot)
      end
    end
  end

  describe "all_bots/0" do
    test "returns all bots as a map" do
      bots = Identity.all_bots()

      assert is_map(bots)
      assert map_size(bots) == 10
      assert bots[:gtd_bot] == %{symbol: "◉", name: "Morgan"}
      assert bots[:fitness_bot] == %{symbol: "▲", name: "Jordan"}
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
