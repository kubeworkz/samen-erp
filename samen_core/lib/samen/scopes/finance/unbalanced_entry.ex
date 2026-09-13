defmodule Samen.Scopes.Finance.UnbalancedEntry do
  @moduledoc """
  The R1 core guard (WS-ERP E1; ADR-049 §2, decision 7): a `JournalEntry` whose
  `JournalLine`s do not SUM to zero is refused — `Σ debits == Σ credits` per
  entry, always, by construction.

  This is the double-entry invariant itself. There is no "unbalanced but
  approved" path: an entry that would not balance is a data error, not a
  business decision. The guard runs in the entry's `before_action` hook — inside
  the action's transaction, before any row lands — over the `lines` INPUT list
  (`Ash.Changeset.get_argument/2`), so a draft is born balanced and stays
  balanced: `:post` re-validates the PERSISTED rows via
  `Samen.Scopes.Finance.PostBalance`, so an entry can never drift out of balance
  between draft and post.

  ## Usage

      change(Samen.Scopes.Finance.UnbalancedEntry,
        lines: :lines,
        debit: :debit_cents,
        credit: :credit_cents
      )

  Accepts each line as a map with the account id + the two integer-cents
  amounts (exactly one non-zero per line, `Samen.Scopes.Finance.LineAmounts`'s
  contract) — the shape the `:create`/`:update` actions take as the `lines`
  argument.

  A `nil`/absent `lines` argument is a no-op here (nothing to balance yet); the
  argument is `allow_nil?: false` on `:create` (an entry is born with lines or
  not at all) and optional on the draft-edit `:update` (an argument-less edit
  touches only `entry_date`/`memo`). The `:post`/`:void` actions take NO
  argument at all — their R1 check is PostBalance's, over the stored rows.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    lines_key = Keyword.fetch!(opts, :lines)
    debit_key = Keyword.fetch!(opts, :debit)
    credit_key = Keyword.fetch!(opts, :credit)

    Ash.Changeset.before_action(changeset, fn changeset ->
      case Ash.Changeset.get_argument(changeset, lines_key) do
        nil ->
          changeset

        [] ->
          # An empty list is NOT a balanced entry (0 == 0 vacuously) — it is a
          # line-less entry, refused at the same gate (an entry is born with
          # lines or not at all).
          Ash.Changeset.add_error(changeset,
            field: lines_key,
            message: "an entry requires at least one line — an empty lines list is not a balanced entry"
          )

        lines when is_list(lines) ->
          check(changeset, lines, debit_key, credit_key)

        other ->
          Ash.Changeset.add_error(changeset,
            field: lines_key,
            message: "expected a list of line maps, got: #{inspect(other)}"
          )
      end
    end)
  end

  defp check(changeset, lines, debit_key, credit_key) do
    totals =
      Enum.reduce(lines, %{debits: 0, credits: 0}, fn line, acc ->
        debit = Map.get(line, debit_key) || 0
        credit = Map.get(line, credit_key) || 0

        # A malformed line (no account, garbage amounts) is refused at a
        # different layer — the argument's type constraints and LineAmounts.
        # This guard owns ONLY the sum.

        %{acc | debits: acc.debits + to_int(debit), credits: acc.credits + to_int(credit)}
      end)

    if totals.debits == totals.credits do
      changeset
    else
      Ash.Changeset.add_error(changeset,
        field: :lines,
        message:
          "unbalanced entry: debits sum to #{totals.debits} but credits sum to " <>
            "#{totals.credits} — Σ debits must equal Σ credits (R1, double entry)"
      )
    end
  end

  defp to_int(v) when is_integer(v), do: v

  defp to_int(v) when is_float(v), do: trunc(v)

  defp to_int(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, ""} -> i
      _ -> 0
    end
  end
  defp to_int(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_int(_), do: 0
end
