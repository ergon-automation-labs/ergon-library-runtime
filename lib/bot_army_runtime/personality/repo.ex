defmodule BotArmyRuntime.Personality.Repo do
  @moduledoc false

  @doc """
  Resolves the Ecto repo for soul and heartbeat persistence.

  Order: explicit `repo` option, `:personality_repo` config, first `bot_army_*`
  application with `ecto_repos`, then `BotArmyRuntime.Ecto.Repo`.
  """
  @spec resolve(module() | nil) :: module()
  def resolve(nil) do
    Application.get_env(:bot_army_runtime, :personality_repo) ||
      first_bot_repo() ||
      BotArmyRuntime.Ecto.Repo
  end

  def resolve(repo) when is_atom(repo), do: repo

  @doc false
  @spec available?(module()) :: boolean()
  def available?(repo) do
    repo_started?(repo) and function_exported?(repo, :query, 2)
  end

  defp first_bot_repo do
    :application.which_applications()
    |> Enum.find_value(fn {app, _, _} ->
      app_str = Atom.to_string(app)

      if String.starts_with?(app_str, "bot_army_") and app != :bot_army_runtime do
        case Application.get_env(app, :ecto_repos, []) do
          [repo | _] -> repo
          _ -> nil
        end
      end
    end)
  end

  defp repo_started?(repo) do
    case Process.whereis(repo) do
      nil -> false
      _pid -> true
    end
  end
end
