defmodule Samen.Scopes.Finance.GrantClaimDecision do
  @moduledoc """
  A grant claim's single decision (WS-ACCT Phase 11; ADR-054 D8). A claim is
  submitted once and decided once: `:submitted` → `:approved` or `:rejected`,
  never back. The approval stamps `approved_on`; a rejection leaves it nil.
  Only approved claims count toward R11.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    decision = Keyword.fetch!(opts, :decision)

    Ash.Changeset.before_action(changeset, fn changeset ->
      if changeset.data.status == :submitted do
        changeset = Ash.Changeset.force_change_attribute(changeset, :status, decision)

        if decision == :approved do
          Ash.Changeset.force_change_attribute(changeset, :approved_on, Date.utc_today())
        else
          changeset
        end
      else
        Ash.Changeset.add_error(changeset,
          field: :status,
          message: "this claim has already been decided (#{changeset.data.status})"
        )
      end
    end)
  end
end
