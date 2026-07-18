defmodule BotArmyLibraryRuntime.Intent.ArmyOpinionVote do
  @moduledoc """
  Request/reply handler for `*.army.opinion.vote` subjects used by
  `bridge.army.opinion.collect`.

  Returns a deterministic persona-leaning choice from `options` (when present)
  so each bot can "vote" without calling an LLM. This is intentionally shallow:
  flavor for humans/operators, not a source of ground truth.
  """

  @personas [:gtd, :synapse, :sre, :llm]

  @spec build_reply(:gtd | :synapse | :sre | :llm, String.t() | map()) :: map()
  def build_reply(persona, body) when persona in @personas and is_binary(body) do
    case Jason.decode(body) do
      {:ok, map} when is_map(map) -> build_reply(persona, map)
      {:error, _} -> error_vote("unknown", "invalid_json")
    end
  end

  def build_reply(persona, req) when persona in @personas and is_map(req) do
    with :ok <- validate_request(req) do
      voter_id = Map.fetch!(req, "voter_id")
      question = Map.fetch!(req, "question")
      options = normalize_options(Map.get(req, "options"))

      {choice, rationale} = choose(persona, question, options)

      base = %{
        "ok" => true,
        "schema_version" => "1.0",
        "voter_id" => voter_id,
        "choice" => choice,
        "rationale" => rationale
      }

      if options == [] do
        Map.put(base, "abstain", true)
      else
        base
      end
    else
      {:error, reason} ->
        error_vote(Map.get(req, "voter_id", "unknown"), inspect(reason))
    end
  end

  defp validate_request(req) do
    cond do
      Map.get(req, "schema_version") != "1.0" ->
        {:error, :bad_schema_version}

      not (is_binary(Map.get(req, "question")) and String.trim(Map.get(req, "question", "")) != "") ->
        {:error, :question_required}

      not (is_binary(Map.get(req, "voter_id")) and String.trim(Map.get(req, "voter_id", "")) != "") ->
        {:error, :voter_id_required}

      not (is_binary(Map.get(req, "correlation_id")) and
               String.trim(Map.get(req, "correlation_id", "")) != "") ->
        {:error, :correlation_id_required}

      true ->
        :ok
    end
  end

  defp normalize_options(nil), do: []

  defp normalize_options(list) when is_list(list) do
    list
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp normalize_options(_), do: []

  defp choose(persona, _question, []) do
    {nil,
     "#{persona_label(persona)}: no options were provided, so I abstain from picking a label."}
  end

  defp choose(persona, _question, options) do
    case first_match(options, patterns_for(persona)) do
      nil ->
        idx = default_index(persona)
        choice = Enum.at(options, rem(idx, max(length(options), 1)))

        {choice,
         "#{persona_label(persona)}: no strong keyword match; defaulting to stable slot #{idx}."}

      choice ->
        {choice,
         "#{persona_label(persona)}: closest match to my usual lane in the listed options."}
    end
  end

  defp patterns_for(:gtd),
    do: [~r/record|keeper|clerk|scribe|ledger|queue|truth/i]

  defp patterns_for(:synapse),
    do: [~r/oracle|narrator|gm|seer|thread|timing|weave/i]

  defp patterns_for(:sre),
    do: [~r/guard|warden|sentry|shield|wall|risk|blast/i]

  defp patterns_for(:llm),
    do: [~r/bard|story|song|metaphor|voice|ember|tale/i]

  defp default_index(:gtd), do: 0
  defp default_index(:synapse), do: 1
  defp default_index(:sre), do: 2
  defp default_index(:llm), do: 3

  defp persona_label(:gtd), do: "GTD"
  defp persona_label(:synapse), do: "Synapse"
  defp persona_label(:sre), do: "SRE"
  defp persona_label(:llm), do: "LLM"

  defp first_match(options, patterns) do
    Enum.find_value(options, fn opt ->
      if Enum.any?(patterns, &Regex.match?(&1, opt)), do: opt, else: nil
    end)
  end

  defp error_vote(voter_id, reason) do
    %{
      "ok" => false,
      "schema_version" => "1.0",
      "voter_id" => voter_id,
      "error" => reason
    }
  end
end
