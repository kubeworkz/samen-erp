defmodule Samen.Scopes.Finance.AssetShape do
  @moduledoc """
  The shape guard for an `Asset` (WS-ACCT Phase 8; ADR-054 D9).

  One rule no single attribute constraint can express:

      cost_cents - salvage_cents >= life_months

  A life that cannot release at least one cent per month is not a schedule; it
  would have to post zero for most months and dump the remainder in the last,
  which is a rounding accident dressed as an accounting policy. The per-
  attribute validations already refuse a non-positive cost or life and a
  negative salvage; this closes the gap between them.

  Runs `before_action`, so the refusal lands inside the create's transaction
  with a field-level message rather than a database CHECK.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &check/1)
  end

  defp check(changeset) do
    cost = Ash.Changeset.get_attribute(changeset, :cost_cents)
    salvage = Ash.Changeset.get_attribute(changeset, :salvage_cents) || 0
    life = Ash.Changeset.get_attribute(changeset, :life_months)

    if is_integer(cost) and is_integer(life) and life > 0 and cost - salvage < life do
      Ash.Changeset.add_error(changeset,
        field: :cost_cents,
        message:
          "cost minus salvage (#{cost - salvage}) must be at least the life in months " <>
            "(#{life}) — an asset's schedule amortizes at least one cent per period"
      )
    else
      changeset
    end
  end
end
