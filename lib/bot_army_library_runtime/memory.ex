defmodule BotArmyLibraryRuntime.Memory do
  @moduledoc """
  Append-only session memory in PostgreSQL for resuming thoughts across restarts.

  Entries are scoped by `scope` (for example a Synapse `session_id`), `tenant_id`,
  and `kind` (`exchange`, `thought`, `summary`, or `episodic`). Callers trim per
  scope with `limit` on append and list.
  """

  use Ecto.Schema

  alias BotArmyLibraryRuntime.Personality.Observability
  alias BotArmyLibraryRuntime.Personality.Repo, as: PersonalityRepo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @exchange_kind "exchange"

  @doc false
  schema "memory_entries" do
    field(:scope, :string)
    field(:tenant_id, :binary_id)
    field(:user_id, :string)
    field(:source, :string)
    field(:kind, :string)
    field(:payload, :map, default: %{})
    field(:recorded_at, :utc_datetime)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Appends one memory entry and trims older rows for the same scope.
  """
  @spec append(map(), keyword()) :: {:ok, %__MODULE__{}} | {:error, term()} | :skipped
  def append(attrs, opts \\ []) when is_map(attrs) do
    telemetry? = Keyword.get(opts, :telemetry, true)
    start_mono = if telemetry?, do: System.monotonic_time(), else: nil

    with {:ok, normalized} <- normalize_append_attrs(attrs) do
      repo = PersonalityRepo.resolve(Keyword.get(opts, :repo))
      limit = Keyword.get(opts, :limit, 10)

      if PersonalityRepo.available?(repo) do
        do_append(repo, normalized, limit, start_mono, telemetry?)
      else
        if telemetry? && start_mono do
          Observability.memory_append_complete(
            start_mono,
            normalized.scope,
            tenant_id_label(normalized.tenant_id),
            :skipped,
            normalized.kind
          )
        end

        :skipped
      end
    end
  end

  @doc """
  Records one question/answer exchange for a session scope.
  """
  @spec record_exchange(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, %__MODULE__{}} | {:error, term()} | :skipped
  def record_exchange(scope, question, answer, opts \\ [])
      when is_binary(scope) and is_binary(question) and is_binary(answer) do
    recorded_at = DateTime.utc_now() |> DateTime.truncate(:second)

    append(
      %{
        scope: scope,
        tenant_id: Keyword.get(opts, :tenant_id, BotArmyLibraryRuntime.Tenant.default_tenant_id()),
        user_id: Keyword.get(opts, :user_id),
        source: Keyword.get(opts, :source, "synapse"),
        kind: @exchange_kind,
        payload: %{
          "question" => question,
          "answer" => answer,
          "at" => DateTime.to_iso8601(recorded_at)
        },
        recorded_at: recorded_at
      },
      opts
    )
  end

  @doc """
  Returns recent memory entries for a scope, oldest first.
  """
  @spec list(String.t(), keyword()) :: [map()]
  def list(scope, opts \\ []) when is_binary(scope) do
    telemetry? = Keyword.get(opts, :telemetry, true)
    start_mono = if telemetry?, do: System.monotonic_time(), else: nil

    tenant_id = Keyword.get(opts, :tenant_id, BotArmyLibraryRuntime.Tenant.default_tenant_id())
    kind = Keyword.get(opts, :kind, @exchange_kind)
    limit = Keyword.get(opts, :limit, 10)
    repo = PersonalityRepo.resolve(Keyword.get(opts, :repo))

    entries =
      if PersonalityRepo.available?(repo) do
        query_entries(repo, scope, tenant_id, kind, limit)
      else
        []
      end

    if telemetry? && start_mono do
      Observability.memory_list_complete(
        start_mono,
        scope,
        tenant_id_label(tenant_id),
        if(entries == [], do: :missing, else: :found),
        kind,
        length(entries)
      )
    end

    entries
  end

  @doc """
  Deletes persisted memory for a scope.
  """
  @spec clear(String.t(), keyword()) :: :ok | {:error, term()} | :skipped
  def clear(scope, opts \\ []) when is_binary(scope) do
    telemetry? = Keyword.get(opts, :telemetry, true)
    start_mono = if telemetry?, do: System.monotonic_time(), else: nil

    tenant_id = Keyword.get(opts, :tenant_id, BotArmyLibraryRuntime.Tenant.default_tenant_id())
    kind = Keyword.get(opts, :kind)
    repo = PersonalityRepo.resolve(Keyword.get(opts, :repo))

    if PersonalityRepo.available?(repo) do
      do_clear(repo, scope, tenant_id, kind, start_mono, telemetry?)
    else
      if telemetry? && start_mono do
        Observability.memory_clear_complete(
          start_mono,
          scope,
          tenant_id_label(tenant_id),
          :skipped,
          kind
        )
      end

      :skipped
    end
  end

  defp normalize_append_attrs(attrs) do
    scope = Map.get(attrs, :scope) || Map.get(attrs, "scope")

    if not is_binary(scope) or scope == "" do
      {:error, :missing_scope}
    else
      tenant_id =
        Map.get(attrs, :tenant_id) || Map.get(attrs, "tenant_id") ||
          BotArmyLibraryRuntime.Tenant.default_tenant_id()

      kind = Map.get(attrs, :kind) || Map.get(attrs, "kind") || "thought"
      payload = Map.get(attrs, :payload) || Map.get(attrs, "payload") || %{}

      recorded_at =
        Map.get(attrs, :recorded_at) || Map.get(attrs, "recorded_at") ||
          DateTime.utc_now() |> DateTime.truncate(:second)

      {:ok,
       %{
         scope: scope,
         tenant_id: tenant_id,
         user_id: Map.get(attrs, :user_id) || Map.get(attrs, "user_id"),
         source: Map.get(attrs, :source) || Map.get(attrs, "source"),
         kind: kind,
         payload: payload,
         recorded_at: recorded_at
       }}
    end
  end

  defp do_append(repo, attrs, limit, start_mono, telemetry?) do
    query = """
    INSERT INTO memory_entries (
      scope,
      tenant_id,
      user_id,
      source,
      kind,
      payload,
      recorded_at,
      inserted_at,
      updated_at
    )
    VALUES ($1, $2::uuid, $3, $4, $5, $6::jsonb, $7, timezone('UTC', now()), timezone('UTC', now()))
    RETURNING *
    """

    params = [
      attrs.scope,
      attrs.tenant_id,
      attrs.user_id,
      attrs.source,
      attrs.kind,
      Jason.encode!(attrs.payload),
      attrs.recorded_at
    ]

    result =
      case repo.query(query, params) do
        {:ok,
         %Postgrex.Result{
           rows: [
             [
               id,
               scope,
               tenant_id,
               user_id,
               source,
               kind,
               payload,
               recorded_at,
               inserted_at,
               updated_at
             ]
           ]
         }} ->
          trim_scope(repo, scope, tenant_id, kind, limit)

          {:ok,
           %__MODULE__{
             id: id,
             scope: scope,
             tenant_id: tenant_id,
             user_id: user_id,
             source: source,
             kind: kind,
             payload: payload,
             recorded_at: recorded_at,
             inserted_at: inserted_at,
             updated_at: updated_at
           }}

        {:ok, %Postgrex.Result{rows: []}} ->
          {:error, "No rows returned from insert"}

        {:error, reason} ->
          {:error, reason}
      end

    if telemetry? && start_mono do
      outcome =
        case result do
          {:ok, _} -> :ok
          {:error, _} -> :error
        end

      Observability.memory_append_complete(
        start_mono,
        attrs.scope,
        tenant_id_label(attrs.tenant_id),
        outcome,
        attrs.kind
      )
    end

    result
  end

  defp query_entries(repo, scope, tenant_id, kind, limit) do
    query = """
    SELECT payload, recorded_at
    FROM memory_entries
    WHERE scope = $1
      AND tenant_id = $2::uuid
      AND kind = $3
    ORDER BY recorded_at ASC, inserted_at ASC
    LIMIT $4
    """

    case repo.query(query, [scope, tenant_id, kind, limit]) do
      {:ok, %Postgrex.Result{rows: rows}} ->
        Enum.map(rows, &entry_from_row/1)

      _ ->
        []
    end
  end

  defp do_clear(repo, scope, tenant_id, kind, start_mono, telemetry?) do
    {query, params} =
      if is_binary(kind) and kind != "" do
        {
          """
          DELETE FROM memory_entries
          WHERE scope = $1
            AND tenant_id = $2::uuid
            AND kind = $3
          """,
          [scope, tenant_id, kind]
        }
      else
        {
          """
          DELETE FROM memory_entries
          WHERE scope = $1
            AND tenant_id = $2::uuid
          """,
          [scope, tenant_id]
        }
      end

    result =
      case repo.query(query, params) do
        {:ok, _} -> :ok
        {:error, reason} -> {:error, reason}
      end

    if telemetry? && start_mono do
      outcome =
        case result do
          :ok -> :ok
          {:error, _} -> :error
        end

      Observability.memory_clear_complete(
        start_mono,
        scope,
        tenant_id_label(tenant_id),
        outcome,
        kind
      )
    end

    result
  end

  defp trim_scope(repo, scope, tenant_id, kind, limit) when is_integer(limit) and limit > 0 do
    query = """
    DELETE FROM memory_entries
    WHERE id IN (
      SELECT id
      FROM memory_entries
      WHERE scope = $1
        AND tenant_id = $2::uuid
        AND kind = $3
      ORDER BY recorded_at DESC, inserted_at DESC
      OFFSET $4
    )
    """

    _ = repo.query(query, [scope, tenant_id, kind, limit])
    :ok
  end

  defp trim_scope(_repo, _scope, _tenant_id, _kind, _limit), do: :ok

  defp entry_from_row([payload, recorded_at]) when is_map(payload) do
    entry_from_payload(payload, recorded_at)
  end

  defp entry_from_row([payload, recorded_at]) when is_binary(payload) do
    case Jason.decode(payload) do
      {:ok, decoded} -> entry_from_payload(decoded, recorded_at)
      _ -> %{}
    end
  end

  defp entry_from_payload(payload, recorded_at) do
    at =
      case Map.get(payload, "at") do
        nil ->
          if recorded_at, do: DateTime.to_iso8601(recorded_at), else: nil

        value ->
          value
      end

    %{
      question: Map.get(payload, "question"),
      answer: Map.get(payload, "answer"),
      at: at
    }
  end

  defp tenant_id_label(tenant_id) when is_binary(tenant_id), do: tenant_id
  defp tenant_id_label(other), do: inspect(other)
end
