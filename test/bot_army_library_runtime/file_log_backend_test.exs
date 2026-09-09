defmodule BotArmyLibraryRuntime.FileLogBackendTest do
  use ExUnit.Case, async: false

  require Logger

  alias BotArmyLibraryRuntime.FileLogBackend

  @tmp System.tmp_dir!()

  setup do
    dir = Path.join(@tmp, "file_log_backend_test_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    System.put_env("BOT_LOG_DIR", dir)
    System.put_env("RELEASE_NAME", "test_bot")

    on_exit(fn ->
      System.delete_env("BOT_LOG_DIR")
      System.delete_env("RELEASE_NAME")
      File.rm_rf!(dir)
    end)

    {:ok, dir: dir}
  end

  test "install adds a backend that mirrors log lines into <name>.log", %{dir: dir} do
    assert :installed = FileLogBackend.install()

    Logger.warning("filelog_backend_test_marker")

    # give the gen_event a beat
    :timer.sleep(20)

    content = File.read!(Path.join(dir, "test_bot.log"))
    assert content =~ "filelog_backend_test_marker"

    Logger.remove_backend({FileLogBackend, path: Path.join(dir, "test_bot.log")})
  end

  test "error level is mirrored to <name>.err", %{dir: dir} do
    assert :installed = FileLogBackend.install()

    Logger.error("filelog_backend_err_marker")
    :timer.sleep(20)

    assert File.read!(Path.join(dir, "test_bot.err")) =~ "filelog_backend_err_marker"

    Logger.remove_backend({FileLogBackend, path: Path.join(dir, "test_bot.log")})
  end

  test "skips when the dir is missing" do
    System.put_env("BOT_LOG_DIR", "/nonexistent_dir_for_test")
    assert :skipped = FileLogBackend.install()
  end

  test "skips without RELEASE_NAME" do
    System.delete_env("RELEASE_NAME")
    assert :skipped = FileLogBackend.install()
  end
end