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
  end

  describe "record_exchange/4" do
    test "returns skipped when no repo is running" do
      assert :skipped =
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
    test "returns an empty list when no repo is running" do
      assert [] =
               Memory.list("session-1",
                 repo: BotArmyLibraryRuntime.Ecto.Repo,
                 telemetry: false
               )
    end
  end
end
