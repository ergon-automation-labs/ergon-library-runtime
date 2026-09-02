defmodule BotArmyLibraryRuntime.Soul do
  @moduledoc """
  Façade for the Bot Army Soul service (served by the memory service).

  Souls are the personality identity of a bot — character voice, tone,
  priorities, refusal rules. Storage is centralized in the memory
  service's database (`souls` table, one row per bot + tenant); this
  module is the fleet-wide read/write surface. Old code stored souls in
  each bot's own database — the memory service is authoritative now.
  """

  alias BotArmyLibraryRuntime.NATS.Publisher

  @doc """
  Retrieves the soul for a bot (e.g. `:gtd` or `"bot_army_gtd"` — the
  service strips the `bot_army_` prefix like the old runtime did).

  ## Returns
    - `{:ok, soul}` — map with atom keys: `:bot_id`, `:tenant_id`,
      `:config` (the personality map, string-keyed — callers use
      `get_in(soul.config, ["identity", "name"])`), `:version`, `:active`
    - `{:error, :not_found}` — the bot has no soul yet
    - `{:error, reason}` — request failed or timed out
  """
  def get(bot_id) do
    case Publisher.request("soul.get", %{"bot_id" => bot_id}) do
      {:ok, %{"ok" => true, "data" => nil}} ->
        # Absence is a distinct outcome, not a service failure
        {:error, :not_found}

      {:ok, %{"ok" => true, "data" => soul}} when is_map(soul) ->
        {:ok, normalize_soul(soul)}

      {:ok, %{"ok" => false} = envelope} ->
        {:error, error_from(envelope)}

      {:ok, other} ->
        {:error, {:unexpected_reply, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Persists a soul config for a bot. Options: `:tenant_id` (defaults to
  the service's default tenant).

  ## Returns
    - `{:ok, %{"id" => id, "version" => version}}` — version is bumped on
      every upsert
    - `{:error, reason}` — invalid config (missing "identity") or request failure
  """
  def upsert(bot_id, config, opts \\ []) when is_map(config) do
    payload =
      %{"bot_id" => bot_id, "config" => config}
      |> maybe_put_tenant(opts)

    case Publisher.request("soul.upsert", payload) do
      {:ok, %{"ok" => true, "data" => data}} ->
        {:ok, data}

      {:ok, %{"ok" => false} = envelope} ->
        {:error, error_from(envelope)}

      {:ok, other} ->
        {:error, {:unexpected_reply, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp maybe_put_tenant(payload, opts) do
    case Keyword.fetch(opts, :tenant_id) do
      {:ok, tenant_id} -> Map.put(payload, "tenant_id", tenant_id)
      :error -> payload
    end
  end

  defp normalize_soul(soul) do
    %{
      bot_id: soul["bot_id"],
      tenant_id: soul["tenant_id"],
      config: soul["config"] || %{},
      version: soul["version"],
      active: soul["active"]
    }
  end

  defp error_from(%{"error" => msg, "code" => code}) do
    case code do
      "not_found" -> :not_found
      _ -> {:service_error, msg}
    end
  end

  defp error_from(envelope), do: {:service_error, Map.get(envelope, "error", "unknown")}
end
