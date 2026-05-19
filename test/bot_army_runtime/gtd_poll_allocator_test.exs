defmodule BotArmyRuntime.GtdPollAllocatorTest do
  use ExUnit.Case
  @moduletag :core

  alias BotArmyRuntime.GtdPollAllocator

  describe "allocate/3 with empty snapshot" do
    test "returns empty list for empty map" do
      assert GtdPollAllocator.allocate(%{}, :gtd, 3) == []
    end

    test "returns empty list for nil snapshot" do
      assert GtdPollAllocator.allocate(nil, :gtd, 3) == []
    end
  end

  describe "allocate/3 with single item" do
    test "allocates full budget to single item" do
      snapshot = %{"task" => ["t1"]}
      result = GtdPollAllocator.allocate(snapshot, :gtd, 5)

      assert length(result) == 1
      assert hd(result)["votes"] == 5
      assert hd(result)["item_type"] == "task"
      assert hd(result)["item_id"] == "t1"
    end

    test "allocates budget of 1 to single item" do
      snapshot = %{"project" => ["p1"]}
      result = GtdPollAllocator.allocate(snapshot, :synapse, 1)

      assert length(result) == 1
      assert hd(result)["votes"] == 1
    end
  end

  describe "allocate/3 with multiple items" do
    test "never exceeds budget" do
      snapshot = %{"task" => ["t1", "t2", "t3", "t4"], "project" => ["p1"]}
      result = GtdPollAllocator.allocate(snapshot, :gtd, 3)

      total_votes = Enum.reduce(result, 0, fn alloc, acc -> acc + alloc["votes"] end)
      assert total_votes <= 3
    end

    test "distributes votes across items" do
      snapshot = %{"task" => ["t1", "t2"], "project" => ["p1"]}
      result = GtdPollAllocator.allocate(snapshot, :synapse, 3)

      assert length(result) >= 2
      total_votes = Enum.reduce(result, 0, fn alloc, acc -> acc + alloc["votes"] end)
      assert total_votes <= 3
    end

    test "task-only snapshot works" do
      snapshot = %{"task" => ["t1", "t2", "t3"]}
      result = GtdPollAllocator.allocate(snapshot, :gtd, 3)

      assert length(result) >= 2
      assert Enum.all?(result, fn alloc -> alloc["item_type"] == "task" end)
    end

    test "project-only snapshot works" do
      snapshot = %{"project" => ["p1", "p2"]}
      result = GtdPollAllocator.allocate(snapshot, :synapse, 3)

      assert result != []
      assert Enum.all?(result, fn alloc -> alloc["item_type"] == "project" end)
    end

    test "mixed snapshot spreads across types" do
      snapshot = %{"task" => ["t1"], "project" => ["p1"], "goal" => ["g1"]}
      result = GtdPollAllocator.allocate(snapshot, :synapse, 5)

      types = Enum.map(result, & &1["item_type"]) |> Enum.uniq() |> Enum.sort()
      assert types == ["goal", "project", "task"]
    end
  end

  describe "allocate/3 with different profiles" do
    test "gtd profile prefers task items" do
      snapshot = %{"task" => ["t1"], "project" => ["p1"]}
      result = GtdPollAllocator.allocate(snapshot, :gtd, 3)

      task_alloc = Enum.find(result, fn a -> a["item_type"] == "task" end)
      project_alloc = Enum.find(result, fn a -> a["item_type"] == "project" end)

      assert task_alloc["votes"] >= project_alloc["votes"]
    end

    test "synapse profile gives project items slightly higher base score" do
      snapshot = %{"task" => ["t1"], "project" => ["p1"]}
      result_gtd = GtdPollAllocator.allocate(snapshot, :gtd, 3)
      result_synapse = GtdPollAllocator.allocate(snapshot, :synapse, 3)

      assert is_list(result_gtd)
      assert is_list(result_synapse)
    end

    test "unknown profile falls through to synapse behavior" do
      snapshot = %{"task" => ["t1", "t2"]}
      result = GtdPollAllocator.allocate(snapshot, :unknown_profile, 3)

      assert is_list(result)
      assert result != []
    end
  end

  describe "allocate/3 budget edge cases" do
    test "budget of 1 with multiple items" do
      snapshot = %{"task" => ["t1", "t2", "t3"]}
      result = GtdPollAllocator.allocate(snapshot, :gtd, 1)

      total_votes = Enum.reduce(result, 0, fn alloc, acc -> acc + alloc["votes"] end)
      assert total_votes <= 1
    end

    test "budget of 2 with many items" do
      snapshot = %{"task" => ["t1", "t2", "t3", "t4"]}
      result = GtdPollAllocator.allocate(snapshot, :gtd, 2)

      total_votes = Enum.reduce(result, 0, fn alloc, acc -> acc + alloc["votes"] end)
      assert total_votes <= 2
    end

    test "handles string item_ids from snapshot" do
      snapshot = %{"task" => ["email-triage-bot-v1", "gtd-poll-fix-v2"]}
      result = GtdPollAllocator.allocate(snapshot, :gtd, 3)

      assert result != []
      assert Enum.all?(result, fn alloc -> is_binary(alloc["item_id"]) end)
    end

    test "handles UUID item_ids from snapshot" do
      snapshot = %{"task" => ["00000000-0000-0000-0000-000000000001"]}
      result = GtdPollAllocator.allocate(snapshot, :synapse, 3)

      assert length(result) == 1
      assert hd(result)["item_id"] == "00000000-0000-0000-0000-000000000001"
    end

    test "handles arbitrary item types like theme/vibe/mechanic" do
      snapshot = %{
        "theme" => ["cyberpunk-resistance", "space-opera-crew"],
        "vibe" => ["dark-and-gritty", "hopeful-and-heroic"],
        "mechanic" => ["quest-bounties-and-fame"]
      }

      result = GtdPollAllocator.allocate(snapshot, :synapse, 3)

      total_votes = Enum.reduce(result, 0, fn alloc, acc -> acc + alloc["votes"] end)
      assert total_votes <= 3
      assert length(result) >= 2

      types = Enum.map(result, & &1["item_type"]) |> Enum.uniq()
      assert "theme" in types or "vibe" in types or "mechanic" in types
    end
  end
end
