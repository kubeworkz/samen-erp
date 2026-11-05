defmodule Samen.Scopes.Finance.GrantClose do
  @moduledoc """
  The one-way grant close (WS-ACCT Phase 11; ADR-054 D8). A closed grant is
  final: there is no reopen action, and a second close is refused rather than
  restamping the date. The ledger is untouched — closing an award is a
  document decision, not a posting.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      if changeset.data.status == :closed do
        Ash.Changeset.add_error(changeset,
          field: :status,
          message: "this grant is already closed — closing is one-way"
        )
      else
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :closed)
        |> Ash.Changeset.force_change_attribute(:closed_on, Date.utc_today())
      end
    end)
  end
end
