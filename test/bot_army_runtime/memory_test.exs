defmodule BotArmyLibraryRuntime.MemoryTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyLibraryRuntime.Memory

  describe "append/2" do
    test "rejects entries without a scope" do
      assert {:error, :missing_scope} =
               Memory.append(%{tenant_id: BotArmyLibraryRuntime.Tenant.default_tenant_id()},
                 telemetry: false
               )
    end

    test "degrades to {:error, :not_connected} with no broker (hermetic)" do
      assert {:error, :not_connected} =
               Memory.append(%{"session_id" => "session-1", "note" => "carry the router"})
    end
  end

  describe "list_entries/2" do
    test "degrades to {:error, :not_connected} with no broker (hermetic)" do
      assert {:error, :not_connected} = Memory.list_entries("session-1")
    end
  end

  describe "record_exchange/4" do
    test "degrades to {:error, :not_connected} with no broker (hermetic)" do
      assert {:error, :not_connected} =
               Memory.record_exchange(
                 "session-1",
                 "What is next?",
                 "Ship the memory layer.",
                 repo: BotArmyLibraryRuntime.Ecto.Repo,
                 telemetry: false
               )
    end
  end

  describe "list/2" do
    test "degrades to {:error, :not_connected} with no broker (hermetic)" do
      assert {:error, :not_connected} =
               Memory.list("session-1",
                 repo: BotArmyLibraryRuntime.Ecto.Repo,
                 telemetry: false
               )
    end
  end
end
