defmodule BotArmyRuntime.Config do
  @moduledoc """
  Shared configuration helpers for all Bot Army bots.

  Provides standard logger setup with correlation_id support.

  ## Usage

  In your bot's config.exs:

      import BotArmyRuntime.Config

      # Use standard logger with correlation_id
      logger_config()

  Or in specific environment configs (config/dev.exs, etc.):

      config :logger, level: :debug
  """

  @doc """
  Configure standard logger with correlation_id metadata support.

  This should be called in config.exs as:

      import BotArmyRuntime.Config
      logger_config()

  ## Options

    - `:include_fields` — Additional metadata fields to include (default: [:correlation_id])
    - `:level` — Log level (default: :info)
  """
  defmacro logger_config(opts \\ []) do
    include_fields = Keyword.get(opts, :include_fields, [:correlation_id])
    level = Keyword.get(opts, :level, :info)

    quote do
      config :logger,
        level: unquote(level),
        backends: [:console],
        default_formatter: {BotArmyRuntime.LoggerFormatter, unquote(include_fields)}

      config :logger, :console,
        format: {BotArmyRuntime.LoggerFormatter, unquote(include_fields)},
        metadata: unquote([:correlation_id | include_fields])
    end
  end

  @doc """
  Minimal logger config (just correlation_id, no other fields).

  Useful for bots that don't need extensive metadata.
  """
  defmacro minimal_logger_config do
    quote do
      config :logger,
        level: :info,
        backends: [:console],
        default_formatter: {BotArmyRuntime.LoggerFormatter, []}

      config :logger, :console,
        format: {BotArmyRuntime.LoggerFormatter, []},
        metadata: [:correlation_id]
    end
  end
end
