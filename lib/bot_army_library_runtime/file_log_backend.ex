defmodule BotArmyLibraryRuntime.FileLogBackend do
  @moduledoc """
  Minimal Logger backend that mirrors console logs into per-bot files
  (`/var/log/bot_army/<name>.log`), the paths the sre LogWatcher greps via
  `bridge.logs.search`.

  Install is zero-touch and release-gated: `FileLogBackend.install/0` is
  called from `BotArmyLibraryRuntime.Application.start/2`. It adds the
  backend only when

    * `RELEASE_NAME` is set (release/container context — launchd-managed
      host bots redirect stdout themselves and must not double-log), and
    * the target directory exists and is writable (mount present) —
      otherwise the fleet simply has no files, and LogSearch answers
      honestly with zero matches.

  Errors are mirrored to `<name>.err` as well — the LogWatcher watches
  both files per bot.
  """

  @behaviour :gen_event

  require Logger

  @format "$time $level [$node] $message\n"

  @impl :gen_event
  def init({__MODULE__, opts}) when is_list(opts) do
    path = Keyword.fetch!(opts, :path)
    err_path = Keyword.get(opts, :err_path)
    formatter = Logger.Formatter.compile(@format)
    {:ok, %{path: path, err_path: err_path, formatter: formatter}}
  end

  @impl :gen_event
  def handle_event({level, _gl, {Logger, msg, ts, meta}}, state) do
    line = Logger.Formatter.format(state.formatter, level, msg, ts, meta)
    File.write(state.path, line, [:append])
    if level == :error and is_binary(state.err_path) do
      File.write(state.err_path, line, [:append])
    end

    {:ok, state}
  end

  @impl :gen_event
  def handle_event(:flush, state), do: {:ok, state}

  @impl :gen_event
  def handle_info(_, state), do: {:ok, state}

  @impl :gen_event
  def handle_call(_request, state), do: {:ok, :ok, state}

  @impl :gen_event
  def terminate(_reason, _state), do: :ok

  @doc """
  Install the backend for this release when the log dir is usable.

  Returns :ok whether or not the install happened — the fleet may run
  without a writable log dir, which is fine (files absent, LogSearch
  answers with empty matches).
  """
  @spec install() :: :installed | :skipped
  def install do
    dir = System.get_env("BOT_LOG_DIR", "/var/log/bot_army")
    name = log_name()

    if is_binary(name) and File.dir?(dir) do
      path = Path.join(dir, name <> ".log")
      err_path = Path.join(dir, name <> ".err")

      case File.touch(path) do
        :ok ->
          # The {Module, opts} tuple here IS the init payload — pass the
          # keyword opts directly (init/1 fetches :path).
          Logger.add_backend({__MODULE__, path: path, err_path: err_path})
          :installed

        _ ->
          :skipped
      end
    else
      :skipped
    end
  end

  # RELEASE_NAME is set inside releases; absent under launchd/mix dev —
  # skipping there avoids double-logging for host-managed bots.
  defp log_name do
    case System.get_env("RELEASE_NAME") do
      nil -> nil
      "" -> nil
      name -> name
    end
  end
end