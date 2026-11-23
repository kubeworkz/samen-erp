defmodule Samen.Scopes.Inventory.ApplyShipmentState do
  @moduledoc """
  The `SalesOrder :apply_shipment` state stamp (WS-LOG L1.2).

  The private internal action takes its target `:status` as an argument; this
  change writes it so `SoState` can validate the pair (pre-state, target)
  before the DB belt sees the update. `ShipPosting` is the only caller.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    target = Ash.Changeset.get_argument(changeset, :status)
    Ash.Changeset.force_change_attribute(changeset, :status, target)
  end
end
