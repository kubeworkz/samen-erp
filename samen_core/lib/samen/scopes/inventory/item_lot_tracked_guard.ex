defmodule Samen.Scopes.Inventory.ItemLotTrackedGuard do
  @moduledoc """
  Keeps `Item.lot_tracked` from being cleared while the item has a live
  `Lot` row.

  The flag is maintained by `Lot :create` (see `LotTrackedFlag`) and
  initialized by the L1 migration. This guard closes the other half of the
  invariant: an `Item :update` may set the flag true, but may set it false
  only when no `Lot` row names the item. A no-lot item keeps the positive
  control of being able to clear the flag.

  The guard runs resource-wide on update actions and is supplied with the
  host's `Lot` module at mount expansion time. An Inventory mount without
  the Finance-facing `Lot` resource passes `nil`; the guard is then a no-op,
  because there is no lot table to consult.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    lot_mod = Keyword.get(opts, :lot)

    if changeset.action && changeset.action.name == :update do
      case {lot_mod, Ash.Changeset.get_attribute(changeset, :lot_tracked)} do
        {nil, _} -> changeset
        {_lot, false} -> refuse_if_lots(changeset, lot_mod)
        {_lot, _} -> changeset
      end
    else
      changeset
    end
  end

  defp refuse_if_lots(changeset, lot_mod) do
    require Ash.Query

    item_id = changeset.data.id

    case Ash.count(
           lot_mod
           |> Ash.Query.filter(item_id == ^item_id),
           authorize?: false
         ) do
      {:ok, 0} ->
        changeset

      {:ok, _count} ->
        Ash.Changeset.add_error(changeset,
          field: :lot_tracked,
          message: "lot_tracked_has_lots: an Item cannot clear lot_tracked while a Lot row exists"
        )

      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :lot_tracked,
          message: "lot_tracked_has_lots: the Lot lookup failed: #{inspect(reason)}"
        )
    end
  end
end
