defmodule Samen.WebTest.ErpFixtures do
  @moduledoc "Shared ERP document fixtures for the web rendering tests."

  import Ecto.Query

  require Ash.Query

  @doc """
  Seeds one item, warehouse, purchase order/line, goods receipt and receipt line
  for an org. Returns `{receipt, receipt_line, po_line}`.
  """
  def seed_goods_receipt(org_id, opts \\ []) do
    suffix = binary_part(Ash.UUID.generate(), 0, 8)
    received_date = Keyword.get(opts, :received_date, ~D[2026-10-05])

    item =
      Samen.WebTest.Erp.Item
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org_id, sku: "SKU-GR-" <> suffix, name: "Receipt item"},
        authorize?: false
      )
      |> Ash.create!()

    warehouse =
      Samen.WebTest.Erp.Warehouse
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org_id, code: "WH-GR-" <> suffix, name: "Receiving"},
        authorize?: false
      )
      |> Ash.create!()

    po =
      Samen.WebTest.Erp.PurchaseOrder
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          vendor_id: Ash.UUID.generate(),
          number: "PO-GR-" <> suffix,
          order_date: ~D[2026-10-01],
          warehouse_id: warehouse.id,
          lines: [%{item_id: item.id, qty: 4, unit_cost_cents: 1_250}]
        },
        authorize?: false
      )
      |> Ash.create!()

    po_line =
      Samen.WebTest.Erp.PoLine
      |> Ash.Query.filter(purchase_order_id == ^po.id)
      |> Ash.read_one!(authorize?: false)

    receipt =
      Samen.WebTest.Erp.GoodsReceipt
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          purchase_order_id: po.id,
          warehouse_id: warehouse.id,
          number: "GR-" <> suffix,
          received_date: received_date,
          memo: "Receipt detail seed"
        },
        authorize?: false
      )
      |> Ash.create!()

    case Keyword.get(opts, :status) do
      status when status in [:draft, :posted] ->
        from(r in "igr_goods_receipt", where: r.igr_id == type(^receipt.id, Ecto.UUID))
        |> Samen.WebTest.Repo.update_all(set: [igr_status: Atom.to_string(status)])

      _other ->
        :ok
    end

    receipt_line =
      Samen.WebTest.Erp.ReceiptLine
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          goods_receipt_id: receipt.id,
          po_line_id: po_line.id,
          qty: 4,
          unit_cost_cents: 1_250
        },
        authorize?: false
      )
      |> Ash.create!()

    {receipt, receipt_line, po_line}
  end
end
