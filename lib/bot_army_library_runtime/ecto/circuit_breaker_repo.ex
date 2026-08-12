defmodule BotArmyLibraryRuntime.Ecto.CircuitBreakerRepo do
  @moduledoc """
  Circuit breaker wrapper for Ecto repositories.

  Wraps all database queries to handle connection failures gracefully by
  returning {:ok, result} or {:error, reason} tuples instead of raising errors.

  ## Usage

  In a bot's repo module:

      defmodule MyBot.Repo do
        use BotArmyRuntime.Ecto.CircuitBreakerRepo,
          otp_app: :my_bot,
          adapter: Ecto.Adapters.Postgres
      end

  ## Result Format

  All queries return tuples:
  - {:ok, result} - Query succeeded
  - {:error, reason} - Query failed or circuit is open
  """

  defmacro __using__(opts) do
    quote do
      # Use Ecto.Repo as the base
      use Ecto.Repo, unquote(opts)

      @doc """
      Initialize repo with circuit breaker state.
      """
      def init(_, opts) do
        {:ok, Keyword.merge(opts, parse_runtime_config())}
      end

      # Wrap all to catch errors and return tuples
      defoverridable all: 2

      def all(queryable, opts) do
        try do
          result = super(queryable, opts)
          {:ok, result}
        rescue
          e in [Postgrex.Error] ->
            {:error, :database_connection_failed}

          e ->
            {:error, :database_error}
        catch
          :exit, {:shutdown, _} ->
            {:error, :database_connection_pool_shutdown}

          :exit, reason ->
            {:error, {:exit, reason}}
        end
      end

      # Wrap insert to catch errors and return tuples
      defoverridable insert: 2

      def insert(changeset, opts) do
        try do
          case super(changeset, opts) do
            {:ok, struct} -> {:ok, struct}
            {:error, changeset} -> {:error, changeset}
          end
        rescue
          e in [Postgrex.Error] ->
            {:error, :database_connection_failed}

          e ->
            {:error, :database_error}
        catch
          :exit, {:shutdown, _} ->
            {:error, :database_connection_pool_shutdown}

          :exit, reason ->
            {:error, {:exit, reason}}
        end
      end

      # Wrap update to catch errors and return tuples
      defoverridable update: 2

      def update(changeset, opts) do
        try do
          case super(changeset, opts) do
            {:ok, struct} -> {:ok, struct}
            {:error, changeset} -> {:error, changeset}
          end
        rescue
          e in [Postgrex.Error] ->
            {:error, :database_connection_failed}

          e ->
            {:error, :database_error}
        catch
          :exit, {:shutdown, _} ->
            {:error, :database_connection_pool_shutdown}

          :exit, reason ->
            {:error, {:exit, reason}}
        end
      end

      # Wrap delete to catch errors and return tuples
      defoverridable delete: 2

      def delete(struct, opts) do
        try do
          case super(struct, opts) do
            {:ok, struct} -> {:ok, struct}
            {:error, changeset} -> {:error, changeset}
          end
        rescue
          e in [Postgrex.Error] ->
            {:error, :database_connection_failed}

          e ->
            {:error, :database_error}
        catch
          :exit, {:shutdown, _} ->
            {:error, :database_connection_pool_shutdown}

          :exit, reason ->
            {:error, {:exit, reason}}
        end
      end

      # Wrap one to catch errors and return tuples
      defoverridable one: 2

      def one(queryable, opts) do
        try do
          case super(queryable, opts) do
            nil -> {:ok, nil}
            struct -> {:ok, struct}
          end
        rescue
          e in [Ecto.MultipleResultsError] ->
            {:error, :multiple_results}

          e in [Postgrex.Error] ->
            {:error, :database_connection_failed}

          e ->
            {:error, :database_error}
        catch
          :exit, {:shutdown, _} ->
            {:error, :database_connection_pool_shutdown}

          :exit, reason ->
            {:error, {:exit, reason}}
        end
      end

      # Wrap transaction to catch errors and return tuples
      defoverridable transaction: 2

      def transaction(fun, opts) do
        try do
          case super(fun, opts) do
            {:ok, result} -> {:ok, result}
            {:error, reason} -> {:error, reason}
          end
        rescue
          e in [Postgrex.Error] ->
            {:error, :database_connection_failed}

          e ->
            {:error, :database_error}
        catch
          :exit, {:shutdown, _} ->
            {:error, :database_connection_pool_shutdown}

          :exit, reason ->
            {:error, {:exit, reason}}
        end
      end

      @doc false
      defp parse_runtime_config do
        case System.get_env("DATABASE_URL") do
          nil ->
            []

          url ->
            case Ecto.Repo.Supervisor.parse_url(url) do
              {:ok, config} -> config
              :error -> raise "Invalid DATABASE_URL: #{url}"
            end
        end
      end
    end
  end
end
