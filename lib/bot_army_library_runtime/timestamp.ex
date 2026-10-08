defmodule BotArmyLibraryRuntime.Timestamp do
  @moduledoc """
  The one place that decides how a time is written down when it leaves this process.

  Ecto's `:naive_datetime` columns hold UTC — `Ecto.Schema.__timestamps__/1` fills them
  with `NaiveDateTime.utc_now/0` — but they are *naive*: they carry no offset. So
  `NaiveDateTime.to_iso8601/1` on one produces a string like `"2026-10-08T00:46:52"`
  that names no zone at all. That is not merely imprecise. Elixir's
  `DateTime.from_iso8601/1` **refuses** it with `{:error, :missing_offset}`, and Go's
  `time.Parse(time.RFC3339, ...)` rejects it too.

  A reader handed such a string therefore has only bad options: guess a zone, fail
  loudly, or fail quietly. Quiet failure is the dangerous one. A surface that draws
  nothing for an unparseable stamp draws exactly what it draws for a bot that reported
  no time at all — which is how a whole feature (the party window's turn times) shipped
  inert while every test stayed green.

  Use `utc_iso8601/1` for every time that goes on the wire. It says the zone out loud,
  and stating it is not a guess: the naive column is UTC by the store's own contract.
  """

  @doc """
  Write a UTC time as an ISO-8601 string that names its zone.

  Accepts the `NaiveDateTime` an Ecto timestamp column yields (read as UTC, which is what
  the column means) or a `DateTime`, which is shifted to UTC first so the name of this
  function stays true.

      iex> BotArmyLibraryRuntime.Timestamp.utc_iso8601(~N[2026-10-08 00:46:52])
      "2026-10-08T00:46:52Z"

      iex> BotArmyLibraryRuntime.Timestamp.utc_iso8601(~U[2026-10-08 00:46:52Z])
      "2026-10-08T00:46:52Z"

      iex> {:ok, two_am_in_paris, _offset} = DateTime.from_iso8601("2026-10-08T02:46:52+02:00")
      iex> BotArmyLibraryRuntime.Timestamp.utc_iso8601(two_am_in_paris)
      "2026-10-08T00:46:52Z"

  """
  @spec utc_iso8601(NaiveDateTime.t() | DateTime.t()) :: String.t()
  def utc_iso8601(%NaiveDateTime{} = naive) do
    naive |> DateTime.from_naive!("Etc/UTC") |> DateTime.to_iso8601()
  end

  def utc_iso8601(%DateTime{} = datetime) do
    datetime |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()
  end

  @doc """
  `utc_iso8601/1` that passes `nil` through instead of raising.

  A column that is legitimately unset should reach the wire as `nil`, not as a string
  that would have to be parsed back into nothing.

      iex> BotArmyLibraryRuntime.Timestamp.utc_iso8601_or_nil(nil)
      nil

  """
  @spec utc_iso8601_or_nil(NaiveDateTime.t() | DateTime.t() | nil) :: String.t() | nil
  def utc_iso8601_or_nil(nil), do: nil
  def utc_iso8601_or_nil(time), do: utc_iso8601(time)
end
