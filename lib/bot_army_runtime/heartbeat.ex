defmodule BotArmy.Heartbeat do
  @moduledoc """
  Persists the latest `system.health` heartbeat per service and tenant.

  Rows are upserted on each publish so restarts and boot announcements can read
  the last known liveness from PostgreSQL instead of relying on NATS alone.
  """

  use Ecto.Schema

  alias BotArmyRuntime.Personality.Observability
  alias BotArmyRuntime.Personality.Repo, as: PersonalityRepo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @doc false
  schema "heartbeats" do
    field(:bot_id, :string)
    field(:service, :string)
    field(:tenant_id, :binary_id)
    field(:source, :string)
    field(:status, :string)
    field(:uptime_seconds, :integer)
    field(:last_event_age_ms, :integer)
    field(:sequence, :integer)
    field(:payload, :map, default: %{})
    field(:recorded_at, :utc_datetime)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Returns the latest persisted heartbeat for a service and tenant.
  """
  @spec get(String.t() | atom(), keyword()) :: %__MODULE__{} | nil
  def get(service, opts \\ []) when is_atom(service) or is_binary(service) do
    telemetry? = Keyword.get(opts, :telemetry, true)
    start_mono = if telemetry?, do: System.monotonic_time(), else: nil

    service_str = normalize_service(service)
    tenant_id = Keyword.get(opts, :tenant_id, BotArmyRuntime.Tenant.default_tenant_id())
    repo = PersonalityRepo.resolve(Keyword.get(opts, :repo))

    result = query_row(repo, service_str, tenant_id)

    if telemetry? && start_mono do
      emit_get_observability(start_mono, service_str, tenant_id, result)
    end

    row_from_query_tag(result)
  end

  @doc """
  Upserts the latest heartbeat from a `system.health` envelope or publish opts.
  """
  @spec record(map() | keyword(), keyword()) :: {:ok, %__MODULE__{}} | {:error, term()} | :skipped
  def record(envelope_or_opts, opts \\ [])

  def record(envelope, opts) when is_map(envelope) do
    record_from_envelope(envelope, opts)
  end

  def record(publish_opts, extra_opts) when is_list(publish_opts) do
    record_from_publish_opts(publish_opts, extra_opts)
  end

  defp record_from_envelope(envelope, opts) do
    with {:ok, attrs} <- envelope_to_attrs(envelope) do
      persist(attrs, opts)
    end
  end

  defp record_from_publish_opts(publish_opts, extra_opts) do
    source = Keyword.fetch!(publish_opts, :source)
    service = Keyword.fetch!(publish_opts, :service)
    tenant_id = Keyword.get(publish_opts, :tenant_id, BotArmyRuntime.Tenant.default_tenant_id())
    tenant_uuid = normalize_tenant_id(tenant_id)

    status =
      case Keyword.get(publish_opts, :status) do
        nil ->
          BotArmyRuntime.SynapseHealth.signal_to_status(
            Keyword.get(publish_opts, :health_signal, "nominal")
          )

        value when is_binary(value) ->
          value
      end

    uptime =
      Keyword.get(publish_opts, :uptime_seconds, BotArmyRuntime.SynapseHealth.uptime_seconds())

    last_age = Keyword.get(publish_opts, :last_event_age_ms, 0)

    payload =
      %{
        "service" => service,
        "status" => status,
        "uptime_seconds" => uptime,
        "last_event_age_ms" => last_age
      }
      |> maybe_put("dedupe_key", Keyword.get(publish_opts, :dedupe_key))
      |> maybe_put("sequence", Keyword.get(publish_opts, :sequence))

    attrs = %{
      bot_id: service,
      service: service,
      tenant_id: tenant_uuid,
      source: source,
      status: status,
      uptime_seconds: uptime,
      last_event_age_ms: last_age,
      sequence: Keyword.get(publish_opts, :sequence),
      payload: payload,
      recorded_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    persist(attrs, extra_opts)
  end

  defp envelope_to_attrs(%{"event" => "system.health"} = envelope) do
    payload = Map.get(envelope, "payload", %{})
    service = Map.get(payload, "service")
    tenant_id = Map.get(envelope, "tenant_id", BotArmyRuntime.Tenant.default_tenant_id())
    tenant_uuid = normalize_tenant_id(tenant_id)

    if is_binary(service) and service != "" do
      {:ok,
       %{
         bot_id: service,
         service: service,
         tenant_id: tenant_uuid,
         source: Map.get(envelope, "source", "unknown"),
         status: Map.get(payload, "status", "unknown"),
         uptime_seconds: Map.get(payload, "uptime_seconds"),
         last_event_age_ms: Map.get(payload, "last_event_age_ms"),
         sequence: Map.get(payload, "sequence"),
         payload: payload,
         recorded_at: parse_recorded_at(Map.get(envelope, "timestamp"))
       }}
    else
      {:error, :missing_service}
    end
  end

  defp envelope_to_attrs(_), do: {:error, :invalid_envelope}

  defp persist(attrs, opts) do
    repo = PersonalityRepo.resolve(Keyword.get(opts, :repo))
    telemetry? = Keyword.get(opts, :telemetry, true)
    start_mono = if telemetry?, do: System.monotonic_time(), else: nil

    unless PersonalityRepo.available?(repo) do
      if telemetry? && start_mono do
        Observability.heartbeat_record_complete(
          start_mono,
          attrs.service,
          tenant_id_label(attrs.tenant_id),
          :skipped,
          nil
        )
      end

      :skipped
    else
      do_persist(repo, attrs, start_mono, telemetry?)
    end
  end

  defp do_persist(repo, attrs, start_mono, telemetry?) do
    query = """
    INSERT INTO heartbeats (
      bot_id,
      service,
      tenant_id,
      source,
      status,
      uptime_seconds,
      last_event_age_ms,
      sequence,
      payload,
      recorded_at,
      inserted_at,
      updated_at
    )
    VALUES ($1, $2, $3::uuid, $4, $5, $6, $7, $8, $9::jsonb, $10, timezone('UTC', now()), timezone('UTC', now()))
    ON CONFLICT (service, tenant_id)
    DO UPDATE SET
      bot_id = EXCLUDED.bot_id,
      source = EXCLUDED.source,
      status = EXCLUDED.status,
      uptime_seconds = EXCLUDED.uptime_seconds,
      last_event_age_ms = EXCLUDED.last_event_age_ms,
      sequence = EXCLUDED.sequence,
      payload = EXCLUDED.payload,
      recorded_at = EXCLUDED.recorded_at,
      updated_at = timezone('UTC', now())
    RETURNING *
    """

    params = [
      attrs.bot_id,
      attrs.service,
      attrs.tenant_id,
      attrs.source,
      attrs.status,
      attrs.uptime_seconds,
      attrs.last_event_age_ms,
      attrs.sequence,
      Jason.encode!(attrs.payload),
      attrs.recorded_at
    ]

    case repo.query(query, params) do
      {:ok,
       %Postgrex.Result{
         rows: [
           [
             id,
             bot_id,
             service,
             tenant_id,
             source,
             status,
             uptime_seconds,
             last_event_age_ms,
             sequence,
             payload,
             recorded_at,
             inserted_at,
             updated_at
           ]
         ]
       }} ->
        heartbeat = %__MODULE__{
          id: id,
          bot_id: bot_id,
          service: service,
          tenant_id: tenant_id,
          source: source,
          status: status,
          uptime_seconds: uptime_seconds,
          last_event_age_ms: last_event_age_ms,
          sequence: sequence,
          payload: payload,
          recorded_at: recorded_at,
          inserted_at: inserted_at,
          updated_at: updated_at
        }

        if telemetry? && start_mono do
          Observability.heartbeat_record_complete(
            start_mono,
            service,
            tenant_id_label(tenant_id),
            :ok,
            status
          )
        end

        {:ok, heartbeat}

      {:ok, %Postgrex.Result{rows: []}} ->
        maybe_emit_record_error(start_mono, telemetry?, attrs, "no rows returned from upsert")
        {:error, "No rows returned from upsert"}

      {:error, reason} ->
        maybe_emit_record_error(start_mono, telemetry?, attrs, inspect(reason))
        {:error, reason}
    end
  end

  defp query_row(repo, service, tenant_id) do
    unless PersonalityRepo.available?(repo) do
      {:error, nil}
    else
      query = """
      SELECT
        id,
        bot_id,
        service,
        tenant_id,
        source,
        status,
        uptime_seconds,
        last_event_age_ms,
        sequence,
        payload,
        recorded_at,
        inserted_at,
        updated_at
      FROM heartbeats
      WHERE service = $1
        AND tenant_id = $2::uuid
      LIMIT 1
      """

      case repo.query(query, [service, tenant_id]) do
        {:ok, %Postgrex.Result{rows: []}} ->
          {:missing, nil}

        {:ok,
         %Postgrex.Result{
           rows: [
             [
               id,
               bot_id,
               service,
               tenant_id,
               source,
               status,
               uptime_seconds,
               last_event_age_ms,
               sequence,
               payload,
               recorded_at,
               inserted_at,
               updated_at
             ]
           ]
         }} ->
          {:found,
           %__MODULE__{
             id: id,
             bot_id: bot_id,
             service: service,
             tenant_id: tenant_id,
             source: source,
             status: status,
             uptime_seconds: uptime_seconds,
             last_event_age_ms: last_event_age_ms,
             sequence: sequence,
             payload: payload,
             recorded_at: recorded_at,
             inserted_at: inserted_at,
             updated_at: updated_at
           }}

        _ ->
          {:error, nil}
      end
    end
  end

  defp emit_get_observability(start_mono, service, tenant_id, result) do
    outcome =
      case result do
        {:found, _} -> :found
        {:missing, _} -> :missing
        {:error, _} -> :error
      end

    heartbeat =
      case result do
        {:found, row} -> row
        _ -> nil
      end

    Observability.heartbeat_get_complete(
      start_mono,
      service,
      tenant_id,
      outcome,
      if(heartbeat, do: heartbeat.status, else: nil)
    )
  end

  defp row_from_query_tag({:found, row}), do: row
  defp row_from_query_tag(_), do: nil

  defp maybe_emit_record_error(start_mono, telemetry?, attrs, message) do
    if telemetry? && start_mono do
      Observability.heartbeat_record_complete(
        start_mono,
        attrs.service,
        tenant_id_label(attrs.tenant_id),
        :error,
        message
      )
    end
  end

  defp normalize_service(service) when is_atom(service), do: Atom.to_string(service)
  defp normalize_service(service) when is_binary(service), do: service

  defp normalize_tenant_id(tenant_id) when is_binary(tenant_id) do
    case Ecto.UUID.dump(tenant_id) do
      {:ok, uuid_binary} -> uuid_binary
      :error -> tenant_id
    end
  end

  defp normalize_tenant_id(other), do: other

  defp tenant_id_label(tenant_id) when is_binary(tenant_id), do: tenant_id
  defp tenant_id_label(other), do: inspect(other)

  defp parse_recorded_at(nil), do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp parse_recorded_at(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _} -> DateTime.truncate(dt, :second)
      _ -> DateTime.utc_now() |> DateTime.truncate(:second)
    end
  end

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
