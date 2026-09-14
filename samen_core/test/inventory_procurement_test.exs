defmodule Samen.InventoryProcurementTest do
  @moduledoc """
  The Procurement documents + the R3-full/R5 reconciliation red-path suite
  (WS-ERP E4; design §3.2 + §6.3), mounted via
  `test/support/inventory_fixture.ex` with the `finance:` wiring onto the
  E1/E2 FinanceFixture modules.

  Every red-path pairs denial with a positive control (anti-tautology, the
  house `RedPath` style). Blocks:

    * r1 the PO draft lifecycle: a member drafts a PO whose `lines` argument
      materializes into real PoLine rows (CONTROL); line-shape refusals
      (RED: zero qty, negative cost) with the positive twin; draft edits
      re-materialize the lines (CONTROL).
    * r2 the PO state machine: `:approve` rides the ADR-040 Gate — ungated
      → `ApprovalRequired` (RED) with the pending row opened (CONTROL); the
      DISTINCT approver's `approve/3` lands `:approved` posting NOTHING
      (committed-not-realized: no entry, no ledger event); re-approve
      refused (RED) with the void CONTROL; a raw-SQL draft→approved
      transition is belt-refused without the marker (RED).
    * r3 the ONE-TRANSACTION chokepoint: `:receive` lands the receipt
      lines + the stock events + the POSTED inventory-asset/AP-clearing
      entry + the receipt's flip + the PO's `:received` — all-or-nothing
      (CONTROL), over-receipt refused (RED), unlinked-item refused
      fail-honest BEFORE anything writes (RED), re-receive refused
      exactly-once (RED).
    * r4 R3-full green: for every receipt the three legs agree — ledger
      Σqty/Σvalue == ReceiptLine facts == GL entry value — whole-org
      (ReconcileProcurement.divergences/2 is empty), and the E3 rollup
      still matches the ledger (R3 never regresses).
    * r5 R5 three-way match: an exact vendor bill is unflagged (CONTROL);
      an over-billed vendor bill flags beyond tolerance (RED twin of the
      green read); tolerance widens to unflag it (the documented-tolerance
      control).
    * r6 the DB belts (raw SQL): frozen PoLine edits refused once the PO
      leaves draft (RED, with the draft-edit CONTROL); a raw-SQL
      draft→received PO transition and a raw-SQL draft→posted receipt
      transition are refused without the marker; ReceiptLine
      UPDATE/DELETE refused (append-only).
    * r7 cross-org: a receipt line naming a FOREIGN org's po_line is
      refused with the same-org CONTROL; a foreign org's rows are
      invisible to the reconciliation reads.
    * r8 catalog registration: every E4 fixture column is catalogued
      (d11's E4 twin, scoped to the four new tables).
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.Reconcile
  alias Samen.Scopes.Inventory.{ReconcileProcurement, ReconcileStock, ThreeWayMatch}
  alias SamenCore.Support.FinanceFixture.{Account, ApInvoice, JournalEntry, JournalLine, PostingAccount}
  alias SamenCore.Support.InventoryFixture.{
    GoodsReceipt,
    Item,
    PoLine,
    PurchaseOrder,
    ReceiptLine,
    StockLedger,
    StockLevel,
    Warehouse
  }

  @repo SamenCore.TestRepo
  @line_resource JournalLine

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()
    {:ok, org: org, scope: tenant_scope(org)}
  end

  # ── r1: the PO draft lifecycle ──────────────────────────────────────────────

  describe "r1 — the PO draft lifecycle" do
    test "a member drafts a PO; the lines argument materializes into real rows (CONTROL)", %{
      org: org,
      scope: scope
    } do
      item = new_item(scope, org)
      warehouse = new_warehouse(scope, org)

      po =
        new_po(scope, org, warehouse.id, [
          %{item_id: item.id, qty: 10, unit_cost_cents: 2_500}
        ])

      assert po.status == :draft

      assert [%PoLine{} = line] = po_lines(po.id)
      assert line.qty == 10
      assert line.unit_cost_cents == 2_500
      assert line.item_id == item.id
    end

    test "a zero qty and a negative cost are refused (RED) — the positive twin lands (CONTROL)", %{
      org: org,
      scope: scope
    } do
      item = new_item(scope, org)
      warehouse = new_warehouse(scope, org)

      assert {:error, %Ash.Error.Invalid{}} =
               PurchaseOrder
               |> Ash.Changeset.for_create(:create, %{
                 org_id: org,
                 vendor_id: Ash.UUID.generate(),
                 number: "PO-ZERO",
                 order_date: ~D[2026-09-10],
                 warehouse_id: warehouse.id,
                 lines: [%{item_id: item.id, qty: 0, unit_cost_cents: 2_500}]
               })
               |> Ash.create(scope: scope)

      assert {:error, %Ash.Error.Invalid{}} =
               PurchaseOrder
               |> Ash.Changeset.for_create(:create, %{
                 org_id: org,
                 vendor_id: Ash.UUID.generate(),
                 number: "PO-NEG",
                 order_date: ~D[2026-09-10],
                 warehouse_id: warehouse.id,
                 lines: [%{item_id: item.id, qty: 5, unit_cost_cents: -1}]
               })
               |> Ash.create(scope: scope)

      # CONTROL: the positive twin lands.
      assert %PurchaseOrder{} =
               new_po(scope, org, warehouse.id, [
                 %{item_id: item.id, qty: 3, unit_cost_cents: 1_000}
               ])
    end

    test "a draft PO re-materializes its lines on edit (CONTROL)", %{org: org, scope: scope} do
      item_a = new_item(scope, org)
      item_b = new_item(scope, org)
      warehouse = new_warehouse(scope, org)

      po =
        new_po(scope, org, warehouse.id, [
          %{item_id: item_a.id, qty: 10, unit_cost_cents: 2_500}
        ])

      edited =
        po
        |> Ash.Changeset.for_update(:update, %{
          lines: [%{item_id: item_b.id, qty: 4, unit_cost_cents: 9_900}]
        })
        |> Ash.update!(scope: scope)

      assert [%PoLine{} = line] = po_lines(edited.id)
      assert line.item_id == item_b.id
      assert line.qty == 4
    end
  end

  # ── r2: the PO state machine (the ADR-040 Gate) ─────────────────────────────

  describe "r2 — the PO state machine (the Gate, committed-not-realized)" do
    test "ungated :approve is refused with ApprovalRequired and opens the pending row (RED + CONTROL)", %{
      org: org,
      scope: scope
    } do
      item = new_item(scope, org)
      warehouse = new_warehouse(scope, org)
      po = new_po(scope, org, warehouse.id, [%{item_id: item.id, qty: 2, unit_cost_cents: 5_000}])

      {:gated, approval_id} = gate(po, scope)

      # CONTROL: the pending approval row exists for the PO's kind.
      {:ok, row} =
        Samen.Approvals.get(approval_id, approval_resource: approval_resource(), repo: @repo)

      assert row.org_id == org
      assert row.subject_ref == "samen:spo:#{po.id}"
    end

    test "the DISTINCT approver lands :approved and the PO posts NOTHING (committed-not-realized)", %{
      org: org,
      scope: scope
    } do
      item = new_item(scope, org)
      warehouse = new_warehouse(scope, org)
      seed_posting_accounts(org)
      po = new_po(scope, org, warehouse.id, [%{item_id: item.id, qty: 2, unit_cost_cents: 5_000}])

      {:gated, approval_id} = gate(po, scope)
      {:ok, _, _} = decide(approval_id)

      approved = Ash.get!(PurchaseOrder, po.id, authorize?: false)
      assert approved.status == :approved

      # Committed-not-realized: NO journal entry movement, NO ledger events.
      assert {:ok, 0} = Reconcile.org_balance(org, @repo, line_resource: @line_resource)

      assert {:ok, []} =
               Ecto.Adapters.SQL.query(
                 @repo,
                 "SELECT 1 FROM skl_stock_ledger WHERE skl_org_id = $1",
                 [Ecto.UUID.dump!(org)]
               )
               |> then(fn {:ok, %{rows: rows}} -> {:ok, rows} end)

      assert {:ok, []} = ReconcileStock.divergences(@repo, StockLedger, StockLevel, org)
    end

    test "re-approve is refused (RED); a pre-receipt PO can still void (CONTROL)", %{
      org: org,
      scope: scope
    } do
      item = new_item(scope, org)
      warehouse = new_warehouse(scope, org)
      po = new_po(scope, org, warehouse.id, [%{item_id: item.id, qty: 2, unit_cost_cents: 5_000}])

      {:gated, approval_id} = gate(po, scope)
      {:ok, _, _} = decide(approval_id)

      # RED: a further :approve call is refused (the row carries the decision).
      assert {:error, _} =
               po
               |> Ash.Changeset.for_update(:approve, %{}, scope: scope)
               |> Ash.update(scope: scope)

      # CONTROL: a pre-receipt (approved) PO CAN void.
      assert %{status: :void} =
               Ash.get!(PurchaseOrder, po.id, authorize?: false)
               |> Ash.Changeset.for_update(:void, %{}, scope: scope)
               |> Ash.update!(scope: scope)
    end

    test "a raw-SQL draft→approved transition is belt-refused without the marker (RED)", %{
      org: org,
      scope: scope
    } do
      item = new_item(scope, org)
      warehouse = new_warehouse(scope, org)
      po = new_po(scope, org, warehouse.id, [%{item_id: item.id, qty: 2, unit_cost_cents: 5_000}])

      assert {:error, _} =
               Ecto.Adapters.SQL.query(
                 @repo,
                 "UPDATE spo_purchase_order SET spo_status = 'approved' WHERE spo_id = $1",
                 [Ecto.UUID.dump!(po.id)]
               )

      # CONTROL: the row is untouched.
      assert Ash.get!(PurchaseOrder, po.id, authorize?: false).status == :draft
    end
  end

  # ── r3: the ONE-TRANSACTION chokepoint ──────────────────────────────────────

  describe "r3 — GoodsReceipt :receive (the ONE-transaction chokepoint)" do
    test "receiving lands lines + stock events + the POSTED GL entry + the receipt flip + the PO stamp", %{
      org: org,
      scope: scope
    } do
      {item, warehouse, po, po_line} = seed_receiveable(scope, org, qty: 10, unit_cost_cents: 2_500)

      [received] = Ash.read!(GoodsReceipt, authorize?: false)

      # The receipt flipped inside :receive.
      assert received.status == :posted
      assert %DateTime{} = received.received_at

      # The PO stamped :received.
      assert po.status == :received

      # The materialized fact rows.
      assert [%ReceiptLine{} = rl] = receipt_lines(received.id)
      assert rl.qty == 10
      assert rl.po_line_id == po_line.id

      # The stock event — anchored goods_receipt.
      {:ok, %{rows: event_rows}} =
        Ecto.Adapters.SQL.query(
          @repo,
          """
          SELECT skl_qty, skl_unit_cost_cents FROM skl_stock_ledger
          WHERE skl_org_id = $1 AND skl_source_key = 'goods_receipt' AND skl_source_id = $2
          """,
          [Ecto.UUID.dump!(org), Ecto.UUID.dump!(receipt_id = received.id)]
        )

      assert event_rows == [[10, 2_500]]
      _ = receipt_id

      # The GL entry — POSTED, balanced, anchored goods_receipt.
      assert %JournalEntry{status: :posted} = entry =
               Ash.get!(JournalEntry, received.posted_entry_id, authorize?: false)

      assert entry.source_key == "goods_receipt"
      assert {:ok, 0} = Reconcile.org_balance(org, @repo, line_resource: @line_resource)

      # The E3 rollup moved with the event (R3 never regresses).
      level = level_row(org, item.id, warehouse.id)
      assert level.qty_on_hand == 10
      assert level.stock_value_cents == 25_000
    end

    test "over-receipt is refused (RED) and nothing lands", %{org: org, scope: scope} do
      item = new_item(scope, org)
      warehouse = new_warehouse(scope, org)
      seed_posting_accounts(org)
      link_inventory_account(scope, org, item.id)

      po = new_po(scope, org, warehouse.id, [%{item_id: item.id, qty: 5, unit_cost_cents: 1_000}])
      [po_line] = po_lines(po.id)

      po = approve_po(po, scope)
      receipt = new_receipt(scope, org, po, warehouse)

      assert {:error, %Ash.Error.Invalid{}} =
               receipt
               |> Ash.Changeset.for_update(:receive, %{lines: [%{po_line_id: po_line.id, qty: 6}]})
               |> Ash.update(scope: scope)

      # Nothing landed anywhere.
      assert Ash.get!(GoodsReceipt, receipt.id, authorize?: false).status == :draft

      assert {:ok, %{on_hand: 0, stock_value: 0}} =
               ReconcileStock.level(@repo, StockLedger, org, item.id, warehouse.id)
    end

    test "an unlinked item refuses the WHOLE receipt fail-honest (RED)", %{org: org, scope: scope} do
      # The item has NO default_inventory_account_id.
      item = new_item(scope, org)
      warehouse = new_warehouse(scope, org)
      seed_posting_accounts(org)

      po = new_po(scope, org, warehouse.id, [%{item_id: item.id, qty: 4, unit_cost_cents: 700}])
      [po_line] = po_lines(po.id)

      po = approve_po(po, scope)
      receipt = new_receipt(scope, org, po, warehouse)

      assert {:error, %Ash.Error.Invalid{}} =
               receipt
               |> Ash.Changeset.for_update(:receive, %{lines: [%{po_line_id: po_line.id, qty: 4}]})
               |> Ash.update(scope: scope)

      # Fail-honest BEFORE any write: no stock, no receipt flip, no receipt lines.
      assert Ash.get!(GoodsReceipt, receipt.id, authorize?: false).status == :draft

      assert {:ok, %{on_hand: 0, stock_value: 0}} =
               ReconcileStock.level(@repo, StockLedger, org, item.id, warehouse.id)

      assert receipt_lines(receipt.id) == []
    end

    test "a receipt posts exactly once — re-receive is refused (RED)", %{org: org, scope: scope} do
      {_item, _warehouse, _po, po_line} = seed_receiveable(scope, org, qty: 10, unit_cost_cents: 2_500)

      # The seed helper already received; a second :receive on the POSTED
      # receipt is refused exactly-once.
      [received] = Ash.read!(GoodsReceipt, authorize?: false)

      assert {:error, %Ash.Error.Invalid{}} =
               received
               |> Ash.Changeset.for_update(:receive, %{lines: [%{po_line_id: po_line.id, qty: 1}]})
               |> Ash.update(scope: scope)
    end
  end

  # ── r4: R3-full green ───────────────────────────────────────────────────────

  describe "r4 — R3-full: the three legs agree for every receipt" do
    test "ledger == facts == GL per receipt and org-wide divergences are empty", %{
      org: org,
      scope: scope
    } do
      {_item, _warehouse, _po, _po_line} =
        seed_receiveable(scope, org, qty: 7, unit_cost_cents: 3_333)

      [received] = Ash.read!(GoodsReceipt, authorize?: false)

      {:ok, legs} =
        ReconcileProcurement.receipt(@repo, org,
          receipt_id: received.id,
          ledger_resource: StockLedger,
          receipt_line_resource: ReceiptLine,
          entry_resource: JournalEntry,
          line_resource: @line_resource
        )

      assert legs.stock == %{qty: 7, value: 23_331}
      assert legs.facts == %{qty: 7, value: 23_331}
      assert legs.gl == %{value: 23_331}

      assert {:ok, []} =
               ReconcileProcurement.divergences(@repo, org,
                 ledger_resource: StockLedger,
                 receipt_line_resource: ReceiptLine,
                 entry_resource: JournalEntry,
                 line_resource: @line_resource
               )
    end
  end

  # ── r5: the R5 three-way match ──────────────────────────────────────────────

  describe "r5 — the R5 three-way match (flag, not a block)" do
    test "an exact vendor bill is unflagged (CONTROL); an over-billed vendor bill flags (RED)", %{
      org: org,
      scope: scope
    } do
      {_item, _warehouse, po, _po_line} =
        seed_receiveable(scope, org, qty: 10, unit_cost_cents: 2_500)

      # CONTROL: a bill for exactly the received value — unflagged.
      {:ok, exact} = match_bill(scope, org, po.vendor_id, 25_000)
      refute exact.flagged?

      # RED: a bill for 10x the received value — flagged (zero tolerance).
      {:ok, over} = match_bill(scope, org, po.vendor_id, 250_000)
      assert over.flagged?
      assert over.variance_cents == 225_000
      assert over.po_received_cents == 25_000
      assert over.po_ordered_cents == 25_000
    end

    test "tolerance widens per host (the documented-tolerance control)", %{org: org, scope: scope} do
      {_item, _warehouse, po, _po_line} =
        seed_receiveable(scope, org, qty: 10, unit_cost_cents: 2_500)

      # 10% over: flagged at zero tolerance, unflagged at a 10% tolerance.
      {:ok, over} = match_bill(scope, org, po.vendor_id, 27_500)
      assert over.flagged?

      {:ok, within} = match_bill(scope, org, po.vendor_id, 27_500, tolerance_pct: 10)
      refute within.flagged?
    end
  end

  # ── r6: the DB belts (raw SQL) ──────────────────────────────────────────────

  describe "r6 — the DB belts refuse raw-SQL facts" do
    test "a PoLine is frozen once its PO leaves draft (RED) — draft edits stay open (CONTROL)", %{
      org: org,
      scope: scope
    } do
      {item, warehouse, po, _po_line} = seed_receiveable(scope, org, qty: 10, unit_cost_cents: 2_500)

      # CONTROL: while draft, the belt allows line edits.
      draft_po = new_po(scope, org, warehouse.id, [%{item_id: item.id, qty: 1, unit_cost_cents: 100}])
      [draft_line] = po_lines(draft_po.id)

      assert {:ok, _} =
               Ecto.Adapters.SQL.query(
                 @repo,
                 "UPDATE spl_po_line SET spl_qty = 2 WHERE spl_id = $1",
                 [Ecto.UUID.dump!(draft_line.id)]
               )

      # RED: the received PO's line is frozen.
      [frozen_line] = po_lines(po.id)

      assert {:error, _} =
               Ecto.Adapters.SQL.query(
                 @repo,
                 "UPDATE spl_po_line SET spl_qty = 99 WHERE spl_id = $1",
                 [Ecto.UUID.dump!(frozen_line.id)]
               )

      assert {:error, _} =
               Ecto.Adapters.SQL.query(
                 @repo,
                 "DELETE FROM spl_po_line WHERE spl_id = $1",
                 [Ecto.UUID.dump!(frozen_line.id)]
               )
    end

    test "a raw-SQL draft→received PO stamp and a raw-SQL draft→posted receipt are marker-refused (RED)", %{
      org: org,
      scope: scope
    } do
      {item, warehouse, _po, _po_line} = seed_receiveable(scope, org, qty: 10, unit_cost_cents: 2_500)

      # A FRESH approved PO (not the seed's already-:received one — the
      # belt's →received arm is a no-op on an already-received row).
      fresh_po =
        new_po(scope, org, warehouse.id, [%{item_id: item.id, qty: 2, unit_cost_cents: 900}])
        |> approve_po(scope)

      raw_receipt = new_receipt(scope, org, fresh_po, warehouse)

      assert {:error, _} =
               Ecto.Adapters.SQL.query(
                 @repo,
                 "UPDATE spo_purchase_order SET spo_status = 'received' WHERE spo_id = $1",
                 [Ecto.UUID.dump!(fresh_po.id)]
               )

      assert {:error, _} =
               Ecto.Adapters.SQL.query(
                 @repo,
                 "UPDATE sgr_goods_receipt SET sgr_status = 'posted' WHERE sgr_id = $1",
                 [Ecto.UUID.dump!(raw_receipt.id)]
               )

      # CONTROL: the rows are untouched.
      assert Ash.get!(PurchaseOrder, fresh_po.id, authorize?: false).status == :approved
      assert Ash.get!(GoodsReceipt, raw_receipt.id, authorize?: false).status == :draft
    end

    test "ReceiptLine rows are append-only at the DB (RED)", %{org: org, scope: scope} do
      {_item, _warehouse, _po, _po_line} = seed_receiveable(scope, org, qty: 10, unit_cost_cents: 2_500)

      [%ReceiptLine{} = rl] = Ash.read!(ReceiptLine, authorize?: false)

      assert {:error, _} =
               Ecto.Adapters.SQL.query(
                 @repo,
                 "UPDATE srl_receipt_line SET srl_qty = 1 WHERE srl_id = $1",
                 [Ecto.UUID.dump!(rl.id)]
               )

      assert {:error, _} =
               Ecto.Adapters.SQL.query(
                 @repo,
                 "DELETE FROM srl_receipt_line WHERE srl_id = $1",
                 [Ecto.UUID.dump!(rl.id)]
               )
    end
  end

  # ── r7: cross-org ───────────────────────────────────────────────────────────

  describe "r7 — cross-org discipline" do
    test "a receipt line naming a FOREIGN org's po_line is refused (RED) — the same-org twin lands (CONTROL)", %{
      org: org,
      scope: scope
    } do
      item = new_item(scope, org)
      warehouse = new_warehouse(scope, org)
      seed_posting_accounts(org)
      link_inventory_account(scope, org, item.id)

      po = new_po(scope, org, warehouse.id, [%{item_id: item.id, qty: 10, unit_cost_cents: 2_500}])
      [own_line] = po_lines(po.id)
      po = approve_po(po, scope)
      receipt = new_receipt(scope, org, po, warehouse)

      # A foreign org's PO + line.
      foreign_org = Ash.UUID.generate()
      foreign_scope = tenant_scope(foreign_org)
      foreign_item = new_item(foreign_scope, foreign_org)
      foreign_warehouse = new_warehouse(foreign_scope, foreign_org)

      foreign_po =
        new_po(foreign_scope, foreign_org, foreign_warehouse.id, [
          %{item_id: foreign_item.id, qty: 3, unit_cost_cents: 500}
        ])

      [foreign_line] = po_lines(foreign_po.id)

      # RED: the foreign po_line does not exist for this org.
      assert {:error, %Ash.Error.Invalid{}} =
               receipt
               |> Ash.Changeset.for_update(:receive, %{lines: [%{po_line_id: foreign_line.id, qty: 1}]})
               |> Ash.update(scope: scope)

      # CONTROL: the same-org line receives.
      assert {:ok, _} =
               receipt
               |> Ash.Changeset.for_update(:receive, %{lines: [%{po_line_id: own_line.id, qty: 5}]})
               |> Ash.update(scope: scope)
    end
  end

  # ── r8: catalog registration ────────────────────────────────────────────────

  describe "r8 — catalog registration (d11's E4 twin)" do
    test "every E4 fixture column has a catalog row (in isolation)", %{org: _org, scope: _scope} do
      {:ok, %{rows: rows}} =
        Ecto.Adapters.SQL.query(
          @repo,
          """
          SELECT c.table_name, c.column_name
          FROM information_schema.columns c
          WHERE c.table_name IN
            ('spo_purchase_order', 'spl_po_line', 'sgr_goods_receipt', 'srl_receipt_line')
          """,
          []
        )

      cataloged = fn table, column ->
        {:ok, %{rows: found}} =
          Ecto.Adapters.SQL.query(
            @repo,
            "SELECT 1 FROM fld_field WHERE fld_table_name = $1 AND fld_column_name = $2",
            [table, column]
          )

        found != []
      end

      for {table, column} <- rows do
        assert cataloged.(table, column),
               "#{table}.#{column} is not catalogued in fld_field"
      end
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

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

  defp approval_resource, do: SamenCore.Support.ApprovalsFixture.Approval

  defp decide(approval_id) do
    Samen.Approvals.approve(approval_id, "a2:decider",
      approval_resource: approval_resource(),
      repo: @repo
    )
  end

  # The Gate discipline (the E2 `gate/2` shape): an ungated :approve fails
  # with ApprovalRequired and returns the pending approval id. NEVER a bare
  # success — the gate-never-skips control.
  defp gate(record, scope) do
    result =
      record
      |> Ash.Changeset.for_update(:approve, %{}, scope: scope)
      |> Ash.update()

    case result do
      {:error, %Ash.Error.Forbidden{errors: errors}} ->
        case Enum.find(errors, &match?(%{__struct__: Samen.Approvals.ApprovalRequired}, &1)) do
          nil -> flunk("expected ApprovalRequired, got: #{inspect(errors)}")
          found -> {:gated, found.approval_id}
        end

      {:ok, _} ->
        flunk("the :approve action succeeded WITHOUT the Gate — the approval discipline is broken")

      {:error, other} ->
        flunk("unexpected :approve failure: #{inspect(other)}")
    end
  end

  defp approve_po(po, scope) do
    {:gated, approval_id} = gate(po, scope)
    {:ok, _, _} = decide(approval_id)
    Ash.get!(PurchaseOrder, po.id, authorize?: false)
  end

  defp new_item(scope, org) do
    Item
    |> Ash.Changeset.for_create(:create, %{
      org_id: org,
      sku: "SKU-" <> binary_part(Ash.UUID.generate(), 0, 8),
      name: "A stocked item"
    })
    |> Ash.create!(scope: scope)
  end

  defp link_inventory_account(_scope, org, item_id) do
    account =
      Account
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org, code: "1400", name: "Inventory", kind: :asset, normal_side: :debit},
        scope: tenant_scope(org)
      )
      |> Ash.create!()

    Item
    |> Ash.Query.filter(id == ^item_id)
    |> Ash.read_one!(authorize?: false)
    |> Ash.Changeset.for_update(:update, %{default_inventory_account_id: account.id},
      scope: admin_scope(org)
    )
    |> Ash.update!()
  end

  defp new_warehouse(scope, org) do
    Warehouse
    |> Ash.Changeset.for_create(:create, %{
      org_id: org,
      code: "WH-" <> binary_part(Ash.UUID.generate(), 0, 8),
      name: "Main"
    })
    |> Ash.create!(scope: scope)
  end

  defp new_po(scope, org, warehouse_id, lines, attrs \\ %{}) do
    PurchaseOrder
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          org_id: org,
          vendor_id: Ash.UUID.generate(),
          number: "PO-" <> binary_part(Ash.UUID.generate(), 0, 8),
          order_date: ~D[2026-09-10],
          warehouse_id: warehouse_id,
          lines: lines
        },
        Map.new(attrs)
      )
    )
    |> Ash.create!(scope: scope)
  end

  defp new_receipt(scope, org, po, warehouse) do
    GoodsReceipt
    |> Ash.Changeset.for_create(:create, %{
      org_id: org,
      purchase_order_id: po.id,
      warehouse_id: warehouse.id,
      number: "GR-" <> binary_part(Ash.UUID.generate(), 0, 8),
      received_date: ~D[2026-09-12]
    })
    |> Ash.create!(scope: scope)
  end

  defp po_lines(po_id) do
    PoLine
    |> Ash.Query.filter(purchase_order_id == ^po_id)
    |> Ash.read!(authorize?: false)
  end

  defp receipt_lines(receipt_id) do
    ReceiptLine
    |> Ash.Query.filter(goods_receipt_id == ^receipt_id)
    |> Ash.read!(authorize?: false)
  end

  defp level_row(org, item_id, warehouse_id) do
    StockLevel
    |> Ash.Query.filter(org_id == ^org and item_id == ^item_id and warehouse_id == ^warehouse_id)
    |> Ash.read_one!(authorize?: false)
  end

  defp seed_posting_accounts(org) do
    for {key, code} <- [ap_clearing: "2000", cash: "1000"] do
      account =
        Account
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org, code: code, name: "Account #{code}", kind: :asset, normal_side: :debit},
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
  end

  # Seeds the green world: an item WITH the inventory-account link, a
  # warehouse, posting accounts, and an approved PO + RECEIVED receipt
  # (qty × cost as given).
  defp seed_receiveable(scope, org, opts) do
    qty = Keyword.fetch!(opts, :qty)
    cost = Keyword.fetch!(opts, :unit_cost_cents)

    item = link_inventory_account(scope, org, new_item(scope, org).id)
    warehouse = new_warehouse(scope, org)
    seed_posting_accounts(org)

    po = new_po(scope, org, warehouse.id, [%{item_id: item.id, qty: qty, unit_cost_cents: cost}])
    [po_line] = po_lines(po.id)

    po = approve_po(po, scope)
    receipt = new_receipt(scope, org, po, warehouse)

    {:ok, _} =
      receipt
      |> Ash.Changeset.for_update(:receive, %{lines: [%{po_line_id: po_line.id, qty: qty}]})
      |> Ash.update(scope: scope)

    {item, warehouse, Ash.get!(PurchaseOrder, po.id, authorize?: false), po_line}
  end

  # Creates an AP bill for the vendor and runs the R5 three-way variance.
  # The account code is UNIQUE per org, so a per-bill suffix keeps repeated
  # match_bill calls in one test collision-free.
  defp match_bill(scope, org, vendor_id, amount_cents, opts \\ []) do
    suffix = binary_part(Ash.UUID.generate(), 0, 6)

    expense =
      Account
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org,
          code: "61" <> suffix,
          name: "Purchases " <> suffix,
          kind: :expense,
          normal_side: :debit
        },
        scope: scope
      )
      |> Ash.create!()

    bill =
      ApInvoice
      |> Ash.Changeset.for_create(:create, %{
        org_id: org,
        vendor_id: vendor_id,
        number: "V-" <> binary_part(Ash.UUID.generate(), 0, 8),
        bill_date: ~D[2026-09-12],
        lines: [%{account_id: expense.id, amount_cents: amount_cents}]
      })
      |> Ash.create!(scope: scope)

    ThreeWayMatch.variance(
      @repo,
      org,
      bill,
      Keyword.merge(
        [po_resource: PurchaseOrder, po_line_resource: PoLine, receipt_line_resource: ReceiptLine],
        opts
      )
    )
  end
end
