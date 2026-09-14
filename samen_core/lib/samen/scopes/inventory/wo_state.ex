defmodule Samen.Scopes.Inventory.WoState do
  @moduledoc """
  The WorkOrder state-machine guard (WS-ERP E6; design §4), the
  `Samen.Scopes.Inventory.PoState` shape: per-action pre-state refusals on
  the lifecycle transitions.

  * `:release` — only a `:draft` WO may be released (the snapshot freeze
    happens exactly once; the belt marker arms the →released flip).
  * `:complete` — only a `:released` WO may complete (the posting facade
    consumes the frozen snapshot; the belt marker arms the →completed
    flip).
  * `:cancel` — only a pre-completion WO (`:draft`/`:released`) may
    cancel; a completed WO's stock facts are facts.
  * `:update` — draft-only edits (labor/overhead/schedule/memo); a
    released WO's economics are frozen with its snapshot.

  The cascades' own flips (`ReleaseWo` stamps `:released`, `ProduceWo`
  stamps `:completed`) force-stamp after their own pre-state checks; the
  DB belt admits `→released`/`→completed` ONLY under the posting marker.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    action = changeset.action && changeset.action.name

    # The PRE-STATE is the PERSISTED state (changeset.data) — resource-wide
    # changes run after the action's own set_attribute stamp (the PoState
    # discipline). NotLoaded falls back to a re-fetch.
    pre =
      case changeset.data.status do
        %Ash.NotLoaded{} -> Ash.load!(changeset.data, [:status], authorize?: false).status
        value -> value
      end

    case {action, pre} do
      {:release, :draft} -> changeset
      {:complete, :released} -> changeset
      {:cancel, s} when s in [:draft, :released] -> changeset
      {:update, :draft} -> changeset
      {:release, other} -> refuse(changeset, :release, other)
      {:complete, other} -> refuse(changeset, :complete, other)
      {:cancel, other} -> refuse(changeset, :cancel, other)
      {:update, other} -> refuse(changeset, :update, other)
      {_, _} -> changeset
    end
  end

  defp refuse(changeset, action, state) do
    Ash.Changeset.add_error(changeset,
      field: :status,
      message:
        "illegal #{action} transition: the WO is #{inspect(state)} — " <> allowed(action)
    )
  end

  defp allowed(:release),
    do: "only a :draft WO can be released (the snapshot freezes exactly once)"

  defp allowed(:complete),
    do: "only a :released WO can complete (the facade consumes the frozen snapshot)"

  defp allowed(:cancel),
    do: "only a pre-completion WO (:draft/:released) can be cancelled — a completed " <>
          "WO's stock facts are facts"

  defp allowed(:update),
    do: "only a :draft WO can be edited — a released WO's economics are frozen with " <>
          "its snapshot"
end
