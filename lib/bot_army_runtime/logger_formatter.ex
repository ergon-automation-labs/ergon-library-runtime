defmodule BotArmyRuntime.LoggerFormatter do
  @moduledoc """
  Structured Logger formatter that includes correlation_id in all log output.

  Elixir 1.15+ handler-based formatter for Logger.
  For Elixir 1.13-1.14 backward compatibility, the :console backend config is deprecated.

  ## Configuration (Elixir 1.15+, recommended)

      config :logger,
        level: :info,
        default_handler: [:console]

      config :logger, :default_handler,
        formatter: {BotArmyRuntime.LoggerFormatter, []},
        level: :info

      config :logger, :console,
        metadata: [:correlation_id]

  ## Legacy Configuration (Elixir 1.13-1.14)

  Not supported in Elixir 1.17+ due to Logger backend deprecation.

  ## Output Format

  Standard format with optional correlation_id:
    [HH:MM:SS.SSS] [LEVEL] [correlation_id=xyz] message
  """

  @doc """
  Init function for Logger handlers (Elixir 1.15+).
  Returns the state that will be passed to handle/1.
  """
  def init(opts) do
    opts
  end

  @doc """
  Handle function for Logger handlers (Elixir 1.15+).
  Receives a log event map and outputs formatted text.
  """
  def handle(%{level: level, msg: msg, timestamp: timestamp, meta: metadata}, state) do
    formatted = format_event(level, msg, timestamp, metadata)
    IO.write(:user, formatted)
    state
  end

  # Fallback for format/5 (legacy, may not be called in 1.17+)
  def format(level, msg, timestamp, metadata, _opts) do
    format_event(level, msg, timestamp, metadata)
  end

  # Format a single log event
  defp format_event(level, msg, timestamp, metadata) do
    timestamp_str = format_timestamp(timestamp)
    level_str = String.upcase(to_string(level))

    # Always include correlation_id if present
    correlation_id_str =
      case Keyword.get(metadata, :correlation_id) do
        nil -> ""
        cid -> "[correlation_id=#{cid}] "
      end

    # Format the actual message
    msg_str = format_message(msg, metadata)

    "#{timestamp_str} [#{level_str}] #{correlation_id_str}#{msg_str}\n"
  end

  # Private helpers

  defp format_timestamp({_date, time}) do
    {hour, minute, second} = time

    # Format: HH:MM:SS.SSS
    :io_lib.format(
      ~c"~2..0B:~2..0B:~2..0B.~3..0B",
      [hour, minute, second, 0]
    )
    |> to_string()
  end

  defp format_message(msg, _metadata) when is_binary(msg) do
    msg
  end

  defp format_message(msg, _metadata) when is_list(msg) do
    msg
    |> IO.chardata_to_string()
  end

  defp format_message(msg, _metadata) do
    inspect(msg)
  end
end
