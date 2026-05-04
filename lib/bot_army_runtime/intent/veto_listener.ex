defmodule BotArmyRuntime.Intent.VetoListener do
  @moduledoc """
  Subscribes to intent subjects and evaluates veto rules from other bots.

  Each bot configures a VetoListener with a set of veto rules. When an intent
  is published on `bot_army.<bot>.intent.<action>`, the listener receives the
  envelope, evaluates its rules, and publishes a veto response if any rule
  matches.

  ## Veto Rules

  A veto rule is a keyword list of built-in matchers:

      [
        bot: "gtd",           # Only match intents from a specific bot
        action: "nudge",      # Only match a specific action
        reason: "...",        # Static reason string or fn(envelope) -> string
        custom: fn env -> ... # Arbitrary predicate on the envelope
      ]

  When multiple keys are provided, all must match (AND logic). When `custom`
  is provided, it receives the decoded envelope map and returns `true` to veto.

  ## Audit Log

  Every veto is recorded in an in-memory ring buffer (last 100 entries) and
  published as an event on `events.bot_army.intent.vetoed` so Synapse and
  other surfaces can display the deliberation. A request/reply subject
  `bot_army.<bot_name>.intent.veto_log` returns the full history.

  ## Usage

  In your bot's application.ex:

      veto_rules = [
        [bot: "gtd", action: "nudge", custom: &BotArmyFitness.VetoRules.veto_stale_nudge/1],
        [bot: "gtd", action: "remind"]
      ]

      children = [
        ...,
        {BotArmyRuntime.Intent.VetoListener, rules: veto_rules}
      ]

  ## Configuration

      config :bot_army_runtime, :veto_listener,
        subscribe_timeout: 5_000,
        queue_group: "veto_listener",
        log_size: 100
  """

  use GenServer

  require Logger

  alias BotArmyRuntime.Intent.Schema
  alias BotArmyRuntime.NATS.Publisher

  @default_queue_group "veto_listener"
  @default_log_size 100

  @doc """
  Start the VetoListener with a list of veto rules.

  Options:
    - `:rules` — list of veto rules (required)
    - `:bot_name` — name of the bot running this listener (for logging and veto attribution)
    - `:name` — GenServer name (default: `__MODULE__`)
    - `:log_size` — max veto log entries to retain (default: 100)
  """
  def start_link(opts) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Update the veto rules at runtime.
  """
  @spec update_rules(GenServer.server(), [keyword()]) :: :ok
  def update_rules(server \\ __MODULE__, rules) do
    GenServer.call(server, {:update_rules, rules})
  end

  @doc """
  Get the current veto rules.
  """
  @spec get_rules(GenServer.server()) :: [keyword()]
  def get_rules(server \\ __MODULE__) do
    GenServer.call(server, :get_rules)
  end

  @doc """
  Get the veto audit log (most recent first).
  """
  @spec get_veto_log(GenServer.server()) :: [map()]
  def get_veto_log(server \\ __MODULE__) do
    GenServer.call(server, :get_veto_log)
  end

  # ───────────────────────────────────────────────────────────────────────────
  # GenServer Callbacks
  # ───────────────────────────────────────────────────────────────────────────

  @impl true
  def init(opts) do
    rules = Keyword.get(opts, :rules, [])
    bot_name = Keyword.get(opts, :bot_name, "unknown")
    log_size = Keyword.get(opts, :log_size, log_size())

    state = %{
      rules: rules,
      bot_name: bot_name,
      subscription_ref: nil,
      veto_log: [],
      log_size: log_size
    }

    send(self(), :subscribe)
    {:ok, state}
  end

  @impl true
  def handle_call({:update_rules, rules}, _from, state) do
    {:reply, :ok, %{state | rules: rules}}
  end

  @impl true
  def handle_call(:get_rules, _from, state) do
    {:reply, state.rules, state}
  end

  @impl true
  def handle_call(:get_veto_log, _from, state) do
    {:reply, Enum.reverse(state.veto_log), state}
  end

  @impl true
  def handle_info(:subscribe, state) do
    case subscribe_to_intents() do
      {:ok, ref} ->
        {:noreply, %{state | subscription_ref: ref}}

      {:error, reason} ->
        Logger.warning("[VetoListener] Failed to subscribe to intents: #{inspect(reason)}")
        Process.send_after(self(), :subscribe, 5_000)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:msg, %{subject: subject, body: body}}, state) do
    if Schema.intent?(subject) do
      handle_intent(subject, body, state)
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ───────────────────────────────────────────────────────────────────────────
  # Private
  # ───────────────────────────────────────────────────────────────────────────

  defp subscribe_to_intents do
    wildcard = Schema.all_intents()
    queue_group = queue_group()

    case get_connection() do
      {:ok, conn} ->
        {:ok, _sid} = Gnat.sub(conn, self(), wildcard, queue_group: queue_group)

        Logger.info("[VetoListener] Subscribed to #{wildcard}",
          queue_group: queue_group
        )

        {:ok, make_ref()}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp handle_intent(subject, body, state) do
    case Jason.decode(body) do
      {:ok, envelope} ->
        evaluate_and_respond(subject, envelope, state)

      {:error, reason} ->
        Logger.debug("[VetoListener] Failed to decode intent envelope: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  defp evaluate_and_respond(subject, envelope, state) do
    case Schema.parse_subject(subject) do
      {:ok, {target_bot, action}} ->
        matching_rules =
          Enum.filter(state.rules, &rule_matches?(&1, envelope, target_bot, action))

        if Enum.any?(matching_rules) do
          rule = hd(matching_rules)
          reason = build_veto_reason(rule, envelope)
          correlation_id = Map.get(envelope, "correlation_id", "")
          matched_rule_desc = describe_rule(rule)

          log_entry = %{
            vetoed_at: DateTime.utc_now() |> DateTime.to_iso8601(),
            vetoing_bot: state.bot_name,
            target_bot: target_bot,
            action: action,
            reason: reason,
            rule: matched_rule_desc,
            correlation_id: correlation_id,
            intent_id: Map.get(envelope, "intent_id", "")
          }

          case Publisher.publish_veto(target_bot, action, state.bot_name, reason, correlation_id) do
            {:ok, _} ->
              Logger.info("[VetoListener] Vetoed #{target_bot}.#{action}: #{reason}",
                bot_name: state.bot_name,
                target_bot: target_bot,
                action: action
              )

              publish_veto_event(log_entry)
              new_log = [log_entry | Enum.take(state.veto_log, state.log_size - 1)]
              {:noreply, %{state | veto_log: new_log}}

            {:error, err_reason} ->
              Logger.warning("[VetoListener] Veto publish failed: #{inspect(err_reason)}")
              {:noreply, state}
          end
        else
          {:noreply, state}
        end

      {:error, :invalid_format} ->
        Logger.debug("[VetoListener] Skipping unparseable subject: #{subject}")
        {:noreply, state}
    end
  end

  defp publish_veto_event(log_entry) do
    Publisher.publish("events.bot_army.intent.vetoed", log_entry)
  end

  defp describe_rule(rule) do
    bot = Keyword.get(rule, :bot, "*")
    action = Keyword.get(rule, :action, "*")
    custom = Keyword.get(rule, :custom, nil)
    "#{bot}.#{action}#{if custom, do: " +custom", else: ""}"
  end

  @doc false
  def rule_matches?(rule, envelope, target_bot, action) do
    bot_match =
      case Keyword.get(rule, :bot) do
        nil -> true
        bot -> bot == target_bot
      end

    action_match =
      case Keyword.get(rule, :action) do
        nil -> true
        act -> act == action
      end

    custom_match =
      case Keyword.get(rule, :custom) do
        nil -> true
        fun when is_function(fun, 1) -> fun.(envelope)
      end

    bot_match and action_match and custom_match
  end

  @doc false
  def build_veto_reason(rule, envelope) do
    bot = Keyword.get(rule, :bot, "unknown")
    action = Keyword.get(rule, :action, "unknown")
    reason = Keyword.get(rule, :reason, "#{bot}.#{action} vetoed by policy")

    if is_function(reason, 1) do
      reason.(envelope)
    else
      reason
    end
  end

  defp queue_group do
    config = Application.get_env(:bot_army_runtime, :veto_listener, [])
    Keyword.get(config, :queue_group, @default_queue_group)
  end

  defp log_size do
    config = Application.get_env(:bot_army_runtime, :veto_listener, [])
    Keyword.get(config, :log_size, @default_log_size)
  end

  defp get_connection do
    timeout_ms = Application.get_env(:bot_army_runtime, :nats_connection_timeout, 1_000)

    BotArmyRuntime.NATS.Connection
    |> GenServer.call(:get_connection, timeout_ms)
  rescue
    _e -> {:error, :no_connection_manager}
  end
end
