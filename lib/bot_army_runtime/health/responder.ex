defmodule BotArmyRuntime.Health.Responder do
  @moduledoc """
  Shared health check responder for Bot Army services.

  Subscribes to `bot.<bot_name>.health` on NATS (request/reply pattern).
  Reports NATS connectivity, database connectivity, key process liveness, and version.

  Also provides subject registry: `bot.<bot_name>.subjects` returns metadata about
  what subjects this bot handles (request/reply and subscriptions).

  Re-registers with ConnectionRegistry on reconnect so subscriptions are always active.
  """

  use GenServer

  require Logger

  @reconnect_delay_ms 5_000

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Register subjects that this bot handles.

  subjects should be a list of maps:
  ```
  [
    %{subject: "gtd.task.list", type: :request_reply, description: "List tasks"},
    %{subject: "events.gtd.task.>", type: :subscribe, description: "Task events"}
  ]
  ```
  """
  def register_subjects(subjects) when is_list(subjects) do
    GenServer.cast(__MODULE__, {:register_subjects, subjects})
  end

  @impl true
  def init(opts) do
    bot_name = Keyword.fetch!(opts, :bot_name)
    health_subject = Keyword.get(opts, :health_subject, "bot.#{bot_name}.health")
    subjects_subject = Keyword.get(opts, :subjects_subject, "bot.#{bot_name}.subjects")

    state = %{
      bot_name: bot_name,
      repo: Keyword.get(opts, :repo),
      process_names: Keyword.get(opts, :process_names, []),
      version: Keyword.get(opts, :version, "unknown"),
      health_subject: health_subject,
      subjects_subject: subjects_subject,
      subjects: [],
      connection: nil,
      health_subscription: nil,
      subjects_subscription: nil
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state) do
    case BotArmyRuntime.NATS.Connection.start_link([]) do
      {:error, {:already_started, _}} ->
        connect_existing(state)

      {:ok, _pid} ->
        connect_existing(state)

      {:error, reason} ->
        Logger.warning("[Health] NATS connection unavailable: #{inspect(reason)}")
        Process.send_after(self(), :reconnect, @reconnect_delay_ms)
        {:noreply, state}
    end
  end

  defp connect_existing(state) do
    case Process.whereis(BotArmyRuntime.NATS.Connection) do
      nil ->
        Logger.warning("[Health] NATS connection process not started yet")
        Process.send_after(self(), :reconnect, @reconnect_delay_ms)
        {:noreply, state}

      _ ->
        case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 1000) do
          {:ok, conn} ->
            health_subject = state.health_subject
            subjects_subject = state.subjects_subject

            with {:ok, health_sub} <- Gnat.sub(conn, self(), health_subject),
                 {:ok, subjects_sub} <- Gnat.sub(conn, self(), subjects_subject) do
              BotArmyRuntime.NATS.Connection.subscribe_to_status()
              Logger.info("[Health] Subscribed to #{health_subject} and #{subjects_subject}")

              {:noreply,
               %{
                 state
                 | connection: conn,
                   health_subscription: health_sub,
                   subjects_subscription: subjects_sub
               }}
            else
              {:error, reason} ->
                Logger.warning("[Health] Failed to subscribe: #{inspect(reason)}")
                Process.send_after(self(), :reconnect, @reconnect_delay_ms)
                {:noreply, state}
            end

          {:error, reason} ->
            Logger.warning("[Health] NATS not connected: #{inspect(reason)}")
            Process.send_after(self(), :reconnect, @reconnect_delay_ms)
            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info({:msg, %{topic: topic, reply_to: reply_to}}, state) when not is_nil(reply_to) do
    payload =
      cond do
        topic == state.health_subject ->
          build_health_response(state)

        topic == state.subjects_subject ->
          build_subjects_response(state)

        true ->
          Jason.encode!(%{"ok" => false, "error" => "unknown_subject"})
      end

    Gnat.pub(state.connection, reply_to, payload)
    {:noreply, state}
  end

  @impl true
  def handle_info({:msg, _msg}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info({:nats, :disconnected}, state) do
    Logger.warning("[Health] NATS disconnected, scheduling reconnect")
    {:noreply, %{state | connection: nil, health_subscription: nil, subjects_subscription: nil}}
  end

  @impl true
  def handle_info({:nats, :connected}, state) do
    Logger.info("[Health] NATS reconnected, re-subscribing")
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info(:reconnect, state) do
    Logger.info("[Health] Attempting NATS reconnect")
    {:noreply, state, {:continue, :connect}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  @impl true
  def handle_cast({:register_subjects, subjects}, state) do
    {:noreply, %{state | subjects: subjects}}
  end

  defp compute_overall_status(state) do
    nats_ok = check_nats() == :ok
    db_ok = check_db(state.repo) == :ok or is_nil(state.repo)
    procs_ok = check_processes(state.process_names) == :ok

    cond do
      nats_ok and db_ok and procs_ok -> :healthy
      nats_ok and (db_ok or procs_ok) -> :degraded
      true -> :unhealthy
    end
  end

  defp check_nats do
    try do
      case Process.whereis(BotArmyRuntime.NATS.Connection) do
        nil ->
          :error

        _ ->
          case GenServer.call(BotArmyRuntime.NATS.Connection, :get_connection, 1000) do
            {:ok, _} -> :ok
            {:error, _} -> :error
          end
      end
    rescue
      _ -> :error
    end
  end

  defp check_db(nil), do: :skip

  defp check_db(repo) do
    try do
      case repo.query("SELECT 1") do
        {:ok, _} -> :ok
        {:error, _} -> :error
      end
    rescue
      _ -> :error
    end
  end

  defp check_processes([]), do: :ok

  defp check_processes(process_names) do
    all_alive =
      Enum.all?(process_names, fn name ->
        if is_pid(name) do
          Process.alive?(name)
        else
          GenServer.whereis(name) != nil
        end
      end)

    if all_alive, do: :ok, else: :error
  end

  defp build_health_response(state) do
    health = %{
      status: compute_overall_status(state),
      bot: state.bot_name,
      version: state.version,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),
      checks: %{
        nats: check_nats(),
        database: check_db(state.repo),
        processes: check_processes(state.process_names)
      }
    }

    Jason.encode!(health)
  end

  defp build_subjects_response(state) do
    response = %{
      "ok" => true,
      "data" => state.subjects,
      "schema_version" => "1.0",
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    Jason.encode!(response)
  end
end
