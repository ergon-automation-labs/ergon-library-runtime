defmodule BotArmyRuntime.HeartbeatTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmy.Heartbeat

  describe "record/2 envelope" do
    test "rejects envelopes without a service" do
      assert {:error, :missing_service} =
               Heartbeat.record(
                 %{
                   "event" => "system.health",
                   "tenant_id" => BotArmyRuntime.Tenant.default_tenant_id(),
                   "payload" => %{}
                 },
                 telemetry: false
               )
    end
  end

  describe "record/2 publish opts" do
    test "returns skipped when no repo is running" do
      assert :skipped =
               Heartbeat.record(
                 [
                   source: "bot_army_gtd",
                   service: "gtd",
                   tenant_id: BotArmyRuntime.Tenant.default_tenant_id(),
                   status: "healthy"
                 ],
                 repo: BotArmyRuntime.Ecto.Repo,
                 telemetry: false
               )
    end
  end
end
