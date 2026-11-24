defmodule Samenerp.LogisticsWalkthroughTest do
  @moduledoc """
  WS-LOG L1.2 HOST PROOF: the `Samenerp.Erp` logistics mount ships ONE sales
  order in two partials. Each shipment posts its own stock event and COGS
  entry, emits a REAL `Samenerp.Billing.Invoice`, and advances the host's
  SalesOrder `confirmed → partially_fulfilled → fulfilled`.

  This is the walkthrough the build plan names; the detailed refusal and
  reconciliation matrices live in `samen_core`'s shipment suite.
  """

  use Samenerp.DataCase, async: false

  require Ash.Query

  alias Samenerp.Billing.{Customer, Invoice}

  alias Samenerp.Erp.{
    Account,
    Item,
    JournalEntry,
    PostingAccount,
    SalesOrder,
    Shipment,
    ShipmentLine,
    SoLine,
    StockLedger,
    StockLevel,
    Warehouse
  }

  setup do
    org = Ecto.UUID.generate()

    {:ok, org: org, scope: scope(org, "u", :member), admin: scope(org, "a", :admin)}
  end

  test "an order ships in two partials and emits the host's invoices", %{
    org: org,
    scope: scope,
    admin: admin
  } do
    for {key, code, kind, side} <- [
          {:ar_clearing, "1200", :asset, :debit},
          {:income, "4000", :income, :credit},
          {:cogs, "5000", :expense, :debit}
        ] do
      account = create_account!(admin, org, code, kind, side)

      PostingAccount
      |> Ash.Changeset.for_create(:create, %{org_id: org, key: key, account_id: account.id})
      |> Ash.create!(scope: admin, authorize?: true)
    end

    inventory_account = create_account!(admin, org, "1300", :asset, :debit)

    item =
      Item
      |> Ash.Changeset.for_create(:create, %{
        org_id: org,
        sku: "WALK-ITEM",
        name: "Walkthrough item",
        kind: :stocked,
        uom: :unit,
        default_inventory_account_id: inventory_account.id
      })
      |> Ash.create!(scope: scope, authorize?: true)

    warehouse =
      Warehouse
      |> Ash.Changeset.for_create(:create, %{org_id: org, code: "WALK-WH", name: "Walkthrough"})
      |> Ash.create!(scope: scope, authorize?: true)

    StockLedger
    |> Ash.Changeset.for_create(:record, %{
      org_id: org,
      item_id: item.id,
      warehouse_id: warehouse.id,
      kind: :receipt,
      qty: 10,
      unit_cost_cents: 1_000
    })
    |> Ash.create!(scope: scope, authorize?: true)

    customer =
      Customer
      |> Ash.Changeset.for_create(:create, %{org_id: org, currency: "USD"})
      |> Ash.create!(scope: scope, authorize?: true)

    so =
      SalesOrder
      |> Ash.Changeset.for_create(:create, %{
        org_id: org,
        customer_id: customer.id,
        number: "SO-WALK-1",
        order_date: ~D[2026-11-23],
        warehouse_id: warehouse.id,
        lines: [%{item_id: item.id, qty: 5, unit_price_cents: 4_000}]
      })
      |> Ash.create!(scope: scope, authorize?: true)
      |> Ash.Changeset.for_update(:confirm, %{}, scope: scope)
      |> Ash.update!()

    so_line = so_line!(scope, so.id)

    first = shipment!(scope, org, so, warehouse, "SHP-WALK-1")
    shipment_line!(scope, org, first, so_line, 2)

    shipped1 = ship!(first, scope)

    assert shipped1.status == :shipped
    assert shipped1.invoice_key == "billing_invoice"
    refute is_nil(shipped1.invoice_id)
    refute is_nil(shipped1.shipped_at)

    assert Ash.get!(SalesOrder, so.id, scope: scope, authorize?: true).status ==
             :partially_fulfilled

    invoice1 = invoice!(scope, shipped1.invoice_id)
    assert invoice1.status == :open
    assert invoice1.amount_due_cents == 8_000

    assert [line1] =
             ShipmentLine
             |> Ash.Query.filter(shipment_id == ^first.id)
             |> Ash.read!(scope: scope, authorize?: true)

    assert line1.unit_cost_cents == 1_000

    assert [event1] =
             StockLedger
             |> Ash.Query.filter(source_key == "shipment" and source_id == ^first.id)
             |> Ash.read!(scope: scope, authorize?: true)

    assert event1.qty == -2

    assert [_cogs1] =
             JournalEntry
             |> Ash.Query.filter(source_key == "shipment" and source_id == ^first.id)
             |> Ash.read!(scope: scope, authorize?: true)

    assert level!(scope, item, warehouse).qty_on_hand == 8

    average_before_second = level!(scope, item, warehouse).avg_unit_cost_cents
    assert is_integer(average_before_second)

    second = shipment!(scope, org, so, warehouse, "SHP-WALK-2")
    shipment_line!(scope, org, second, so_line, 3)

    shipped2 = ship!(second, scope)

    assert shipped2.status == :shipped
    assert Ash.get!(SalesOrder, so.id, scope: scope, authorize?: true).status == :fulfilled

    invoice2 = invoice!(scope, shipped2.invoice_id)
    assert invoice2.status == :open
    assert invoice2.amount_due_cents == 12_000

    assert [line2] =
             ShipmentLine
             |> Ash.Query.filter(shipment_id == ^second.id)
             |> Ash.read!(scope: scope, authorize?: true)

    assert line2.unit_cost_cents == average_before_second

    assert [event2] =
             StockLedger
             |> Ash.Query.filter(source_key == "shipment" and source_id == ^second.id)
             |> Ash.read!(scope: scope, authorize?: true)

    assert event2.qty == -3

    assert [_cogs2] =
             JournalEntry
             |> Ash.Query.filter(source_key == "shipment" and source_id == ^second.id)
             |> Ash.read!(scope: scope, authorize?: true)

    assert level!(scope, item, warehouse).qty_on_hand == 5

    invoices =
      Invoice
      |> Ash.Query.filter(org_id == ^org)
      |> Ash.read!(scope: scope, authorize?: true)

    assert length(invoices) == 2
    assert Enum.sort(Enum.map(invoices, & &1.amount_due_cents)) == [8_000, 12_000]
  end

  defp shipment!(scope, org, so, warehouse, number) do
    Shipment
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        number: number,
        sales_order_id: so.id,
        warehouse_id: warehouse.id
      },
      scope: scope
    )
    |> Ash.create!(scope: scope, authorize?: true)
  end

  defp shipment_line!(scope, org, shipment, so_line, qty) do
    ShipmentLine
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        shipment_id: shipment.id,
        so_line_id: so_line.id,
        item_id: so_line.item_id,
        qty: qty,
        unit_price_cents: so_line.unit_price_cents
      },
      scope: scope
    )
    |> Ash.create!(scope: scope, authorize?: true)
  end

  defp ship!(shipment, scope) do
    shipment
    |> Ash.Changeset.for_update(:ship, %{}, scope: scope)
    |> Ash.update!()
  end

  defp so_line!(scope, sales_order_id) do
    SoLine
    |> Ash.Query.filter(sales_order_id == ^sales_order_id)
    |> Ash.read_one!(scope: scope, authorize?: true)
  end

  defp invoice!(scope, id) do
    Ash.get!(Invoice, id, scope: scope, authorize?: true)
  end

  defp level!(scope, item, warehouse) do
    StockLevel
    |> Ash.Query.filter(item_id == ^item.id and warehouse_id == ^warehouse.id)
    |> Ash.read_one!(scope: scope, authorize?: true)
  end

  defp create_account!(scope, org, code, kind, side) do
    Account
    |> Ash.Changeset.for_create(:create, %{
      org_id: org,
      code: code,
      name: "Account #{code}",
      kind: kind,
      normal_side: side
    })
    |> Ash.create!(scope: scope, authorize?: true)
  end

  defp scope(org, prefix, role) do
    %Samen.Scope{
      actor: %{id: "#{prefix}:#{org}", org_id: org, role: role, kind: :tenant, plane: :tenant}
    }
  end
end
