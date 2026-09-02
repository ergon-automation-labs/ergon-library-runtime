defmodule BotArmyLibraryRuntime.SoulTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyLibraryRuntime.Soul

  describe "get/1" do
    test "degrades to {:error, :not_connected} with no broker (hermetic)" do
      assert {:error, :not_connected} = Soul.get(:gtd)
    end

    test "accepts atom or string bot ids without crashing on encode" do
      # Both shapes must at least reach the (absent) broker and fail with
      # the same hermetic error, proving the payload encodes cleanly.
      assert {:error, :not_connected} = Soul.get("bot_army_gtd")
      assert {:error, :not_connected} = Soul.get(:gtd)
    end
  end

  describe "upsert/3" do
    test "degrades to {:error, :not_connected} with no broker (hermetic)" do
      assert {:error, :not_connected} =
               Soul.upsert(:gtd, %{"identity" => %{"name" => "GTD Bot"}, "tone" => "dry"})
    end
  end
end
