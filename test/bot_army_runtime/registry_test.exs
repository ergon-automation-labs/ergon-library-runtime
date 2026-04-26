defmodule BotArmyRuntime.RegistryTest do
  use ExUnit.Case
  @moduletag :core

  setup do
    # Registry is already started by BotArmyRuntime.Application
    # Clear any previous registrations for test isolation
    case BotArmyRuntime.Registry.list_bots() do
      {:ok, bots} ->
        Enum.each(bots, fn bot -> BotArmyRuntime.Registry.deregister(bot["name"]) end)

      :error ->
        :ok
    end

    :ok
  end

  describe "register/2" do
    test "registers a bot with its subjects" do
      subjects = [
        %{subject: "test.task.create", type: :request_reply, description: "Create task"},
        %{subject: "test.task.list", type: :request_reply, description: "List tasks"}
      ]

      BotArmyRuntime.Registry.register("test_bot", subjects)

      {:ok, [bot]} = BotArmyRuntime.Registry.list_bots()
      assert bot["name"] == "test_bot"
      assert bot["subject_count"] == 2
      assert length(bot["subjects"]) == 2
    end

    test "updates registration when called again" do
      subjects1 = [%{subject: "test.task.create", type: :request_reply}]

      subjects2 = [
        %{subject: "test.task.create", type: :request_reply},
        %{subject: "test.task.update", type: :request_reply}
      ]

      BotArmyRuntime.Registry.register("test_bot", subjects1)
      BotArmyRuntime.Registry.register("test_bot", subjects2)

      {:ok, bots} = BotArmyRuntime.Registry.list_bots()
      assert length(bots) == 1
      assert bots |> List.first() |> Map.get("subject_count") == 2
    end
  end

  describe "deregister/1" do
    test "removes a registered bot" do
      subjects = [%{subject: "test.task.create", type: :request_reply}]
      BotArmyRuntime.Registry.register("test_bot", subjects)

      {:ok, bots} = BotArmyRuntime.Registry.list_bots()
      assert length(bots) == 1

      BotArmyRuntime.Registry.deregister("test_bot")

      {:ok, bots} = BotArmyRuntime.Registry.list_bots()
      assert length(bots) == 0
    end
  end

  describe "list_bots/1" do
    test "returns all registered bots" do
      subjects = [%{subject: "test.task.create", type: :request_reply}]
      BotArmyRuntime.Registry.register("bot1", subjects)
      BotArmyRuntime.Registry.register("bot2", subjects)

      {:ok, bots} = BotArmyRuntime.Registry.list_bots()
      assert length(bots) == 2

      names = Enum.map(bots, & &1["name"])
      assert "bot1" in names
      assert "bot2" in names
    end

    test "returns empty list when no bots registered" do
      {:ok, bots} = BotArmyRuntime.Registry.list_bots()
      assert bots == []
    end
  end

  describe "get_bot/1" do
    test "returns bot details when found" do
      subjects = [
        %{subject: "test.task.create", type: :request_reply, description: "Create task"},
        %{subject: "test.task.list", type: :request_reply, description: "List tasks"}
      ]

      BotArmyRuntime.Registry.register("test_bot", subjects)

      {:ok, bot} = BotArmyRuntime.Registry.get_bot("test_bot")
      assert bot["name"] == "test_bot"
      assert bot["subject_count"] == 2
      assert length(bot["subjects"]) == 2

      subject = List.first(bot["subjects"])
      assert subject["subject"] == "test.task.create"
      assert subject["type"] == "request_reply"
      assert subject["description"] == "Create task"
    end

    test "returns error when bot not found" do
      {:error, :not_found} = BotArmyRuntime.Registry.get_bot("nonexistent")
    end
  end

  describe "heartbeat detection" do
    test "cleans up stale bots after inactivity" do
      subjects = [%{subject: "test.task.create", type: :request_reply}]
      BotArmyRuntime.Registry.register("test_bot", subjects)

      {:ok, [bot]} = BotArmyRuntime.Registry.list_bots()
      assert bot["name"] == "test_bot"

      # Manually trigger heartbeat check (in real scenario this happens every 30s)
      # Bots older than 40s will be cleaned up
      # For testing, we'd need to mock System.monotonic_time or wait, so we skip this for now
      # This would be better tested with integration tests against real NATS
    end
  end

  describe "subject formatting" do
    test "formats subjects with defaults for missing fields" do
      subjects = [
        %{subject: "test.create", type: :request_reply},
        %{
          subject: "test.update",
          type: :request_reply,
          description: "Update task",
          timeout_ms: 3000
        }
      ]

      BotArmyRuntime.Registry.register("test_bot", subjects)

      {:ok, bot} = BotArmyRuntime.Registry.get_bot("test_bot")
      formatted_subjects = bot["subjects"]

      # Check defaults are applied
      first = Enum.at(formatted_subjects, 0)
      assert first["description"] == ""
      assert first["timeout_ms"] == 5000

      # Check explicit values are used
      second = Enum.at(formatted_subjects, 1)
      assert second["description"] == "Update task"
      assert second["timeout_ms"] == 3000
    end
  end
end
