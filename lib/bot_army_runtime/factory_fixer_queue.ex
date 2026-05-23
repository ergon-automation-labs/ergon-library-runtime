defmodule BotArmyRuntime.FactoryFixerQueue do
  @moduledoc """
  Queue work for factory_fixer bot via GTD tasks.

  Any bot can call this module to create tasks that factory_fixer will automatically
  pick up, prioritize, and complete. Automatically applies pi-go:next label and
  proper context so factory_fixer discovers the work.

  ## Usage

      BotArmyRuntime.FactoryFixerQueue.create_task(
        title: "Fix failing test in dispatcher",
        description: "Test TestModule.test_case is flaky under load",
        project_id: "...",
        priority: :high
      )

  Returns `{:ok, task_id}` or `{:error, reason}`.
  """

  require Logger

  @timeout_ms 10_000

  @doc """
  Create a task for factory_fixer to work on.

  Options:
  - `:title` (required) - Task title
  - `:description` (optional) - Task description with context
  - `:project_id` (optional) - Assign to a specific project
  - `:priority` (optional) - `:low`, `:normal`, or `:high` (default: `:normal`)
  - `:context` (optional) - GTD context: `:inbox`, `:next`, `:someday`, `:reference`, `:waiting` (default: `:next`)

  All tasks automatically get the `pi-go:next` label for factory_fixer discovery.
  """
  def create_task(opts) do
    title = Keyword.fetch!(opts, :title)
    description = Keyword.get(opts, :description, "")
    project_id = Keyword.get(opts, :project_id)
    priority = Keyword.get(opts, :priority, "normal") |> normalize_priority()
    context = Keyword.get(opts, :context, "next") |> normalize_context()

    payload = %{
      "title" => title,
      "description" => description,
      "priority" => priority,
      "context" => context,
      "labels" => ["pi-go:next"]
    }

    payload = if project_id, do: Map.put(payload, "project_id", project_id), else: payload

    case call_bridge("bridge.task.create", payload) do
      {:ok, response} ->
        task_id = get_in(response, ["data", "task_id"])
        Logger.info("factory_fixer task created", task_id: task_id, title: title)
        {:ok, task_id}

      {:error, reason} ->
        Logger.error("failed to queue factory_fixer task", title: title, error: reason)
        {:error, reason}
    end
  end

  @doc """
  Batch create multiple tasks for factory_fixer.

  Takes a list of task option maps. Returns list of `{:ok, task_id}` or `{:error, reason}` tuples.
  """
  def create_tasks(tasks_list) when is_list(tasks_list) do
    Enum.map(tasks_list, &create_task/1)
  end

  # Private helpers

  defp call_bridge(subject, payload) do
    with {:ok, conn} <- get_nats_connection(),
         encoded <- Jason.encode!(payload),
         {:ok, reply} <- Gnat.request(conn, subject, encoded, receive_timeout: @timeout_ms) do
      case Jason.decode(reply.body) do
        {:ok, decoded} ->
          if decoded["ok"] == true do
            {:ok, decoded}
          else
            {:error, decoded["data"]["error"] || "Bridge returned error"}
          end

        {:error, reason} ->
          {:error, "Failed to parse bridge response: #{inspect(reason)}"}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_nats_connection do
    case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 1000) do
      {:ok, conn} -> {:ok, conn}
      {:error, reason} -> {:error, reason}
      _ -> {:error, "NATS connection not available"}
    end
  rescue
    _ -> {:error, "NATS connection not available"}
  end

  defp normalize_priority(priority) when is_atom(priority) do
    Atom.to_string(priority)
  end

  defp normalize_priority(priority) when is_binary(priority) do
    case priority do
      "low" -> "low"
      "normal" -> "normal"
      "high" -> "high"
      _ -> "normal"
    end
  end

  defp normalize_context(context) when is_atom(context) do
    Atom.to_string(context)
  end

  defp normalize_context(context) when is_binary(context) do
    case context do
      "inbox" -> "inbox"
      "next" -> "next"
      "someday" -> "someday"
      "reference" -> "reference"
      "waiting" -> "waiting"
      _ -> "next"
    end
  end
end
