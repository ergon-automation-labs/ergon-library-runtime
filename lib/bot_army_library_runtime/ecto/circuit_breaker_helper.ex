defmodule BotArmyLibraryRuntime.Ecto.CircuitBreakerHelper do
  @moduledoc """
  Helper functions for using the database circuit breaker in bots.

  This module provides convenience functions for wrapping Repo calls with
  circuit breaker protection.

  ## Usage

  Instead of:
      user = MyRepo.get(User, id)

  Use:
      case CircuitBreakerHelper.get(MyRepo, User, id) do
        {:ok, user} -> handle_user(user)
        {:error, {:circuit_open, retry_after}} ->
          Logger.warning("DB unavailable, retry in \#{retry_after}ms")
        {:error, reason} ->
          Logger.error("Query failed: \#{inspect(reason)}")
      end

  ## Common patterns

  - `CircuitBreakerHelper.get(repo, schema, id)` — find by primary key
  - `CircuitBreakerHelper.all(repo, query)` — fetch all records
  - `CircuitBreakerHelper.insert(repo, changeset)` — insert with protection
  - `CircuitBreakerHelper.update(repo, changeset)` — update with protection
  """

  alias BotArmyLibraryRuntime.Ecto.CircuitBreaker

  @doc "Get a single record by primary key"
  def get(repo, schema, id) do
    CircuitBreaker.call(fn ->
      repo.get(schema, id)
    end)
  end

  @doc "Get a single record by primary key, raise on error"
  def get!(repo, schema, id) do
    case get(repo, schema, id) do
      {:ok, record} -> record
      {:error, reason} -> raise "Failed to get #{schema}: #{inspect(reason)}"
    end
  end

  @doc "Fetch all records matching a query"
  def all(repo, queryable) do
    CircuitBreaker.call(fn ->
      repo.all(queryable)
    end)
  end

  @doc "Fetch one record, or nil"
  def one(repo, queryable) do
    CircuitBreaker.call(fn ->
      repo.one(queryable)
    end)
  end

  @doc "Fetch one record, raise on error"
  def one!(repo, queryable) do
    case one(repo, queryable) do
      {:ok, record} -> record
      {:error, reason} -> raise "Failed to fetch record: #{inspect(reason)}"
    end
  end

  @doc "Insert a changeset"
  def insert(repo, changeset) do
    CircuitBreaker.call(fn ->
      repo.insert(changeset)
    end)
  end

  @doc "Insert and raise on error"
  def insert!(repo, changeset) do
    case insert(repo, changeset) do
      {:ok, record} -> record
      {:error, reason} -> raise "Insert failed: #{inspect(reason)}"
    end
  end

  @doc "Update a changeset"
  def update(repo, changeset) do
    CircuitBreaker.call(fn ->
      repo.update(changeset)
    end)
  end

  @doc "Update and raise on error"
  def update!(repo, changeset) do
    case update(repo, changeset) do
      {:ok, record} -> record
      {:error, reason} -> raise "Update failed: #{inspect(reason)}"
    end
  end

  @doc "Delete a record"
  def delete(repo, struct) do
    CircuitBreaker.call(fn ->
      repo.delete(struct)
    end)
  end

  @doc "Delete and raise on error"
  def delete!(repo, struct) do
    case delete(repo, struct) do
      {:ok, record} -> record
      {:error, reason} -> raise "Delete failed: #{inspect(reason)}"
    end
  end

  @doc "Execute a custom query function with circuit breaker protection"
  def query(fun) do
    CircuitBreaker.call(fun)
  end

  @doc "Execute a transaction with circuit breaker protection"
  def transaction(repo, fun) do
    CircuitBreaker.transaction(repo, fun)
  end
end
