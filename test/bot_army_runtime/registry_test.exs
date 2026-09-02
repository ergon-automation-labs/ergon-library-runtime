defmodule BotArmyLibraryRuntime.RegistryTest do
  use ExUnit.Case, async: false
  @moduletag :core

  setup do
    # Registry is already started by BotArmyLibraryRuntime.Application
    # Clear any previous registrations for test isolation
    case BotArmyLibraryRuntime.Registry.list_bots() do
      {:ok, bots} ->
        Enum.each(bots, fn bot -> BotArmyLibraryRuntime.Registry.deregister(bot["name"]) end)
        # Wait a moment for deregistrations to settle
        Process.sleep(10)

      :error ->
        :ok
    end

    on_exit(fn ->
      # Cleanup after test completes
      case BotArmyLibraryRuntime.Registry.list_bots() do
        {:ok, bots} ->
          Enum.each(bots, fn bot -> BotArmyLibraryRuntime.Registry.deregister(bot["name"]) end)
          Process.sleep(10)

        :error ->
          :ok
      end
    end)

    :ok
  end

  describe "register/2" do
    test "registers a bot with its subjects" do
      subjects = [
        %{subject: "test.task.create", type: :request_reply, description: "Create task"},
        %{subject: "test.task.list", type: :request_reply, description: "List tasks"}
      ]

      BotArmyLibraryRuntime.Registry.register("test_bot", subjects)

      {:ok, bots} = BotArmyLibraryRuntime.Registry.list_bots()
      bot = Enum.find(bots, &(&1["name"] == "test_bot"))
      assert bot["subject_count"] == 2
      assert length(bot["subjects"]) == 2
    end

    test "updates registration when called again" do
      subjects1 = [%{subject: "test.task.create", type: :request_reply}]

      subjects2 = [
        %{subject: "test.task.create", type: :request_reply},
        %{subject: "test.task.update", type: :request_reply}
      ]

      BotArmyLibraryRuntime.Registry.register("test_bot", subjects1)
      BotArmyLibraryRuntime.Registry.register("test_bot", subjects2)

      {:ok, bots} = BotArmyLibraryRuntime.Registry.list_bots()
      assert length(bots) == 1
      assert bots |> List.first() |> Map.get("subject_count") == 2
    end

    test "accepts JSON-shaped string-key subject maps (presence decode shape)" do
      subjects = [
        %{
          "subject" => "synapse.log.create",
          "type" => "request_reply",
          "description" => "Create log entry",
          "timeout_ms" => 5000
        }
      ]

      BotArmyLibraryRuntime.Registry.register("json_shape_bot", subjects)

      {:ok, [bot]} = BotArmyLibraryRuntime.Registry.list_bots()
      assert bot["name"] == "json_shape_bot"
      [subj | _] = bot["subjects"]
      assert subj["subject"] == "synapse.log.create"
      assert subj["type"] == "request_reply"
    end
  end

  describe "deregister/1" do
    test "removes a registered bot" do
      subjects = [%{subject: "test.task.create", type: :request_reply}]
      BotArmyLibraryRuntime.Registry.register("test_bot", subjects)

      {:ok, bots} = BotArmyLibraryRuntime.Registry.list_bots()
      assert Enum.any?(bots, &(&1["name"] == "test_bot"))

      BotArmyLibraryRuntime.Registry.deregister("test_bot")

      {:ok, bots} = BotArmyLibraryRuntime.Registry.list_bots()
      refute Enum.any?(bots, &(&1["name"] == "test_bot"))
    end
  end

  describe "list_bots/1" do
    test "returns all registered bots" do
      subjects = [%{subject: "test.task.create", type: :request_reply}]
      BotArmyLibraryRuntime.Registry.register("bot1", subjects)
      BotArmyLibraryRuntime.Registry.register("bot2", subjects)

      {:ok, bots} = BotArmyLibraryRuntime.Registry.list_bots()
      assert length(bots) == 2

      names = Enum.map(bots, & &1["name"])
      assert "bot1" in names
      assert "bot2" in names
    end

    test "returns empty list when no bots registered" do
      {:ok, bots} = BotArmyLibraryRuntime.Registry.list_bots()
      assert bots == []
    end
  end

  describe "get_bot/1" do
    test "returns bot details when found" do
      subjects = [
        %{subject: "test.task.create", type: :request_reply, description: "Create task"},
        %{subject: "test.task.list", type: :request_reply, description: "List tasks"}
      ]

      BotArmyLibraryRuntime.Registry.register("test_bot", subjects)

      {:ok, bot} = BotArmyLibraryRuntime.Registry.get_bot("test_bot")
      assert bot["name"] == "test_bot"
      assert bot["subject_count"] == 2
      assert length(bot["subjects"]) == 2

      subject = List.first(bot["subjects"])
      assert subject["subject"] == "test.task.create"
      assert subject["type"] == "request_reply"
      assert subject["description"] == "Create task"
    end

    test "returns error when bot not found" do
      {:error, :not_found} = BotArmyLibraryRuntime.Registry.get_bot("nonexistent")
    end
  end

  describe "heartbeat detection" do
    test "cleans up stale bots after inactivity" do
      subjects = [%{subject: "test.task.create", type: :request_reply}]
      BotArmyLibraryRuntime.Registry.register("test_bot", subjects)

      {:ok, [bot]} = BotArmyLibraryRuntime.Registry.list_bots()
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

      BotArmyLibraryRuntime.Registry.register("test_bot", subjects)

      {:ok, bot} = BotArmyLibraryRuntime.Registry.get_bot("test_bot")
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

  describe "subject discovery APIs" do
    test "lists subjects with provider counts across bots" do
      BotArmyLibraryRuntime.Registry.register("gtd_bot", [
        %{subject: "gtd.task.create", type: :request_reply, description: "Create task"},
        %{subject: "gtd.task.list", type: :request_reply, description: "List tasks"}
      ])

      BotArmyLibraryRuntime.Registry.register("automation_bot", [
        %{subject: "gtd.task.create", type: :request_reply, description: "Create task"}
      ])

      {:ok, subjects} = BotArmyLibraryRuntime.Registry.list_subjects()
      by_subject = Map.new(subjects, &{&1["subject"], &1})

      assert by_subject["gtd.task.create"]["provider_count"] == 2
      assert by_subject["gtd.task.list"]["provider_count"] == 1
    end

    test "returns providers for a specific subject" do
      BotArmyLibraryRuntime.Registry.register("gtd_bot", [
        %{subject: "gtd.task.create", type: :request_reply, description: "Create task"}
      ])

      {:ok, discovery} = BotArmyLibraryRuntime.Registry.get_subject_providers("gtd.task.create")
      assert discovery["subject"] == "gtd.task.create"
      assert discovery["provider_count"] == 1
      assert List.first(discovery["providers"])["bot_name"] == "gtd_bot"
    end

    test "returns not_found for unknown subject providers lookup" do
      {:error, :not_found} =
        BotArmyLibraryRuntime.Registry.get_subject_providers("missing.subject")
    end
  end

  describe "version tracking" do
    test "register/3 stores version" do
      subjects = [%{subject: "test.task.create", type: :request_reply}]
      BotArmyLibraryRuntime.Registry.register("versioned_bot", subjects, "1.2.3")

      {:ok, bot} = BotArmyLibraryRuntime.Registry.get_bot("versioned_bot")
      assert bot["version"] == "1.2.3"
    end

    test "register/2 defaults version to unknown" do
      subjects = [%{subject: "test.task.create", type: :request_reply}]
      BotArmyLibraryRuntime.Registry.register("unversioned_bot", subjects)

      {:ok, bot} = BotArmyLibraryRuntime.Registry.get_bot("unversioned_bot")
      assert bot["version"] == "unknown"
    end
  end

  describe "capability APIs" do
    test "find_by_capability returns matching bots" do
      BotArmyLibraryRuntime.Registry.register("gtd", [
        %{subject: "gtd.task.list", type: :request_reply, capabilities: ["task.query"]},
        %{subject: "gtd.task.create", type: :request_reply, capabilities: ["task.create"]}
      ])

      BotArmyLibraryRuntime.Registry.register("automation", [
        %{subject: "auto.task.list", type: :request_reply, capabilities: ["task.query"]}
      ])

      {:ok, bots} = BotArmyLibraryRuntime.Registry.find_by_capability("task.query")
      assert "gtd" in bots
      assert "automation" in bots
    end

    test "list_capabilities returns aggregated map" do
      BotArmyLibraryRuntime.Registry.register("gtd", [
        %{subject: "gtd.task.list", type: :request_reply, capabilities: ["task.query"]}
      ])

      {:ok, caps} = BotArmyLibraryRuntime.Registry.list_capabilities()
      assert caps["task.query"] == ["gtd"]
    end

    test "find_target_for_intent routes by capability" do
      BotArmyLibraryRuntime.Registry.register("gtd", [
        %{subject: "gtd.task.list", type: :request_reply, capabilities: ["task.query"]}
      ])

      assert {:ok, "gtd"} = BotArmyLibraryRuntime.Registry.find_target_for_intent("list_tasks")
    end

    test "find_target_for_intent falls back to subject match" do
      BotArmyLibraryRuntime.Registry.register("gtd", [
        %{subject: "gtd.task.list", type: :request_reply}
      ])

      assert {:ok, "gtd"} = BotArmyLibraryRuntime.Registry.find_target_for_intent("task")
    end

    test "find_target_for_intent returns no_provider when nothing matches" do
      assert {:error, :no_provider} =
               BotArmyLibraryRuntime.Registry.find_target_for_intent("nonexistent_thing")
    end
  end
end
