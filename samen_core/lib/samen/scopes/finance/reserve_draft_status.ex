defmodule Samen.Scopes.Finance.ReserveDraftStatus do
  @moduledoc """
  The one-way guard for a reserve write-down (WS-ACCT Phase 9; ADR-054 D10).

  `:post` only matches a `:draft`. This validation runs while the changeset is
  built — BEFORE the Gate's `before_transaction` hook — so a second post on an
  already-posted row is refused as `:already_posted` instead of opening a new
  approval that could never execute. The Gate still owns second-party consent;
  this module only keeps the state machine honest in front of it.
  """

  use Ash.Resource.Validation

  @impl true
  def validate(changeset, _opts, _context) do
    case changeset.data.status do
      :draft ->
        :ok

      :posted ->
        {:error,
         field: :status,
         message:
           "this write-down is already posted — a posted write-down is final; a " <>
             "correction is a new proposal and entry, never a re-post"}
    end
  end
end
