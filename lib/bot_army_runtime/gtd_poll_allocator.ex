defmodule BotArmyRuntime.GtdPollAllocator do
  @moduledoc """
  Converts a GTD poll snapshot into structured vote allocations.

  Each bot profile produces different allocation patterns based on its
  heuristic preferences. Used when a GTD poll broadcast is received via
  `synapse.army_general.poll.broadcast` to determine how a bot should
  distribute its vote budget across the poll's items.
  """

  @type profile :: :gtd | :synapse | :skills | :llm | :learning

  @doc """
  Allocate vote budget across items in a GTD poll snapshot.

  Returns a list of allocations: [%{"item_type" => "task", "item_id" => "...", "votes" => 2}, ...]
  Total votes across all allocations will not exceed budget.

  ## Profiles

  - `:gtd` — Prefers task items, uses task count as overload signal
  - `:synapse` — Spreads votes across item types for balance
  - Others fall through to `:synapse` behavior
  """
  @spec allocate(snapshot :: map(), profile :: profile(), budget :: pos_integer()) :: [map()]
  def allocate(snapshot, profile, budget)
      when is_map(snapshot) and is_integer(budget) and budget > 0 do
    items = flatten_snapshot(snapshot)

    case items do
      [] ->
        []

      [single] ->
        [%{"item_type" => single.type, "item_id" => single.id, "votes" => budget}]

      multiple ->
        scored = score_items(multiple, profile)
        distribute_votes(scored, budget)
    end
  end

  def allocate(_snapshot, _profile, _budget), do: []

  defp flatten_snapshot(snapshot) do
    snapshot
    |> Enum.flat_map(fn {type, items} ->
      case items do
        items when is_list(items) ->
          Enum.map(items, fn id -> %{type: to_string(type), id: to_string(id)} end)

        _ ->
          []
      end
    end)
  end

  defp score_items(items, profile) do
    Enum.map(items, fn item ->
      score = score_for_profile(item, profile, length(items))
      Map.put(item, :score, score)
    end)
    |> Enum.sort_by(& &1.score, :desc)
  end

  defp score_for_profile(item, :gtd, count) do
    case item.type do
      "task" -> 1.0 - min(count, 20) * 0.02
      "project" -> 0.7
      "goal" -> 0.5
      _ -> 0.6
    end
  end

  defp score_for_profile(item, _profile, _count) do
    case item.type do
      "task" -> 0.8
      "project" -> 0.85
      "goal" -> 0.75
      _ -> 0.6
    end
  end

  defp distribute_votes(sorted_items, budget) do
    top_votes = min(2, budget - 1)

    case sorted_items do
      [first | rest] ->
        allocations = [%{"item_type" => first.type, "item_id" => first.id, "votes" => top_votes}]
        remaining = budget - top_votes

        rest_allocations =
          rest
          |> Enum.take(remaining)
          |> Enum.map(fn item ->
            %{"item_type" => item.type, "item_id" => item.id, "votes" => 1}
          end)

        allocations ++ rest_allocations

      [] ->
        []
    end
  end
end
