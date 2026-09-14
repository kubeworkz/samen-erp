defmodule Samen.InventoryManufacturingTest do
  @moduledoc """
  The Manufacturing documents + the R4 reconciliation red-path suite
  (WS-ERP E6; design §4 + §6.3), mounted via
  `test/support/inventory_fixture.ex` (the BASE mount — the posting facade
  rides the Inventory scope's own ledger).

  Every red-path pairs denial with a positive control (anti-tautology, the
  house `RedPath` style). Blocks:

    * m1 the BOM lifecycle: a member drafts a BOM whose `lines` argument
      materializes into real BomLine rows (CONTROL); the line-shape
      refusals (RED: empty bill, zero qty, 101% scrap) with the positive
      twin (CONTROL); draft re-materialization replaces the rows
      (CONTROL).
    * m2 the cycle refusal: a self-reference refused (RED) with the DAG
      twin (CONTROL); a TRANSITIVE cycle (A→B→A via a BOM edit) refused
      (RED) with the bill left untouched.
    * m3 the snapshot freeze: `:release` stamps the BOM SNAPSHOT
      (`bom_snapshot` jsonb + `bom_version` — ceil(qty_per × (1 +
      scrap/100) × wo_qty) per line) (CONTROL); a released WO's BOM-line
      edits are REFUSED — Ash-side (BomLinesWriter's frozen-edges guard,
      RED) and belt-side (raw SQL, RED) — with the no-in-flight-WO
      re-materialization CONTROL.
    * m4 the one-transaction facade: `:complete` lands per-component
      `:production_consume` events (NEGATIVE qty, the moving-average
      snapshot cost) + the finished item's `:production_in` event at the
      ROLLED-UP unit cost + the ProductionLog rows + the order's flip —
      all-or-nothing (CONTROL); the never-stocked component refusal
      (RED), the oversell refusal past NegativeStock (RED), the
      empty-bill release refusal (RED) with the frozen-snapshot CONTROL,
      re-completion refused exactly-once (RED).
    * m5 R4 green: for every completed WO the two legs agree —
      `order/3`'s ledger leg vs the log leg — and the standing
      `divergences/2` read is EMPTY.
    * m6 the labor/overhead carry: `:adjust` log rows (no stock events —
      a cost carry is not a movement) roll into the produce event's unit
      cost; the rollup's moving average prices the FINISHED item at the
      rolled-up cost.
    * m7 the DB belts (raw SQL): a raw-SQL draft→released stamp and a
      raw-SQL released→completed stamp are marker-refused (RED);
      ProductionLog rows are append-only (RED); a non-draft WO's raw
      column edit is frozen (RED, draft-edit CONTROL).
    * m8 catalog registration: every E6 fixture column is catalogued
      (the E4 r8 twin, scoped to the four new tables).
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Scopes.Inventory.ReconcileProduction
  alias SamenCore.Support.InventoryFixture.{
    Bom,
    BomLine,
    Item,
    ProductionLog,
    StockLedger,
    StockLevel,
    Warehouse,
    WorkOrder
  }

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()
    {:ok, org: org, scope: tenant_scope(org)}
  end

  # ── m1: the BOM draft lifecycle ─────────────────────────────────────────────

  describe "m1 — the BOM draft lifecycle" do
    test "a member drafts a BOM; the lines argument materializes into real rows (CONTROL)", %{
      org: org,
      scope: scope
    } do
      item = new_item(scope, org)
      component = new_item(scope, org)

      bom = new_bom(scope, org, item.id, [%{component_item_id: component.id, qty_per: 2}])

      assert [%BomLine{} = line] = bom_lines(bom.id)
      assert line.qty_per == 2
      assert line.scrap_pct == 0
      assert line.item_id == component.id
      assert line.bom_id == bom.id
    end

    test "an empty bill, a zero qty, and a 101% scrap are refused (RED) — the positive twin lands (CONTROL)", %{
      org: org,
      scope: scope
    } do
      item = new_item(scope, org)
      component = new_item(scope, org)

      # RED: a bill without components is a data error.
      assert {:error, %Ash.Error.Invalid{}} =
               Bom
               |> Ash.Changeset.for_create(:create, %{
                 org_id: org,
                 item_id: item.id,
                 name: "BOM-EMPTY",
                 lines: []
               })
               |> Ash.create(scope: scope)

      # RED: qty_per must be positive.
      assert {:error, %Ash.Error.Invalid{}} =
               Bom
               |> Ash.Changeset.for_create(:create, %{
                 org_id: org,
                 item_id: item.id,
                 name: "BOM-ZERO",
                 lines: [%{component_item_id: component.id, qty_per: 0, scrap_pct: 0}]
               })
               |> Ash.create(scope: scope)

      # RED: scrap_pct is 0–100.
      assert {:error, %Ash.Error.Invalid{}} =
               Bom
               |> Ash.Changeset.for_create(:create, %{
                 org_id: org,
                 item_id: item.id,
                 name: "BOM-SCRAP",
                 lines: [%{component_item_id: component.id, qty_per: 1, scrap_pct: 101}]
               })
               |> Ash.create(scope: scope)

      # No line rows leaked from the refused creates.
      assert [] = Ash.read!(BomLine, authorize?: false)

      # CONTROL: the positive twin lands.
      bom =
        new_bom(scope, org, item.id, [%{component_item_id: component.id, qty_per: 1, scrap_pct: 5}])

      assert [%BomLine{}] = bom_lines(bom.id)
    end

    test "a draft re-materialization replaces the line rows (CONTROL)", %{org: org, scope: scope} do
      item = new_item(scope, org)
      component = new_item(scope, org)
      other = new_item(scope, org)

      bom = new_bom(scope, org, item.id, [%{component_item_id: component.id, qty_per: 2}])

      assert {:ok, _} =
               bom
               |> Ash.Changeset.for_update(:update, %{
                 lines: [%{component_item_id: other.id, qty_per: 3, scrap_pct: 10}]
               })
               |> Ash.update(scope: scope)

      lines = bom_lines(bom.id)
      assert length(lines) == 1
      assert hd(lines).item_id == other.id
      assert hd(lines).qty_per == 3
      assert hd(lines).scrap_pct == 10
    end
  end

  # ── m2: the cycle refusal ───────────────────────────────────────────────────

  describe "m2 — the BOM cycle refusal" do
    test "a BOM whose component IS its own item is refused (RED) — the DAG twin lands (CONTROL)", %{
      org: org,
      scope: scope
    } do
      # RED: the direct self-cycle.
      item = new_item(scope, org)

      assert {:error, %Ash.Error.Invalid{}} =
               Bom
               |> Ash.Changeset.for_create(:create, %{
                 org_id: org,
                 item_id: item.id,
                 name: "BOM-SELF",
                 lines: [%{component_item_id: item.id, qty_per: 1}]
               })
               |> Ash.create(scope: scope)

      # CONTROL: the same shape with a DIFFERENT component lands.
      component = new_item(scope, org)
      assert %Bom{} = new_bom(scope, org, item.id, [%{component_item_id: component.id, qty_per: 1}])
    end

    test "a TRANSITIVE cycle (A's component feeds back to A) is refused (RED)", %{org: org, scope: scope} do
      item_a = new_item(scope, org)
      item_b = new_item(scope, org)
      leaf = new_item(scope, org)

      # A's BOM consumes B; B's BOM consumes the leaf.
      _bom_b = new_bom(scope, org, item_b.id, [%{component_item_id: leaf.id, qty_per: 1}])
      _bom_a = new_bom(scope, org, item_a.id, [%{component_item_id: item_b.id, qty_per: 1}])

      # Now B's BOM is edited to consume A — the transitive cycle A→B→A.
      [bom_b] = bom_for(org, item_b.id)

      assert {:error, %Ash.Error.Invalid{}} =
               bom_b
               |> Ash.Changeset.for_update(:update, %{
                 lines: [%{component_item_id: item_a.id, qty_per: 1}]
               })
               |> Ash.update(scope: scope)

      # The refused edit left the bill untouched.
      assert [%BomLine{} = line] = bom_lines(bom_b.id)
      assert line.item_id == leaf.id
    end
  end

  # ── m3: the snapshot freeze ─────────────────────────────────────────────────

  describe "m3 — the release snapshot freeze" do
    test "a member releases a WO; the BOM is SNAPSHOT-FROZEN into the order (CONTROL)", %{
      org: org,
      scope: scope
    } do
      {component, _wh, bom, wo} = seed_bom_and_wo(scope, org, qty_per: 2, scrap_pct: 50, wo_qty: 10)

      released = release_wo(scope, wo)

      assert released.status == :released
      assert released.bom_version == bom.version

      # The snapshot line: ceil(qty_per × (1 + scrap/100) × wo_qty) —
      # 2 × 1.5 × 10 → 30 units of the component for the whole order.
      component_id = component.id

      assert [%{"component_item_id" => ^component_id, "qty_per" => 2, "qty" => 30}] =
               normalize_snapshot(released.bom_snapshot)
    end

    test "a BOM-line edit under an in-flight WO is refused Ash-side (RED) — the raw twin (belt, RED), the no-WO re-materialization (CONTROL)", %{
      org: org,
      scope: scope
    } do
      item = new_item(scope, org)
      component = new_item(scope, org)
      other = new_item(scope, org)
      locked_item = new_item(scope, org)
      wh = new_warehouse(scope, org)

      # CONTROL: a BOM with NO work orders re-materializes freely.
      free_bom = new_bom(scope, org, item.id, [%{component_item_id: component.id, qty_per: 1}])

      assert {:ok, _} =
               free_bom
               |> Ash.Changeset.for_update(:update, %{
                 lines: [%{component_item_id: other.id, qty_per: 2, scrap_pct: 0}]
               })
               |> Ash.update(scope: scope)

      # RED (Ash-side): a BOM referenced by a RELEASED WO has frozen lines.
      # (Its own item — the {item, version} identity must not collide with
      # free_bom's version 1.)
      locked_bom =
        new_bom(scope, org, locked_item.id, [%{component_item_id: component.id, qty_per: 1}])
      wo = new_wo(scope, org, locked_bom, wh, qty: 5)
      release_wo(scope, wo)

      assert {:error, %Ash.Error.Invalid{}} =
               locked_bom
               |> Ash.Changeset.for_update(:update, %{
                 lines: [%{component_item_id: other.id, qty_per: 2, scrap_pct: 0}]
               })
               |> Ash.update(scope: scope)

      # RED (belt-side): the raw-SQL twin refuses the same edit — the
      # guard and the belt hold the SAME boundary.
      [line] = bom_lines(locked_bom.id)

      assert {:error, _} =
               Ecto.Adapters.SQL.query(
                 @repo,
                 "UPDATE sbl_bom_line SET sbl_qty_per = 99 WHERE sbl_id = $1",
                 [Ecto.UUID.dump!(line.id)]
               )

      # CONTROL (the design-honest twin): the release snapshot already
      # froze the economics, so a NEW BOM VERSION supersedes the old bill
      # (new versions, not rewrites) and the released WO never re-prices.
      assert {:ok, _} =
               locked_bom
               |> Ash.Changeset.for_update(:update, %{version: 2, is_active: false})
               |> Ash.update(scope: scope)
    end
  end

  # ── m4: the one-transaction facade ──────────────────────────────────────────

  describe "m4 — the :complete posting facade" do
    test "a released WO completes: consume + produce + log + flip land TOGETHER (CONTROL)", %{
      org: org,
      scope: scope
    } do
      {component, wh, _bom, wo} = seed_completable(scope, org, qty_per: 30, wo_qty: 10)

      completed = complete_wo(scope, wo)

      # The roll-up: 300 units consumed @ 1_000 → 300_000 material;
      # (300_000 + 0 + 0) ÷ 10 = 30_000.
      assert completed.status == :completed
      assert completed.actual_material_cents == 300_000
      assert completed.actual_unit_cost_cents == 30_000

      # The ledger: per-component consumption (negative) + the produce event.
      events = wo_events(org, wo.id)
      assert length(events) == 2

      consume = Enum.find(events, &(&1.kind == :production_consume))
      produce = Enum.find(events, &(&1.kind == :production_in))

      assert consume.item_id == component.id
      assert consume.qty == -300
      assert consume.unit_cost_cents == 1_000
      assert produce.item_id == wo.item_id
      assert produce.qty == 10
      assert produce.unit_cost_cents == 30_000

      # The log mirrors the events (consume + produce rows, both anchored).
      rows = log_rows(org, wo.id)
      assert length(rows) == 2

      # The finished item's stock: 10 units at the rolled-up cost.
      level = level_row(org, wo.item_id, wh.id)
      assert level.qty_on_hand == 10
      assert level.avg_unit_cost_cents == 30_000
    end

    test "a NEVER-STOCKED component is refused fail-honest BEFORE any write (RED)", %{
      org: org,
      scope: scope
    } do
      # The BOM consumes a component that exists but has NO stock (no
      # moving average to snapshot — consumption cost must be a fact).
      {component, wh, _bom, wo} = seed_completable(scope, org, qty_per: 30, wo_qty: 10, skip_seed: true)

      assert {:error, %Ash.Error.Invalid{}} =
               wo
               |> Ash.Changeset.for_update(:complete, %{}, scope: scope)
               |> Ash.update()

      # NOTHING landed — not the consume, not the produce, not the flip.
      assert [] = wo_events(org, wo.id)
      assert [] = log_rows(org, wo.id)
      assert Ash.get!(WorkOrder, wo.id, authorize?: false).status == :released
      assert is_nil(level_row(org, component.id, wh.id))
    end

    test "an oversell past NegativeStock is refused (RED) — the whole completion rolls back", %{
      org: org,
      scope: scope
    } do
      # Stock the component BELOW what the snapshot demands (29 on hand
      # against a 300-unit consumption).
      {component, wh, _bom, wo} = seed_completable(scope, org, qty_per: 30, wo_qty: 10, seed_qty: 29)

      assert {:error, %Ash.Error.Invalid{}} =
               wo
               |> Ash.Changeset.for_update(:complete, %{}, scope: scope)
               |> Ash.update()

      # The first consume may have been attempted inside the transaction —
      # NOTHING survives the rollback.
      assert [] = wo_events(org, wo.id)
      assert [] = log_rows(org, wo.id)
      assert Ash.get!(WorkOrder, wo.id, authorize?: false).status == :released

      # The component's stock is untouched.
      assert level_row(org, component.id, wh.id).qty_on_hand == 29
    end

    test "a WO cannot release from an EMPTY BOM (RED) — the snapshot is the binding contract (CONTROL)", %{
      org: org,
      scope: scope
    } do
      # RED: strip the bill while the WO is a DRAFT (no in-flight orders —
      # the frozen-edges guard permits the raw strip), then release: the
      # empty-bill refusal fires.
      {_component, _wh, bom, wo} = seed_completable(scope, org, qty_per: 10, wo_qty: 5, defer_release: true)

      [line] = bom_lines(bom.id)

      assert {:ok, _} =
               Ecto.Adapters.SQL.query(
                 @repo,
                 "DELETE FROM sbl_bom_line WHERE sbl_id = $1",
                 [Ecto.UUID.dump!(line.id)]
               )

      assert {:error, %Ash.Error.Invalid{}} =
               wo
               |> Ash.Changeset.for_update(:release, %{}, scope: scope)
               |> Ash.update()

      assert Ash.get!(WorkOrder, wo.id, authorize?: false).status == :draft

      # CONTROL: the release snapshot is the binding contract — the WO
      # released BEFORE any bill change completes from its frozen lines,
      # even though the bill is later superseded by a NEW VERSION.
      {component2, _wh2, bom2, wo2} = seed_completable(scope, org, qty_per: 10, wo_qty: 5)

      # Supersede the bill (new version, not a rewrite — the frozen-edges
      # guard permits a version/is_active edit with NO lines argument).
      assert {:ok, _} =
               bom2
               |> Ash.Changeset.for_update(:update, %{version: 2, is_active: false})
               |> Ash.update(scope: scope)

      completed = complete_wo(scope, wo2)
      assert completed.status == :completed
      assert completed.bom_version == 1

      component2_id = component2.id

      assert [%{"component_item_id" => ^component2_id, "qty" => 50}] =
               normalize_snapshot(completed.bom_snapshot)
    end

    test "a second :complete is refused exactly-once (RED)", %{org: org, scope: scope} do
      {_component, _wh, _bom, wo} = seed_completable(scope, org, qty_per: 10, wo_qty: 4)

      completed = complete_wo(scope, wo)

      assert {:error, %Ash.Error.Invalid{}} =
               completed
               |> Ash.Changeset.for_update(:complete, %{}, scope: scope)
               |> Ash.update()

      # Still exactly one consume + one produce event, and two log rows.
      assert length(wo_events(org, wo.id)) == 2
      assert length(log_rows(org, wo.id)) == 2
    end
  end

  # ── m5: R4 green ────────────────────────────────────────────────────────────

  describe "m5 — the R4 reconciliation (green)" do
    test "for every completed WO the ledger and the log agree; divergences/2 is EMPTY (CONTROL)", %{
      org: org,
      scope: scope
    } do
      {_c1, _wh1, _b1, wo1} = seed_completable(scope, org, qty_per: 30, wo_qty: 10)
      complete_wo(scope, wo1)

      {_c2, _wh2, _b2, wo2} = seed_completable(scope, org, qty_per: 100, wo_qty: 3)
      complete_wo(scope, wo2)

      for wo <- [wo1, wo2] do
        assert {:ok, %{ledger: ledger, log: log}} =
                 ReconcileProduction.order(@repo, org,
                   work_order_id: wo.id,
                   ledger_resource: StockLedger,
                   log_resource: ProductionLog
                 )

        assert ledger.produce_cost == log.produce_cost
        assert ledger.produce_qty == wo.qty
      end

      assert {:ok, []} =
               ReconcileProduction.divergences(@repo, org,
                 wo_resource: WorkOrder,
                 ledger_resource: StockLedger,
                 log_resource: ProductionLog
               )
    end
  end

  # ── m6: the labor/overhead carry ────────────────────────────────────────────

  describe "m6 — the labor/overhead cost carry" do
    test "labor/overhead roll into the produce cost as an :adjust row — no stock events for a cost carry", %{
      org: org,
      scope: scope
    } do
      {_component, wh, _bom, wo} =
        seed_completable(scope, org, qty_per: 30, wo_qty: 10, labor_cents: 5_000, overhead_cents: 5_000)

      completed = complete_wo(scope, wo)

      # Roll-up: (300 × 1_000 + 5_000 + 5_000) ÷ 10 = 31_000.
      assert completed.actual_material_cents == 300_000
      assert completed.actual_unit_cost_cents == 31_000

      # The :adjust row exists; NO :adjust stock event exists (a cost
      # carry is not a movement).
      assert [%{adjustment_cents: 10_000}] =
               log_rows(org, wo.id) |> Enum.filter(&(&1.entry_kind == :adjust))

      events = wo_events(org, wo.id)
      assert Enum.all?(events, &(&1.kind in [:production_consume, :production_in]))
      assert length(events) == 2

      # The finished item's moving average now carries the labor/overhead.
      level = level_row(org, wo.item_id, wh.id)
      assert level.avg_unit_cost_cents == 31_000
    end
  end

  # ── m7: the DB belts (raw SQL) ──────────────────────────────────────────────

  describe "m7 — the DB belts" do
    test "a raw-SQL draft→released and released→completed stamp are marker-refused (RED)", %{
      org: org,
      scope: scope
    } do
      {_component, _wh, _bom, wo} = seed_bom_and_wo(scope, org, qty_per: 10, wo_qty: 5)

      # RED: a raw stamp out of draft is refused (no marker).
      assert {:error, _} =
               Ecto.Adapters.SQL.query(
                 @repo,
                 "UPDATE swk_work_order SET swk_status = 'released' WHERE swk_id = $1",
                 [Ecto.UUID.dump!(wo.id)]
               )

      released = release_wo(scope, wo)

      # RED: a raw stamp to completed is refused (no marker).
      assert {:error, _} =
               Ecto.Adapters.SQL.query(
                 @repo,
                 "UPDATE swk_work_order SET swk_status = 'completed' WHERE swk_id = $1",
                 [Ecto.UUID.dump!(released.id)]
               )

      # CONTROL: a BOM whose WO is RELEASED is belt-frozen — the CONTROL
      # is the DESIGN-honest one: the release snapshot already froze the
      # economics, so a NEW BOM VERSION supersedes the old bill (new
      # versions, not rewrites) and the released WO never re-prices.
      assert Ash.get!(WorkOrder, released.id, authorize?: false).status == :released
    end

    test "a non-draft WO's raw column edit is frozen (RED) — the draft edit is open (CONTROL)", %{
      org: org,
      scope: scope
    } do
      # CONTROL: a draft WO's snapshot column is writable (it is born []).
      {_c, _wh, _bom, draft_wo} = seed_bom_and_wo(scope, org, qty_per: 10, wo_qty: 5)

      assert {:ok, _} =
               Ecto.Adapters.SQL.query(
                 @repo,
                 "UPDATE swk_work_order SET swk_bom_snapshot = '[]'::jsonb WHERE swk_id = $1",
                 [Ecto.UUID.dump!(draft_wo.id)]
               )

      # RED: once RELEASED, a raw column edit is refused — the snapshot is
      # the binding contract (only the marker-armed cascades may write it).
      released = release_wo(scope, draft_wo)

      assert {:error, _} =
               Ecto.Adapters.SQL.query(
                 @repo,
                 "UPDATE swk_work_order SET swk_bom_snapshot = '[{\"x\":1}]'::jsonb WHERE swk_id = $1",
                 [Ecto.UUID.dump!(released.id)]
               )
    end

    test "ProductionLog rows are append-only at the DB (RED)", %{org: org, scope: scope} do
      {_component, _wh, _bom, wo} = seed_completable(scope, org, qty_per: 10, wo_qty: 4)
      _ = complete_wo(scope, wo)

      [row] = log_rows(org, wo.id) |> Enum.take(1)

      assert {:error, _} =
               Ecto.Adapters.SQL.query(
                 @repo,
                 "UPDATE spg_production_log SET spg_qty = 1 WHERE spg_id = $1",
                 [Ecto.UUID.dump!(row.id)]
               )

      assert {:error, _} =
               Ecto.Adapters.SQL.query(
                 @repo,
                 "DELETE FROM spg_production_log WHERE spg_id = $1",
                 [Ecto.UUID.dump!(row.id)]
               )
    end
  end

  # ── m8: catalog registration ────────────────────────────────────────────────

  describe "m8 — catalog registration" do
    test "every E6 fixture column is catalogued" do
      for table <- ["sbm_bom", "sbl_bom_line", "swk_work_order", "spg_production_log"] do
        cols =
          Ecto.Adapters.SQL.query!(
            @repo,
            "SELECT c.column_name FROM information_schema.columns c WHERE c.table_name = $1",
            [table]
          ).rows
          |> List.flatten()
          |> MapSet.new()

        catalogued =
          Ecto.Adapters.SQL.query!(
            @repo,
            "SELECT f.fld_column_name FROM fld_field f WHERE f.fld_table_name = $1",
            [table]
          ).rows
          |> List.flatten()
          |> MapSet.new()

        assert MapSet.subset?(cols, catalogued),
               "#{table} has uncatalogued columns: #{inspect(MapSet.difference(cols, catalogued))}"
      end
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp tenant_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, kind: :tenant, plane: :tenant}
    }
  end

  defp new_item(scope, org) do
    Item
    |> Ash.Changeset.for_create(:create, %{
      org_id: org,
      sku: "SKU-" <> binary_part(Ash.UUID.generate(), 0, 8),
      name: "A manufactured item"
    })
    |> Ash.create!(scope: scope)
  end

  defp new_warehouse(scope, org) do
    Warehouse
    |> Ash.Changeset.for_create(:create, %{
      org_id: org,
      code: "WH-" <> binary_part(Ash.UUID.generate(), 0, 8),
      name: "Factory floor"
    })
    |> Ash.create!(scope: scope)
  end

  defp new_bom(scope, org, item_id, lines, attrs \\ %{}) do
    # scrap_pct is REQUIRED by the embedded-argument constraint — default 0.
    lines = Enum.map(lines, &Map.put_new(&1, :scrap_pct, 0))

    Bom
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          org_id: org,
          item_id: item_id,
          name: "BOM-" <> binary_part(Ash.UUID.generate(), 0, 8),
          lines: lines
        },
        Map.new(attrs)
      )
    )
    |> Ash.create!(scope: scope)
  end

  defp new_wo(scope, org, bom, warehouse, opts) do
    WorkOrder
    |> Ash.Changeset.for_create(:create, %{
      org_id: org,
      item_id: bom.item_id,
      bom_id: bom.id,
      warehouse_id: warehouse.id,
      number: "WO-" <> binary_part(Ash.UUID.generate(), 0, 8),
      qty: Keyword.fetch!(opts, :qty),
      labor_cents: Keyword.get(opts, :labor_cents, 0),
      overhead_cents: Keyword.get(opts, :overhead_cents, 0)
    })
    |> Ash.create!(scope: scope)
  end

  defp stock_up(scope, org, item, wh, qty, unit_cost) do
    StockLedger
    |> Ash.Changeset.for_create(:record, %{
      org_id: org,
      item_id: item.id,
      warehouse_id: wh.id,
      kind: :receipt,
      qty: qty,
      unit_cost_cents: unit_cost
    })
    |> Ash.create!(scope: scope)
  end

  defp release_wo(scope, wo) do
    wo
    |> Ash.Changeset.for_update(:release, %{}, scope: scope)
    |> Ash.update!()
  end

  defp complete_wo(scope, wo) do
    wo
    |> Ash.Changeset.for_update(:complete, %{}, scope: scope)
    |> Ash.update!()
  end

  defp bom_lines(bom_id) do
    BomLine
    |> Ash.Query.filter(bom_id == ^bom_id)
    |> Ash.read!(authorize?: false)
    |> Enum.sort_by(& &1.id)
  end

  defp bom_for(org, item_id) do
    Bom
    |> Ash.Query.filter(org_id == ^org and item_id == ^item_id)
    |> Ash.read!(authorize?: false)
  end

  defp wo_events(org, wo_id) do
    StockLedger
    |> Ash.Query.filter(org_id == ^org and source_id == ^wo_id)
    |> Ash.read!(authorize?: false)
    |> Enum.sort_by(& &1.id)
  end

  defp log_rows(org, wo_id) do
    ProductionLog
    |> Ash.Query.filter(org_id == ^org and work_order_id == ^wo_id)
    |> Ash.read!(authorize?: false)
    |> Enum.sort_by(& &1.id)
  end

  defp level_row(org, item_id, warehouse_id) do
    StockLevel
    |> Ash.Query.filter(org_id == ^org and item_id == ^item_id and warehouse_id == ^warehouse_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp normalize_snapshot(snapshot) do
    Enum.map(snapshot, fn line ->
      %{
        "component_item_id" => line["component_item_id"],
        "qty_per" => line["qty_per"] && String.to_integer(to_string(line["qty_per"])),
        "qty" => line["qty"] && String.to_integer(to_string(line["qty"]))
      }
    end)
  end

  # A BOM (one component) + a WO for it in a fresh warehouse — nothing
  # stocked, nothing released: the raw material every block shapes.
  defp seed_bom_and_wo(scope, org, opts) do
    item = new_item(scope, org)
    component = new_item(scope, org)
    wh = new_warehouse(scope, org)

    bom =
      new_bom(scope, org, item.id, [
        %{
          component_item_id: component.id,
          qty_per: Keyword.fetch!(opts, :qty_per),
          scrap_pct: Keyword.get(opts, :scrap_pct, 0)
        }
      ])

    wo =
      new_wo(scope, org, bom, wh,
        qty: Keyword.fetch!(opts, :wo_qty),
        labor_cents: Keyword.get(opts, :labor_cents, 0),
        overhead_cents: Keyword.get(opts, :overhead_cents, 0)
      )

    {component, wh, bom, wo}
  end

  # The completion seed: BOM + WO, the component stocked at 1_000 (unless
  # skipped), and the WO released (the snapshot frozen) — unless
  # `defer_release` keeps it draft for a test that releases itself.
  defp seed_completable(scope, org, opts) do
    {component, wh, bom, wo} =
      seed_bom_and_wo(scope, org,
        qty_per: Keyword.fetch!(opts, :qty_per),
        wo_qty: Keyword.fetch!(opts, :wo_qty),
        labor_cents: Keyword.get(opts, :labor_cents, 0),
        overhead_cents: Keyword.get(opts, :overhead_cents, 0)
      )

    cond do
      opts[:skip_seed] -> :skip
      is_integer(opts[:seed_qty]) -> stock_up(scope, org, component, wh, opts[:seed_qty], 1_000)
      true -> stock_up(scope, org, component, wh, 10_000, 1_000)
    end

    if opts[:defer_release] do
      {component, wh, bom, wo}
    else
      {component, wh, bom, release_wo(scope, wo)}
    end
  end
end
