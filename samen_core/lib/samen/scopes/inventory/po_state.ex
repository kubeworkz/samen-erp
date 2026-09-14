defmodule Samen.Scopes.Inventory.PoState do
  @moduledoc """
  The PO state machine guard (WS-ERP E4; design §3.2), the
  `Samen.Scopes.Finance.ApLines` shape: per-action pre-state refusals on the
  lifecycle transitions, with the cascade's own force-stamps exempt.

  * `:approve` — only a `:draft` PO may be approved (one-way machine).
  * `:close` — only a `:received` PO may close (an unclosed partial order
    keeps receiving; closing early would contradict the ReceiptLine facts).
  * `:void` — only a pre-receipt PO (`:draft`/`:approved`/`:sent`) may void;
    a void with receipts would orphan the realized stock and GL value (the
    base system's correction path for a received PO is a return receipt, P2).

  The cascade's stamps (GoodsPosting's `:received`, on `:receive`) do NOT run
  through these actions' guards — the cascade force-stamps AFTER its own
  receivability check (GoodsPosting refuses a non-receivable PO), so no
  ungated path to `:received` exists.

  The DB belt trigger is this guard's raw-SQL twin (the migration refuses the
  same illegal transitions plus the unmarked `:received` stamp).
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    action = changeset.action && changeset.action.name

    # The PRE-STATE is the PERSISTED state (changeset.data), never the pending
    # attribute: resource-wide changes run AFTER the action's own
    # set_attribute stamp, so get_attribute would already carry the transition's
    # destination. Only when the record's own status is NotLoaded (a caller
    # holding a create result) do we re-fetch.
    pre =
      case changeset.data.status do
        %Ash.NotLoaded{} ->
          Ash.load!(changeset.data, [:status], authorize?: false).status

        value ->
          value
      end

    case {action, pre} do
      {:approve, :draft} -> changeset
      {:close, :received} -> changeset
      {:void, s} when s in [:draft, :approved, :sent] -> changeset
      {:approve, other} -> refuse(changeset, :approve, other)
      {:close, other} -> refuse(changeset, :close, other)
      {:void, other} -> refuse(changeset, :void, other)
      {_, _} -> changeset
    end
  end

  defp refuse(changeset, action, state) do
    Ash.Changeset.add_error(changeset,
      field: :status,
      message:
        "illegal #{action} transition: the PO is #{inspect(state)} — " <> allowed(action)
    )
  end

  defp allowed(:approve),
    do: "only a :draft PO can be approved (one-way state machine)"

  defp allowed(:close),
    do: "only a :received PO can be closed (an open order keeps receiving)"

  defp allowed(:void),
    do: "only a pre-receipt PO (:draft/:approved/:sent) can be void — a received PO's " <>
          "realized stock and GL value need a return receipt, not a void (P2)"
end
