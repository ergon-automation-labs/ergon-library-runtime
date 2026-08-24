defmodule BotArmyLibraryRuntime.LeaderElection do
  @moduledoc """
  Leader/standby election for dual-node (air + mini) bot deployments.

  Generalizes the pattern GTD's own `leader_monitor.ex` attempted. That
  module never actually worked: it subscribed to `system.health.gtd`, a
  subject nothing publishes to (the real fleet heartbeat is the generic
  `system.health`, shared by 40+ bots via `SynapseHealth.publish/1` — not
  something to repurpose here), and it had no `handle_info` clause to turn
  a received NATS message into its own `:heartbeat_received` event. The
  same two bugs are copy-pasted in `bot_army_skills`'s monitor.

  This module fixes both, and adds two things nothing in the fleet had:

    - Standby nodes fully unsubscribe from business subjects on transition
      (via `on_role_change`) instead of just gating writes after the fact —
      a standby that's still subscribed still answers requests.
    - A manual force-leader/force-standby override, so a collision between
      two live nodes can be resolved immediately instead of waiting out a
      heartbeat timeout.

  ## Usage

      {BotArmyLibraryRuntime.LeaderElection,
       service: "llm",
       node_name: System.get_env("LEADER_NODE_NAME", "unknown"),
       default_role: BotArmyLibraryRuntime.LeaderElection.role_from_env("LLM_NODE_ROLE"),
       on_role_change: {BotArmyLlm.NATS.Consumer, :leader_role_changed, []}}

  `on_role_change` is an `{module, function, extra_args}` MFA. It's invoked
  as `apply(module, function, extra_args ++ [role])` once at startup and
  again on every role transition, so the bot can subscribe/unsubscribe its
  business NATS subjects. `role` is `:primary` or `:standby`.

  ## Subjects

    - `bot.<service>.leader.heartbeat` — published every 30s by whichever
      node is *designated* primary (via `default_role`), independent of
      forced state, so a returning primary is always detectable.
    - `bot.<service>.leader.force` — publish `{"node": "air" | "mini"}` to
      pin that node as leader and the other as standby regardless of
      heartbeat state; publish `{"node": null}` to clear the override and
      resume normal heartbeat-timeout logic. In-memory only — does not
      survive a process restart.
  """

  use GenServer
  require Logger

  alias BotArmyLibraryRuntime.NATS.Connection
  alias BotArmyLibraryRuntime.NATS.Publisher

  @heartbeat_interval_ms 30_000
  @heartbeat_timeout_ms 90_000
  @check_interval_ms 10_000

  # ───────────────────────────────────────────────────────────────────────────
  # Public API
  # ───────────────────────────────────────────────────────────────────────────

  def start_link(opts) do
    service = Keyword.fetch!(opts, :service)
    GenServer.start_link(__MODULE__, opts, name: name_for(service))
  end

  @doc "Parses a `<SERVICE>_NODE_ROLE` env var (\"primary\"/\"standby\") into `:primary` | `:standby`, defaulting to `:primary`."
  @spec role_from_env(String.t()) :: :primary | :standby
  def role_from_env(env_var) do
    case System.get_env(env_var) do
      "standby" -> :standby
      "primary" -> :primary
      _ -> :primary
    end
  end

  def leader?(service) do
    GenServer.call(name_for(service), :leader?, 5_000)
  catch
    :exit, _ -> false
  end

  def get_status(service) do
    GenServer.call(name_for(service), :get_status, 5_000)
  catch
    :exit, _ -> %{role: :unknown, is_leader: false, forced_node: nil}
  end

  @doc "Publishes a force-override. `node` is a node-name string (e.g. \"air\") or `nil` to clear."
  def force(service, node) when is_binary(node) or is_nil(node) do
    Publisher.publish(force_subject(service), %{"node" => node})
  end

  defp name_for(service), do: :"#{__MODULE__}.#{service}"
  defp heartbeat_subject(service), do: "bot.#{service}.leader.heartbeat"
  defp force_subject(service), do: "bot.#{service}.leader.force"

  # ───────────────────────────────────────────────────────────────────────────
  # GenServer
  # ───────────────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    service = Keyword.fetch!(opts, :service)
    node_name = Keyword.fetch!(opts, :node_name)
    default_role = Keyword.fetch!(opts, :default_role)
    on_role_change = Keyword.fetch!(opts, :on_role_change)
    heartbeat_timeout_ms = Keyword.get(opts, :heartbeat_timeout_ms, @heartbeat_timeout_ms)
    check_interval_ms = Keyword.get(opts, :check_interval_ms, @check_interval_ms)

    state = %{
      service: service,
      node_name: node_name,
      default_role: default_role,
      on_role_change: on_role_change,
      heartbeat_timeout_ms: heartbeat_timeout_ms,
      check_interval_ms: check_interval_ms,
      last_heartbeat_ms: System.monotonic_time(:millisecond),
      forced_node: nil,
      is_leader: nil,
      connection: nil
    }

    Process.send_after(self(), :setup_nats, 0)
    Process.send_after(self(), :check_role, check_interval_ms)

    if default_role == :primary do
      Process.send_after(self(), :publish_heartbeat, 1_000)
    end

    {:ok, apply_role(state)}
  end

  @impl true
  def handle_call(:leader?, _from, state) do
    {:reply, compute_role(state) == :primary, state}
  end

  @impl true
  def handle_call(:get_status, _from, state) do
    {:reply,
     %{
       role: compute_role(state),
       is_leader: state.is_leader,
       forced_node: state.forced_node,
       last_heartbeat_ms: state.last_heartbeat_ms
     }, state}
  end

  @impl true
  def handle_info(:setup_nats, state) do
    case Process.whereis(Connection) do
      nil ->
        Process.send_after(self(), :setup_nats, 1_000)
        {:noreply, state}

      _ ->
        case GenServer.call(Connection, :get_connection, 5_000) do
          {:ok, conn} ->
            {:ok, _} = Gnat.sub(conn, self(), force_subject(state.service))

            if state.default_role == :standby do
              {:ok, _} = Gnat.sub(conn, self(), heartbeat_subject(state.service))
            end

            Logger.info("[LeaderElection:#{state.service}] Subscribed on #{state.node_name}")
            {:noreply, %{state | connection: conn}}

          {:error, reason} ->
            Logger.warning(
              "[LeaderElection:#{state.service}] NATS not ready, retrying in 1s: #{inspect(reason)}"
            )

            Process.send_after(self(), :setup_nats, 1_000)
            {:noreply, state}
        end
    end
  end

  @impl true
  def handle_info({:nats, :disconnected}, state) do
    {:noreply, %{state | connection: nil}}
  end

  @impl true
  def handle_info({:nats, :connected}, state) do
    Process.send_after(self(), :setup_nats, 100)
    {:noreply, state}
  end

  @impl true
  def handle_info({:msg, %{topic: topic} = msg}, state) do
    cond do
      topic == force_subject(state.service) ->
        handle_force_message(msg, state)

      topic == heartbeat_subject(state.service) ->
        {:noreply, apply_role(%{state | last_heartbeat_ms: System.monotonic_time(:millisecond)})}

      true ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:check_role, state) do
    Process.send_after(self(), :check_role, state.check_interval_ms)
    {:noreply, apply_role(state)}
  end

  @impl true
  def handle_info(:publish_heartbeat, state) do
    Process.send_after(self(), :publish_heartbeat, @heartbeat_interval_ms)

    Publisher.publish(heartbeat_subject(state.service), %{
      "node" => state.node_name,
      "service" => state.service,
      "ts" => DateTime.to_iso8601(DateTime.utc_now())
    })

    {:noreply, state}
  end

  defp handle_force_message(msg, state) do
    forced_node =
      case Jason.decode(msg.body) do
        {:ok, %{"node" => node}} -> node
        _ -> state.forced_node
      end

    Logger.warning(
      "[LeaderElection:#{state.service}] Force override received on #{state.node_name}: #{inspect(forced_node)}"
    )

    {:noreply, apply_role(%{state | forced_node: forced_node})}
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Role computation
  # ───────────────────────────────────────────────────────────────────────────

  defp compute_role(state) do
    cond do
      state.forced_node == state.node_name -> :primary
      not is_nil(state.forced_node) -> :standby
      state.default_role == :primary -> :primary
      heartbeat_stale?(state) -> :primary
      true -> :standby
    end
  end

  defp heartbeat_stale?(state) do
    now = System.monotonic_time(:millisecond)
    now - state.last_heartbeat_ms > state.heartbeat_timeout_ms
  end

  defp apply_role(state) do
    new_role = compute_role(state)
    new_is_leader = new_role == :primary

    if new_is_leader != state.is_leader do
      log_transition(state, new_role)
      run_on_role_change(state.on_role_change, new_role)
    end

    %{state | is_leader: new_is_leader}
  end

  defp log_transition(state, new_role) do
    Logger.warning(
      "[LeaderElection:#{state.service}] #{state.node_name} transitioning to #{new_role}"
    )
  end

  defp run_on_role_change({module, function, extra_args}, role) do
    apply(module, function, extra_args ++ [role])
  rescue
    error ->
      Logger.error("[LeaderElection] on_role_change callback failed: #{inspect(error)}")
  end
end
