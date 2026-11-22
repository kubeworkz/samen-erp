defmodule Samenerp.LogisticsShipmentMountTest do
  @moduledoc """
  WS-LOG L1.1 on the real host mount: the opt-in `logistics:` branch creates
  and reads `Samenerp.Erp.Shipment` / `ShipmentLine`, and both resources
  refuse a same-org FK that points at another tenant.
  """

  use Samenerp.DataCase, async: false

  require Ash.Query

  alias Samenerp.Billing.Customer
  alias Samenerp.Erp.{Item, SalesOrder, Shipment, ShipmentLine, SoLine, Warehouse}

  setup do
    org = Ecto.UUID.generate()
    other_org = Ecto.UUID.generate()

    {:ok,
     org: org,
     other_org: other_org,
     scope: scope(org, "u"),
     other_scope: scope(other_org, "other")}
  end

  test "Shipment and ShipmentLine create and read on the host mount", %{
    org: org,
    scope: scope,
    other_scope: other_scope
  } do
    %{shipment: shipment, so_line: so_line, item: item} = create_shipment_fixture!(scope, org)

    assert shipment.status == :draft
    assert shipment.number == "SHP-L1-1"

    read_shipment = Ash.get!(Shipment, shipment.id, scope: scope, authorize?: true)
    assert read_shipment.sales_order_id == shipment.sales_order_id
    assert read_shipment.warehouse_id == shipment.warehouse_id
    assert read_shipment.memo == "L1.1 host shipment"

    line =
      ShipmentLine
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org,
          shipment_id: shipment.id,
          so_line_id: so_line.id,
          item_id: item.id,
          qty: 2,
          unit_price_cents: 500
        },
        scope: scope
      )
      |> Ash.create!(scope: scope, authorize?: true)

    assert line.unit_cost_cents == nil

    read_line = Ash.get!(ShipmentLine, line.id, scope: scope, authorize?: true)
    assert read_line.shipment_id == shipment.id
    assert read_line.so_line_id == so_line.id
    assert read_line.item_id == item.id
    assert read_line.qty == 2
    assert read_line.unit_price_cents == 500

    # The read policy keeps the rows inside the creating tenant.
    assert Ash.read!(Shipment, scope: other_scope, authorize?: true) == []
    assert Ash.read!(ShipmentLine, scope: other_scope, authorize?: true) == []
  end

  test "Shipment refuses a sales_order from another org", %{
    org: org,
    other_org: other_org,
    scope: scope,
    other_scope: other_scope
  } do
    warehouse = create_warehouse!(scope, org, "SHP-WH-A")
    other_item = create_item!(other_scope, other_org, "OTHER")
    other_warehouse = create_warehouse!(other_scope, other_org, "SO-OTHER-WH")

    other_so =
      create_sales_order!(other_scope, other_org, "SO-OTHER", other_item, other_warehouse)

    assert {:error, error} =
             Shipment
             |> Ash.Changeset.for_create(
               :create,
               %{
                 org_id: org,
                 number: "SHP-CROSS",
                 sales_order_id: other_so.id,
                 warehouse_id: warehouse.id
               },
               scope: scope
             )
             |> Ash.create(scope: scope, authorize?: true)

    assert inspect(error) =~ "cross-org FK"
    assert Ash.read!(Shipment, scope: scope, authorize?: true) == []
  end

  test "ShipmentLine refuses an item from another org", %{
    org: org,
    other_org: other_org,
    scope: scope,
    other_scope: other_scope
  } do
    %{shipment: shipment, so_line: so_line} = create_shipment_fixture!(scope, org)
    other_item = create_item!(other_scope, other_org, "SHP-OTHER-ITEM")

    assert {:error, error} =
             ShipmentLine
             |> Ash.Changeset.for_create(
               :create,
               %{
                 org_id: org,
                 shipment_id: shipment.id,
                 so_line_id: so_line.id,
                 item_id: other_item.id,
                 qty: 1,
                 unit_price_cents: 500
               },
               scope: scope
             )
             |> Ash.create(scope: scope, authorize?: true)

    assert inspect(error) =~ "cross-org FK"
    assert Ash.read!(ShipmentLine, scope: scope, authorize?: true) == []
  end

  defp create_shipment_fixture!(scope, org) do
    item = create_item!(scope, org, "SHP-ITEM")
    warehouse = create_warehouse!(scope, org, "SHP-WH")
    sales_order = create_sales_order!(scope, org, "SO-SHP-1", item, warehouse)
    so_line = so_line!(scope, sales_order.id)

    shipment =
      Shipment
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org,
          number: "SHP-L1-1",
          sales_order_id: sales_order.id,
          warehouse_id: warehouse.id,
          memo: "L1.1 host shipment"
        },
        scope: scope
      )
      |> Ash.create!(scope: scope, authorize?: true)

    %{shipment: shipment, sales_order: sales_order, so_line: so_line, item: item}
  end

  defp create_item!(scope, org, sku) do
    Item
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, sku: sku, name: "Shipment item #{sku}", kind: :stocked, uom: :unit},
      scope: scope
    )
    |> Ash.create!(scope: scope, authorize?: true)
  end

  defp create_warehouse!(scope, org, code) do
    Warehouse
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, code: code, name: "Shipment warehouse #{code}"},
      scope: scope
    )
    |> Ash.create!(scope: scope, authorize?: true)
  end

  defp create_sales_order!(scope, org, number, item, warehouse) do
    customer =
      Customer
      |> Ash.Changeset.for_create(:create, %{org_id: org, currency: "USD"}, scope: scope)
      |> Ash.create!(scope: scope, authorize?: true)

    SalesOrder
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        customer_id: customer.id,
        number: number,
        order_date: ~D[2026-11-22],
        warehouse_id: warehouse.id,
        lines: [%{item_id: item.id, qty: 3, unit_price_cents: 500}]
      },
      scope: scope
    )
    |> Ash.create!(scope: scope, authorize?: true)
  end

  defp so_line!(scope, sales_order_id) do
    SoLine
    |> Ash.Query.filter(sales_order_id == ^sales_order_id)
    |> Ash.read_one!(scope: scope, authorize?: true)
  end

  defp scope(org, prefix) do
    %Samen.Scope{
      actor: %{id: "#{prefix}:#{org}", org_id: org, role: :member, kind: :tenant, plane: :tenant}
    }
  end
end
