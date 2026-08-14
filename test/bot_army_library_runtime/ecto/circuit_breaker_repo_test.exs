defmodule BotArmyLibraryRuntime.Ecto.CircuitBreakerRepoTest do
  use ExUnit.Case
  @moduletag :ecto

  alias BotArmyLibraryRuntime.Ecto.CircuitBreaker
  alias BotArmyLibraryRuntime.Ecto.CircuitBreakerRepo

  setup do
    Application.put_env(:bot_army_library_runtime, :db_circuit_breaker,
      enabled: true,
      failure_threshold: 3,
      half_open_timeout_ms: 500
    )

    CircuitBreaker.reset()
    Process.sleep(100)

    on_exit(fn ->
      Application.put_env(:bot_army_library_runtime, :db_circuit_breaker,
        enabled: true,
        failure_threshold: 5,
        half_open_timeout_ms: 30_000
      )

      CircuitBreaker.reset()
    end)

    :ok
  end

  describe "guard/1 result normalisation" do
    test "wraps a plain value" do
      assert CircuitBreakerRepo.guard(fn -> [1, 2, 3] end) == {:ok, [1, 2, 3]}
    end

    test "does not double-wrap an {:ok, _} result" do
      # insert/update/delete already answer with {:ok, struct}; without
      # flattening, callers would have to match {:ok, {:ok, struct}}.
      assert CircuitBreakerRepo.guard(fn -> {:ok, :record} end) == {:ok, :record}
    end

    test "passes a changeset error through unchanged" do
      assert CircuitBreakerRepo.guard(fn -> {:error, :changeset} end) == {:error, :changeset}
    end

    test "maps Postgrex errors to :database_connection_failed" do
      assert CircuitBreakerRepo.guard(fn -> raise Postgrex.Error, message: "boom" end) ==
               {:error, :database_connection_failed}
    end

    test "maps multiple results to :multiple_results" do
      result =
        CircuitBreakerRepo.guard(fn ->
          raise Ecto.MultipleResultsError, queryable: "q", count: 2
        end)

      assert result == {:error, :multiple_results}
    end

    test "maps any other exception to :database_error" do
      assert CircuitBreakerRepo.guard(fn -> raise ArgumentError, "nope" end) ==
               {:error, :database_error}
    end

    test "maps a pool shutdown exit to :database_connection_pool_shutdown" do
      assert CircuitBreakerRepo.guard(fn -> exit({:shutdown, :pool_closed}) end) ==
               {:error, :database_connection_pool_shutdown}
    end
  end

  describe "guard/1 circuit behaviour" do
    test "reports {:circuit_open, retry_after} once the breaker opens" do
      for _ <- 1..3 do
        CircuitBreakerRepo.guard(fn -> raise Postgrex.Error, message: "connection refused" end)
      end

      assert {:error, {:circuit_open, retry_after}} =
               CircuitBreakerRepo.guard(fn -> [1] end)

      assert is_integer(retry_after)
    end

    test "an exit counts as a database failure and opens the circuit" do
      for _ <- 1..3 do
        CircuitBreakerRepo.guard(fn -> exit({:shutdown, :pool_closed}) end)
      end

      assert CircuitBreaker.get_state().state == :open
    end
  end

  describe "runtime_config/0" do
    test "returns [] when DATABASE_URL is unset" do
      original = System.get_env("DATABASE_URL")
      System.delete_env("DATABASE_URL")
      on_exit(fn -> original && System.put_env("DATABASE_URL", original) end)

      assert CircuitBreakerRepo.runtime_config() == []
    end

    test "parses DATABASE_URL into repo config" do
      original = System.get_env("DATABASE_URL")
      System.put_env("DATABASE_URL", "postgres://someone:secret@db.example:5433/mydb")

      on_exit(fn ->
        if original,
          do: System.put_env("DATABASE_URL", original),
          else: System.delete_env("DATABASE_URL")
      end)

      config = CircuitBreakerRepo.runtime_config()

      assert config[:database] == "mydb"
      assert config[:hostname] == "db.example"
      assert config[:port] == 5433
    end
  end
end
