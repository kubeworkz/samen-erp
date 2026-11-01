defmodule Samen.Scopes.Finance.StandardCard do
  @moduledoc """
  Resolving the standard card **in force for a period** (WS-ACCT Phase 7;
  ADR-054 D4).

  Standards are effective-dated, not mutable: `CostStandard.effective_on` says
  when a card starts to govern, and a revision is a NEW card, never an edit.
  Repricing history would be the ledger equivalent of rewriting a posted entry.
  The period's card is therefore

      the latest card for this {org, cost object} whose `effective_on` is on or
      before the period's last day

  and both the engine and R8 resolve it through THIS module, so "which card was
  in force" has one answer.

  Two guards that look redundant and are not:

    * the engine refuses to run a card that is not the one in force for the
      period (`:standard_not_in_force`) — a caller holding an old card id must
      not retroactively price a period the newer card governs, and a caller
      holding a future card must not price a period before it exists;
    * R8 re-resolves the card independently and flags a row whose
      `standard_id` is not the in-force card (`{:off_card, …}`), which is what
      makes a variance posting *provably* tied to the card it claims.

  ## No card is not "no variance"

  `{:ok, nil}` means the period has no card at all; the engine refuses
  (`:no_standard`) rather than posting zero. `{:error, reason}` is an
  unreadable standard table, which is also a refusal — a read failure is not
  permission to price on nothing.
  """

  require Ash.Query

  @doc """
  The card in force for `cost_object_id` at `period_end`.

  Returns `{:ok, standard | nil}` or `{:error, reason}`.
  """
  def in_force(standard_mod, org_id, cost_object_id, period_end) do
    standard_mod
    |> Ash.Query.filter(
      org_id == ^org_id and cost_object_id == ^cost_object_id and
        effective_on <= ^period_end
    )
    |> Ash.Query.sort(effective_on: :desc, inserted_at: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one(authorize?: false)
  end

  @doc "The period's last day for a `\"YYYY-MM\"` key, or `{:error, :bad_period}`."
  def period_end(period_key) when is_binary(period_key) do
    with [year, month] <- String.split(period_key, "-"),
         {year, ""} <- Integer.parse(year),
         {month, ""} <- Integer.parse(month),
         true <- month in 1..12,
         {:ok, date} <- Date.new(year, month, 1) do
      {:ok, Date.end_of_month(date)}
    else
      _ -> {:error, :bad_period}
    end
  end

  def period_end(_), do: {:error, :bad_period}
end
