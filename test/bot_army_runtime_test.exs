defmodule BotArmyRuntimeTest do
  use ExUnit.Case
  @moduletag :core

  doctest BotArmyRuntime

  describe "BotArmyRuntime" do
    test "has a version" do
      assert BotArmyRuntime.version() == "0.1.0"
    end
  end

  describe "Ecto.Repo" do
    test "Repo is configured" do
      # Verify the repo is available
      assert BotArmyRuntime.Ecto.Repo
    end

    test "Repo can be called" do
      # Basic sanity check that Repo is accessible
      # This will fail if Repo isn't properly configured
      config = BotArmyRuntime.Ecto.Repo.config()
      assert is_list(config)
    end
  end

  describe "NATS.Connection" do
    test "Connection module exists" do
      assert BotArmyRuntime.NATS.Connection
    end
  end

  describe "NATS.Publisher" do
    test "Publisher module exists" do
      assert BotArmyRuntime.NATS.Publisher
    end
  end

  describe "Telemetry" do
    test "Telemetry module exists" do
      assert BotArmyRuntime.Telemetry
    end
  end

  describe "Tenant" do
    test "default_tenant_id returns UUID" do
      assert BotArmyRuntime.Tenant.default_tenant_id() == "00000000-0000-0000-0000-000000000001"
    end

    test "subject/2 builds tenant-prefixed subject" do
      assert BotArmyRuntime.Tenant.subject(
               "gtd.task.list",
               "00000000-0000-0000-0000-000000000001"
             ) ==
               "tenant.00000000-0000-0000-0000-000000000001.gtd.task.list"

      assert BotArmyRuntime.Tenant.subject("dungeon.session.start", "acme-corp") ==
               "tenant.acme-corp.dungeon.session.start"
    end

    test "from_subject/1 extracts tenant ID" do
      assert BotArmyRuntime.Tenant.from_subject(
               "tenant.00000000-0000-0000-0000-000000000001.gtd.tasks"
             ) == "00000000-0000-0000-0000-000000000001"

      assert BotArmyRuntime.Tenant.from_subject("tenant.acme-123.gtd.tasks") == "acme-123"
      assert BotArmyRuntime.Tenant.from_subject("gtd.tasks") == nil
      assert BotArmyRuntime.Tenant.from_subject("events.llm.completion") == nil
    end

    test "tenant_subject?/1 checks if subject is tenant-prefixed" do
      assert BotArmyRuntime.Tenant.tenant_subject?(
               "tenant.00000000-0000-0000-0000-000000000001.gtd.tasks"
             ) == true

      assert BotArmyRuntime.Tenant.tenant_subject?("tenant.acme-123.events.test") == true
      assert BotArmyRuntime.Tenant.tenant_subject?("gtd.tasks") == false
      assert BotArmyRuntime.Tenant.tenant_subject?("events.llm.completion") == false
    end

    test "strip_tenant_prefix/1 removes tenant prefix" do
      assert BotArmyRuntime.Tenant.strip_tenant_prefix(
               "tenant.00000000-0000-0000-0000-000000000001.gtd.tasks"
             ) == "gtd.tasks"

      assert BotArmyRuntime.Tenant.strip_tenant_prefix("tenant.acme-123.events.test") ==
               "events.test"

      assert BotArmyRuntime.Tenant.strip_tenant_prefix("gtd.tasks") == nil
    end
  end
end
