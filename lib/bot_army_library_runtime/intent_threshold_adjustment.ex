defmodule BotArmy.IntentThresholdAdjustment do
  @moduledoc """
  Adaptive weight adjustments for intent thresholds.

  ReflectionJob writes adjustments when it detects outcome patterns
  (consecutive failures, low success rates). ThresholdModel reads them
  alongside static config and applies as multipliers on weights.

  Each row stores the original weight and the adjusted weight for a
  specific (bot_name, action, observation_type) triple. The effective
  factor is `adjusted_weight / original_weight`.
  """

  use Ecto.Schema

  alias BotArmyLibraryRuntime.Personality.Repo, as: PersonalityRepo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  schema "intent_threshold_adjustments" do
    field(:bot_name, :string)
    field(:action, :string)
    field(:observation_type, :string)
    field(:original_weight, :float)
    field(:adjusted_weight, :float)
    field(:adjustment_reason, :string)
    field(:source, :string, default: "reflection")

    timestamps(type: :utc_datetime)
  end

  @doc """
  Record a new threshold weight adjustment.
  """
  @spec record(map(), keyword()) :: {:ok, %__MODULE__{}} | {:error, term()} | :skipped
  def record(attrs, opts \\ []) when is_map(attrs) do
    repo = PersonalityRepo.resolve(Keyword.get(opts, :repo))

    bot_name = Map.get(attrs, :bot_name) || Map.get(attrs, "bot_name")
    action = Map.get(attrs, :action) || Map.get(attrs, "action")
    observation_type = Map.get(attrs, :observation_type) || Map.get(attrs, "observation_type")
    original_weight = Map.get(attrs, :original_weight) || Map.get(attrs, "original_weight")
    adjusted_weight = Map.get(attrs, :adjusted_weight) || Map.get(attrs, "adjusted_weight")

    cond do
      not PersonalityRepo.available?(repo) ->
        :skipped

      not is_binary(bot_name) or bot_name == "" ->
        {:error, :missing_bot_name}

      not is_binary(action) or action == "" ->
        {:error, :missing_action}

      not is_binary(observation_type) or observation_type == "" ->
        {:error, :missing_observation_type}

      true ->
        do_record(repo, %{
          bot_name: bot_name,
          action: action,
          observation_type: observation_type,
          original_weight: original_weight,
          adjusted_weight: adjusted_weight,
          adjustment_reason:
            Map.get(attrs, :adjustment_reason) || Map.get(attrs, "adjustment_reason"),
          source: Map.get(attrs, :source) || Map.get(attrs, "source") || "reflection"
        })
    end
  end

  @doc """
  Get the latest adjustment per observation_type for a bot+action pair.

  Returns a list of maps with :observation_type, :original_weight,
  :adjusted_weight, :adjustment_reason, :source, :created_at.
  """
  @spec latest_adjustments(String.t(), String.t(), keyword()) :: [map()]
  def latest_adjustments(bot_name, action, opts \\ []) when is_binary(bot_name) do
    repo = PersonalityRepo.resolve(Keyword.get(opts, :repo))

    if PersonalityRepo.available?(repo) do
      query_latest(repo, bot_name, action)
    else
      []
    end
  end

  @doc """
  List all adjustments for a bot+action pair, newest first.
  """
  @spec list_adjustments(String.t(), String.t(), keyword()) :: [map()]
  def list_adjustments(bot_name, action, opts \\ []) when is_binary(bot_name) do
    repo = PersonalityRepo.resolve(Keyword.get(opts, :repo))
    limit = Keyword.get(opts, :limit, 50)

    if PersonalityRepo.available?(repo) do
      query_list(repo, bot_name, action, limit)
    else
      []
    end
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Private
  # ───────────────────────────────────────────────────────────────────────────

  defp do_record(repo, attrs) do
    query = """
    INSERT INTO intent_threshold_adjustments (
      bot_name, action, observation_type, original_weight, adjusted_weight,
      adjustment_reason, source, inserted_at, updated_at
    )
    VALUES ($1, $2, $3, $4, $5, $6, $7,
            timezone('UTC', now()), timezone('UTC', now()))
    RETURNING *
    """

    params = [
      attrs.bot_name,
      attrs.action,
      attrs.observation_type,
      attrs.original_weight,
      attrs.adjusted_weight,
      attrs.adjustment_reason,
      attrs.source
    ]

    case repo.query(query, params) do
      {:ok, %Postgrex.Result{rows: [row]}} ->
        {:ok, row_to_struct(row)}

      {:ok, %Postgrex.Result{rows: []}} ->
        {:error, "No rows returned from insert"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp query_latest(repo, bot_name, action) do
    query = """
    SELECT DISTINCT ON (observation_type)
      bot_name, action, observation_type, original_weight, adjusted_weight,
      adjustment_reason, source, inserted_at
    FROM intent_threshold_adjustments
    WHERE bot_name = $1 AND action = $2
    ORDER BY observation_type, inserted_at DESC
    """

    case repo.query(query, [bot_name, action]) do
      {:ok, %Postgrex.Result{rows: rows}} ->
        Enum.map(rows, &row_to_map/1)

      _ ->
        []
    end
  end

  defp query_list(repo, bot_name, action, limit) do
    query = """
    SELECT bot_name, action, observation_type, original_weight, adjusted_weight,
           adjustment_reason, source, inserted_at
    FROM intent_threshold_adjustments
    WHERE bot_name = $1 AND action = $2
    ORDER BY inserted_at DESC
    LIMIT $3
    """

    case repo.query(query, [bot_name, action, limit]) do
      {:ok, %Postgrex.Result{rows: rows}} ->
        Enum.map(rows, &row_to_map/1)

      _ ->
        []
    end
  end

  defp row_to_struct([
         id,
         bot_name,
         action,
         observation_type,
         original_weight,
         adjusted_weight,
         adjustment_reason,
         source,
         inserted_at,
         updated_at
       ]) do
    %__MODULE__{
      id: id,
      bot_name: bot_name,
      action: action,
      observation_type: observation_type,
      original_weight: original_weight,
      adjusted_weight: adjusted_weight,
      adjustment_reason: adjustment_reason,
      source: source,
      inserted_at: inserted_at,
      updated_at: updated_at
    }
  end

  defp row_to_struct(row) when is_list(row) do
    fields = [
      :id,
      :bot_name,
      :action,
      :observation_type,
      :original_weight,
      :adjusted_weight,
      :adjustment_reason,
      :source,
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
         observation_type,
         original_weight,
         adjusted_weight,
         adjustment_reason,
         source,
         inserted_at
       ]) do
    %{
      bot_name: bot_name,
      action: action,
      observation_type: observation_type,
      original_weight: original_weight,
      adjusted_weight: adjusted_weight,
      adjustment_reason: adjustment_reason,
      source: source,
      created_at: inserted_at
    }
  end
end
