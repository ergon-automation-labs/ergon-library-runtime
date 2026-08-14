defmodule BotArmyLibraryRuntime.GossipPollAffinityTest do
  use ExUnit.Case
  @moduletag :core

  test "snapshot ranks active goals by lexical overlap + recency/activity signals" do
    now = DateTime.utc_now()

    tasks = [
      %{"title" => "Finish prepush reliability hook drain"},
      %{"title" => "Triage CI noise in synapse gossip"}
    ]

    goals = [
      %{
        "name" => "Prepush Reliability",
        "area" => "engineering",
        "status" => "active",
        :last_active_at => DateTime.add(now, -3600, :second),
        :decision_count => 3,
        :progress_summary => "standardize hooks"
      },
      %{
        "name" => "Unrelated Goal",
        "area" => "life",
        "status" => "active",
        :last_active_at => DateTime.add(now, -50 * 24 * 3600, :second),
        :decision_count => 0
      }
    ]

    snap = BotArmyLibraryRuntime.GossipPollAffinity.snapshot(tasks, goals)

    assert snap["version"] == 1
    assert get_in(snap, ["top_goal", "name"]) == "Prepush Reliability"
    assert get_in(snap, ["signals", "task_goal_lexical"]) > 0.0
  end

  test "choose_priority_vote preserves hard reduce_load under overload even with strong affinity" do
    tasks = for i <- 1..10, do: %{"title" => "task #{i}"}

    goals = [
      %{
        "name" => "Prepush Reliability",
        "status" => "active",
        :last_active_at => DateTime.utc_now(),
        :decision_count => 9
      }
    ]

    snapshot = %{
      "tasks_top" => Enum.map(tasks, & &1["title"]),
      "projects_top" => Enum.map(goals, & &1["name"]),
      "goals_top" => Enum.map(goals, & &1["name"]),
      "affinity" => BotArmyLibraryRuntime.GossipPollAffinity.snapshot(tasks, goals)
    }

    vote =
      BotArmyLibraryRuntime.GossipPollAffinity.choose_priority_vote(
        ["protect_focus", "reduce_load", "ship_more"],
        snapshot,
        :skills,
        ":skills"
      )

    assert vote == "reduce_load"
  end
end
