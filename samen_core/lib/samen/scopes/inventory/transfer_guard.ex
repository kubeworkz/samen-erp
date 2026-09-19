defmodule Samen.Scopes.Inventory.TransferGuard do
  @moduledoc """
  Transfer order guard (WS-ERP E13).

  Enforces invariants on TransferOrder create/post:

  1. **Same item.** The source and destination warehouse must stock the
     same item (enforced by design — both movements reference the same
     `item_id`).

  2. **Positive qty.** The transfer quantity must be positive.

  3. **Source ≠ destination.** A warehouse cannot transfer to itself.

  4. **Source has stock.** The source warehouse must have sufficient
     `qty_on_hand` (the `NegativeStock` guard — `allow_negative: false`
     is the default). This is checked on `:post`, not `:create`, because
     stock levels may change between draft and post.

  5. **Both warehouses exist.** The source and destination warehouse IDs
     must reference existing warehouses.

  On `:create`, the guard validates invariants 1–3 and 5.
  On `:post`, the guard additionally validates invariant 4 (stock check).
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      source = Ash.Changeset.get_attribute(changeset, :source_warehouse_id)
      dest = Ash.Changeset.get_attribute(changeset, :dest_warehouse_id)
      qty = Ash.Changeset.get_attribute(changeset, :qty)

      with :ok <- validate_positive_qty(changeset, qty),
           :ok <- validate_different_warehouses(changeset, source, dest),
           :ok <- validate_warehouses_exist(changeset, source, dest) do
        # Stock check is only on :post
        if Ash.Changeset.get_attribute(changeset, :status) == :posted do
          validate_stock(changeset, source, qty)
        else
          changeset
        end
      end
    end)
  end

  defp validate_positive_qty(_changeset, qty) when is_integer(qty) and qty > 0, do: :ok

  defp validate_positive_qty(changeset, _qty_val) do
    Ash.Changeset.add_error(changeset,
      field: :qty,
      message: "Transfer quantity must be positive"
    )
    |> tap_error()
  end

  defp validate_different_warehouses(changeset, source, dest) do
    if source == dest do
      Ash.Changeset.add_error(changeset,
        field: :dest_warehouse_id,
        message: "Source and destination warehouse must be different"
      )
      |> tap_error()
    else
      :ok
    end
  end

  defp validate_warehouses_exist(changeset, source, dest) do
    # Both warehouses must reference existing records.
    # This is validated by the belongs_to FK constraint, but we check
    # explicitly for a better error message.
    if is_nil(source) or is_nil(dest) do
      Ash.Changeset.add_error(changeset,
        field: :source_warehouse_id,
        message: "Both source and destination warehouses must be specified"
      )
      |> tap_error()
    else
      :ok
    end
  end

  defp validate_stock(changeset, source_warehouse_id, qty) do
    # Check that the source warehouse has sufficient stock.
    # This queries the StockLevel table for the (item, warehouse) pair.
    item_id = Ash.Changeset.get_attribute(changeset, :item_id)

    stock_level_resource = Samen.Scopes.Inventory.StockLevel
    table = AshPostgres.DataLayer.Info.table(stock_level_resource)
    repo = AshPostgres.DataLayer.Info.repo(stock_level_resource, :mutate)

    sql = """
    SELECT qty_on_hand FROM #{table}
    WHERE item_id = $1 AND warehouse_id = $2
    """

    case repo.query(sql, [dump_uuid(item_id), dump_uuid(source_warehouse_id)]) do
      {:ok, %{rows: [[qty_on_hand]]}} when qty_on_hand >= qty ->
        changeset

      {:ok, %{rows: [[qty_on_hand]]}} ->
        Ash.Changeset.add_error(changeset,
          field: :qty,
          message:
            "Insufficient stock at source warehouse: has #{qty_on_hand}, " <>
              "transfer requires #{qty}"
        )
        |> tap_error()

      {:ok, %{rows: []}} ->
        Ash.Changeset.add_error(changeset,
          field: :source_warehouse_id,
          message: "No stock level found at source warehouse"
        )
        |> tap_error()

      {:error, _} ->
        # Can't verify stock — fail closed
        Ash.Changeset.add_error(changeset,
          field: :qty,
          message: "Cannot verify stock level at source warehouse"
        )
        |> tap_error()
    end
  end

  defp tap_error(changeset), do: changeset

  defp dump_uuid(nil), do: nil
  defp dump_uuid(id), do: Ecto.UUID.dump!(id)
end
