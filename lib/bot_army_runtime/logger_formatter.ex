defmodule BotArmyRuntime.LoggerFormatter do
  @moduledoc """
  Structured Logger formatter that includes correlation_id in all log output.

  This formatter ensures that correlation_id (trace_id) flows through standard Logger output,
  making it easy to search logs across bots for a single request flow.

  ## Configuration

  In your config.exs, use the helper from BotArmyRuntime.Config:

      import BotArmyRuntime.Config
      logger_config()

  Or manually:

      config :logger,
        level: :info,
        backends: [:console],
        default_formatter: {BotArmyRuntime.LoggerFormatter, []}

      config :logger, :console,
        format: {BotArmyRuntime.LoggerFormatter, []},
        metadata: [:correlation_id]

  ## Output Format

  Standard format with optional correlation_id:
    [HH:MM:SS.SSS] [LEVEL] [correlation_id=xyz] message

  If no correlation_id is set, it's omitted:
    [HH:MM:SS.SSS] [LEVEL] message

  Additional metadata fields can be included by passing a list of field names
  to the formatter configuration.
  """

  @doc """
  Format a log entry with optional correlation_id and other metadata.

  Called by the Logger infrastructure for each log event. The `metadata_fields`
  parameter specifies which additional metadata fields to include in the output.

  ## Arguments

    - `level` - Log level atom (:info, :error, etc.)
    - `msg` - Message (can be binary, charlist, or iodata)
    - `timestamp` - {date, time} tuple
    - `metadata` - Keyword list of log metadata
    - `metadata_fields` - List of additional metadata field names to include

  Returns iodata suitable for output.
  """
  def format(level, msg, timestamp, metadata, metadata_fields \\ []) do
    timestamp_str = format_timestamp(timestamp)
    level_str = String.upcase(to_string(level))

    # Always include correlation_id if present
    correlation_id_str =
      case Keyword.get(metadata, :correlation_id) do
        nil -> ""
        cid -> "[correlation_id=#{cid}] "
      end

    # Include additional metadata fields
    extra_fields_str = format_extra_fields(metadata_fields, metadata)

    # Format the actual message
    msg_str = format_message(msg, metadata)

    "#{timestamp_str} [#{level_str}] #{correlation_id_str}#{extra_fields_str}#{msg_str}\n"
  end

  defp format_extra_fields([], _metadata), do: ""

  defp format_extra_fields(fields, metadata) when is_list(fields) do
    result =
      for field <- fields, Keyword.has_key?(metadata, field) do
        "[#{field}=#{inspect(Keyword.get(metadata, field))}]"
      end
      |> Enum.join(" ")

    case result do
      "" -> ""
      str -> str <> " "
    end
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
