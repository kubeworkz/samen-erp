defmodule Samen.Scopes.Banking.Recognize do
  @moduledoc """
  The auto-match recognition engine for Banking (WS-ERP E9).

  For each unmatched statement line, this module searches posted journal
  entries for candidates that could match. The matching strategy:

  1. **Exact amount match** — the entry's total (Σ debit − Σ credit) equals
     the statement line amount (exact integer cents). This is the highest-
     confidence match.

  2. **Amount ± tolerance** — within 1 cent, for floating-point precision
     in multi-currency scenarios.

  3. **Date proximity** — the entry's `entry_date` is within ±3 days of
     the statement line's `posted_at`. Used as a tiebreaker when multiple
     entries have the same amount.

  4. **Description similarity** — the entry's `memo` contains keywords from
     the statement line description. Used as a secondary signal.

  The engine is a pure function — no DB writes. It returns a list of
  `%{line: line, candidates: [%{entry: entry, confidence: float}]}` structs
  for the UI to present to the user.

  The user confirms or rejects each suggestion. Confirmed suggestions
  create a `Banking.Match` row.
  """

  @date_tolerance_days 3
  @amount_tolerance_cents 1

  @doc """
  Recognize match candidates for a batch of unmatched statement lines.

  Returns a list of maps:
  ```
  %{
    line: %{id, amount_cents, posted_at, description},
    candidates: [
      %{entry: entry, amount_cents: int, confidence: float, reason: String.t()}
    ]
  }
  ```
  """
  def recognize(lines, entries) do
    Enum.map(lines, fn line ->
      candidates = find_candidates(line, entries)
      %{line: line, candidates: candidates}
    end)
  end

  @doc """
  Find match candidates for a single statement line.
  """
  def find_candidates(line, entries) do
    entries
    |> Enum.filter(&posted?/1)
    |> Enum.map(fn entry ->
      entry_total = entry_total(entry)
      confidence = compute_confidence(line, entry, entry_total)
      reason = explain_match(line, entry, entry_total)

      %{entry: entry, amount_cents: entry_total, confidence: confidence, reason: reason}
    end)
    |> Enum.filter(&(&1.confidence > 0))
    |> Enum.sort_by(&{-&1.confidence, &1.amount_cents})
  end

  defp posted?(%{status: :posted}), do: true
  defp posted?(_), do: false

  defp entry_total(entry) do
    # The entry's total is Σ debit_cents − Σ credit_cents over its lines.
    # This is stored as a derived value or computed from the lines.
    # For now, we expect the entry to have loaded lines.
    case Map.get(entry, :lines) do
      nil -> 0
      lines -> Enum.reduce(lines, 0, fn l, acc -> acc + l.debit_cents - l.credit_cents end)
    end
  end

  defp compute_confidence(line, entry, entry_total) do
    amount_match = line.amount_cents == entry_total
    amount_close = abs(line.amount_cents - entry_total) <= @amount_tolerance_cents

    date_match =
      date_diff_days(line.posted_at, entry.entry_date) <= @date_tolerance_days

    description_match = description_similarity(line.description, entry.memo)

    cond do
      amount_match and date_match -> 1.0
      amount_match -> 0.8
      amount_close and date_match -> 0.6
      amount_close -> 0.4
      date_match and description_match > 0.3 -> 0.3
      true -> 0.0
    end
  end

  defp explain_match(line, entry, entry_total) do
    amount_match = line.amount_cents == entry_total
    date_diff = date_diff_days(line.posted_at, entry.entry_date)

    cond do
      amount_match and date_diff == 0 ->
        "Exact amount match on same date"

      amount_match ->
        "Exact amount match (#{date_diff} day(s) apart)"

      abs(line.amount_cents - entry_total) <= @amount_tolerance_cents ->
        "Amount within tolerance (#{date_diff} day(s) apart)"

      true ->
        "Possible match (#{date_diff} day(s) apart)"
    end
  end

  defp date_diff_days(nil, _), do: 999
  defp date_diff_days(_, nil), do: 999

  defp date_diff_days(%NaiveDateTime{} = a, %Date{} = b) do
    date_diff_days(NaiveDateTime.to_date(a), b)
  end

  defp date_diff_days(%Date{} = a, %NaiveDateTime{} = b) do
    date_diff_days(a, NaiveDateTime.to_date(b))
  end

  defp date_diff_days(%Date{} = a, %Date{} = b) do
    abs(Date.diff(a, b))
  end

  defp description_similarity(nil, _), do: 0.0
  defp description_similarity(_, nil), do: 0.0

  defp description_similarity(description, memo) do
    desc_words =
      description
      |> String.downcase()
      |> String.split(~r/\s+/, trim: true)
      |> MapSet.new()

    memo_words =
      memo
      |> String.downcase()
      |> String.split(~r/\s+/, trim: true)
      |> MapSet.new()

    intersection = MapSet.intersection(desc_words, memo_words)
    union = MapSet.union(desc_words, memo_words)

    if MapSet.size(union) > 0 do
      MapSet.size(intersection) / MapSet.size(union)
    else
      0.0
    end
  end
end
