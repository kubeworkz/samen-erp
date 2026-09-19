defmodule Samen.Scopes.Banking.RuleEngine do
  @moduledoc """
  The auto-categorization rule engine for Banking (WS-ERP E9).

  On import, each unmatched statement line is evaluated against active rules.
  Rules are matched by:
  1. **Pattern** — substring or regex matched against the statement line
     description (case-insensitive).
  2. **Amount bounds** — optional `min_amount_cents` / `max_amount_cents`
     filter.
  3. **Bank account scope** — a rule with `bank_account_id: nil` applies to
     all accounts; a rule with a specific `bank_account_id` applies only to
     that account.

  When multiple rules match, the highest `priority` wins. Ties are broken by
  pattern length (longer = more specific).

  The engine is a pure function — no side effects, no DB writes. It returns
  a list of `{statement_line_id, account_id}` tuples for the caller to
  apply in batch.
  """

  @doc """
  Evaluate rules against a batch of unmatched statement lines.

  Returns a list of `{line_id, account_id}` tuples for lines that matched
  a rule. Lines with no match are not included.
  """
  def evaluate(rules, lines) do
    Enum.map(lines, fn line ->
      case find_best_match(rules, line) do
        nil -> nil
        rule -> {line.id, rule.account_id}
      end
    end)
    |> Enum.reject(&is_nil/1)
  end

  @doc """
  Find the best matching rule for a single statement line.
  Returns the rule or nil.
  """
  def find_best_match(rules, line) do
    rules
    |> Enum.filter(&active?/1)
    |> Enum.filter(&matches_account?(&1, line.bank_account_id))
    |> Enum.filter(&matches_pattern?(&1, line.description))
    |> Enum.filter(&matches_amount?(&1, line.amount_cents))
    |> sort_by_specificity()
    |> List.first()
  end

  # A rule is active unless explicitly disabled.
  defp active?(rule), do: rule.is_active

  # A rule with bank_account_id: nil applies to all accounts.
  defp matches_account?(%{bank_account_id: nil}, _), do: true
  defp matches_account?(%{bank_account_id: id}, id), do: true
  defp matches_account?(_, _), do: false

  # Pattern matching: substring (default) or regex (if wrapped in /.../).
  defp matches_pattern?(%{pattern: pattern}, description) do
    desc_lower = String.downcase(description)

    if is_struct(pattern, Regex) do
      Regex.match?(pattern, desc_lower)
    else
      String.contains?(desc_lower, String.downcase(pattern))
    end
  end

  # Amount bounds: optional min/max.
  defp matches_amount?(%{min_amount_cents: nil, max_amount_cents: nil}, _), do: true

  defp matches_amount?(%{min_amount_cents: min, max_amount_cents: nil}, amount) do
    amount >= min
  end

  defp matches_amount?(%{min_amount_cents: nil, max_amount_cents: max}, amount) do
    amount <= max
  end

  defp matches_amount?(%{min_amount_cents: min, max_amount_cents: max}, amount) do
    amount >= min and amount <= max
  end

  # Sort by priority (descending), then by pattern length (descending).
  defp sort_by_specificity(rules) do
    Enum.sort_by(rules, fn r -> {-r.priority, -String.length(r.pattern)} end)
  end
end
