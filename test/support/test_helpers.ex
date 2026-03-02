defmodule BotArmyRuntime.TestHelpers do
  @moduledoc """
  Test helpers for Bot Army Runtime.

  Provides utilities for:
  - Starting test NATS server
  - Managing test database transactions
  - Publishing test messages
  - Assertion helpers
  """

  require Logger

  @doc """
  Starts a NATS server on the test port (4223) for integration tests.

  Returns `{:ok, pid}` or `{:error, reason}` if server fails to start.

  Note: This requires `nats-server` to be installed and in PATH.

  ## Examples

      {:ok, pid} = BotArmyRuntime.TestHelpers.start_test_nats()
      on_exit(fn -> Process.kill(pid, :sigterm) end)
  """
  def start_test_nats do
    port = 4223

    case System.cmd("which", ["nats-server"]) do
      {_path, 0} ->
        start_nats_server(port)

      {_, _} ->
        {:error, "nats-server not found in PATH"}
    end
  end

  @doc """
  A test helper to run a test with NATS server available.

  The server is automatically started and stopped around the test.

  ## Examples

      test "publishes message" do
        with_test_nats(fn ->
          {:ok, "subject"} = Publisher.publish("subject", %{"data" => "test"})
          assert "subject" == "subject"
        end)
      end
  """
  def with_test_nats(fun) when is_function(fun, 0) do
    case start_test_nats() do
      {:ok, pid} ->
        try do
          # Wait briefly for server to be ready
          Process.sleep(100)
          fun.()
        after
          stop_test_nats(pid)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Publishes a test message to a given subject.

  Used in integration tests to verify message flow.

  ## Examples

      {:ok, "test.subject"} = publish_test_message("test.subject", %{"key" => "value"})
  """
  def publish_test_message(subject, payload) when is_binary(subject) and is_map(payload) do
    BotArmyRuntime.NATS.Publisher.publish(subject, payload)
  end

  @doc """
  Waits for a message on a given subject with a timeout.

  Used to verify message flow in integration tests.

  ## Examples

      {:ok, message} = wait_for_message("test.subject", timeout: 1000)
  """
  def wait_for_message(subject, opts \\ []) when is_binary(subject) do
    timeout = Keyword.get(opts, :timeout, 5000)

    with {:ok, conn} <- get_test_connection() do
      case Gnat.subscribe(conn, self(), subject) do
        {:ok, _sid} ->
          receive do
            {:msg, _sid, _subject, payload} ->
              case Jason.decode(payload) do
                {:ok, decoded} -> {:ok, decoded}
                {:error, _} -> {:ok, payload}
              end
          after
            timeout -> {:error, :timeout}
          end

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Clears all data from a given table (for test cleanup).

  Use in test cleanup to ensure tests don't interfere with each other.

  ## Examples

      on_exit(fn -> clear_table(MySchema) end)
  """
  def clear_table(schema) do
    BotArmyRuntime.Ecto.Repo.delete_all(schema)
  end

  @doc """
  Creates a test fixture in the database.

  Helper for consistent test data setup.

  ## Examples

      user = create_fixture(User, name: "Test User", email: "test@example.com")
  """
  def create_fixture(schema, attrs) when is_list(attrs) do
    schema
    |> struct(attrs)
    |> BotArmyRuntime.Ecto.Repo.insert!()
  end

  # Private helpers

  defp start_nats_server(port) do
    case System.cmd("nats-server", [
      "-p",
      to_string(port),
      "-D",
      "-l",
      "/tmp/nats_#{port}.log"
    ]) do
      {_output, 0} ->
        Process.sleep(500)
        {:ok, self()}

      {error, code} ->
        {:error, "Failed to start nats-server: exit code #{code}, error: #{error}"}
    end
  end

  defp stop_test_nats(_pid) do
    # Kill any nats-server process on the test port
    System.cmd("pkill", ["-f", "nats-server.*4223"])
    Process.sleep(100)
  end

  defp get_test_connection do
    BotArmyRuntime.NATS.Connection
    |> GenServer.call(:get_connection, 1000)
  rescue
    _e -> {:error, :no_connection_manager}
  end
end
