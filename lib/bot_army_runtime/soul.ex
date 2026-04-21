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

  # Update soul config
  {:ok, _} = BotArmy.Soul.update(:gtd_bot, %{tone: "more sarcastic"})
  ```
  """

  use Ecto.Schema
  import Ecto.Changeset

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
  @spec get(atom() | String.t(), opts :: [tenant_id: String.t(), repo: module()]) ::
          %__MODULE__{} | nil
  def get(bot_id, opts \\ []) when is_atom(bot_id) or is_binary(bot_id) do
    bot_id_str = Atom.to_string(bot_id) |> String.replace_prefix("bot_army_", "")

    tenant_id = Keyword.get(opts, :tenant_id, BotArmyRuntime.Tenant.default_tenant_id())
    repo = Keyword.get(opts, :repo, BotArmyRuntime.Ecto.Repo)

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
        nil

      {:ok,
       %Postgrex.Result{
         rows: [[id, bot_id, tenant_id, config, version, active, inserted_at, updated_at]]
       }} ->
        %__MODULE__{
          id: id,
          bot_id: bot_id,
          tenant_id: tenant_id,
          config: config,
          version: version,
          active: active,
          inserted_at: inserted_at,
          updated_at: updated_at
        }

      _ ->
        nil
    end
  end

  @doc """
  Create or update a soul configuration.

  Uses INSERT ... ON CONFLICT to handle upserts.
  """
  @spec upsert(atom() | String.t(), map(), opts :: [tenant_id: String.t(), repo: module()]) ::
          {:ok, %__MODULE__{}} | {:error, Ecto.Changeset.t()}
  def upsert(bot_id, config, opts \\ []) do
    bot_id_str = Atom.to_string(bot_id) |> String.replace_prefix("bot_army_", "")

    tenant_id = Keyword.get(opts, :tenant_id, BotArmyRuntime.Tenant.default_tenant_id())
    repo = Keyword.get(opts, :repo, BotArmyRuntime.Ecto.Repo)

    # Get current soul to determine version
    current = get(bot_id, tenant_id: tenant_id, repo: repo)

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

    case repo.query(query, [
           bot_id_str,
           tenant_id,
           Jason.encode!(config),
           version
         ]) do
      {:ok,
       %Postgrex.Result{
         rows: [[id, bot_id, tenant_id, config, version, active, inserted_at, updated_at]]
       }} ->
        {:ok,
         %__MODULE__{
           id: id,
           bot_id: bot_id,
           tenant_id: tenant_id,
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
  end

  @doc """
  Publish soul to NATS for the given bot.

  Publishes to `bot.army.soul.<bot_id>` with the current soul config.
  """
  @spec publish(atom() | String.t(), opts :: [tenant_id: String.t(), repo: module()]) ::
          :ok | {:error, String.t()}
  def publish(bot_id, opts \\ []) do
    case get(bot_id, opts) do
      nil ->
        {:error, "No soul found for #{bot_id}"}

      soul ->
        payload = %{
          bot_id: soul.bot_id,
          tenant_id: soul.tenant_id,
          config: soul.config,
          version: soul.version,
          timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
        }

        BotArmyRuntime.NATS.Publisher.publish("bot.army.soul.#{soul.bot_id}", payload)
        :ok
    end
  end
end
