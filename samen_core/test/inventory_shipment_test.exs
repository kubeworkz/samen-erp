defmodule Samen.InventoryShipmentTest do
  @moduledoc """
  WS-LOG L1.2 — the partial-shipment posting chokepoint, mounted through
  `test/support/inventory_fixture.ex` with the `logistics: true` branch.

  Every red path is paired with a positive control (the house anti-tautology
  discipline):

    * s1 one order ships in two partials: each shipment lands its own stock
      events, COGS entry and invoice; the SO moves confirmed →
      partially_fulfilled → fulfilled;
    * s2 exactly-once: a second `:ship` on the same shipment is refused and
      posts nothing;
    * s3 preflight refusals before any write: over-ship, zero qty, a
      never-stocked item, an unlinked item, a warehouse mismatch and a line
      whose item disagrees with its SO line — each with its positive twin;
    * s4 the frozen moving-average cost is what COGS uses; a zero-cost
      shipment posts no COGS entry;
    * s5 the lot gate: a maintained `lot_tracked` flag with no Lot row, and
      an out-of-band Lot row with the flag still false, are both refused
      before any write; the non-lot control still ships;
    * s6 the private `:apply_shipment` transition admits only confirmed →
      partially_fulfilled and partially_fulfilled → fulfilled;
    * s7 R6 reconciles stock, shipment lines, invoice, COGS and the SO's
      open quantity, and names each half-landed/over-ship shape;
    * s8 concurrency (explicitly allowed sandbox connection): a concurrent second ship of
      the same partial shipment is refused after the first posts; two
      simultaneous shipments cannot both pass the posted-quantity check. The
      shipment-state and posted-quantity re-reads are anchored by sabotages
      438/439; this is not two-session `FOR UPDATE` contention;
    * s9 true two-session contention: committed fixtures and two unboxed
      connections under a third-session SO-row barrier; removing the shipment
      `FOR UPDATE` lock alone lets both sessions post and fails the named test.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Scopes.Inventory.{ReconcileShipment, ReconcileStock}
  alias Samen.Scopes.Inventory.ShipPosting

  alias SamenCore.Support.FinanceFixture.{
    Account,
    CostObject,
    InvoiceMirror,
    JournalEntry,
    JournalLine,
    PostingAccount
  }

  alias SamenCore.Support.InventoryFixture.{
    Item,
    Lot,
    SalesOrder,
    Shipment,
    ShipmentLine,
    SoLine,
    StockLedger,
    StockLevel,
    Warehouse
  }

  @repo SamenCore.TestRepo

  @cleanup_resources [
    JournalLine,
    JournalEntry,
    StockLevel,
    StockLedger,
    ShipmentLine,
    Shipment,
    SoLine,
    SalesOrder,
    InvoiceMirror,
    Item,
    Warehouse,
    PostingAccount,
    Account
  ]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)

    org = Ash.UUID.generate()
    scope = tenant_scope(org)

    :ok = seed_posting_accounts(org)

    {:ok, org: org, scope: scope}
  end

  # ── s1: two partials ────────────────────────────────────────────────────────

  describe "s1 — one order ships in two partials" do
    test "each partial posts its own stock, COGS and invoice; the SO progresses", %{
      org: org,
      scope: scope
    } do
      {item, warehouse} = seed_pair(scope, org)
      stock_pair(scope, org, item, warehouse, 10, 500)

      so = confirmed_so(scope, org, warehouse, item, qty: 5, price: 1_000)
      [so_line] = so_lines(so.id)

      shp1 = new_shipment(scope, org, so, warehouse, "SHP-PART-1")
      new_shipment_line(scope, org, shp1, so_line, 2)

      shipped1 = ship(shp1, scope)

      assert shipped1.status == :shipped
      assert shipped1.invoice_key == "billing_invoice"
      refute is_nil(shipped1.invoice_id)
      refute is_nil(shipped1.shipped_at)

      assert Ash.get!(SalesOrder, so.id, authorize?: false).status == :partially_fulfilled

      assert [event1] = ship_events(shp1.id)
      assert event1.qty == -2
      assert event1.unit_cost_cents == 500
      assert event1.kind == :sale
      assert event1.source_key == "shipment"
      assert event1.source_id == shp1.id

      inv1 = Ash.get!(InvoiceMirror, shipped1.invoice_id, authorize?: false)
      assert inv1.status == :open
      assert inv1.amount_due_cents == 2_000

      assert [cogs1] = shipment_entries(shp1.id)
      assert cogs1.status == :posted
      assert cogs1.source_key == "shipment"
      assert cogs1.source_id == shp1.id
      assert cogs_debit(cogs1.id) == 1_000
      assert cogs_credit(cogs1.id) == item.default_inventory_account_id

      assert {:ok, %{on_hand: 8}} =
               ReconcileStock.level(@repo, StockLedger, org, item.id, warehouse.id)

      assert Ash.get!(ShipmentLine, hd(shipment_lines(shp1.id)).id, authorize?: false).unit_cost_cents ==
               500

      shp2 = new_shipment(scope, org, so, warehouse, "SHP-PART-2")
      new_shipment_line(scope, org, shp2, so_line, 3)

      shipped2 = ship(shp2, scope)

      assert Ash.get!(SalesOrder, so.id, authorize?: false).status == :fulfilled

      assert [event2] = ship_events(shp2.id)
      assert event2.qty == -3
      # The rollup's moving average after the first sale: (10×500 − 2×500)/12.
      assert event2.unit_cost_cents == 333

      inv2 = Ash.get!(InvoiceMirror, shipped2.invoice_id, authorize?: false)
      assert inv2.amount_due_cents == 3_000

      assert [cogs2] = shipment_entries(shp2.id)
      assert cogs_debit(cogs2.id) == 999

      assert {:ok, %{on_hand: 5}} =
               ReconcileStock.level(@repo, StockLedger, org, item.id, warehouse.id)

      assert length(all_invoices(org)) == 2
    end
  end

  # ── s2: exactly-once ────────────────────────────────────────────────────────

  describe "s2 — exactly-once" do
    test "re-shipping is refused exactly-once and posts nothing new", %{
      org: org,
      scope: scope
    } do
      {item, warehouse} = seed_pair(scope, org)
      stock_pair(scope, org, item, warehouse, 10, 500)

      so = confirmed_so(scope, org, warehouse, item, qty: 2, price: 1_000)
      [so_line] = so_lines(so.id)

      shipment = new_shipment(scope, org, so, warehouse, "SHP-ONCE")
      new_shipment_line(scope, org, shipment, so_line, 2)

      _shipped = ship(shipment, scope)

      assert {:error, %Ash.Error.Invalid{}} =
               shipment
               |> Ash.Changeset.for_update(:ship, %{}, scope: scope)
               |> Ash.update()

      assert [_] = ship_events(shipment.id)
      assert [_] = all_invoices(org)
      assert [_] = shipment_entries(shipment.id)
      assert Ash.get!(SalesOrder, so.id, authorize?: false).status == :fulfilled
    end
  end

  # ── s3: preflight refusals ──────────────────────────────────────────────────

  describe "s3 — preflight refusals land nothing" do
    test "an over-shipment is refused before any write, then a valid shipment lands", %{
      org: org,
      scope: scope
    } do
      {item, warehouse} = seed_pair(scope, org)
      stock_pair(scope, org, item, warehouse, 10, 500)

      so = confirmed_so(scope, org, warehouse, item, qty: 3, price: 1_000)
      [so_line] = so_lines(so.id)

      bad = new_shipment(scope, org, so, warehouse, "SHP-OVER")
      new_shipment_line(scope, org, bad, so_line, 4)

      assert {:error, %Ash.Error.Invalid{} = error} =
               bad |> Ash.Changeset.for_update(:ship, %{}, scope: scope) |> Ash.update()

      assert inspect(error) =~ "over-ship"
      assert ship_events(bad.id) == []
      assert all_invoices(org) == []
      assert shipment_entries(bad.id) == []
      assert Ash.get!(Shipment, bad.id, authorize?: false).status == :draft
      assert Ash.get!(SalesOrder, so.id, authorize?: false).status == :confirmed

      good = new_shipment(scope, org, so, warehouse, "SHP-OK")
      new_shipment_line(scope, org, good, so_line, 3)

      assert ship(good, scope).status == :shipped
      assert Ash.get!(SalesOrder, so.id, authorize?: false).status == :fulfilled
    end

    test "a zero-qty line is refused at create", %{org: org, scope: scope} do
      {item, warehouse} = seed_pair(scope, org)
      so = confirmed_so(scope, org, warehouse, item, qty: 1, price: 900)
      [so_line] = so_lines(so.id)
      shipment = new_shipment(scope, org, so, warehouse, "SHP-ZERO")

      assert {:error, %Ash.Error.Invalid{}} =
               ShipmentLine
               |> Ash.Changeset.for_create(
                 :create,
                 %{
                   org_id: org,
                   shipment_id: shipment.id,
                   so_line_id: so_line.id,
                   item_id: item.id,
                   qty: 0,
                   unit_price_cents: 900
                 },
                 scope: scope
               )
               |> Ash.create(scope: scope)

      assert shipment_lines(shipment.id) == []
    end

    test "a never-stocked item is refused, then the same shipment lands after stock", %{
      org: org,
      scope: scope
    } do
      {item, warehouse} = seed_pair(scope, org)
      so = confirmed_so(scope, org, warehouse, item, qty: 2, price: 1_000)
      [so_line] = so_lines(so.id)

      shipment = new_shipment(scope, org, so, warehouse, "SHP-UNSTOCKED")
      new_shipment_line(scope, org, shipment, so_line, 2)

      assert {:error, %Ash.Error.Invalid{} = error} =
               shipment |> Ash.Changeset.for_update(:ship, %{}, scope: scope) |> Ash.update()

      assert inspect(error) =~ "never stocked"
      assert ship_events(shipment.id) == []
      assert all_invoices(org) == []

      stock_pair(scope, org, item, warehouse, 5, 400)

      assert ship(shipment, scope).status == :shipped
      assert [event] = ship_events(shipment.id)
      assert event.unit_cost_cents == 400
    end

    test "an unlinked item is refused, then lands after the account is set", %{
      org: org,
      scope: scope
    } do
      item = new_item(scope, org, %{default_inventory_account_id: nil})
      warehouse = new_warehouse(scope, org)
      stock_pair(scope, org, item, warehouse, 10, 500)

      so = confirmed_so(scope, org, warehouse, item, qty: 1, price: 900)
      [so_line] = so_lines(so.id)

      shipment = new_shipment(scope, org, so, warehouse, "SHP-UNLINKED")
      new_shipment_line(scope, org, shipment, so_line, 1)

      assert {:error, %Ash.Error.Invalid{} = error} =
               shipment |> Ash.Changeset.for_update(:ship, %{}, scope: scope) |> Ash.update()

      assert inspect(error) =~ "default_inventory_account_id"
      assert ship_events(shipment.id) == []
      assert all_invoices(org) == []

      item
      |> Ash.Changeset.for_update(
        :update,
        %{default_inventory_account_id: default_inventory_account(org).id},
        scope: scope
      )
      |> Ash.update!()

      assert ship(shipment, scope).status == :shipped
    end

    test "a warehouse mismatch is refused, then the SO's warehouse lands", %{
      org: org,
      scope: scope
    } do
      {item, so_warehouse} = seed_pair(scope, org)
      other_warehouse = new_warehouse(scope, org)
      stock_pair(scope, org, item, so_warehouse, 10, 500)

      so = confirmed_so(scope, org, so_warehouse, item, qty: 1, price: 900)
      [so_line] = so_lines(so.id)

      bad = new_shipment(scope, org, so, other_warehouse, "SHP-WH")
      new_shipment_line(scope, org, bad, so_line, 1)

      assert {:error, %Ash.Error.Invalid{} = error} =
               bad |> Ash.Changeset.for_update(:ship, %{}, scope: scope) |> Ash.update()

      assert inspect(error) =~ "not the SO's"
      assert ship_events(bad.id) == []
      assert Ash.get!(SalesOrder, so.id, authorize?: false).status == :confirmed

      good = new_shipment(scope, org, so, so_warehouse, "SHP-WH-OK")
      new_shipment_line(scope, org, good, so_line, 1)
      assert ship(good, scope).status == :shipped
    end

    test "a line whose item disagrees with its SO line is refused", %{
      org: org,
      scope: scope
    } do
      {item, warehouse} = seed_pair(scope, org)
      other_item = new_item(scope, org)
      stock_pair(scope, org, item, warehouse, 10, 500)
      stock_pair(scope, org, other_item, warehouse, 10, 500)

      so = confirmed_so(scope, org, warehouse, item, qty: 1, price: 900)
      [so_line] = so_lines(so.id)

      shipment = new_shipment(scope, org, so, warehouse, "SHP-MISMATCH")
      new_shipment_line(scope, org, shipment, so_line, 1, item_id: other_item.id)

      assert {:error, %Ash.Error.Invalid{} = error} =
               shipment |> Ash.Changeset.for_update(:ship, %{}, scope: scope) |> Ash.update()

      assert inspect(error) =~ "disagrees"
      assert ship_events(shipment.id) == []
      assert Ash.get!(SalesOrder, so.id, authorize?: false).status == :confirmed
    end
  end

  # ── s4: frozen cost / zero cost ─────────────────────────────────────────────

  describe "s4 — the frozen cost is the COGS cost" do
    test "a zero-cost shipment fulfills without a zero-value COGS entry", %{
      org: org,
      scope: scope
    } do
      {item, warehouse} = seed_pair(scope, org)
      stock_pair(scope, org, item, warehouse, 5, 0)

      so = confirmed_so(scope, org, warehouse, item, qty: 2, price: 1_000)
      [so_line] = so_lines(so.id)

      shipment = new_shipment(scope, org, so, warehouse, "SHP-FREE")
      new_shipment_line(scope, org, shipment, so_line, 2)

      shipped = ship(shipment, scope)

      assert [event] = ship_events(shipment.id)
      assert event.unit_cost_cents == 0

      assert Ash.get!(ShipmentLine, hd(shipment_lines(shipment.id)).id, authorize?: false).unit_cost_cents ==
               0

      inv = Ash.get!(InvoiceMirror, shipped.invoice_id, authorize?: false)
      assert inv.amount_due_cents == 2_000
      assert shipment_entries(shipment.id) == []
      assert Ash.get!(SalesOrder, so.id, authorize?: false).status == :fulfilled

      opts = reconcile_opts()

      assert {:ok, read} =
               ReconcileShipment.shipment(@repo, org, [shipment_id: shipment.id] ++ opts)

      assert read.cogs == %{
               status: :ok,
               entries: 0,
               debit_cents: 0,
               foreign_entries: 0,
               expected_cents: 0
             }

      assert read.divergences == []
      assert {:ok, []} = ReconcileShipment.divergences(@repo, org, opts)
    end
  end

  # ── s5: the lot gate ────────────────────────────────────────────────────────

  describe "s5 — the lot gate" do
    test "a Lot created after the L1 backfill cannot ship as a non-lot item", %{
      org: org,
      scope: scope
    } do
      {item, warehouse} = seed_pair(scope, org)
      stock_pair(scope, org, item, warehouse, 10, 500)

      so = confirmed_so(scope, org, warehouse, item, qty: 2, price: 1_000)
      [so_line] = so_lines(so.id)

      shipment = new_shipment(scope, org, so, warehouse, "SHP-LOT")
      new_shipment_line(scope, org, shipment, so_line, 2)

      # The out-of-band row: inserted directly, so `Lot :create`'s flag
      # maintenance never runs and the item still reads `lot_tracked: false`.
      out_of_band_lot!(org, item)
      refute Ash.get!(Item, item.id, authorize?: false).lot_tracked

      assert {:error, %Ash.Error.Invalid{} = error} =
               shipment |> Ash.Changeset.for_update(:ship, %{}, scope: scope) |> Ash.update()

      assert inspect(error) =~ "lot_tracked_requires_l1b"
      assert ship_events(shipment.id) == []
      assert all_invoices(org) == []
      assert shipment_entries(shipment.id) == []
      assert Ash.get!(SalesOrder, so.id, authorize?: false).status == :confirmed

      # The flag half: true with NO Lot row is refused too.
      {item_flagged, warehouse_flagged} = seed_pair(scope, org)
      stock_pair(scope, org, item_flagged, warehouse_flagged, 10, 500)

      item_flagged =
        item_flagged
        |> Ash.Changeset.for_update(:update, %{lot_tracked: true}, scope: scope)
        |> Ash.update!()

      assert item_flagged.lot_tracked

      assert Lot
             |> Ash.Query.filter(item_id == ^item_flagged.id)
             |> Ash.read!(authorize?: false) == []

      so_flagged = confirmed_so(scope, org, warehouse_flagged, item_flagged, qty: 2, price: 1_000)
      [so_line_flagged] = so_lines(so_flagged.id)

      shipment_flagged = new_shipment(scope, org, so_flagged, warehouse_flagged, "SHP-FLAG")
      new_shipment_line(scope, org, shipment_flagged, so_line_flagged, 2)

      assert {:error, %Ash.Error.Invalid{} = flag_error} =
               shipment_flagged
               |> Ash.Changeset.for_update(:ship, %{}, scope: scope)
               |> Ash.update()

      assert inspect(flag_error) =~ "lot_tracked_requires_l1b"
      assert ship_events(shipment_flagged.id) == []
      assert Ash.get!(SalesOrder, so_flagged.id, authorize?: false).status == :confirmed

      # The non-lot CONTROL still ships.
      {item_ctrl, warehouse_ctrl} = seed_pair(scope, org)
      stock_pair(scope, org, item_ctrl, warehouse_ctrl, 10, 500)
      so_ctrl = confirmed_so(scope, org, warehouse_ctrl, item_ctrl, qty: 2, price: 1_000)
      [so_line_ctrl] = so_lines(so_ctrl.id)

      shipment_ctrl = new_shipment(scope, org, so_ctrl, warehouse_ctrl, "SHP-CTRL")
      new_shipment_line(scope, org, shipment_ctrl, so_line_ctrl, 2)

      assert ship(shipment_ctrl, scope).status == :shipped
      assert [event] = ship_events(shipment_ctrl.id)
      assert event.qty == -2
    end
  end

  # ── s6: the internal apply_shipment transition ──────────────────────────────

  describe "s6 — :apply_shipment is a guarded internal transition" do
    test "it refuses a draft, cancelled, fulfilled or skipped target", %{org: org, scope: scope} do
      {item, warehouse} = seed_pair(scope, org)
      draft = new_so(scope, org, warehouse, item, qty: 1, price: 100)

      assert {:error, %Ash.Error.Invalid{} = draft_error} =
               draft
               |> Ash.Changeset.for_update(
                 :apply_shipment,
                 %{status: :partially_fulfilled},
                 scope: scope
               )
               |> Ash.update()

      assert inspect(draft_error) =~ "apply_shipment"
      assert Ash.get!(SalesOrder, draft.id, authorize?: false).status == :draft

      confirmed = confirm(draft, scope)

      # A direct confirmed -> fulfilled jump is not an admitted shipment step.
      assert {:error, %Ash.Error.Invalid{}} =
               confirmed
               |> Ash.Changeset.for_update(:apply_shipment, %{status: :fulfilled}, scope: scope)
               |> Ash.update()

      assert Ash.get!(SalesOrder, confirmed.id, authorize?: false).status == :confirmed

      cancelled = Ash.update!(Ash.Changeset.for_update(draft, :cancel, %{}, scope: scope))

      assert {:error, %Ash.Error.Invalid{}} =
               cancelled
               |> Ash.Changeset.for_update(
                 :apply_shipment,
                 %{status: :partially_fulfilled},
                 scope: scope
               )
               |> Ash.update()

      assert Ash.get!(SalesOrder, cancelled.id, authorize?: false).status == :cancelled
    end
  end

  # ── s7: R6 shipment reconciliation ──────────────────────────────────────────

  describe "s7 — R6 shipment reconciliation" do
    test "a shipped shipment reconciles stock, lines, invoice, COGS and the order's open qty", %{
      org: org,
      scope: scope
    } do
      {item, warehouse} = seed_pair(scope, org)
      stock_pair(scope, org, item, warehouse, 10, 500)

      so = confirmed_so(scope, org, warehouse, item, qty: 5, price: 1_000)
      [so_line] = so_lines(so.id)

      shp1 = new_shipment(scope, org, so, warehouse, "SHP-R6-1")
      new_shipment_line(scope, org, shp1, so_line, 2)
      shipped1 = ship(shp1, scope)

      opts = reconcile_opts()

      assert {:ok, read1} =
               ReconcileShipment.shipment(@repo, org, [shipment_id: shp1.id] ++ opts)

      assert read1.status == :shipped
      assert read1.stock == %{events: 1, qty: -2, value_cents: -1_000}
      assert read1.lines == %{count: 1, qty: 2, price_cents: 2_000, cost_cents: 1_000}

      assert read1.invoice == %{
               key: "billing_invoice",
               id: shipped1.invoice_id,
               exists: true,
               amount_due_cents: 2_000,
               expected_cents: 2_000
             }

      assert read1.cogs == %{
               status: :ok,
               entries: 1,
               debit_cents: 1_000,
               foreign_entries: 0,
               expected_cents: 1_000
             }

      assert read1.order == %{
               sales_order_id: so.id,
               ordered_qty: 5,
               shipped_qty: 2,
               open_qty: 3
             }

      assert read1.divergences == []
      assert {:ok, []} = ReconcileShipment.divergences(@repo, org, opts)

      shp2 = new_shipment(scope, org, so, warehouse, "SHP-R6-2")
      new_shipment_line(scope, org, shp2, so_line, 3)
      _shipped2 = ship(shp2, scope)

      assert {:ok, read2} =
               ReconcileShipment.shipment(@repo, org, [shipment_id: shp2.id] ++ opts)

      assert read2.stock == %{events: 1, qty: -3, value_cents: -999}
      assert read2.lines == %{count: 1, qty: 3, price_cents: 3_000, cost_cents: 999}
      assert read2.invoice.amount_due_cents == 3_000
      assert read2.cogs.status == :ok
      assert read2.cogs.debit_cents == 999

      assert read2.order == %{
               sales_order_id: so.id,
               ordered_qty: 5,
               shipped_qty: 5,
               open_qty: 0
             }

      assert read2.divergences == []
      assert {:ok, []} = ReconcileShipment.divergences(@repo, org, opts)
      assert Ash.get!(SalesOrder, so.id, authorize?: false).status == :fulfilled
    end

    test "R6 names stock that no shipment line explains", %{org: org, scope: scope} do
      {item, warehouse} = seed_pair(scope, org)
      stock_pair(scope, org, item, warehouse, 10, 500)

      so = confirmed_so(scope, org, warehouse, item, qty: 5, price: 1_000)
      [so_line] = so_lines(so.id)

      shipment = new_shipment(scope, org, so, warehouse, "SHP-R6-STOCK")
      new_shipment_line(scope, org, shipment, so_line, 2)
      _shipped = ship(shipment, scope)

      # A second ledger event with no shipment line behind it.
      StockLedger
      |> Ash.Changeset.for_create(:record, %{
        org_id: org,
        item_id: item.id,
        warehouse_id: warehouse.id,
        kind: :sale,
        qty: -1,
        unit_cost_cents: 500,
        source_key: "shipment",
        source_id: shipment.id
      })
      |> Ash.create!(scope: scope)

      assert {:ok, [div]} = ReconcileShipment.divergences(@repo, org, reconcile_opts())

      assert div.shipment_id == shipment.id
      assert :stock_line_count_mismatch in div.divergences
      assert :stock_line_qty_mismatch in div.divergences
      assert :stock_line_value_mismatch in div.divergences
      refute :missing_invoice in div.divergences
    end

    test "R6 names an invoice total that disagrees with the lines", %{org: org, scope: scope} do
      {item, warehouse} = seed_pair(scope, org)
      stock_pair(scope, org, item, warehouse, 10, 500)

      so = confirmed_so(scope, org, warehouse, item, qty: 5, price: 1_000)
      [so_line] = so_lines(so.id)

      shipment = new_shipment(scope, org, so, warehouse, "SHP-R6-INVOICE")
      new_shipment_line(scope, org, shipment, so_line, 2)
      shipped = ship(shipment, scope)

      raw_sql!(
        "UPDATE sim_invoice_mirror SET sim_amount_due_cents = 1 WHERE sim_id = $1",
        [Ecto.UUID.dump!(shipped.invoice_id)]
      )

      assert {:ok, [div]} = ReconcileShipment.divergences(@repo, org, reconcile_opts())

      assert div.shipment_id == shipment.id
      assert :invoice_total_mismatch in div.divergences
      assert div.invoice.amount_due_cents == 1
      assert div.invoice.expected_cents == 2_000
    end

    test "R6 names a shipment whose COGS entry was skipped", %{org: org, scope: scope} do
      {item, warehouse} = seed_pair(scope, org)
      stock_pair(scope, org, item, warehouse, 10, 500)

      so = confirmed_so(scope, org, warehouse, item, qty: 5, price: 1_000)
      [so_line] = so_lines(so.id)

      shipment = new_shipment(scope, org, so, warehouse, "SHP-R6-COGS")

      new_shipment_line(scope, org, shipment, so_line, 2)
      |> Ash.Changeset.for_update(:stamp_cost, %{unit_cost_cents: 500}, authorize?: false)
      |> Ash.update!(authorize?: false)

      assert {:ok, [_event]} =
               ShipPosting.write_stock_events(
                 StockLedger,
                 org,
                 warehouse.id,
                 "shipment",
                 shipment.id,
                 [%{item_id: item.id, qty: 2}],
                 %{item.id => 500}
               )

      assert {:ok, invoice} =
               ShipPosting.emit_invoice(
                 InvoiceMirror,
                 org,
                 so.customer_id,
                 [%{qty: 2, unit_price_cents: 1_000}],
                 nil,
                 "Shipment without COGS"
               )

      raw_sql!(
        "UPDATE sis_shipment SET sis_status = 'shipped', sis_invoice_key = 'billing_invoice', " <>
          "sis_invoice_id = $1 WHERE sis_id = $2",
        [Ecto.UUID.dump!(invoice.id), Ecto.UUID.dump!(shipment.id)]
      )

      assert {:ok, [div]} = ReconcileShipment.divergences(@repo, org, reconcile_opts())

      assert div.shipment_id == shipment.id
      assert div.cogs.status == :missing
      assert :missing_cogs in div.divergences
      refute :invoice_total_mismatch in div.divergences
      refute :stock_line_qty_mismatch in div.divergences
      refute :negative_open_qty in div.divergences
    end

    test "R6 names a negative SO open quantity after an over-shipment", %{
      org: org,
      scope: scope
    } do
      {item, warehouse} = seed_pair(scope, org)
      stock_pair(scope, org, item, warehouse, 10, 500)

      so = confirmed_so(scope, org, warehouse, item, qty: 5, price: 1_000)
      [so_line] = so_lines(so.id)

      shipment = new_shipment(scope, org, so, warehouse, "SHP-R6-OPEN")
      new_shipment_line(scope, org, shipment, so_line, 2)
      _shipped = ship(shipment, scope)

      # Bypass the remaining check: the shipment now claims six of five.
      raw_sql!(
        "UPDATE ssi_shipment_line SET ssi_qty = 6 WHERE ssi_shipment_id = $1",
        [Ecto.UUID.dump!(shipment.id)]
      )

      assert {:ok, [div]} = ReconcileShipment.divergences(@repo, org, reconcile_opts())

      assert div.shipment_id == shipment.id
      assert div.order.ordered_qty == 5
      assert div.order.shipped_qty == 6
      assert div.order.open_qty == -1
      assert :negative_open_qty in div.divergences
    end
  end

  # ── s8: concurrent ships ────────────────────────────────────────────────────

  describe "s8 — concurrent :ship calls serialize" do
    # The module setup owns the manual checkout. ship_concurrently/1 explicitly
    # allows both Tasks on that connection, so no global {:shared, _} mode can
    # leak into s9. This block is not the two-session proof; s9 below covers
    # FOR UPDATE contention and is anchored by sabotage 440.

    test "two concurrent ships of one shipment post exactly once", %{org: org, scope: scope} do
      {item, warehouse} = seed_pair(scope, org)
      stock_pair(scope, org, item, warehouse, 10, 500)

      so = confirmed_so(scope, org, warehouse, item, qty: 5, price: 1_000)
      [so_line] = so_lines(so.id)

      shipment = new_shipment(scope, org, so, warehouse, "SHP-RACE-ONE")
      new_shipment_line(scope, org, shipment, so_line, 2)

      results = ship_concurrently([{shipment, scope}, {shipment, scope}])

      assert [{:ok, shipped}] = Enum.filter(results, &match?({:ok, _}, &1))
      assert [{:error, %Ash.Error.Invalid{}}] = Enum.reject(results, &match?({:ok, _}, &1))
      assert shipped.status == :shipped

      assert [_] = ship_events(shipment.id)
      assert [_] = all_invoices(org)
      assert [_] = shipment_entries(shipment.id)
      assert Ash.get!(SalesOrder, so.id, authorize?: false).status == :partially_fulfilled

      assert {:ok, %{on_hand: 8}} =
               ReconcileStock.level(@repo, StockLedger, org, item.id, warehouse.id)
    end

    test "two concurrent shipments on one SO cannot both pass the remaining check", %{
      org: org,
      scope: scope
    } do
      {item, warehouse} = seed_pair(scope, org)
      stock_pair(scope, org, item, warehouse, 10, 500)

      so = confirmed_so(scope, org, warehouse, item, qty: 5, price: 1_000)
      [so_line] = so_lines(so.id)

      first = new_shipment(scope, org, so, warehouse, "SHP-RACE-SO-1")
      new_shipment_line(scope, org, first, so_line, 3)

      second = new_shipment(scope, org, so, warehouse, "SHP-RACE-SO-2")
      new_shipment_line(scope, org, second, so_line, 3)

      results = ship_concurrently([{first, scope}, {second, scope}])

      assert [{:ok, shipped}] = Enum.filter(results, &match?({:ok, _}, &1))
      assert [{:error, %Ash.Error.Invalid{}}] = Enum.reject(results, &match?({:ok, _}, &1))

      loser = if shipped.id == first.id, do: second, else: first

      assert Ash.get!(Shipment, loser.id, authorize?: false).status == :draft
      assert ship_events(loser.id) == []
      assert shipment_entries(loser.id) == []
      assert [_] = ship_events(shipped.id)
      assert [_] = shipment_entries(shipped.id)
      assert [_] = all_invoices(org)
      assert Ash.get!(SalesOrder, so.id, authorize?: false).status == :partially_fulfilled

      assert {:ok, %{on_hand: 7}} =
               ReconcileStock.level(@repo, StockLedger, org, item.id, warehouse.id)
    end
  end

  # ── s9: true two-session contention ────────────────────────────────────────

  describe "s9 — two-session FOR UPDATE contention" do
    setup do
      # Leave the ExUnit sandbox and use committed rows: the two :ship calls
      # must run on separate PostgreSQL sessions, not the shared sandbox
      # connection. on_exit removes every committed row this test creates,
      # bypassing the finance append-only triggers for that cleanup only.
      :ok = Ecto.Adapters.SQL.Sandbox.checkin(@repo)
      :ok = Ecto.Adapters.SQL.Sandbox.mode(@repo, :manual)
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo, sandbox: false)

      org = Ash.UUID.generate()
      scope = tenant_scope(org)

      on_exit(fn -> purge_org!(org) end)
      :ok = seed_posting_accounts(org)

      {:ok, org: org, scope: scope}
    end

    test "two sessions serialize a partial shipment and post exactly once", %{
      org: org,
      scope: scope
    } do
      {item, warehouse} = seed_pair(scope, org)
      stock_pair(scope, org, item, warehouse, 10, 500)

      so = confirmed_so(scope, org, warehouse, item, qty: 5, price: 1_000)
      [so_line] = so_lines(so.id)

      shipment = new_shipment(scope, org, so, warehouse, "SHP-TRUE-RACE")
      new_shipment_line(scope, org, shipment, so_line, 2)

      # A third session holds the SO row. With the shipment lock in place, the
      # winner blocks on this SO row while the loser blocks on the shipment row;
      # without that shipment lock, BOTH callers reach this SO row with the same
      # stale draft shipment snapshot. Releasing the SO row therefore makes the
      # lock removal observable as a second successful posting.
      so_table = table!(SalesOrder)
      so_id = source_column!(SalesOrder, :id)

      @repo.query!("BEGIN")

      %{num_rows: 1} =
        @repo.query!(
          "SELECT #{so_id} FROM #{so_table} WHERE #{so_id} = $1 FOR UPDATE",
          [Ecto.UUID.dump!(so.id)]
        )

      parent = self()

      tasks =
        Enum.map(1..2, fn _ ->
          Task.async(fn ->
            :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo, sandbox: false)
            %{rows: [[backend_pid]]} = @repo.query!("SELECT pg_backend_pid()")
            send(parent, {:ready, self(), backend_pid})

            try do
              shipment
              |> Ash.Changeset.for_update(:ship, %{}, scope: scope)
              |> Ash.update()
            after
              Ecto.Adapters.SQL.Sandbox.checkin(@repo)
            end
          end)
        end)

      task_backends =
        for _ <- tasks do
          assert_receive({:ready, _pid, backend_pid}, 5_000)
          backend_pid
        end

      try do
        wait_for_ship_waiters!(task_backends, 2)
        @repo.query!("COMMIT")

        results = Enum.map(tasks, &Task.await(&1, 20_000))

        assert [{:ok, shipped}] = Enum.filter(results, &match?({:ok, _}, &1))
        assert [{:error, %Ash.Error.Invalid{}}] = Enum.reject(results, &match?({:ok, _}, &1))
        assert shipped.status == :shipped

        assert [_] = ship_events(shipment.id)
        assert [_] = all_invoices(org)
        assert [_] = shipment_entries(shipment.id)
        assert Ash.get!(SalesOrder, so.id, authorize?: false).status == :partially_fulfilled

        assert {:ok, %{on_hand: 8}} =
                 ReconcileStock.level(@repo, StockLedger, org, item.id, warehouse.id)
      after
        Enum.each(tasks, &Task.shutdown(&1, :brutal_kill))
        _ = @repo.query("ROLLBACK")
        Ecto.Adapters.SQL.Sandbox.checkin(@repo)
      end
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp reconcile_opts do
    [
      shipment_resource: Shipment,
      shipment_line_resource: ShipmentLine,
      ledger_resource: StockLedger,
      invoice_resource: InvoiceMirror,
      entry_resource: JournalEntry,
      line_resource: JournalLine,
      so_line_resource: SoLine
    ]
  end

  defp tenant_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, kind: :tenant, plane: :tenant}
    }
  end

  defp admin_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "a:#{org_id}", org_id: org_id, role: :admin, kind: :tenant, plane: :tenant}
    }
  end

  defp new_item(scope, org, attrs \\ %{}) do
    attrs = Map.new(attrs)

    attrs =
      if Map.has_key?(attrs, :default_inventory_account_id) do
        attrs
      else
        Map.put(attrs, :default_inventory_account_id, default_inventory_account(org).id)
      end

    Item
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          org_id: org,
          sku: "SKU-" <> binary_part(Ash.UUID.generate(), 0, 8),
          name: "A stocked item"
        },
        attrs
      ),
      scope: scope
    )
    |> Ash.create!()
  end

  defp default_inventory_account(org) do
    case Account
         |> Ash.Query.filter(org_id == ^org and code == "1300")
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        Account
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org, code: "1300", name: "Inventory", kind: :asset, normal_side: :debit},
          scope: tenant_scope(org)
        )
        |> Ash.create!()

      {:ok, account} ->
        account

      {:error, reason} ->
        flunk("inventory account lookup failed: #{inspect(reason)}")
    end
  end

  defp new_warehouse(scope, org, attrs \\ %{}) do
    Warehouse
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          org_id: org,
          code: "WH-" <> binary_part(Ash.UUID.generate(), 0, 8),
          name: "Main"
        },
        Map.new(attrs)
      ),
      scope: scope
    )
    |> Ash.create!()
  end

  defp seed_pair(scope, org) do
    {new_item(scope, org), new_warehouse(scope, org)}
  end

  defp stock_pair(scope, org, item, warehouse, qty, unit_cost) do
    StockLedger
    |> Ash.Changeset.for_create(:record, %{
      org_id: org,
      item_id: item.id,
      warehouse_id: warehouse.id,
      kind: :receipt,
      qty: qty,
      unit_cost_cents: unit_cost
    })
    |> Ash.create!(scope: scope)
  end

  defp new_so(scope, org, warehouse, item, opts) do
    qty = Keyword.fetch!(opts, :qty)
    price = Keyword.fetch!(opts, :price)

    SalesOrder
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        customer_id: Ash.UUID.generate(),
        number: "SO-" <> binary_part(Ash.UUID.generate(), 0, 8),
        order_date: ~D[2026-11-23],
        warehouse_id: warehouse.id,
        lines: [%{item_id: item.id, qty: qty, unit_price_cents: price}]
      },
      scope: scope
    )
    |> Ash.create!()
  end

  defp confirmed_so(scope, org, warehouse, item, opts) do
    new_so(scope, org, warehouse, item, opts) |> confirm(scope)
  end

  defp confirm(so, scope) do
    Ash.update!(Ash.Changeset.for_update(so, :confirm, %{}, scope: scope))
  end

  defp so_lines(so_id) do
    SoLine |> Ash.Query.filter(sales_order_id == ^so_id) |> Ash.read!(authorize?: false)
  end

  defp new_shipment(scope, org, so, warehouse, number) do
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
    |> Ash.create!(scope: scope)
  end

  defp new_shipment_line(scope, org, shipment, so_line, qty, attrs \\ %{}) do
    ShipmentLine
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          org_id: org,
          shipment_id: shipment.id,
          so_line_id: so_line.id,
          item_id: so_line.item_id,
          qty: qty,
          unit_price_cents: so_line.unit_price_cents
        },
        Map.new(attrs)
      ),
      scope: scope
    )
    |> Ash.create!(scope: scope)
  end

  defp ship(shipment, scope) do
    Ash.update!(Ash.Changeset.for_update(shipment, :ship, %{}, scope: scope))
  end

  # Release both `:ship` calls together so they contend. s8 explicitly allows
  # both Tasks on this test's checked-out connection, so they serialize there.
  defp ship_concurrently(calls) do
    parent = self()
    go = make_ref()

    tasks =
      Enum.map(calls, fn {shipment, scope} ->
        Task.async(fn ->
          send(parent, {:ready, self()})

          receive do
            {:go, ^go} ->
              shipment
              |> Ash.Changeset.for_update(:ship, %{}, scope: scope)
              |> Ash.update()
          end
        end)
      end)

    Enum.each(tasks, &Ecto.Adapters.SQL.Sandbox.allow(@repo, parent, &1.pid))

    for _ <- tasks, do: assert_receive({:ready, _}, 5_000)
    Enum.each(tasks, &send(&1.pid, {:go, go}))
    Enum.map(tasks, &Task.await(&1, 15_000))
  end

  defp table!(resource), do: AshPostgres.DataLayer.Info.table(resource)

  defp source_column!(resource, attribute) do
    attr = Ash.Resource.Info.attribute(resource, attribute)
    to_string(attr.source || attr.name)
  end

  defp wait_for_ship_waiters!(task_backends, expected, attempts \\ 200) do
    placeholders = Enum.map_join(1..length(task_backends), ",", &"$#{&1}")

    %{rows: [[waiters]]} =
      @repo.query!(
        """
        SELECT count(*)
        FROM pg_stat_activity
        WHERE pid IN (#{placeholders})
          AND wait_event_type = 'Lock'
        """,
        task_backends
      )

    cond do
      waiters >= expected ->
        :ok

      attempts > 0 ->
        Process.sleep(25)
        wait_for_ship_waiters!(task_backends, expected, attempts - 1)

      true ->
        %{rows: rows} =
          @repo.query!(
            """
            SELECT pid, state, wait_event_type, wait_event, pg_blocking_pids(pid), query
            FROM pg_stat_activity
            WHERE pid IN (#{placeholders})
            """,
            task_backends
          )

        flunk("expected #{expected} blocked task sessions, saw #{waiters}: #{inspect(rows)}")
    end
  end

  defp purge_org!(org) do
    case Ecto.Adapters.SQL.Sandbox.checkout(@repo, sandbox: false) do
      :ok -> :ok
      {:already, :owner} -> :ok
      other -> flunk("cleanup could not check out: #{inspect(other)}")
    end

    try do
      # The finance fixture's posted journal lines are append-only. This is test
      # cleanup of one committed org, not a production rewrite: bypass USER
      # triggers for THIS transaction only, then commit the deletes.
      @repo.query!("BEGIN")
      @repo.query!("SET LOCAL session_replication_role = replica")

      Enum.each(@cleanup_resources, fn resource ->
        table = table!(resource)
        org_column = source_column!(resource, :org_id)

        @repo.query!(
          "DELETE FROM #{table} WHERE #{org_column} = $1",
          [Ecto.UUID.dump!(org)]
        )
      end)

      @repo.query!("COMMIT")
    rescue
      error ->
        _ = @repo.query("ROLLBACK")
        reraise error, __STACKTRACE__
    after
      Ecto.Adapters.SQL.Sandbox.checkin(@repo)
    end
  end

  defp shipment_lines(shipment_id) do
    ShipmentLine
    |> Ash.Query.filter(shipment_id == ^shipment_id)
    |> Ash.read!(authorize?: false)
  end

  defp ship_events(shipment_id) do
    StockLedger
    |> Ash.Query.filter(source_key == "shipment" and source_id == ^shipment_id)
    |> Ash.read!(authorize?: false)
    |> Enum.reverse()
  end

  defp shipment_entries(shipment_id) do
    JournalEntry
    |> Ash.Query.filter(source_key == "shipment" and source_id == ^shipment_id)
    |> Ash.read!(authorize?: false)
  end

  defp all_invoices(org) do
    InvoiceMirror |> Ash.Query.filter(org_id == ^org) |> Ash.read!(authorize?: false)
  end

  defp cogs_debit(entry_id) do
    JournalLine
    |> Ash.Query.filter(entry_id == ^entry_id and debit_cents > 0)
    |> Ash.read_one!(authorize?: false)
    |> Map.fetch!(:debit_cents)
  end

  defp cogs_credit(entry_id) do
    JournalLine
    |> Ash.Query.filter(entry_id == ^entry_id and credit_cents > 0)
    |> Ash.read_one!(authorize?: false)
    |> Map.fetch!(:account_id)
  end

  defp seed_posting_accounts(org) do
    _inventory = default_inventory_account(org)

    case PostingAccount
         |> Ash.Query.filter(org_id == ^org and key == :ar_clearing)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} ->
        for {key, code, kind, side} <- [
              {:ar_clearing, "1200", :asset, :debit},
              {:cash, "1000", :asset, :debit},
              {:income, "4000", :income, :credit},
              {:cogs, "5000", :expense, :debit}
            ] do
          account =
            Account
            |> Ash.Changeset.for_create(
              :create,
              %{
                org_id: org,
                code: code,
                name: "Account #{code}",
                kind: kind,
                normal_side: side
              },
              scope: tenant_scope(org)
            )
            |> Ash.create!()

          PostingAccount
          |> Ash.Changeset.for_create(:create, %{org_id: org, key: key, account_id: account.id},
            scope: admin_scope(org)
          )
          |> Ash.create!()
        end

        :ok

      {:ok, _row} ->
        :ok

      {:error, reason} ->
        flunk("PostingAccount seed lookup failed: #{inspect(reason)}")
    end
  end

  # A `Lot` row written directly, bypassing `Lot :create`'s flag maintenance:
  # the item's `lot_tracked` stays `false` — the out-of-band case the live
  # EXISTS check (not the maintained flag) must catch.
  defp out_of_band_lot!(org, item) do
    cost_object =
      CostObject
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org,
          code: "CO-" <> binary_part(Ash.UUID.generate(), 0, 8),
          name: "Lot cost object",
          kind: :chip
        },
        scope: admin_scope(org)
      )
      |> Ash.create!()

    raw_sql!(
      """
      INSERT INTO slt_lot
        (slt_id, slt_org_id, slt_item_id, slt_cost_object_id, slt_code,
         slt_inserted_at, slt_updated_at)
      VALUES ($1, $2, $3, $4, $5, now()::timestamp, now()::timestamp)
      """,
      [
        Ecto.UUID.bingenerate(),
        Ecto.UUID.dump!(org),
        Ecto.UUID.dump!(item.id),
        Ecto.UUID.dump!(cost_object.id),
        "LOT-" <> binary_part(Ash.UUID.generate(), 0, 8)
      ]
    )
  end

  defp raw_sql!(sql, params) do
    case Ecto.Adapters.SQL.query(@repo, sql, params) do
      {:ok, _} -> :ok
      {:error, reason} -> flunk("raw SQL unexpectedly failed: #{inspect(reason)}\n#{sql}")
    end
  end
end
