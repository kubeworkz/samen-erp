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
  * `:apply_shipment` — the private internal partial path admits only
    `:confirmed -> :partially_fulfilled` and
    `:partially_fulfilled -> :fulfilled`. A first complete shipment makes
    both transitions in that order; every other pre-state/target pair is
    refused before the DB belt sees it.

  The legacy cascade's own flip (FulfillOrder stamps `:fulfilled` on
  `:fulfill`) does not run through a guarded transition action — the cascade
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

    target = Ash.Changeset.get_attribute(changeset, :status)

    case {action, pre, target} do
      {:confirm, :draft, _} -> changeset
      {:fulfill, :confirmed, _} -> changeset
      {:cancel, s, _} when s in [:draft, :confirmed] -> changeset
      {:apply_shipment, :confirmed, :partially_fulfilled} -> changeset
      {:apply_shipment, :partially_fulfilled, :fulfilled} -> changeset
      {:apply_shipment, _, _} -> refuse_apply_shipment(changeset, pre, target)
      {:confirm, other, _} -> refuse(changeset, :confirm, other)
      {:fulfill, other, _} -> refuse(changeset, :fulfill, other)
      {:cancel, other, _} -> refuse(changeset, :cancel, other)
      {_, _, _} -> changeset
    end
  end

  defp refuse_apply_shipment(changeset, pre, target) do
    Ash.Changeset.add_error(changeset,
      field: :status,
      message:
        "illegal :apply_shipment transition: #{inspect(pre)} -> #{inspect(target)} — only " <>
          ":confirmed -> :partially_fulfilled and :partially_fulfilled -> :fulfilled are admitted"
    )
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
