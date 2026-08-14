defmodule BotArmyLibraryRuntime.Ecto.CircuitBreakerRepo do
  @moduledoc """
  Ecto repo wrapper that routes every query through the database circuit breaker
  and returns tuples instead of raising.

  Queries pass through `BotArmyLibraryRuntime.Ecto.CircuitBreaker`, which:
  - blocks queries once the database has failed `failure_threshold` times in a row
  - probes again after `half_open_timeout_ms` to detect recovery
  - resumes normally when a probe succeeds

  ## Usage

  In a bot's repo module, replace `use Ecto.Repo`:

      defmodule MyBot.Repo do
        use BotArmyLibraryRuntime.Ecto.CircuitBreakerRepo,
          otp_app: :my_bot,
          adapter: Ecto.Adapters.Postgres
      end

  `all/2`, `one/2`, `insert/2`, `update/2`, `delete/2` and `transaction/2` are
  wrapped. Other repo functions — including `get/3` — are untouched and still
  return their usual values or raise on failure.

  ## Result format

  Every wrapped function returns a tuple:

  - `{:ok, result}` — query succeeded
  - `{:error, changeset}` — `insert`/`update`/`delete` validation failure
  - `{:error, {:circuit_open, retry_after_ms}}` — breaker is open, query not attempted
  - `{:error, :database_connection_failed}` — `Postgrex.Error`
  - `{:error, :multiple_results}` — `one/2` matched more than one row
  - `{:error, :database_error}` — any other exception
  - `{:error, :circuit_breaker_unavailable}` — breaker process not reachable

  Callers must match on the tuple; a bare `Repo.all(query)` no longer returns a
  list.
  """

  alias BotArmyLibraryRuntime.Ecto.CircuitBreaker

  @doc """
  Runs `fun` through the circuit breaker and normalises the result.

  Exposed so wrapped repos share one error contract rather than repeating a
  rescue block per function.
  """
  def guard(fun) when is_function(fun, 0) do
    fun |> CircuitBreaker.call() |> normalize()
  end

  # The breaker returns {:ok, whatever fun returned}, so unwrap the inner tuple
  # for callbacks that already answer with {:ok, _} / {:error, _}.
  defp normalize({:ok, {:ok, result}}), do: {:ok, result}
  defp normalize({:ok, {:error, reason}}), do: {:error, reason}
  defp normalize({:ok, result}), do: {:ok, result}

  defp normalize({:error, {:circuit_open, retry_after}}),
    do: {:error, {:circuit_open, retry_after}}

  defp normalize({:error, :circuit_breaker_unavailable}),
    do: {:error, :circuit_breaker_unavailable}

  defp normalize({:error, %Ecto.MultipleResultsError{}}), do: {:error, :multiple_results}
  defp normalize({:error, %Postgrex.Error{}}), do: {:error, :database_connection_failed}

  defp normalize({:error, {:exit, {:shutdown, _}}}),
    do: {:error, :database_connection_pool_shutdown}

  defp normalize({:error, {:exit, reason}}), do: {:error, {:exit, reason}}
  defp normalize({:error, _other}), do: {:error, :database_error}

  defmacro __using__(opts) do
    quote do
      use Ecto.Repo, unquote(opts)

      alias BotArmyLibraryRuntime.Ecto.CircuitBreakerRepo

      @doc """
      Merges runtime DATABASE_URL config over the compiled config.
      """
      def init(_type, opts) do
        {:ok, Keyword.merge(opts, CircuitBreakerRepo.runtime_config())}
      end

      # Deliberately does not wrap get/3: bots already call Repo.get and expect
      # a struct or nil, so wrapping it would change every call site.
      defoverridable all: 2, one: 2, insert: 2, update: 2, delete: 2, transaction: 2

      def all(queryable, opts) do
        CircuitBreakerRepo.guard(fn -> super(queryable, opts) end)
      end

      def one(queryable, opts) do
        CircuitBreakerRepo.guard(fn -> super(queryable, opts) end)
      end

      def insert(changeset, opts) do
        CircuitBreakerRepo.guard(fn -> super(changeset, opts) end)
      end

      def update(changeset, opts) do
        CircuitBreakerRepo.guard(fn -> super(changeset, opts) end)
      end

      def delete(struct, opts) do
        CircuitBreakerRepo.guard(fn -> super(struct, opts) end)
      end

      def transaction(fun, opts) do
        CircuitBreakerRepo.guard(fn -> super(fun, opts) end)
      end
    end
  end

  @doc """
  Config parsed from `DATABASE_URL`, or `[]` when it is unset.
  """
  def runtime_config do
    # parse_url/1 returns a keyword list and raises Ecto.InvalidURLError on bad
    # input — it has no {:ok, _} / :error form.
    case System.get_env("DATABASE_URL") do
      nil -> []
      url -> Ecto.Repo.Supervisor.parse_url(url)
    end
  end
end
