defmodule BotArmyLibraryRuntime.Ecto.MigrationRunner do
  @moduledoc """
  Shared database migration runner for Bot Army services.

  Provides a dependency-injected interface for running migrations, allowing each bot to
  inject its own Repo module. Handles both development and production release contexts.

  Migrations are discovered and run in this order:
  1. bot_army_library_runtime migrations (shared tables like heartbeats)
  2. Bot-specific migrations (app-specific tables)

  The runner works in both dev and production release contexts by using `:code.lib_dir()`
  to reliably find app directories even when packaged in releases with version numbers.

  ## Two migration tables

  The two sets are versioned independently: runtime migrations are tracked in
  `runtime_schema_migrations` and the bot's own in the usual `schema_migrations`.

  They shared one table until 2026-08-14, which made version numbers collide
  across repos that never see each other. A bot migration numbered the same as a
  runtime migration was recorded as applied without ever running, and the failure
  only surfaced later as a missing column or table — `bot_army_library_learning`
  lost `add_tenant_and_user_id` this way to runtime's `create_souls`.

  On first run against an existing database, runtime versions already recorded in
  `schema_migrations` are copied into `runtime_schema_migrations` so nothing
  re-runs. The original rows are deliberately left in place rather than deleted:
  they are what keeps a bot's colliding migration skipped on databases where it
  has effectively already been accounted for, so removing them would change
  behaviour on every existing database at once.

  Bot migrations that collide with a runtime version are reported at run time so
  the collision is visible instead of silent. The fix is to renumber the bot's
  migration. Note that the collision only stays suppressed on databases that
  already recorded the runtime version — on a freshly created database the bot's
  migration now runs, which is the correct behaviour but will surface migrations
  that have never actually executed anywhere.

  ## Usage in Release Module

  A bot's Release module uses this to run migrations:

      defmodule BotArmyLlm.Release do
        @app :bot_army_llm

        def migrate do
          BotArmyLibraryRuntime.Ecto.MigrationRunner.run(
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

  @runtime_migration_source "runtime_schema_migrations"

  @doc """
  Runs all pending migrations for a given repo.

  ## Options

  - `:repo_module` - The Ecto.Repo module (required)
  - `:app_module` - The application module for loading config (required)
  - `:direction` - Migration direction, `:up` or `:down` (default: `:up`)

  ## Examples

      BotArmyLibraryRuntime.Ecto.MigrationRunner.run(
        repo_module: BotArmyLlm.Repo,
        app_module: :bot_army_llm
      )

      BotArmyLibraryRuntime.Ecto.MigrationRunner.run(
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

    runtime_path = find_migrations_path(:bot_army_library_runtime)
    runtime_versions = if runtime_path, do: migration_versions(runtime_path), else: []

    # Run runtime library migrations first (includes shared tables like heartbeats)
    runtime_result =
      run_migrations(
        repo_module,
        :bot_army_library_runtime,
        "bot_army_library_runtime",
        direction,
        runtime_versions
      )

    case runtime_result do
      :ok ->
        # Then run bot-specific migrations
        run_migrations(
          repo_module,
          app_module,
          app_module_name(app_module),
          direction,
          runtime_versions
        )

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Migration versions defined in `path`, as integers, sorted ascending.
  """
  def migration_versions(path) do
    path
    |> migration_files()
    |> Enum.map(fn {version, _file} -> version end)
    |> Enum.sort()
  end

  @doc """
  Bot migration files in `path` whose version is also a runtime migration version.

  These are recorded as applied by the runtime set and never run. Returns
  `{version, filename}` pairs sorted by version.
  """
  def colliding_migrations(path, runtime_versions) do
    runtime = MapSet.new(runtime_versions)

    path
    |> migration_files()
    |> Enum.filter(fn {version, _file} -> MapSet.member?(runtime, version) end)
    |> Enum.sort()
  end

  # {version, filename} for every migration in `path`, unsorted.
  defp migration_files(path) do
    path
    |> File.ls!()
    |> Enum.filter(&String.ends_with?(&1, ".exs"))
    |> Enum.flat_map(fn file ->
      case Integer.parse(file) do
        {version, "_" <> _} -> [{version, file}]
        _ -> []
      end
    end)
  end

  defp run_migrations(repo_module, app_module, display_name, direction, runtime_versions) do
    runtime? = app_module == :bot_army_library_runtime

    case find_migrations_path(app_module) do
      nil ->
        IO.puts("⚠ [#{display_name}] No migrations found")
        :ok

      path ->
        unless runtime?, do: report_collisions(display_name, path, runtime_versions)
        migrate_path(repo_module, display_name, path, direction, runtime?, runtime_versions)
    end
  end

  defp migrate_path(repo_module, display_name, path, direction, runtime?, runtime_versions) do
    runner = fn repo ->
      if runtime?, do: adopt_legacy_runtime_versions(repo, runtime_versions)
      Ecto.Migrator.run(repo_module, path, direction, all: true)
    end

    result =
      with_migration_source(repo_module, runtime?, fn ->
        Ecto.Migrator.with_repo(repo_module, runner)
      end)

    case result do
      {:ok, migrations_run, _} ->
        IO.puts("✓ [#{display_name}] #{length(migrations_run)} migrations #{direction}")
        :ok

      {:error, reason} ->
        IO.puts("✗ [#{display_name}] Migration failed: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc false
  # `:migration_source` is read off the repo's config, not from the options
  # given to `Ecto.Migrator.run/4`. Passing it there was silently ignored, so
  # runtime migrations kept landing in `schema_migrations` while
  # `runtime_schema_migrations` only ever held the adopted legacy versions.
  # The repo reads its config when it starts, so the override has to be in
  # place before `Ecto.Migrator.with_repo/2` boots it.
  def with_migration_source(_repo_module, false, fun), do: fun.()

  def with_migration_source(repo_module, true, fun) do
    otp_app = repo_module.config()[:otp_app]
    previous = Application.get_env(otp_app, repo_module, [])

    Application.put_env(
      otp_app,
      repo_module,
      Keyword.put(previous, :migration_source, @runtime_migration_source)
    )

    try do
      fun.()
    after
      Application.put_env(otp_app, repo_module, previous)
    end
  end

  defp report_collisions(display_name, path, runtime_versions) do
    case colliding_migrations(path, runtime_versions) do
      [] ->
        :ok

      collisions ->
        IO.puts(
          "⚠ [#{display_name}] #{length(collisions)} migration(s) share a version with " <>
            "bot_army_library_runtime and will NOT run — renumber them:"
        )

        Enum.each(collisions, fn {version, file} ->
          IO.puts("    #{version}  #{file}")
        end)
    end
  end

  # Copies runtime versions already recorded in schema_migrations into
  # runtime_schema_migrations, so separating the two tables does not make an
  # existing database re-run migrations whose tables are already there.
  defp adopt_legacy_runtime_versions(_repo, []), do: :ok

  defp adopt_legacy_runtime_versions(repo, runtime_versions) do
    repo.query!("""
    CREATE TABLE IF NOT EXISTS "#{@runtime_migration_source}" (
      "version" bigint NOT NULL PRIMARY KEY,
      "inserted_at" timestamp(0) NULL
    )
    """)

    %{rows: [[legacy_table?]]} =
      repo.query!("SELECT to_regclass('schema_migrations') IS NOT NULL")

    if legacy_table? do
      %{num_rows: adopted} =
        repo.query!(
          """
          INSERT INTO "#{@runtime_migration_source}" ("version", "inserted_at")
          SELECT "version", "inserted_at" FROM "schema_migrations" WHERE "version" = ANY($1)
          ON CONFLICT ("version") DO NOTHING
          """,
          [runtime_versions]
        )

      if adopted > 0 do
        IO.puts(
          "✓ [bot_army_library_runtime] adopted #{adopted} version(s) from schema_migrations " <>
            "into #{@runtime_migration_source}"
        )
      end
    end

    :ok
  rescue
    error ->
      # Adoption is a one-time migration of bookkeeping, not the migration itself.
      # Let Ecto.Migrator report the real problem rather than masking it here.
      IO.puts("⚠ [bot_army_library_runtime] could not adopt legacy versions: #{inspect(error)}")
      :ok
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
