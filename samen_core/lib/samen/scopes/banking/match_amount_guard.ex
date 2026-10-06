defmodule Samen.Scopes.Banking.MatchAmountGuard do
  @moduledoc """
  The amount-strict match guard for Banking.Match (WS-ERP E9).

  When a match is created, this guard verifies the statement line's amount against
  the journal entry's effect on the BANK ACCOUNT'S OWN GL cash account — the cash
  LEG of the entry (Σ debit − credit over the entry's lines whose `account_id` is
  the BankAccount's GL `account_id`). The bank statement sees exactly that leg:
  money out is a credit on cash (negative leg), money in a debit (positive leg),
  matching the statement line's signed `amount_cents` convention.

  ## Why not Σ over the WHOLE entry

  A balanced double-entry totals Σ(debit − credit) = 0 by construction (the
  Finance blueprint's `UnbalancedEntry` change refuses anything else), so a
  whole-entry sum could never equal a non-zero statement line — the check would
  refuse every match. The cash leg is the semantically correct comparison.

  ## Why Ash reads, not raw SQL

  The original implementation queried `SELECT amount_cents FROM <table>` with
  unprefixed column names — against this system's `<abbrev>_`-prefixed storage
  (`bkl_amount_cents`, `bkl_id`, …) every such query ERRORS, the error branch
  returned 0, and the guard compared 0 to 0: a tautology that could never fail.
  Ash reads resolve attribute→column mapping themselves, so they are
  prefix-proof on every host. A missing/indeterminate row REFUSES the match
  (fail-closed) — never a silent pass.

  The tolerance is ±1 cent (integer cents; the slack covers multi-currency
  rounding on the leg sum).
  """
  use Ash.Resource.Change

  @tolerance 1

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      statement_line_id = Ash.Changeset.get_attribute(changeset, :statement_line_id)
      entry_id = Ash.Changeset.get_attribute(changeset, :entry_id)

      line_resource = resolve_statement_line_resource(changeset)
      entry_resource = resolve_entry_resource(changeset)
      bank_account_resource = resolve_bank_account_resource(line_resource)

      with {:ok, line} <- fetch(line_resource, statement_line_id),
           {:ok, bank_account} <- fetch(bank_account_resource, line.bank_account_id),
           {:ok, cash_account_id} when not is_nil(cash_account_id) <- {:ok, bank_account.account_id},
           {:ok, entry} <- fetch(entry_resource, entry_id, load: [:lines]),
           {:ok, line_amount} when is_integer(line_amount) <- {:ok, line.amount_cents},
           {:ok, cash_total} <- cash_leg_total(entry, cash_account_id) do
        diff = abs(line_amount - cash_total)

        if diff > @tolerance do
          Ash.Changeset.add_error(changeset,
            field: :entry_id,
            message:
              "Amount mismatch: statement line is #{format_cents(line_amount)} but the entry's " <>
                "cash-account leg totals #{format_cents(cash_total)} (difference: #{format_cents(diff)})",
            variable: entry_id
          )
        else
          changeset
        end
      else
        {:error, :amount_unknown, detail} ->
          Ash.Changeset.add_error(changeset,
            field: :entry_id,
            message: "Cannot verify the match amount: #{detail}",
            variable: entry_id
          )

        {:error, _} ->
          Ash.Changeset.add_error(changeset,
            field: :entry_id,
            message: "Cannot verify the match amount: a referenced row is missing",
            variable: entry_id
          )
      end
    end)
  end

  # Σ (debit − credit) over the entry's lines that hit the bank account's GL
  # cash account. An entry with no leg on that account totals 0 — which then
  # fails the comparison against any non-zero line (correct: nothing in this
  # entry moves that bank's money).
  defp cash_leg_total(entry, cash_account_id) do
    lines = entry.lines || []

    if Enum.any?(lines, &is_nil(&1.account_id)) do
      {:error, :amount_unknown, "a journal line has no account"}
    else
      total =
        lines
        |> Enum.filter(&(&1.account_id == cash_account_id))
        |> Enum.reduce(0, fn l, acc -> acc + (l.debit_cents || 0) - (l.credit_cents || 0) end)

      {:ok, total}
    end
  end

  defp fetch(resource, id, opts \\ []) do
    case Ash.get(resource, id, Keyword.merge([authorize?: false], opts)) do
      {:ok, nil} -> {:error, :missing}
      {:ok, record} -> {:ok, record}
      {:error, _} -> {:error, :missing}
    end
  end

  defp resolve_statement_line_resource(changeset) do
    changeset.resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.name == :statement_line))
    |> Map.fetch!(:destination)
  end

  defp resolve_entry_resource(changeset) do
    changeset.resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.name == :entry))
    |> Map.fetch!(:destination)
  end

  defp resolve_bank_account_resource(line_resource) do
    line_resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.name == :bank_account))
    |> Map.fetch!(:destination)
  end

  defp format_cents(cents) do
    dollars = div(cents, 100)
    remainder = cents |> rem(100) |> abs()
    "$#{dollars}.#{String.pad_leading(Integer.to_string(remainder), 2, "0")}"
  end
end
