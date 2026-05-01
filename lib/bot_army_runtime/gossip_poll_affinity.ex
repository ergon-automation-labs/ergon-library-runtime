defmodule BotArmyRuntime.GossipPollAffinity do
  @moduledoc false

  @stopwords MapSet.new(~w(
    the a an and or of to in on for with from into over under per via at by as is are was were be been being it its this that these those
    project projects goal goals task tasks todo next action inbox
  ))

  @doc """
  Build an operator-auditable affinity snapshot from ambient GTD task titles + active goals.

  Important: this intentionally avoids emitting stable identifiers (e.g. project_id) so poll
  broadcasts can remain implicit while still giving voters a transparent hint surface.
  """
  def snapshot(tasks, goals) when is_list(tasks) and is_list(goals) do
    corpus_text =
      tasks
      |> Enum.map(&title/1)
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" ")

    corpus_tokens = tokenize(corpus_text)

    active_goals =
      goals
      |> Enum.filter(&is_map/1)
      |> Enum.filter(&(Map.get(&1, "status") == "active"))

    scored =
      active_goals
      |> Enum.map(&score_goal(&1, corpus_tokens))
      |> Enum.sort_by(& &1.score, :desc)

    case scored do
      [best | rest] ->
        %{
          "version" => 1,
          "top_goal" => %{
            "name" => best.name,
            "area" => best.area,
            "status" => best.status,
            "score" => round4(best.score),
            "matched_tokens" => Enum.take(best.matched_tokens, 12),
            "components" => best.components
          },
          "candidates" =>
            rest
            |> Enum.take(2)
            |> Enum.map(fn g ->
              %{
                "name" => g.name,
                "area" => g.area,
                "status" => g.status,
                "score" => round4(g.score),
                "matched_tokens" => Enum.take(g.matched_tokens, 8)
              }
            end),
          "signals" => %{
            "task_goal_lexical" => round4(best.components.lexical),
            "goal_recency" => round4(best.components.recency),
            "goal_activity" => round4(best.components.activity)
          },
          "notes" =>
            "Implicit affinity derived from active goal names vs recent task titles; no project_id is published."
        }

      _ ->
        %{
          "version" => 1,
          "top_goal" => nil,
          "candidates" => [],
          "signals" => %{
            "task_goal_lexical" => 0.0,
            "goal_recency" => 0.0,
            "goal_activity" => 0.0
          },
          "notes" => "No active goals available for affinity scoring."
        }
    end
  end

  def snapshot(_, _), do: snapshot([], [])

  @doc """
  Choose a `priorities` poll vote using existing heuristic thresholds, then apply a small
  lexical/recency affinity nudge when safe (never overriding hard risk/overload signals).
  """
  def choose_priority_vote(options, context_snapshot, profile, tie_salt \\ "")

  def choose_priority_vote(options, context_snapshot, profile, tie_salt)
      when is_list(options) and is_map(context_snapshot) do
    {tasks_n, projects_n, goals_n, text} = snapshot_lists(context_snapshot)

    thresholds = thresholds_for(profile)

    hard_reduce? =
      risky_text?(text) or
        tasks_n >= thresholds.reduce_tasks or
        projects_n >= thresholds.reduce_projects

    preferred =
      cond do
        hard_reduce? ->
          "reduce_load"

        ship_candidate?(text, tasks_n, goals_n, thresholds) ->
          "ship_more"

        true ->
          "protect_focus"
      end

    baseline =
      cond do
        preferred in options ->
          preferred

        options != [] and tie_salt != "" ->
          idx = :erlang.phash2(text <> tie_salt, length(options))
          Enum.at(options, idx)

        options != [] ->
          List.first(options)

        true ->
          "protect_focus"
      end

    maybe_nudge_priorities(
      hard_reduce?,
      baseline,
      options,
      text,
      tasks_n,
      projects_n,
      goals_n,
      context_snapshot
    )
  end

  def choose_priority_vote(options, _context_snapshot, _profile, _tie_salt)
      when is_list(options) do
    if options == [], do: "protect_focus", else: List.first(options)
  end

  def choose_priority_vote(_, _, _, _), do: "protect_focus"

  defp maybe_nudge_priorities(
         hard_reduce?,
         baseline,
         options,
         text,
         tasks_n,
         projects_n,
         goals_n,
         context_snapshot
       ) do
    if hard_reduce? or baseline == "reduce_load" do
      baseline
    else
      do_maybe_nudge_priorities(
        baseline,
        options,
        text,
        tasks_n,
        projects_n,
        goals_n,
        context_snapshot
      )
    end
  end

  defp do_maybe_nudge_priorities(
         baseline,
         options,
         text,
         tasks_n,
         projects_n,
         goals_n,
         context_snapshot
       ) do
    affinity = Map.get(context_snapshot, "affinity") || %{}

    lex =
      affinity
      |> Map.get("signals", %{})
      |> Map.get("task_goal_lexical", 0.0)
      |> as_float()

    rec =
      affinity
      |> Map.get("signals", %{})
      |> Map.get("goal_recency", 0.0)
      |> as_float()

    act =
      affinity
      |> Map.get("signals", %{})
      |> Map.get("goal_activity", 0.0)
      |> as_float()

    ship_sig = ship_signal_strength(text)
    risk_sig = risk_signal_strength(text)

    weights = %{
      "protect_focus" => 0.45 + 0.22 * lex + 0.12 * rec + 0.10 * act - 0.06 * ship_sig,
      "ship_more" => 0.25 + 0.18 * ship_sig + 0.10 * lex - 0.10 * risk_sig - 0.06 * rec,
      "reduce_load" =>
        0.30 + 0.35 * risk_sig + 0.10 * overload_int(tasks_n, projects_n, goals_n) - 0.10 * lex
    }

    # Only nudge when affinity is meaningful and the baseline decision is "soft" / close.
    margin = baseline_margin(weights, baseline, options)

    if lex >= 0.18 and margin <= 0.12 do
      winner =
        weights
        |> Enum.filter(fn {k, _} -> k in options end)
        |> Enum.max_by(fn {_k, v} -> v end, fn -> {baseline, -1.0} end)
        |> elem(0)

      if winner in options, do: winner, else: baseline
    else
      baseline
    end
  end

  defp overload_int(tasks_n, projects_n, goals_n) do
    cond do
      tasks_n >= 9 or projects_n >= 7 or goals_n >= 7 -> 1.0
      tasks_n >= 7 or projects_n >= 5 or goals_n >= 5 -> 0.65
      true -> 0.25
    end
  end

  defp baseline_margin(weights, baseline, options) do
    pairs =
      weights
      |> Enum.filter(fn {k, _} -> k in options end)
      |> Enum.sort_by(fn {_k, v} -> v end, :desc)

    case pairs do
      [] ->
        1.0

      [{top_key, top_v} | rest] ->
        base_v = Map.get(weights, baseline, top_v)

        cond do
          baseline == top_key ->
            case rest do
              [{_k2, second} | _] -> top_v - second
              _ -> 1.0
            end

          true ->
            top_v - base_v
        end
    end
  end

  defp snapshot_lists(context_snapshot) do
    tasks = list_size(context_snapshot["tasks_top"])
    projects = list_size(context_snapshot["projects_top"])
    goals = list_size(context_snapshot["goals_top"])

    text =
      [
        context_snapshot["tasks_top"],
        context_snapshot["projects_top"],
        context_snapshot["goals_top"]
      ]
      |> List.flatten()
      |> Enum.filter(&is_binary/1)
      |> Enum.join(" ")
      |> String.downcase()

    {tasks, projects, goals, text}
  end

  defp thresholds_for(:synapse),
    do: %{reduce_tasks: 8, reduce_projects: 6, ship_tasks_max: 5, ship_goals_max: 3}

  defp thresholds_for(:skills),
    do: %{reduce_tasks: 8, reduce_projects: 6, ship_tasks_max: 5, ship_goals_max: 3}

  defp thresholds_for(:llm),
    do: %{reduce_tasks: 9, reduce_projects: 6, ship_tasks_max: 6, ship_goals_max: 3}

  defp thresholds_for(:learning),
    do: %{reduce_tasks: 7, reduce_projects: 5, ship_tasks_max: 4, ship_goals_max: 3}

  defp thresholds_for(_),
    do: thresholds_for(:synapse)

  defp risky_text?(text) do
    String.contains?(text, [
      "risk",
      "block",
      "blocked",
      "fix",
      "incident",
      "hardening",
      "outage",
      "sev",
      "rollback",
      "regression"
    ])
  end

  defp ship_candidate?(text, tasks_n, goals_n, thresholds) do
    String.contains?(text, ["release", "ship", "deploy", "launch", "cutover"]) and
      tasks_n <= thresholds.ship_tasks_max and goals_n <= thresholds.ship_goals_max
  end

  defp ship_signal_strength(text) do
    hits =
      [
        {"release", 1.0},
        {"ship", 0.9},
        {"deploy", 0.95},
        {"launch", 0.85},
        {"cutover", 0.9},
        {"tag", 0.35},
        {"version", 0.35}
      ]
      |> Enum.reduce(0.0, fn {needle, w}, acc ->
        if String.contains?(text, needle), do: max(acc, w), else: acc
      end)

    min(1.0, hits)
  end

  defp risk_signal_strength(text) do
    hits =
      [
        {"incident", 1.0},
        {"outage", 1.0},
        {"sev", 0.9},
        {"rollback", 0.85},
        {"regression", 0.75},
        {"risk", 0.55},
        {"blocked", 0.65},
        {"blocker", 0.65}
      ]
      |> Enum.reduce(0.0, fn {needle, w}, acc ->
        if String.contains?(text, needle), do: max(acc, w), else: acc
      end)

    min(1.0, hits)
  end

  defp list_size(list) when is_list(list), do: length(list)
  defp list_size(_), do: 0

  defp title(task) when is_map(task), do: Map.get(task, "title") || Map.get(task, :title)
  defp title(_), do: nil

  defp score_goal(goal, corpus_tokens) do
    name = Map.get(goal, "name") || Map.get(goal, :name) || ""
    area = Map.get(goal, "area") || Map.get(goal, :area)
    status = Map.get(goal, "status") || Map.get(goal, :status)

    goal_tokens = tokenize(name)
    matched = MapSet.intersection(corpus_tokens, goal_tokens) |> MapSet.to_list() |> Enum.sort()

    lexical =
      case MapSet.size(goal_tokens) do
        0 -> 0.0
        n -> min(1.0, length(matched) / n)
      end

    recency = recency_strength(goal)
    activity = activity_strength(goal)

    score = 0.62 * lexical + 0.22 * recency + 0.16 * activity

    %{
      name: name,
      area: area,
      status: status,
      score: score,
      matched_tokens: matched,
      components: %{lexical: lexical, recency: recency, activity: activity}
    }
  end

  defp recency_strength(goal) do
    dt =
      Enum.find_value(
        [
          Map.get(goal, :last_active_at),
          Map.get(goal, :last_decision_at),
          parse_dt(Map.get(goal, "updated_at")),
          parse_dt(Map.get(goal, "created_at")),
          Map.get(goal, :synced_at)
        ],
        & &1
      )

    case dt do
      %DateTime{} = t ->
        hours = DateTime.diff(DateTime.utc_now(), t, :second) / 3600.0
        # 1.0 at <= 6h, decays toward 0 by ~10d
        :math.exp(-hours / 72.0)

      _ ->
        0.0
    end
  end

  defp activity_strength(goal) do
    decisions = Map.get(goal, :decision_count, 0) || 0
    d = min(12, decisions) / 12.0

    summary = Map.get(goal, :progress_summary)
    s = if is_binary(summary) and String.trim(summary) != "", do: 0.35, else: 0.0

    min(1.0, 0.55 * d + s)
  end

  defp parse_dt(nil), do: nil

  defp parse_dt(bin) when is_binary(bin) do
    case DateTime.from_iso8601(bin) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end

  defp parse_dt(%DateTime{} = dt), do: dt
  defp parse_dt(_), do: nil

  defp tokenize(text) when is_binary(text) do
    text
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, " ")
    |> String.split(" ", trim: true)
    |> Enum.filter(fn t -> String.length(t) >= 3 end)
    |> Enum.reject(&MapSet.member?(@stopwords, &1))
    |> MapSet.new()
  end

  defp tokenize(_), do: MapSet.new()

  defp as_float(v) when is_float(v), do: v
  defp as_float(v) when is_integer(v), do: v * 1.0

  defp as_float(v) when is_binary(v) do
    case Float.parse(v) do
      {f, _} -> f
      :error -> 0.0
    end
  end

  defp as_float(_), do: 0.0

  defp round4(n) when is_number(n), do: Float.round(n * 1.0, 4)
  defp round4(_), do: 0.0
end
