defmodule BotArmyRuntime.Ecto.MigrationRunner do
  @moduledoc """
  Shared database migration runner for Bot Army services.

  Provides a dependency-injected interface for running migrations, allowing each bot to
  inject its own Repo module. Migrations are triggered via explicit Salt task before bot startup,
  not during application initialization.

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
    migrations_path = Application.app_dir(app_module, "priv/repo/migrations")

    case Ecto.Migrator.with_repo(repo_module, fn _repo ->
           Ecto.Migrator.run(repo_module, migrations_path, direction, all: true)
         end) do
      {:ok, migrations_run, _} ->
        IO.puts("✓ [#{display_name}] #{migrations_run} migrations #{direction}")
        :ok

      {:error, reason} ->
        IO.puts("✗ [#{display_name}] Migration failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp app_module_name(app) when is_atom(app) do
    app |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()
  end

  defp load_app(app_module) when is_atom(app_module) do
    Application.load(app_module)
  end
end
