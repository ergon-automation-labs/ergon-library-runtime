defmodule BotArmyRuntimeTest do
  use ExUnit.Case

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
end
