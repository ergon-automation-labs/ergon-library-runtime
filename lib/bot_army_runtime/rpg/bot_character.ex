defmodule BotArmyRuntime.RPG.BotCharacter do
  alias BotArmyRuntime.Tenant
  alias BotArmyRuntime.NATS.Publisher

  @moduledoc """
  Shared helper for bot character provisioning via NATS.

  Thin facade over `rpg.character.ensure` and `rpg.character.get_by_bot`
  so bots can provision and query RPG characters without depending on
  `bot_army_rpg` directly.
  """

  require Logger

  @ensure_timeout_ms 5_000
  @get_timeout_ms 500

  @doc """
  Ensure a bot has an RPG character. Sends NATS request to `rpg.character.ensure`.

  Returns `{:ok, character}` or `{:error, reason}`.
  """
  @spec ensure(atom() | String.t(), String.t() | nil) :: {:ok, map()} | {:error, atom()}
  def ensure(bot_id, tenant_id \\ nil) do
    tenant_id = tenant_id || Tenant.default_tenant_id()
    bot_id_str = normalize_bot_id(bot_id)

    payload = %{
      "bot_id" => bot_id_str,
      "tenant_id" => tenant_id
    }

    case Publisher.request(
           "rpg.character.ensure",
           payload,
           timeout_ms: @ensure_timeout_ms
         ) do
      {:ok, body} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, %{"ok" => true, "data" => character}} -> {:ok, character}
          {:ok, %{"ok" => false, "error" => error}} -> {:error, error}
          _ -> {:error, :invalid_response}
        end

      {:ok, %{} = decoded} ->
        case decoded do
          %{"ok" => true, "data" => character} -> {:ok, character}
          %{"ok" => false, "error" => error} -> {:error, error}
          _ -> {:error, :invalid_response}
        end

      {:error, reason} ->
        Logger.debug("[RPG.BotCharacter] ensure failed for #{bot_id_str}: #{inspect(reason)}")
        {:error, :rpg_unavailable}
    end
  end

  @doc """
  Get a bot's RPG character by bot_id. Sends NATS request to `rpg.character.get_by_bot`.

  Returns `{:ok, character}` or `{:error, reason}`.
  """
  @spec get_by_bot(atom() | String.t(), String.t() | nil) :: {:ok, map()} | {:error, atom()}
  def get_by_bot(bot_id, tenant_id \\ nil) do
    tenant_id = tenant_id || Tenant.default_tenant_id()
    bot_id_str = normalize_bot_id(bot_id)

    payload = %{
      "bot_id" => bot_id_str,
      "tenant_id" => tenant_id
    }

    case Publisher.request(
           "rpg.character.get_by_bot",
           payload,
           timeout_ms: @get_timeout_ms
         ) do
      {:ok, body} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, %{"ok" => true, "data" => character}} -> {:ok, character}
          {:ok, %{"ok" => false, "error" => error}} -> {:error, error}
          _ -> {:error, :invalid_response}
        end

      {:ok, %{} = decoded} ->
        case decoded do
          %{"ok" => true, "data" => character} -> {:ok, character}
          %{"ok" => false, "error" => error} -> {:error, error}
          _ -> {:error, :invalid_response}
        end

      {:error, reason} ->
        Logger.debug("[RPG.BotCharacter] get_by_bot failed for #{bot_id_str}: #{inspect(reason)}")
        {:error, :rpg_unavailable}
    end
  end

  @doc """
  Get a bot's character name, returning the RPG sheet name or a fallback.

  Returns `{:ok, name}` or `{:error, reason}`.
  """
  @spec name(atom() | String.t(), String.t() | nil) :: {:ok, String.t()} | {:error, atom()}
  def name(bot_id, tenant_id \\ nil) do
    case get_by_bot(bot_id, tenant_id) do
      {:ok, character} -> {:ok, Map.get(character, "name", fallback_name(bot_id))}
      {:error, _} -> {:ok, fallback_name(bot_id)}
    end
  end

  defp fallback_name(bot_id) do
    bot_id
    |> normalize_bot_id()
    |> String.replace_prefix("bot_army_", "")
    |> String.replace("_", " ")
    |> String.split()
    |> Enum.map_join(" ", &String.capitalize/1)
  end

  defp normalize_bot_id(bot_id) when is_binary(bot_id), do: bot_id
  defp normalize_bot_id(bot_id) when is_atom(bot_id), do: Atom.to_string(bot_id)
  defp normalize_bot_id(bot_id), do: to_string(bot_id)
end
