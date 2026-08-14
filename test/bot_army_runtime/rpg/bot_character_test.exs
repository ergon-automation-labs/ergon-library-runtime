defmodule BotArmyLibraryRuntime.RPG.BotCharacterTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyLibraryRuntime.RPG.BotCharacter

  describe "name/2" do
    test "returns fallback name when RPG bot is unreachable" do
      assert {:ok, "Gtd Bot"} = BotCharacter.name("gtd_bot")
    end

    test "normalizes atom bot_id" do
      assert {:ok, "Runtime Unknown Bot"} = BotCharacter.name(:runtime_unknown_bot)
    end

    test "strips bot_army_ prefix for fallback" do
      assert {:ok, "Job Applications"} = BotCharacter.name("bot_army_job_applications")
    end
  end
end
