defmodule BotArmyRuntime.Ecto.MigrationRunner do
  @moduledoc """
  Shared database migration runner for Bot Army services.

  Provides a dependency-injected interface for running migrations, allowing each bot to
  inject its own Repo module. Handles both development and production release contexts.

  Migrations are discovered and run in this order:
  1. bot_army_library_runtime migrations (shared tables like heartbeats)
  2. Bot-specific migrations (app-specific tables)

  The runner works in both dev and production release contexts by using `:code.lib_dir()`
  to reliably find app directories even when packaged in releases with version numbers.

  ## Usage in Release Module

  A bot's Release module uses this to run migrations:

      defmodule BotArmyLlm.Release do
        @app :bot_army_llm

        def migrate do
          BotArmyRuntime.Ecto.MigrationRunner.run(
            repo_module: BotArmyLlm.Repo,
            app_module: @app
          )
        end
      end

  ## Deployment

  Salt calls this during bot deployment before the bot starts:

      cmd.run:
        - name: /opt/ergon/releases/bot_army_llm/bin/bot_army_llm eval 'BotArmyLlm.Release.migrate()'

  This ensures all shared and bot-specific migrations are applied before the bot starts.
  """

  @doc """
  Runs all pending migrations for a given repo.

  ## Options

  - `:repo_module` - The Ecto.Repo module (required)
  - `:app_module` - The application module for loading config (required)
  - `:direction` - Migration direction, `:up` or `:down` (default: `:up`)

  ## Examples

      BotArmyRuntime.Ecto.MigrationRunner.run(
        repo_module: BotArmyLlm.Repo,
        app_module: :bot_army_llm
      )

      BotArmyRuntime.Ecto.MigrationRunner.run(
        repo_module: BotArmyGtd.Repo,
        app_module: :bot_army_gtd,
        direction: :down
      )
  """
  def run(opts) when is_list(opts) do
    repo_module = Keyword.fetch!(opts, :repo_module)
    app_module = Keyword.fetch!(opts, :app_module)
    direction = Keyword.get(opts, :direction, :up)

    load_app(app_module)
    Application.load(:bot_army_library_runtime)

    # Run runtime library migrations first (includes shared tables like heartbeats)
    runtime_result =
      run_migrations(
        repo_module,
        :bot_army_library_runtime,
        "bot_army_library_runtime",
        direction
      )

    case runtime_result do
      :ok ->
        # Then run bot-specific migrations
        run_migrations(
          repo_module,
          app_module,
          app_module_name(app_module),
          direction
        )

      {:error, _} = err ->
        err
    end
  end

  defp run_migrations(repo_module, app_module, display_name, direction) do
    migrations_path = find_migrations_path(app_module)

    case migrations_path do
      nil ->
        IO.puts("⚠ [#{display_name}] No migrations found")
        :ok

      path ->
        case Ecto.Migrator.with_repo(repo_module, fn _repo ->
               Ecto.Migrator.run(repo_module, path, direction, all: true)
             end) do
          {:ok, migrations_run, _} ->
            IO.puts("✓ [#{display_name}] #{length(migrations_run)} migrations #{direction}")
            :ok

          {:error, reason} ->
            IO.puts("✗ [#{display_name}] Migration failed: #{inspect(reason)}")
            {:error, reason}
        end
    end
  end

  defp find_migrations_path(app_module) do
    # Strategy 1: Try Application.app_dir (works in dev and dev releases)
    case Application.app_dir(app_module, "priv/repo/migrations") do
      path when is_binary(path) and path != "" ->
        if File.dir?(path) do
          return_if_exists(path)
        else
          nil
        end

      _ ->
        # Strategy 2: For prod releases, try finding in lib directory
        # Releases package dependencies as app-version directories
        case find_release_app_path(app_module) do
          nil ->
            IO.puts("⚠ [#{app_module}] Could not locate migrations path in release")
            nil

          release_path ->
            migrations_path = Path.join(release_path, "priv/repo/migrations")
            return_if_exists(migrations_path)
        end
    end
  end

  defp find_release_app_path(app_module) do
    # In releases, apps are in: /path/to/release/lib/app_name-version/
    # :code.lib_dir() returns the actual app directory regardless of version
    case :code.lib_dir(app_module) do
      {:error, _} ->
        nil

      lib_dir when is_list(lib_dir) ->
        lib_dir |> List.to_string() |> return_if_exists()

      lib_dir when is_binary(lib_dir) ->
        return_if_exists(lib_dir)
    end
  end

  defp return_if_exists(path) when is_binary(path) do
    if File.dir?(path) do
      path
    else
      nil
    end
  end

  defp return_if_exists(_), do: nil

  defp app_module_name(app) when is_atom(app) do
    app |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp load_app(app_module) when is_atom(app_module) do
    Application.load(app_module)
  end
end
