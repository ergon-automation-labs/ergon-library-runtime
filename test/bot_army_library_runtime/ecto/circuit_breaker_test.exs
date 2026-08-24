defmodule BotArmyLibraryRuntime.Ecto.CircuitBreakerTest do
  use ExUnit.Case
  @moduletag :ecto

  alias BotArmyLibraryRuntime.Ecto.CircuitBreaker

  setup do
    # Override config for testing with shorter timeouts
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
    end)

    :ok
  end

  test "runs the query unprotected when the breaker process is not registered" do
    # Release `eval` tasks (migrations) run without the supervision tree, so the
    # breaker is absent. That must not read as "database unavailable".
    pid = Process.whereis(CircuitBreaker)
    Process.unregister(CircuitBreaker)

    try do
      assert CircuitBreaker.call(fn -> :ran end) == {:ok, :ran}
    after
      Process.register(pid, CircuitBreaker)
    end
  end

  test "circuit starts in closed state" do
    state = CircuitBreaker.get_state()
    assert state.state == :closed
    assert state.failures == 0
  end

  test "allows successful queries when closed" do
    result = CircuitBreaker.call(fn -> {:ok, "success"} end)
    assert result == {:ok, {:ok, "success"}}

    state = CircuitBreaker.get_state()
    assert state.state == :closed
    assert state.failures == 0
  end

  test "opens circuit after failure threshold" do
    # Trigger 3 failures (threshold for tests)
    for _ <- 1..3 do
      CircuitBreaker.call(fn -> raise Postgrex.Error, message: "connection refused" end)
    end

    state = CircuitBreaker.get_state()
    assert state.state == :open
    assert state.failures == 3
  end

  test "rejects queries when circuit is open" do
    # Trigger failures to open circuit
    for _ <- 1..3 do
      CircuitBreaker.call(fn -> raise Postgrex.Error, message: "connection refused" end)
    end

    # Next query should be rejected
    result = CircuitBreaker.call(fn -> {:ok, "success"} end)
    assert {:error, {:circuit_open, _retry_after}} = result

    state = CircuitBreaker.get_state()
    assert state.state == :open
  end

  test "transitions to half-open after timeout" do
    # Trigger failures to open circuit
    for _ <- 1..3 do
      CircuitBreaker.call(fn -> raise Postgrex.Error, message: "connection refused" end)
    end

    # Immediately should be open
    result = CircuitBreaker.call(fn -> {:ok, "success"} end)
    assert {:error, {:circuit_open, _}} = result

    # Wait for half-open timeout (500ms for tests)
    Process.sleep(600)

    # Next call should be allowed as a probe
    result = CircuitBreaker.call(fn -> {:ok, "success"} end)
    assert {:ok, {:ok, "success"}} = result

    # Should have transitioned to half-open and then closed on success
    state = CircuitBreaker.get_state()
    assert state.state == :closed
    assert state.failures == 0
  end

  test "reopens circuit if probe fails" do
    # Open the circuit
    for _ <- 1..3 do
      CircuitBreaker.call(fn -> raise Postgrex.Error, message: "connection refused" end)
    end

    # Wait for half-open (500ms for tests)
    Process.sleep(600)

    # Probe fails
    CircuitBreaker.call(fn -> raise Postgrex.Error, message: "still broken" end)

    # Should be open again
    result = CircuitBreaker.call(fn -> {:ok, "success"} end)
    assert {:error, {:circuit_open, _}} = result
  end

  test "probe times out instead of hanging forever" do
    Application.put_env(:bot_army_library_runtime, :db_circuit_breaker,
      enabled: true,
      failure_threshold: 3,
      half_open_timeout_ms: 500,
      probe_timeout_ms: 100
    )

    CircuitBreaker.reset()
    Process.sleep(100)

    # Open the circuit
    for _ <- 1..3 do
      CircuitBreaker.call(fn -> raise Postgrex.Error, message: "connection refused" end)
    end

    # Wait for half-open
    Process.sleep(600)

    start = System.monotonic_time(:millisecond)
    result = CircuitBreaker.call(fn -> Process.sleep(1000) end)
    elapsed = System.monotonic_time(:millisecond) - start

    assert {:error, {:probe_timeout, 100}} = result
    assert elapsed < 1000

    # The failed probe should have reopened the circuit
    result = CircuitBreaker.call(fn -> {:ok, "success"} end)
    assert {:error, {:circuit_open, _}} = result
  end
end
