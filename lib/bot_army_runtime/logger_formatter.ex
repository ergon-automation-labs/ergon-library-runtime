defmodule BotArmyRuntime.LoggerFormatter do
  @moduledoc """
  Structured Logger formatter that includes correlation_id in all log output.

  This formatter ensures that correlation_id (trace_id) flows through standard Logger output,
  making it easy to search logs across bots for a single request flow.

  ## Configuration

  Add to your config.exs:

      config :logger, :default_handler,
        formatter: {BotArmyRuntime.LoggerFormatter, :format}

  Or for all handlers:

      config :logger, :console,
        format: {BotArmyRuntime.LoggerFormatter, :format}

  ## Output Format

  Standard format with optional correlation_id:
    [timestamp] [level] [correlation_id=xyz] Module message

  If no correlation_id is set, it's omitted:
    [timestamp] [level] Module message
  """

  @doc """
  Format a log entry with optional correlation_id.

  This is called by the Logger infrastructure for each log event.
  """
  def format(level, msg, timestamp, metadata) do
    timestamp_str = format_timestamp(timestamp)
    level_str = String.upcase(to_string(level))

    # Extract correlation_id from metadata if present
    correlation_id_str =
      case Keyword.get(metadata, :correlation_id) do
        nil -> ""
        cid -> "[correlation_id=#{cid}] "
      end

    # Extract module/function info if available
    module_str =
      case Keyword.get(metadata, :module) do
        nil ->
          ""

        mod ->
          case Keyword.get(metadata, :function) do
            nil -> "[#{inspect(mod)}] "
            func -> "[#{inspect(mod)}.#{elem(func, 0)}/#{elem(func, 1)}] "
          end
      end

    # Format the actual message
    msg_str = format_message(msg, metadata)

    "#{timestamp_str} [#{level_str}] #{correlation_id_str}#{module_str}#{msg_str}\n"
  end

  # Private helpers

  defp format_timestamp({date, time}) do
    {year, month, day} = date
    {hour, minute, second} = time

    # Try to get microseconds from metadata if available
    microseconds = 0

    # Format: HH:MM:SS.SSS
    :io_lib.format(
      ~c"~2..0B:~2..0B:~2..0B.~3..0B",
      [hour, minute, second, div(microseconds, 1000)]
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
