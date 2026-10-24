defmodule BotArmyLibraryRuntime.ConfigLoaderTest do
  use ExUnit.Case, async: false

  alias BotArmyLibraryRuntime.ConfigLoader

  @moduletag :core

  setup do
    previous = Application.get_env(:bot_army_library_runtime, :config_data)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:bot_army_library_runtime, :config_data)
        value -> Application.put_env(:bot_army_library_runtime, :config_data, value)
      end
    end)

    :ok
  end

  # The rendered file's name is the OTP release's, and the name in the environment is
  # not always the same one. Measured 2026-10-24 on air: context_broker's VM answered
  # `RELEASE_NAME=context_broker` while the only file on disk was
  # `context_broker_bot.config.exs`, so the load found nothing and answered `%{}` — the
  # bot had been taught to load the file and was still reading nothing.
  test "a name finds its release-named file, and the release name finds itself" do
    assert "/etc/bot_army/context_broker_bot.config.exs" in ConfigLoader.config_candidates(
             "context_broker"
           )

    assert "/etc/bot_army/context_broker_bot.config.exs" in ConfigLoader.config_candidates(
             "context_broker_bot"
           )

    assert "/etc/bot_army/sre_bot.config.exs" in ConfigLoader.config_candidates("sre_bot")

    # No path is offered twice: the order is the search order and a duplicate would be a
    # second stat for nothing.
    for name <- ["context_broker", "context_broker_bot", "sre_bot", "bot_army"] do
      candidates = ConfigLoader.config_candidates(name)
      assert candidates == Enum.uniq(candidates)
    end
  end

  # The loader is a file reader once someone names a file: this is the seam a test can
  # use, and the parse is what every bot's runtime.exs depends on.
  test "a named file is read, and its values answer through get/2" do
    path =
      Path.join(System.tmp_dir!(), "config_loader_test_#{System.unique_integer([:positive])}.exs")

    File.write!(path, ~s(%{"CONTEXT_BROKER_TEST_KNOB" => "from-the-file"}\n))
    on_exit(fn -> File.rm(path) end)

    assert %{"CONTEXT_BROKER_TEST_KNOB" => "from-the-file"} = ConfigLoader.load_config(path)

    Application.put_env(:bot_army_library_runtime, :config_data, ConfigLoader.load_config(path))
    assert ConfigLoader.get("CONTEXT_BROKER_TEST_KNOB") == "from-the-file"

    # A name the file does not hold falls through to the environment and then the default,
    # exactly as before — the load does not make `get/2` stricter.
    assert ConfigLoader.get("CONTEXT_BROKER_ABSENT_KNOB", "the-default") == "the-default"
  end

  test "a file that is not there is an empty map, not a crash" do
    assert ConfigLoader.load_config("/etc/bot_army/definitely-not-here.config.exs") == %{}
  end
end
