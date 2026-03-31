defmodule BotArmyRuntime.Logging do
  @moduledoc """
  Helper for any bot to record structured activity entries to the GTD daily log.

  This module provides a simple interface for bots to publish log entries without
  knowing about GTD internals. Entries are published to `gtd.log.create` where
  the GTD bot processes them.

  ## Usage

  ```elixir
  BotArmyRuntime.Logging.record("Task completed successfully", source: "advocacy_bot")
  BotArmyRuntime.Logging.record("New bill found", source: "advocacy_bot", category: "work", tags: ["bill", "federal"])
  ```

  ## Options

  - `source` (required) - Bot or component name (e.g., "advocacy_bot", "liveview")
  - `category` - One of: work, personal, health, learning, care, admin, social (default: "personal")
  - `task_id` - Optional link to a GTD task ID
  - `tags` - List of string tags for categorization
  """

  @subject "gtd.log.create"

  @doc """
  Record a log entry.

  The `body` is required and should be a brief description of what occurred.

  Returns `:ok` or `{:error, reason}`.

  ## Options

  - `source` - Bot or component name (required)
  - `category` - work | personal | health | learning | care | admin | social
  - `task_id` - Link to a task ID
  - `tags` - List of string tags
  """
  def record(body, opts \\ []) when is_binary(body) and is_list(opts) do
    source = Keyword.fetch!(opts, :source)
    category = Keyword.get(opts, :category, "personal")
    task_id = Keyword.get(opts, :task_id)
    tags = Keyword.get(opts, :tags, [])

    payload = build_envelope(body, source, category, task_id, tags)
    BotArmyRuntime.NATS.Publisher.publish(@subject, payload)
  end

  # Private functions

  defp build_envelope(body, source, category, task_id, tags) do
    %{
      "event" => "gtd.log.create",
      "event_id" => generate_id(),
      "timestamp" => DateTime.utc_now() |> DateTime.to_iso8601(),
      "source" => source,
      "source_node" => node() |> Atom.to_string(),
      "triggered_by" => source,
      "schema_version" => "1.0",
      "payload" => %{
        "body" => body,
        "category" => category,
        "task_id" => task_id,
        "tags" => tags,
        "source" => source,
        "occurred_at" => DateTime.utc_now() |> DateTime.to_iso8601()
      }
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(16)
    |> Base.encode16(case: :lower)
  end
end
