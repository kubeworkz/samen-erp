defmodule Samen.Scopes.Finance.LabourAllocationDiscard do
  @moduledoc """
  Withdraws a **draft** labour allocation (WS-ACCT Unit 10.2; ADR-054 D17).

  A draft is a proposal: nothing posted, so it may be withdrawn. This is the
  route a `labour_drift` refusal points at — when approved hours move after
  drafting, the stale proposal is discarded and re-drafted against the current
  driver. A **posted** allocation is a reported fact and cannot be discarded;
  its correction is a reversing entry, exactly like every other posted fact in
  this scope.

  Discarding is a status write, never a delete: the frozen shares and their
  minutes stay as evidence of what was proposed, and the partial unique index
  (`status <> 'discarded'`) frees the {period, source account} slot for the
  re-draft. The DB trigger allows exactly two status writes — `draft → posted`
  and `draft → discarded` — so a withdrawn proposal can never be revived and a
  posted one can never change.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      if changeset.data.status == :draft do
        Ash.Changeset.force_change_attribute(changeset, :status, :discarded)
      else
        Ash.Changeset.add_error(changeset,
          message:
            "a #{changeset.data.status} labour allocation is final — a correction is a " <>
              "reversing entry, never a discard"
        )
      end
    end)
  end
end
