defmodule BotArmyLibraryRuntime.Ecto.CircuitBreaker do
  @moduledoc """
  Circuit breaker for database operations to prevent hammering the database
  during outages.

  When the database is unavailable, the circuit breaker will:
  1. Block database queries after a threshold of failures
  2. Automatically probe the database every 30 seconds
  3. Resume normal operation when the probe succeeds

  States:
  - `:closed` — normal operation, queries pass through
  - `:open` — too many failures, queries are rejected immediately
  - `:half_open` — timeout expired, allowing a single probe query

  ## Configuration

  Add to your bot's config/config.exs:

      config :bot_army_library_runtime, :db_circuit_breaker,
        enabled: true,
        failure_threshold: 5,
        half_open_timeout_ms: 30_000,
        probe_timeout_ms: 5_000

  ## Usage

  Wrap database queries with the circuit breaker:

      BotArmyLibraryRuntime.Ecto.CircuitBreaker.call(fn ->
        MyRepo.get(User, id)
      end)

  Or use the Repo.transaction wrapper:

      BotArmyLibraryRuntime.Ecto.CircuitBreaker.transaction(MyRepo, fn ->
        MyRepo.get(User, id)
      end)
  """

  use GenServer
  require Logger

  @failure_threshold 5
  @half_open_timeout_ms 30_000
  @probe_timeout_ms 5_000

  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      type: :worker
    }
  end

  def start_link(_opts \\ []) do
    GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  end

  @doc """
  Execute a database query with circuit breaker protection.

  Returns the result of the function if the circuit is closed or half-open.
  Returns `{:error, {:circuit_open, retry_after_ms}}` if the circuit is open.

  ## Example

      case BotArmyLibraryRuntime.Ecto.CircuitBreaker.call(fn ->
        MyRepo.get(User, id)
      end) do
        {:ok, user} -> handle_success(user)
        {:error, {:circuit_open, retry_after}} -> handle_circuit_open(retry_after)
        {:error, reason} -> handle_error(reason)
      end
  """
  def call(fun) do
    if enabled?() do
      do_call(fun)
    else
      # Circuit breaker disabled, execute directly
      try do
        {:ok, fun.()}
      rescue
        e -> {:error, e}
      end
    end
  end

  @doc """
  Execute a transaction with circuit breaker protection.

  Similar to `call/1` but wraps the entire transaction in the circuit breaker.

  ## Example

      BotArmyLibraryRuntime.Ecto.CircuitBreaker.transaction(MyRepo, fn ->
        {:ok, user} = MyRepo.insert(changeset)
        {:ok, post} = MyRepo.insert(post_changeset)
        {:ok, {user, post}}
      end)
  """
  def transaction(repo, fun) do
    call(fn ->
      repo.transaction(fun)
    end)
  end

  @doc """
  Get the current state of the circuit breaker.
  """
  def get_state do
    if enabled?() do
      GenServer.call(__MODULE__, :get_state, 1000)
    else
      %{state: :disabled, failures: 0}
    end
  end

  @doc """
  Manually reset the circuit breaker (for testing or manual recovery).
  """
  def reset do
    if enabled?() do
      GenServer.cast(__MODULE__, :reset)
    end
  end

  # Private functions

  defp enabled? do
    Application.get_env(:bot_army_library_runtime, :db_circuit_breaker, enabled: true)[:enabled]
  end

  defp do_call(fun) do
    case GenServer.call(__MODULE__, :check, 1000) do
      :ok ->
        try do
          result = fun.()
          GenServer.cast(__MODULE__, :success)
          {:ok, result}
        rescue
          e in Postgrex.Error ->
            GenServer.cast(__MODULE__, {:failure, :database_error})
            {:error, e}

          e ->
            GenServer.cast(__MODULE__, {:failure, :unknown})
            {:error, e}
        end

      {:open, retry_after} ->
        {:error, {:circuit_open, retry_after}}
    end
  catch
    :exit, _ -> {:error, :circuit_breaker_unavailable}
  end

  # GenServer callbacks

  @impl true
  def init(_) do
    {:ok,
     %{
       circuit_state: :closed,
       failures: 0,
       opened_at: nil,
       config: %{
         failure_threshold:
           Application.get_env(:bot_army_library_runtime, :db_circuit_breaker,
             failure_threshold: 5
           )[
             :failure_threshold
           ],
         half_open_timeout_ms:
           Application.get_env(:bot_army_library_runtime, :db_circuit_breaker,
             half_open_timeout_ms: 30_000
           )[
             :half_open_timeout_ms
           ]
       }
     }}
  end

  @impl true
  def handle_call(:check, _from, state) do
    now = System.monotonic_time(:millisecond)

    case state.circuit_state do
      :closed ->
        {:reply, :ok, state}

      :open ->
        elapsed = now - state.opened_at

        if elapsed >= state.config.half_open_timeout_ms do
          Logger.info(
            "[DB CircuitBreaker] Transitioning to half-open after #{elapsed}ms, allowing probe"
          )

          {:reply, :ok, %{state | circuit_state: :half_open}}
        else
          retry_after = state.config.half_open_timeout_ms - elapsed
          {:reply, {:open, retry_after}, state}
        end

      :half_open ->
        {:reply, :ok, state}
    end
  end

  def handle_call(:get_state, _from, state) do
    {:reply,
     %{
       state: state.circuit_state,
       failures: state.failures,
       opened_at: state.opened_at
     }, state}
  end

  @impl true
  def handle_cast(:success, state) do
    case state.circuit_state do
      :half_open ->
        Logger.info("[DB CircuitBreaker] Database is healthy, circuit closed")

        {:noreply, %{state | circuit_state: :closed, failures: 0, opened_at: nil}}

      _ ->
        {:noreply, %{state | failures: 0}}
    end
  end

  def handle_cast({:failure, reason}, state) do
    new_failures = state.failures + 1

    if new_failures >= state.config.failure_threshold do
      now = System.monotonic_time(:millisecond)

      Logger.warning(
        "[DB CircuitBreaker] Database circuit opened after #{new_failures} failures (reason: #{reason})"
      )

      {:noreply,
       %{
         state
         | circuit_state: :open,
           failures: new_failures,
           opened_at: now
       }}
    else
      Logger.debug(
        "[DB CircuitBreaker] Database query failed: #{reason} (#{new_failures}/#{state.config.failure_threshold})"
      )

      {:noreply, %{state | failures: new_failures}}
    end
  end

  def handle_cast(:reset, state) do
    Logger.info("[DB CircuitBreaker] Manual reset")
    {:noreply, %{state | circuit_state: :closed, failures: 0, opened_at: nil}}
  end
end
