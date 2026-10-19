defmodule Samen.Web.Notes.Offset do
  @moduledoc """
  The ONE offset module for WS-Notes (ADR-053 §2 D3; `docs/ws-notes/p0-findings.md` §3).

  ## Why this exists

  A browser reports `selectionStart` in **UTF-16 code units**. `String.split_at/2` counts
  **graphemes**. The two agree for ASCII and diverge for emoji (a surrogate pair is TWO units, one
  grapheme), many CJK characters (`String.length/1` counts graphemes, not units) and combining
  marks (`"é"` decomposed is two code points, one grapheme). Splitting with the raw unit count
  therefore cuts in the wrong place — it does not crash, which is what makes it dangerous.

  P0 left exactly one open contract question (findings §3), and recommended a single helper used by
  BOTH the split/merge write path and the dialect tokeniser. This is that helper:

    * `split/2` — split a binary at a UTF-16 code-unit offset **without ever cutting a grapheme**;
      an offset inside a surrogate pair or inside a combining sequence snaps BACK to the start of
      that grapheme (never raises, never drops text).
    * `utf16_length/1` — the inverse count, so a caller can clamp/report an offset.

  The contract is deliberately small: offsets are counted from the start of the block's text, the
  same origin the browser uses, and out-of-range values clamp (negative → 0, past the end → the
  whole string). Everything else is `Samen.Web.Notes.Writes`' business.
  """

  @doc """
  Split `text` at a UTF-16 code-unit `offset`.

  Returns `{left, right}` such that `left <> right == text`. The cut lands on a grapheme boundary
  at or before `offset`; an offset inside a multi-unit or multi-code-point grapheme keeps that
  grapheme whole in `right`.
  """
  @spec split(binary(), integer()) :: {binary(), binary()}
  def split(text, offset) when is_binary(text) and is_integer(offset) do
    cond do
      offset <= 0 -> {"", text}
      offset >= utf16_length(text) -> {text, ""}
      true -> walk(text, offset, "")
    end
  end

  @doc """
  The number of UTF-16 code units `text` occupies — what `selectionStart`/`selectionEnd` report.

  Each code point is 1 unit, 2 units above U+FFFF (where a surrogate pair is needed). Graphemes
  made of several code points (a base + a combining mark) therefore count as several units, which
  is exactly the browser's own arithmetic.
  """
  @spec utf16_length(binary()) :: non_neg_integer()
  def utf16_length(text) when is_binary(text) do
    text
    |> String.to_charlist()
    |> Enum.reduce(0, fn codepoint, acc -> acc + if(codepoint > 0xFFFF, do: 2, else: 1) end)
  end

  # Walk grapheme by grapheme, consuming whole clusters while they fit. The first cluster that
  # would cross the requested boundary is where the split lands — so no cluster is ever cut.
  defp walk("", _remaining, left), do: {left, ""}

  defp walk(rest, remaining, left) do
    case String.next_grapheme(rest) do
      nil ->
        {left, ""}

      {grapheme, tail} ->
        width = grapheme_utf16_width(grapheme)

        if width > remaining do
          {left, rest}
        else
          walk(tail, remaining - width, left <> grapheme)
        end
    end
  end

  defp grapheme_utf16_width(grapheme) do
    grapheme
    |> String.to_charlist()
    |> Enum.reduce(0, fn cp, acc -> acc + if(cp > 0xFFFF, do: 2, else: 1) end)
  end
end
