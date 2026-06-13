defmodule BotArmyRuntime.NATS.CircuitBreaker do
  @moduledoc """
  Generic circuit breaker for NATS inter-bot request-reply calls.

  Tracks call failures per bot/subject and opens the circuit after a threshold
  is reached, preventing cascading failures when downstream bots are unavailable
  or degraded.

  States:
  - `:closed` — normal operation, requests pass through
  - `:open` — too many failures, requests are rejected immediately
  - `:half_open` — timeout expired, allowing a single probe request

  Rate-limited responses (timeout, 429) can trigger longer cooldowns.

  ## Configuration

  - `:failure_threshold` — consecutive failures before opening (default: 5)
  - `:half_open_timeout_ms` — time before trying a probe (default: 30_000)
  - `:rate_limit_cooldown_ms` — cooldown after rate-limit (default: 60_000)

  ## Usage

      # Check before making a request
      case BotArmyRuntime.NATS.CircuitBreaker.allow?("my_bot:target.subject") do
        :ok ->
          # Proceed with request
          {:ok, reply} = BotArmyRuntime.NATS.Publisher.request(...)
          BotArmyRuntime.NATS.CircuitBreaker.record_success("my_bot:target.subject")
          {:ok, reply}

        {:open, retry_after} ->
          # Circuit is open, fail fast
          {:error, {:circuit_open, retry_after}}
      end

      # On timeout or error, record it
      {:error, :timeout} ->
        BotArmyRuntime.NATS.CircuitBreaker.record_failure("my_bot:target.subject", :timeout)
        {:error, :timeout}
  """

  use GenServer
  require Logger

  @failure_threshold 5
  @half_open_timeout_ms 30_000
  @rate_limit_cooldown_ms 60_000

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      type: :supervisor
    }
  end

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc """
  Check if a request is allowed for a given circuit breaker key.

  Returns:
  - `:ok` — circuit is closed or half-open (request allowed)
  - `{:open, retry_after_ms}` — circuit is open, request should fail fast
  """
  def allow?(key) do
    case lookup_registry(key) do
      # No breaker registered yet, allow the request
      [] ->
        :ok

      [{pid, _}] ->
        try do
          GenServer.call(pid, :check, 1000)
        catch
          :exit, _ -> :ok
        end
    end
  end

  @doc """
  Record a successful request. Closes the circuit if it was half-open.
  """
  def record_success(key) do
    case lookup_registry(key) do
      [] ->
        :ok

      [{pid, _}] ->
        try do
          GenServer.cast(pid, :success)
        catch
          :exit, _ -> :ok
        end
    end
  end

  @doc """
  Record a failed request. Opens the circuit if threshold is reached.

  Pass `:rate_limited` or `:timeout` as reason for longer cooldown.
  """
  def record_failure(key, reason \\ :error) do
    case ensure_breaker(key) do
      {:ok, pid} ->
        try do
          GenServer.cast(pid, {:failure, reason})
        catch
          :exit, _ -> :ok
        end

      :unavailable ->
        :ok
    end
  end

  @doc """
  Get the current state of a circuit breaker key.
  """
  def get_state(key) do
    case lookup_registry(key) do
      [] ->
        %{state: :unknown, failures: 0}

      [{pid, _}] ->
        try do
          GenServer.call(pid, :get_state, 1000)
        catch
          :exit, _ -> %{state: :unknown, failures: 0}
        end
    end
  end

  defp lookup_registry(key) do
    Registry.lookup(BotArmyRuntime.NATS.CircuitBreakerRegistry, key)
  rescue
    ArgumentError -> []
  end

  defp ensure_breaker(key) do
    case lookup_registry(key) do
      [{pid, _}] ->
        {:ok, pid}

      [] ->
        try do
          {:ok, pid} =
            GenServer.start_link(__MODULE__, key,
              name: {:via, Registry, {BotArmyRuntime.NATS.CircuitBreakerRegistry, key}}
            )

          {:ok, pid}
        rescue
          ArgumentError ->
            :unavailable
        end
    end
  end

  # GenServer callbacks

  @impl true
  def init(nil) do
    # Parent supervisor
    {:ok, nil}
  end

  def init(key) do
    {:ok,
     %{
       key: key,
       circuit_state: :closed,
       failures: 0,
       opened_at: nil,
       cooldown_until: nil
     }}
  end

  @impl true
  def handle_call(:check, _from, nil) do
    {:reply, :ok, nil}
  end

  def handle_call(:check, _from, state) do
    now = System.monotonic_time(:millisecond)

    case state.circuit_state do
      :closed ->
        {:reply, :ok, state}

      :open ->
        elapsed = now - state.opened_at

        if elapsed >= @half_open_timeout_ms do
          {:reply, :ok, %{state | circuit_state: :half_open}}
        else
          retry_after = @half_open_timeout_ms - elapsed
          {:reply, {:open, retry_after}, state}
        end

      :half_open ->
        {:reply, :ok, state}
    end
  end

  @impl true
  def handle_call(:get_state, _from, nil) do
    {:reply, %{state: :unknown, failures: 0}, nil}
  end

  def handle_call(:get_state, _from, state) do
    {:reply, %{state: state.circuit_state, failures: state.failures}, state}
  end

  @impl true
  def handle_cast(:success, nil) do
    {:noreply, nil}
  end

  def handle_cast(:success, state) do
    case state.circuit_state do
      :half_open ->
        Logger.info("[CircuitBreaker] #{state.key}: closed after successful probe")

        {:noreply,
         %{state | circuit_state: :closed, failures: 0, opened_at: nil, cooldown_until: nil}}

      _ ->
        {:noreply, %{state | failures: 0}}
    end
  end

  @impl true
  def handle_cast({:failure, _reason}, nil) do
    {:noreply, nil}
  end

  def handle_cast({:failure, reason}, state) when reason in [:rate_limited, :timeout] do
    now = System.monotonic_time(:millisecond)
    cooldown_until = now + @rate_limit_cooldown_ms

    Logger.warning(
      "[CircuitBreaker] #{state.key}: #{reason}, cooldown #{@rate_limit_cooldown_ms}ms"
    )

    {:noreply,
     %{
       state
       | circuit_state: :open,
         failures: state.failures + 1,
         opened_at: now,
         cooldown_until: cooldown_until
     }}
  end

  def handle_cast({:failure, _reason}, state) do
    new_failures = state.failures + 1

    if new_failures >= @failure_threshold do
      now = System.monotonic_time(:millisecond)

      Logger.warning("[CircuitBreaker] #{state.key}: opened after #{new_failures} failures")

      {:noreply, %{state | circuit_state: :open, failures: new_failures, opened_at: now}}
    else
      {:noreply, %{state | failures: new_failures}}
    end
  end
end
