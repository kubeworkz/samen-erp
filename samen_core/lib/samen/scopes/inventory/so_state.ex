defmodule Samen.Scopes.Inventory.SoState do
  @moduledoc """
  The SO state machine guard (WS-ERP E5; design §3.3), the
  `Samen.Scopes.Inventory.PoState` shape: per-action pre-state refusals on
  the lifecycle transitions.

  * `:confirm` — only a `:draft` SO may be confirmed. A sale is not a
    spend: no ADR-040 Gate here (the contrast with the PO's `:approve` is
    the design's point — approval discipline guards OUTBOUND value).
  * `:fulfill` — only a `:confirmed` SO may fulfill (the bridge consumes a
    commitment, not a sketch).
  * `:cancel` — only a pre-fulfillment SO (`:draft`/`:confirmed`) may
    cancel; a fulfilled SO's stock and invoice are facts.

  The cascade's own flip (FulfillOrder stamps `:fulfilled` on `:fulfill`)
  does not run through a guarded transition action — the cascade
  force-stamps after its own pre-state check, and the DB belt admits
  `→fulfilled` ONLY under the posting marker.
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
      {:confirm, :draft} -> changeset
      {:fulfill, :confirmed} -> changeset
      {:cancel, s} when s in [:draft, :confirmed] -> changeset
      {:confirm, other} -> refuse(changeset, :confirm, other)
      {:fulfill, other} -> refuse(changeset, :fulfill, other)
      {:cancel, other} -> refuse(changeset, :cancel, other)
      {_, _} -> changeset
    end
  end

  defp refuse(changeset, action, state) do
    Ash.Changeset.add_error(changeset,
      field: :status,
      message:
        "illegal #{action} transition: the SO is #{inspect(state)} — " <> allowed(action)
    )
  end

  defp allowed(:confirm), do: "only a :draft SO can be confirmed"

  defp allowed(:fulfill),
    do: "only a :confirmed SO can be fulfilled (the bridge consumes a commitment)"

  defp allowed(:cancel),
    do: "only a pre-fulfillment SO (:draft/:confirmed) can be cancelled — a fulfilled " <>
          "SO's stock and invoice are facts"
end
