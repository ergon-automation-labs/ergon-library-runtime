defmodule BotArmyRuntime.RPG.BotCharacterTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyRuntime.RPG.BotCharacter

  describe "name/2" do
    test "returns fallback name when RPG bot is unreachable" do
      assert {:ok, "Gtd Bot"} = BotCharacter.name("gtd_bot")
    end

    test "normalizes atom bot_id" do
      assert {:ok, "Synapse"} = BotCharacter.name(:synapse)
    end

    test "strips bot_army_ prefix for fallback" do
      assert {:ok, "Job Applications"} = BotCharacter.name("bot_army_job_applications")
    end
  end
end
