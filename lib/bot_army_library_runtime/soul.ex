defmodule BotArmy.Soul do
  @moduledoc """
  Soul storage and retrieval module.

  The soul is the personality identity of a bot - its character voice, tone,
  priorities, and refusal rules. Stored as JSONB in PostgreSQL.

  ## Soul Schema

  ```json
  {
    "identity": {
      "name": "GTD Bot",
      "symbol": "◉",
      "role": "Surface the next right action"
    },
    "tone": "conversational",
    "verbosity": "medium",
    "priorities": ["actionability", "clarity", "warmth"],
    "refusals": ["judgmental", "saccharine", "overly technical"],
    "failure_behavior": "honest but kind"
  }
  ```

  ## Storage

  Soul configs are stored in PostgreSQL using the `souls` table:

  ```sql
  CREATE TABLE souls (
    id UUID PRIMARY KEY,
    bot_id TEXT NOT NULL,
    tenant_id UUID NOT NULL,
    config JSONB NOT NULL,
    version INTEGER DEFAULT 1,
    active BOOLEAN DEFAULT true,
    inserted_at TIMESTAMPTZ,
    updated_at TIMESTAMPTZ
  );
  ```

  ## Usage

  ```elixir
  # Get the current soul for a bot
  soul = BotArmy.Soul.get(:gtd_bot)

  # Get soul for a specific tenant
  soul = BotArmy.Soul.get(:gtd_bot, tenant_id: "uuid-here")

  # Upsert soul config (persists JSONB row per bot_id + tenant_id)
  {:ok, _} = BotArmy.Soul.upsert(:gtd_bot, %{"identity" => %{...}, "tone" => "more sarcastic"})
  ```

  ## Observability

  Loads, upserts, and NATS publishes emit `[:bot_army, :personality, :soul, :get | :upsert | :publish]` telemetry
  (see `BotArmyLibraryRuntime.Personality.Observability`) and structured logs. Pass `telemetry: false`
  to `get/2` only when probing version inside `upsert/3` to avoid duplicate load metrics.

  PromEx scrapes counters and latency histograms via `BotArmyLibraryRuntime.Metrics.PromExPlugin`.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias BotArmyLibraryRuntime.NATS.Publisher
  alias BotArmyLibraryRuntime.Personality.Observability
  alias BotArmyLibraryRuntime.Personality.Repo, as: PersonalityRepo

  @primary_key {:id, :binary_id, autogenerate: true}
  @foreign_key_type :binary_id

  @doc false
  schema "souls" do
    field(:bot_id, :string)
    field(:tenant_id, :binary_id)
    field(:config, :map, default: %{})
    field(:version, :integer, default: 1)
    field(:active, :boolean, default: true)

    timestamps(type: :utc_datetime)
  end

  @doc """
  Returns a changeset for soul creation/update.
  """
  def changeset(soul, attrs) do
    soul
    |> cast(attrs, [:bot_id, :tenant_id, :config, :version, :active])
    |> validate_required([:bot_id, :tenant_id, :config])
    |> validate_jsonb_config()
  end

  defp validate_jsonb_config(changeset) do
    # Validate config has expected structure
    case fetch_field(changeset, :config) do
      :error ->
        changeset

      {:ok, config} ->
        # Ensure config is a map with at least identity
        if is_map(config) and Map.has_key?(config, "identity") do
          changeset
        else
          add_error(changeset, :config, "must contain 'identity' field")
        end
    end
  end

  @doc """
  Get the current soul for a bot.

  Returns the active soul with the highest version for the given bot and tenant.

  ## Examples

      iex> BotArmy.Soul.get(:gtd_bot)
      %BotArmy.Soul{config: %{"identity" => %{...}}}

      iex> BotArmy.Soul.get(:gtd_bot, tenant_id: "uuid")
      %BotArmy.Soul{config: %{"identity" => %{...}}}

  """
  @spec get(
          atom() | String.t(),
          opts :: [tenant_id: String.t(), repo: module(), telemetry: boolean()]
        ) ::
          %__MODULE__{} | nil
  def get(bot_id, opts \\ []) when is_atom(bot_id) or is_binary(bot_id) do
    telemetry? = Keyword.get(opts, :telemetry, true)
    start_mono = if telemetry?, do: System.monotonic_time(), else: nil

    bot_id_str = Atom.to_string(bot_id) |> String.replace_prefix("bot_army_", "")

    tenant_id = Keyword.get(opts, :tenant_id, BotArmyLibraryRuntime.Tenant.default_tenant_id())
    repo = PersonalityRepo.resolve(Keyword.get(opts, :repo))

    result = query_soul_row(repo, bot_id_str, tenant_id)

    if telemetry? && start_mono do
      emit_soul_get_observability(start_mono, bot_id_str, tenant_id, result)
    end

    soul_from_query_tag(result)
  end

  defp query_soul_row(repo, bot_id_str, tenant_id) do
    query = """
    SELECT * FROM souls
    WHERE bot_id = $1
      AND tenant_id = $2::uuid
      AND active = true
    ORDER BY version DESC
    LIMIT 1
    """

    case repo.query(query, [bot_id_str, tenant_id]) do
      {:ok, %Postgrex.Result{rows: []}} ->
        {:missing, nil}

      {:ok,
       %Postgrex.Result{
         rows: [
           [id, row_bot_id, row_tenant_id, config, version, active, inserted_at, updated_at]
         ]
       }} ->
        {:found,
         %__MODULE__{
           id: id,
           bot_id: row_bot_id,
           tenant_id: row_tenant_id,
           config: config,
           version: version,
           active: active,
           inserted_at: inserted_at,
           updated_at: updated_at
         }}

      _ ->
        {:error, nil}
    end
  end

  defp emit_soul_get_observability(start_mono, bot_id_str, tenant_id, result) do
    {outcome, soul} =
      case result do
        {:missing, _} -> {:missing, nil}
        {:found, s} -> {:found, s}
        {:error, _} -> {:error, nil}
      end

    Observability.soul_get_complete(
      start_mono,
      bot_id_str,
      tenant_id_label(tenant_id),
      outcome,
      if(soul, do: soul.version, else: nil)
    )
  end

  defp soul_from_query_tag({:found, soul}), do: soul
  defp soul_from_query_tag(_), do: nil

  @doc """
  Create or update a soul configuration.

  Uses INSERT ... ON CONFLICT to handle upserts.
  """
  @spec upsert(atom() | String.t(), map(), opts :: [tenant_id: String.t(), repo: module()]) ::
          {:ok, %__MODULE__{}} | {:error, term()}
  def upsert(bot_id, config, opts \\ []) do
    start_mono = System.monotonic_time()

    bot_id_str = Atom.to_string(bot_id) |> String.replace_prefix("bot_army_", "")

    tenant_id = Keyword.get(opts, :tenant_id, BotArmyLibraryRuntime.Tenant.default_tenant_id())
    repo = PersonalityRepo.resolve(Keyword.get(opts, :repo))

    # Get current soul to determine version (suppress duplicate soul_get telemetry)
    current = get(bot_id, tenant_id: tenant_id, repo: repo, telemetry: false)

    version =
      case current do
        nil -> 1
        %__MODULE__{version: v} -> v + 1
      end

    query = """
    INSERT INTO souls (bot_id, tenant_id, config, version, active, inserted_at, updated_at)
    VALUES ($1, $2::uuid, $3::jsonb, $4, true, timezone('UTC', now()), timezone('UTC', now()))
    ON CONFLICT (bot_id, tenant_id)
    DO UPDATE SET
      config = $3::jsonb,
      version = $4,
      updated_at = timezone('UTC', now())
    RETURNING *
    """

    upsert_result =
      case repo.query(query, [
             bot_id_str,
             tenant_id,
             Jason.encode!(config),
             version
           ]) do
        {:ok,
         %Postgrex.Result{
           rows: [
             [id, row_bot_id, row_tenant_id, config, version, active, inserted_at, updated_at]
           ]
         }} ->
          {:ok,
           %__MODULE__{
             id: id,
             bot_id: row_bot_id,
             tenant_id: row_tenant_id,
             config: config,
             version: version,
             active: active,
             inserted_at: inserted_at,
             updated_at: updated_at
           }}

        {:ok, %Postgrex.Result{rows: []}} ->
          {:error, "No rows returned from upsert"}

        {:error, reason} ->
          {:error, reason}
      end

    case upsert_result do
      {:ok, soul} ->
        Observability.soul_upsert_complete(
          start_mono,
          bot_id_str,
          tenant_id_label(tenant_id),
          :ok,
          soul.version
        )

      {:error, _} ->
        Observability.soul_upsert_complete(
          start_mono,
          bot_id_str,
          tenant_id_label(tenant_id),
          :error,
          nil
        )
    end

    upsert_result
  end

  @doc """
  Publish soul to NATS for the given bot.

  Publishes to `bot.army.soul.<bot_id>` with the current soul config.
  """
  @spec publish(atom() | String.t(), opts :: [tenant_id: String.t(), repo: module()]) ::
          :ok | {:error, String.t()}
  def publish(bot_id, opts \\ []) do
    bot_id_str = Atom.to_string(bot_id) |> String.replace_prefix("bot_army_", "")
    tenant_id = Keyword.get(opts, :tenant_id, BotArmyLibraryRuntime.Tenant.default_tenant_id())

    case get(bot_id, opts) do
      nil ->
        Observability.soul_publish(
          bot_id_str,
          tenant_id_label(tenant_id),
          :error,
          "no_soul_row"
        )

        {:error, "No soul found for #{bot_id}"}

      soul ->
        payload = %{
          bot_id: soul.bot_id,
          tenant_id: soul.tenant_id,
          config: soul.config,
          version: soul.version,
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        subject = "bot.army.soul.#{soul.bot_id}"

        case Publisher.publish(subject, payload) do
          {:ok, _} ->
            Observability.soul_publish(
              bot_id_str,
              tenant_id_label(tenant_id),
              :ok,
              nil
            )

            :ok

          {:error, reason} ->
            msg = error_message(reason)

            Observability.soul_publish(
              bot_id_str,
              tenant_id_label(tenant_id),
              :error,
              msg
            )

            {:error, msg}
        end
    end
  end

  defp tenant_id_label(tenant_id) when is_binary(tenant_id), do: tenant_id
  defp tenant_id_label(other), do: inspect(other)

  defp error_message(%_{} = e), do: Exception.message(e)
  defp error_message(other), do: inspect(other)
end
