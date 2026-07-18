defmodule BotArmyLibraryRuntime.ThemeRenderer do
  @moduledoc """
  Deterministic theme renderer for the Resistance Chronicle.

  Converts structured data + theme config into flavored strings.
  Same input + same theme always produces the same output.
  No LLM at render time.

  Only flavors framing, labels, and connective prose.
  IDs, counts, links, and codes pass through untouched.
  """

  alias BotArmyLibraryRuntime.Personality.ThemeConfig

  @flavorable_fields ~w(title description name)

  @doc """
  Render structured data through a theme.

  Returns the original map with added keys:
  - `"flavored"` — themed representation of the title
  - `"prefix"` — template prefix for the data's type
  - `"suffix"` — template suffix for the data's type
  - `"label"` — themed type label (e.g. "bounty" instead of "task")
  - `"original"` — the original title value

  Pass-through fields (id, count, url, code, etc.) are never vocabulary-substituted.
  """
  @spec render(map(), ThemeConfig.t(), map() | nil) :: map()
  def render(structured_data, %ThemeConfig{} = theme, _world_snapshot \\ nil)
      when is_map(structured_data) do
    type = Map.get(structured_data, "type", "unknown")
    template = get_template(theme, type)
    label = label_for(type, theme)
    title = Map.get(structured_data, "title", "")

    flavored_title = substitute(title, theme)

    flavored =
      case {template[:prefix], template[:suffix]} do
        {nil, nil} -> flavored_title
        {prefix, nil} -> "#{prefix} #{flavored_title}"
        {nil, suffix} -> "#{flavored_title} #{suffix}"
        {prefix, suffix} -> "#{prefix} #{flavored_title} #{suffix}"
      end

    flavored_data =
      structured_data
      |> Map.put("flavored", flavored)
      |> Map.put("prefix", template[:prefix])
      |> Map.put("suffix", template[:suffix])
      |> Map.put("label", label)
      |> Map.put("original", title)

    apply_vocabulary_to_flavorable_fields(flavored_data, theme)
  end

  @doc """
  Apply vocabulary substitution to a single string.

  Replaces known plain-English terms with themed equivalents.
  Whole-word matching only — does not substitute substrings.
  Longest keys are matched first to prevent partial overlap issues.
  """
  @spec substitute(String.t(), ThemeConfig.t()) :: String.t()
  def substitute(text, %ThemeConfig{} = theme) when is_binary(text) do
    if map_size(theme.vocabulary) == 0 do
      text
    else
      theme.vocabulary
      |> Enum.sort_by(fn {key, _val} -> String.length(key) end, :desc)
      |> Enum.reduce(text, fn {plain, themed}, acc ->
        pattern = ~r/(?<=\b|^)#{Regex.escape(plain)}(?=\b|$)/u
        String.replace(acc, pattern, themed)
      end)
    end
  end

  def substitute(text, _), do: text

  @doc """
  Get the themed label for a type.

  Returns the vocabulary-mapped term if available, then the template label,
  otherwise the original type string.
  """
  @spec label_for(String.t(), ThemeConfig.t()) :: String.t()
  def label_for(type, %ThemeConfig{} = theme) when is_binary(type) do
    case Map.get(theme.vocabulary, type) do
      nil ->
        case get_template(theme, type) do
          %{label: label} when is_binary(label) -> label
          _ -> type
        end

      themed ->
        themed
    end
  end

  def label_for(type, _), do: type

  defp get_template(%ThemeConfig{templates: templates}, type) when is_map(templates) do
    case Map.get(templates, type) do
      nil -> %{prefix: nil, suffix: nil, label: nil}
      template -> template
    end
  end

  defp get_template(_, _), do: %{prefix: nil, suffix: nil, label: nil}

  defp apply_vocabulary_to_flavorable_fields(data, theme) do
    Enum.reduce(@flavorable_fields, data, fn field, acc ->
      case Map.get(acc, field) do
        value when is_binary(value) ->
          Map.put(acc, field, substitute(value, theme))

        _ ->
          acc
      end
    end)
  end
end
