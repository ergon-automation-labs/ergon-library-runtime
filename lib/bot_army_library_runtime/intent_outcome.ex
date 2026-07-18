defmodule BotArmyLibraryRuntime.IntentOutcome do
  @moduledoc """
  Persisted intent outcome tracking in PostgreSQL.

  Records every intent decision (act, defer, abort, vetoed) and its eventual
  outcome (success, failure, partial, unknown). ThresholdModel and ReflectionJob
  use this data to adapt intent thresholds based on past performance.

  Follows the same raw SQL via PersonalityRepo pattern as Soul/Heartbeat/Memory.
  """

  use Ecto.Schema

  alias BotArmyLibraryRuntime.Personality.Repo, as: PersonalityRepo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "intent_outcomes" do
    field(:bot_name, :string)
    field(:action, :string)
    field(:intent_id, :string)
    field(:decision, :string)
    field(:outcome, :string)
    field(:outcome_metadata, :map, default: %{})
    field(:score, :float)
    field(:reason, :string)
    field(:observed_at, :utc_datetime)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Record an initial intent outcome (decision phase).
  """
  @spec record(map(), keyword()) :: {:ok, %__MODULE__{}} | {:error, term()} | :skipped
  def record(attrs, opts \\ []) when is_map(attrs) do
    telemetry? = Keyword.get(opts, :telemetry, true)
    start_mono = if telemetry?, do: System.monotonic_time(), else: nil

    with {:ok, normalized} <- normalize_record_attrs(attrs) do
      repo = PersonalityRepo.resolve(Keyword.get(opts, :repo))

      if PersonalityRepo.available?(repo) do
        do_record(repo, normalized, start_mono, telemetry?)
      else
        if telemetry? && start_mono do
          :telemetry.execute(
            [:bot_army, :intent, :outcome, :record],
            %{duration: System.monotonic_time() - start_mono},
            %{status: :skipped, bot_name: normalized.bot_name}
          )
        end

        :skipped
      end
    end
  end

  @doc """
  Resolve an outcome for an existing intent by intent_id.

  Updates the outcome, outcome_metadata, and updated_at fields.
  Returns `:not_found` if no row matches the intent_id.
  """
  @spec resolve(String.t(), String.t(), map(), keyword()) ::
          {:ok, %__MODULE__{}} | {:error, term()} | :not_found | :skipped
  def resolve(intent_id, outcome, metadata \\ %{}, opts \\ []) when is_binary(intent_id) do
    repo = PersonalityRepo.resolve(Keyword.get(opts, :repo))

    if PersonalityRepo.available?(repo) do
      do_resolve(repo, intent_id, outcome, metadata)
    else
      :skipped
    end
  end

  @doc """
  Query recent outcomes for a bot+action pair, newest first.
  """
  @spec recent_outcomes(String.t(), String.t(), keyword()) :: [map()]
  def recent_outcomes(bot_name, action, opts \\ []) when is_binary(bot_name) do
    repo = PersonalityRepo.resolve(Keyword.get(opts, :repo))
    limit = Keyword.get(opts, :limit, 20)

    if PersonalityRepo.available?(repo) do
      query_recent(repo, bot_name, action, limit)
    else
      []
    end
  end

  @doc """
  Calculate success rate for a bot+action over a time window.

  Returns a float between 0.0 and 1.0. Returns 0.0 if no resolved outcomes.
  Default window is 24 hours.
  """
  @spec success_rate(String.t(), String.t(), keyword()) :: float()
  def success_rate(bot_name, action, opts \\ []) when is_binary(bot_name) do
    repo = PersonalityRepo.resolve(Keyword.get(opts, :repo))
    window_hours = Keyword.get(opts, :window_hours, 24)

    if PersonalityRepo.available?(repo) do
      query_success_rate(repo, bot_name, action, window_hours)
    else
      0.0
    end
  end

  @doc """
  List distinct (bot_name, action) pairs that have outcomes within a time window.
  Used by ReflectionJob to find active bot+action combinations.
  """
  @spec active_pairs(keyword()) :: [%{bot_name: String.t(), action: String.t()}]
  def active_pairs(opts \\ []) do
    repo = PersonalityRepo.resolve(Keyword.get(opts, :repo))
    window_hours = Keyword.get(opts, :window_hours, 24)

    if PersonalityRepo.available?(repo) do
      query_active_pairs(repo, window_hours)
    else
      []
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Private
  # ───────────────────────────────────────────────────────────────────────────

  defp normalize_record_attrs(attrs) do
    bot_name = Map.get(attrs, :bot_name) || Map.get(attrs, "bot_name")
    action = Map.get(attrs, :action) || Map.get(attrs, "action")
    intent_id = Map.get(attrs, :intent_id) || Map.get(attrs, "intent_id")

    cond do
      not is_binary(bot_name) or bot_name == "" ->
        {:error, :missing_bot_name}

      not is_binary(action) or action == "" ->
        {:error, :missing_action}

      not is_binary(intent_id) or intent_id == "" ->
        {:error, :missing_intent_id}

      true ->
        {:ok,
         %{
           bot_name: bot_name,
           action: action,
           intent_id: intent_id,
           decision: Map.get(attrs, :decision) || Map.get(attrs, "decision") || "unknown",
           outcome: Map.get(attrs, :outcome) || Map.get(attrs, "outcome"),
           outcome_metadata:
             Map.get(attrs, :outcome_metadata) || Map.get(attrs, "outcome_metadata") || %{},
           score: Map.get(attrs, :score) || Map.get(attrs, "score"),
           reason: Map.get(attrs, :reason) || Map.get(attrs, "reason"),
           observed_at:
             Map.get(attrs, :observed_at) || Map.get(attrs, "observed_at") ||
               DateTime.utc_now() |> DateTime.truncate(:second)
         }}
    end
  end

  defp do_record(repo, attrs, start_mono, telemetry?) do
    query = """
    INSERT INTO intent_outcomes (
      bot_name, action, intent_id, decision, outcome,
      outcome_metadata, score, reason, observed_at,
      inserted_at, updated_at
    )
    VALUES ($1, $2, $3, $4, $5, $6::jsonb, $7, $8, $9,
            timezone('UTC', now()), timezone('UTC', now()))
    RETURNING *
    """

    params = [
      attrs.bot_name,
      attrs.action,
      attrs.intent_id,
      attrs.decision,
      attrs.outcome,
      Jason.encode!(attrs.outcome_metadata),
      attrs.score,
      attrs.reason,
      attrs.observed_at
    ]

    result =
      case repo.query(query, params) do
        {:ok, %Postgrex.Result{rows: [row]}} ->
          {:ok, row_to_struct(row)}

        {:ok, %Postgrex.Result{rows: []}} ->
          {:error, "No rows returned from insert"}

        {:error, reason} ->
          {:error, reason}
      end

    if telemetry? && start_mono do
      :telemetry.execute(
        [:bot_army, :intent, :outcome, :record],
        %{duration: System.monotonic_time() - start_mono},
        %{
          status: if(match?({:ok, _}, result), do: :ok, else: :error),
          bot_name: attrs.bot_name,
          action: attrs.action
        }
      )
    end

    result
  end

  defp do_resolve(repo, intent_id, outcome, metadata) do
    query = """
    UPDATE intent_outcomes
    SET outcome = $1,
        outcome_metadata = $2::jsonb,
        updated_at = timezone('UTC', now())
    WHERE intent_id = $3
    RETURNING *
    """

    params = [
      outcome,
      Jason.encode!(metadata),
      intent_id
    ]

    case repo.query(query, params) do
      {:ok, %Postgrex.Result{rows: [row]}} ->
        {:ok, row_to_struct(row)}

      {:ok, %Postgrex.Result{rows: []}} ->
        :not_found

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp query_recent(repo, bot_name, action, limit) do
    query = """
    SELECT bot_name, action, intent_id, decision, outcome,
           outcome_metadata, score, reason, observed_at
    FROM intent_outcomes
    WHERE bot_name = $1 AND action = $2
    ORDER BY observed_at DESC
    LIMIT $3
    """

    case repo.query(query, [bot_name, action, limit]) do
      {:ok, %Postgrex.Result{rows: rows}} ->
        Enum.map(rows, &row_to_map/1)

      _ ->
        []
    end
  end

  defp query_success_rate(repo, bot_name, action, window_hours) do
    query = """
    SELECT
      COUNT(*) FILTER (WHERE outcome = 'success') AS successes,
      COUNT(*) FILTER (WHERE outcome IS NOT NULL AND outcome != 'unknown') AS total_resolved
    FROM intent_outcomes
    WHERE bot_name = $1
      AND action = $2
      AND observed_at >= $3
    """

    cutoff = DateTime.utc_now() |> DateTime.add(-window_hours * 3600, :second)
    params = [bot_name, action, cutoff]

    case repo.query(query, params) do
      {:ok, %Postgrex.Result{rows: [[successes, total]]}} ->
        if is_nil(total) or total == 0 do
          0.0
        else
          Float.round(successes / total, 4)
        end

      _ ->
        0.0
    end
  end

  defp query_active_pairs(repo, window_hours) do
    query = """
    SELECT DISTINCT bot_name, action
    FROM intent_outcomes
    WHERE observed_at >= $1
    """

    cutoff = DateTime.utc_now() |> DateTime.add(-window_hours * 3600, :second)

    case repo.query(query, [cutoff]) do
      {:ok, %Postgrex.Result{rows: rows}} ->
        Enum.map(rows, fn [bot_name, action] ->
          %{bot_name: bot_name, action: action}
        end)

      _ ->
        []
    end
  end

  defp row_to_struct([
         id,
         bot_name,
         action,
         intent_id,
         decision,
         outcome,
         outcome_metadata,
         score,
         reason,
         observed_at,
         inserted_at,
         updated_at
       ]) do
    %__MODULE__{
      id: id,
      bot_name: bot_name,
      action: action,
      intent_id: intent_id,
      decision: decision,
      outcome: outcome,
      outcome_metadata: outcome_metadata,
      score: score,
      reason: reason,
      observed_at: observed_at,
      inserted_at: inserted_at,
      updated_at: updated_at
    }
  end

  defp row_to_struct(row) when is_list(row) do
    fields = [
      :id,
      :bot_name,
      :action,
      :intent_id,
      :decision,
      :outcome,
      :outcome_metadata,
      :score,
      :reason,
      :observed_at,
      :inserted_at,
      :updated_at
    ]

    fields
    |> Enum.zip(row)
    |> Enum.into(%{})
  end

  defp row_to_map([
         bot_name,
         action,
         intent_id,
         decision,
         outcome,
         outcome_metadata,
         score,
         reason,
         observed_at
       ]) do
    decoded_metadata =
      case outcome_metadata do
        m when is_map(m) -> m
        s when is_binary(s) -> Jason.decode!(s)
        nil -> %{}
      end

    %{
      bot_name: bot_name,
      action: action,
      intent_id: intent_id,
      decision: decision,
      outcome: outcome,
      outcome_metadata: decoded_metadata,
      score: score,
      reason: reason,
      observed_at: observed_at
    }
  end
end
