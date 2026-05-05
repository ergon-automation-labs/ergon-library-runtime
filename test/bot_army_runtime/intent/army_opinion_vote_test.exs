defmodule BotArmyRuntime.Intent.ArmyOpinionVoteTest do
  use ExUnit.Case, async: true

  alias BotArmyRuntime.Intent.ArmyOpinionVote

  @options [
    "Record-keeper (truth + queues)",
    "Oracle (ties threads + timing)",
    "Guard (risk + walls)",
    "Bard (voice + metaphor)"
  ]

  defp req(extra \\ %{}) do
    Map.merge(
      %{
        "schema_version" => "1.0",
        "correlation_id" => "corr-test-1",
        "voter_id" => "gtd",
        "question" => "Which tavern role fits you?",
        "options" => @options
      },
      extra
    )
  end

  test "GTD leans record-keeper" do
    assert %{"ok" => true, "choice" => choice, "voter_id" => "gtd"} =
             ArmyOpinionVote.build_reply(:gtd, req(%{"voter_id" => "gtd"}))

    assert String.contains?(String.downcase(choice), "record")
  end

  test "Synapse leans oracle" do
    assert %{"ok" => true, "choice" => choice} =
             ArmyOpinionVote.build_reply(:synapse, req(%{"voter_id" => "synapse"}))

    assert String.contains?(String.downcase(choice), "oracle")
  end

  test "SRE leans guard" do
    assert %{"ok" => true, "choice" => choice} =
             ArmyOpinionVote.build_reply(:sre, req(%{"voter_id" => "sre"}))

    assert String.contains?(String.downcase(choice), "guard")
  end

  test "LLM leans bard" do
    assert %{"ok" => true, "choice" => choice} =
             ArmyOpinionVote.build_reply(:llm, req(%{"voter_id" => "llm"}))

    assert String.contains?(String.downcase(choice), "bard")
  end

  test "rejects bad schema version" do
    assert %{"ok" => false, "error" => err} =
             ArmyOpinionVote.build_reply(:gtd, req(%{"schema_version" => "0.9"}))

    assert err =~ "bad_schema_version"
  end

  test "accepts JSON binary body" do
    body = Jason.encode!(req(%{"voter_id" => "gtd"}))
    assert %{"ok" => true} = ArmyOpinionVote.build_reply(:gtd, body)
  end
end
