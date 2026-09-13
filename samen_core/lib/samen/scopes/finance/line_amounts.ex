defmodule Samen.Scopes.Finance.LineAmounts do
  @moduledoc """
  The per-line amount discipline for `JournalLine` (WS-ERP E1; ADR-049 §2):
  each line carries integer cents `debit_cents` / `credit_cents` and **exactly
  one of the two is non-zero** — a line is either a debit or a credit, never
  both, never neither (a zero-zero line carries no accounting meaning and is
  refused as noise).

  Runs as an `Ash.Resource.Change` on the line's create/update actions; `nil`
  amounts coerce to `0` (the attribute default) before the check so an omitted
  field behaves as zero rather than slipping past the validation.

  A NEGATIVE amount is also refused here: direction is expressed by WHICH
  column is non-zero, never by a sign. This keeps the R1 sum a plain unsigned
  tally on both faces (input maps in `UnbalancedEntry`, persisted rows in
  `Samen.Scopes.Finance.Reconcile`).
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &check/1)
  end

  defp check(changeset) do
    debit = coerce(Ash.Changeset.get_attribute(changeset, :debit_cents))
    credit = coerce(Ash.Changeset.get_attribute(changeset, :credit_cents))

    cond do
      debit < 0 or credit < 0 ->
        Ash.Changeset.add_error(changeset,
          field: :debit_cents,
          message: "amounts are unsigned integer cents — direction is which column is non-zero"
        )

      debit > 0 and credit > 0 ->
        Ash.Changeset.add_error(changeset,
          field: :debit_cents,
          message: "a line is a debit OR a credit — exactly one of debit_cents/credit_cents may be non-zero"
        )

      debit == 0 and credit == 0 ->
        Ash.Changeset.add_error(changeset,
          field: :debit_cents,
          message: "a line must carry an amount — exactly one of debit_cents/credit_cents must be non-zero"
        )

      true ->
        changeset
    end
  end

  defp coerce(nil), do: 0
  defp coerce(v) when is_integer(v), do: v
  defp coerce(%Decimal{} = d), do: Decimal.to_integer(d)
  defp coerce(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, ""} -> i
      _ -> 0
    end
  end
  defp coerce(_), do: 0
end
