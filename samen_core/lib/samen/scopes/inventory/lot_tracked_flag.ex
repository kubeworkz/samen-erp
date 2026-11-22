defmodule Samen.Scopes.Inventory.LotTrackedFlag do
  @moduledoc """
  Maintains `Item.lot_tracked = true` when a `Lot` is created.

  Runs in `Lot :create`'s `after_action`, inside the action transaction (the
  `HiredEvent`/cross-row-cascade discipline). The item update is internal:
  it bypasses the caller's item policy because the lot action has already
  enforced `SameOrgFk` for the named item, and it uses the Item `:update`
  action so the clearing guard still applies to the write. If the mark
  fails, the error propagates out of `after_action` and the lot create rolls
  back — a lot can never commit while its item remains unflagged.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    if changeset.action && changeset.action.name == :create do
      Ash.Changeset.after_action(changeset, fn changeset, lot ->
        mark_item(changeset, lot, Keyword.fetch!(opts, :item))
      end)
    else
      changeset
    end
  end

  defp mark_item(changeset, lot, item_mod) do
    org_id = resolve_org(changeset, lot)
    item_id = Ash.Changeset.get_attribute(changeset, :item_id) || lot.item_id

    case Ash.get(item_mod, item_id, authorize?: false, load: [:org_id]) do
      {:ok, item} ->
        if is_binary(org_id) and item.org_id != org_id do
          same_org_error()
        else
          mark_loaded_item(item, lot)
        end

      {:error, reason} ->
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :item_id,
           message: "the lot's item could not be loaded: #{inspect(reason)}",
           value: nil
         )}
    end
  end

  # SameOrgFk has already checked the item before this after_action runs; this
  # is a defensive comparison. Prefer the changeset's org, then the committed
  # record's, and skip the comparison if neither is loaded (the result struct
  # can carry NotLoaded values, as in the HiredEvent precedent).
  defp resolve_org(changeset, lot) do
    case Ash.Changeset.get_attribute(changeset, :org_id) do
      value when is_binary(value) -> value
      _ -> if is_binary(lot.org_id), do: lot.org_id, else: nil
    end
  end

  defp mark_loaded_item(item, lot) do
    item
    |> Ash.Changeset.for_update(:update, %{lot_tracked: true}, authorize?: false)
    |> Ash.update()
    |> case do
      {:ok, _item} ->
        {:ok, lot}

      {:error, reason} ->
        {:error,
         Ash.Error.Changes.InvalidAttribute.exception(
           field: :lot_tracked,
           message: "the item's lot_tracked flag failed to land: #{inspect(reason)}",
           value: nil
         )}
    end
  end

  defp same_org_error do
    {:error,
     Ash.Error.Changes.InvalidAttribute.exception(
       field: :item_id,
       message: "the lot's item must belong to the same org",
       value: nil
     )}
  end
end
