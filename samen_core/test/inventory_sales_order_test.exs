defmodule Samen.InventorySalesOrderTest do
  @moduledoc """
  The SalesOrder bridge + the R3-fulfillment red-path suite (WS-ERP E5;
  design §3.3 + §6.3), mounted via `test/support/inventory_fixture.ex` with
  the `finance:` + `billing:` wiring onto the E1/E2 FinanceFixture modules.

  Every red-path pairs denial with a positive control (anti-tautology, the
  house `RedPath` style). Blocks:

    * f1 the SO draft lifecycle: a member drafts a SO whose `lines`
      argument materializes into real rows (CONTROL); an empty/zero-qty/
      negative-price shape is refused (RED) with the positive twin landing;
      lines are a draft-only replace — a confirmed SO cannot edit them.
    * f2 the state machine: draft → confirmed → fulfilled; re-confirm,
      cancel-after-fulfill refused (RED) with the sanctioned twins landing.
    * f3 THE ONE-TRANSACTION BRIDGE: `:fulfill` lands the negative-qty
      stock events (cost = the moving-average snapshot) + the emitted
      invoice + the SO's flip + its invoice anchor — all-or-nothing.
      Refusals are fail-honest BEFORE any write: a draft order, a
      never-stocked item, an oversell past NegativeStock (with the
      `allow_negative` CONTROL), and the exactly-once re-fulfill.
    * f4 R3-fulfillment green: the stock leg == the billing leg per order
      and org-wide (`ReconcileFulfillment.divergences/2` empty); the
      org-zero twin (a foreign org's chain is invisible).
    * f5 anti-tautology: a FORGED raw-SQL `:sale` event on a confirmed SO
      flags the standing read; the sanctioned fulfill heals it; a raw-SQL
      anchor wipe on a fulfilled SO flags again (the sabotage's bypass is
      visible BY CONSTRUCTION, not by assumption).
    * f6 the DB belts: raw-SQL →fulfilled without the marker refused (RED);
      SoLine frozen once the SO leaves draft (RED, draft-edit CONTROL).
    * f7 cross-org: a SO naming a foreign warehouse is refused (RED) with
      the same-org CONTROL; foreign rows are invisible.
    * f8 THE GOVERNED WALKTHROUGH: Lead → Opportunity → SO → fulfill →
      Invoice (the `sim` mirror) → PaymentReceipt (posted) → GL cash+AR —
      one chain where every link already has a home, ending with the
      standing fulfillment read empty.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.ReconcilePayments
  alias Samen.Scopes.Inventory.ReconcileFulfillment
  alias Samen.Scopes.Inventory.ReconcileStock
  alias SamenCore.Support.CrmScopeFixture

  alias SamenCore.Support.FinanceFixture.{
    Account,
    InvoiceMirror,
    JournalEntry,
    JournalLine,
    PaymentReceipt,
    PostingAccount
  }

  alias SamenCore.Support.InventoryFixture.{Item, SalesOrder, SoLine, StockLedger, Warehouse}
  alias SamenCore.Support.SalesOpsFixture.Lead

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)

    # The walkthrough's Lead create vaults PII — the sales_ops suite's KMS posture.
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    on_exit(fn -> Samen.Kms.FileBacked.simulate_outage(false) end)

    org = Ash.UUID.generate()
    {:ok, org: org, scope: tenant_scope(org)}
  end

  # ── f1: the SO draft lifecycle ───────────────────────────────────────────────

  describe "f1 — the SO draft lifecycle" do
    test "a member drafts a SO; the lines argument materializes into real rows (CONTROL)", %{
      org: org,
      scope: scope
    } do
      {item, warehouse} = seed_pair(scope, org)

      so = new_so(scope, org, warehouse.id, [%{item_id: item.id, qty: 3, unit_price_cents: 1_200}])

      assert so.status == :draft

      assert [%SoLine{} = line] = so_lines(so.id)
      assert line.qty == 3
      assert line.unit_price_cents == 1_200
      assert line.item_id == item.id
    end

    test "an empty, zero-qty, and negative-price shape are refused (RED) — the positive twin lands", %{
      org: org,
      scope: scope
    } do
      {item, warehouse} = seed_pair(scope, org)

      for {number, lines} <- [
            {"SO-EMPTY", []},
            {"SO-ZERO", [%{item_id: item.id, qty: 0, unit_price_cents: 1_200}]},
            {"SO-NEG", [%{item_id: item.id, qty: 1, unit_price_cents: -5}]}
          ] do
        assert {:error, %Ash.Error.Invalid{}} =
                 SalesOrder
                 |> Ash.Changeset.for_create(:create, %{
                   org_id: org,
                   customer_id: Ash.UUID.generate(),
                   number: number,
                   order_date: ~D[2026-09-13],
                   warehouse_id: warehouse.id,
                   lines: lines
                 })
                 |> Ash.create(scope: scope)
      end

      # Nothing leaked.
      assert SalesOrder |> Ash.read!(authorize?: false) == []

      # CONTROL: the positive shape lands.
      so = new_so(scope, org, warehouse.id, [%{item_id: item.id, qty: 1, unit_price_cents: 1_200}])
      assert so.status == :draft
    end

    test "lines are a draft-only replace: a confirmed SO cannot edit them (RED)", %{
      org: org,
      scope: scope
    } do
      {item, warehouse} = seed_pair(scope, org)

      so = new_so(scope, org, warehouse.id, [%{item_id: item.id, qty: 2, unit_price_cents: 800}])

      # CONTROL: while draft, the replace re-materializes.
      so =
        so
        |> Ash.Changeset.for_update(:update, %{
          lines: [%{item_id: item.id, qty: 5, unit_price_cents: 800}]
        })
        |> Ash.update!(scope: scope)

      assert [%SoLine{} = line] = so_lines(so.id)
      assert line.qty == 5

      confirmed = confirm(so, scope)

      assert {:error, %Ash.Error.Invalid{}} =
               confirmed
               |> Ash.Changeset.for_update(:update, %{
                 lines: [%{item_id: item.id, qty: 99, unit_price_cents: 1}]
               })
               |> Ash.update(scope: scope)

      # The frozen lines survive the refused edit.
      assert [%SoLine{} = line] = so_lines(so.id)
      assert line.qty == 5
    end
  end

  # ── f2: the state machine ────────────────────────────────────────────────────

  describe "f2 — the SO state machine (no Gate: a sale is not a spend)" do
    test "draft → confirm lands (CONTROL); re-confirm is refused (RED)", %{org: org, scope: scope} do
      {item, warehouse} = seed_pair(scope, org)
      so = new_so(scope, org, warehouse.id, [%{item_id: item.id, qty: 1, unit_price_cents: 500}])

      confirmed = confirm(so, scope)
      assert confirmed.status == :confirmed

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.Changeset.for_update(confirmed, :confirm, %{}, scope: scope)
               |> Ash.update()
    end

    test "a fulfilled SO cannot be cancelled (RED) — its stock and invoice are facts", %{
      org: org,
      scope: scope
    } do
      {_item, _warehouse, so, invoice} = seed_fulfilled(scope, org, qty: 2, price: 900)

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.Changeset.for_update(so, :cancel, %{}, scope: scope)
               |> Ash.update()

      # The facts stand.
      assert Ash.get!(SalesOrder, so.id, authorize?: false).status == :fulfilled
      assert so_lines(so.id) != []
      refute is_nil(invoice.id)
    end

    test "cancel from draft lands (CONTROL)", %{org: org, scope: scope} do
      {item, warehouse} = seed_pair(scope, org)
      so = new_so(scope, org, warehouse.id, [%{item_id: item.id, qty: 1, unit_price_cents: 500}])

      cancelled = Ash.update!(Ash.Changeset.for_update(so, :cancel, %{}, scope: scope))
      assert cancelled.status == :cancelled
    end
  end

  # ── f3: THE ONE-TRANSACTION BRIDGE ───────────────────────────────────────────

  describe "f3 — the one-transaction fulfillment bridge" do
    test "the CONTROL: stock events + invoice + flip + anchor land TOGETHER", %{
      org: org,
      scope: scope
    } do
      {item, warehouse, so, invoice} = seed_fulfilled(scope, org, qty: 4, price: 900)

      # The stock side: a NEGATIVE-qty :sale event at the moving-average cost.
      assert [event] = sale_events(so.id)
      assert event.qty == -4
      assert event.unit_cost_cents == 500
      assert event.kind == :sale

      # The rollup moved: 10 received @ 500 - 4 sold = 6 on hand.
      assert {:ok, %{on_hand: 6}} = ReconcileStock.level(@repo, StockLedger, org, item.id, warehouse.id)

      # The billing side: the emitted invoice, :open, Σ qty×price.
      assert invoice.status == :open
      assert invoice.amount_due_cents == 3_600
      assert invoice.amount_paid_cents == 0
      assert length(invoice.line_items) == 1

      # The SO's own flip + anchor.
      fulfilled = Ash.get!(SalesOrder, so.id, authorize?: false)
      assert fulfilled.status == :fulfilled
      assert fulfilled.invoice_key == "billing_invoice"
      assert fulfilled.invoice_id == invoice.id
      refute is_nil(fulfilled.fulfilled_at)
    end

    test "a :draft SO cannot fulfill (RED) — nothing lands", %{org: org, scope: scope} do
      {item, warehouse} = seed_pair(scope, org)
      stock_pair(scope, org, item, warehouse, 10, 500)

      so = new_so(scope, org, warehouse.id, [%{item_id: item.id, qty: 1, unit_price_cents: 900}])

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.Changeset.for_update(so, :fulfill, %{}, scope: scope)
               |> Ash.update()

      assert Ash.get!(SalesOrder, so.id, authorize?: false).status == :draft
      assert sale_events(so.id) == []
      assert invoices_for_org(org) == []
    end

    test "a never-stocked item is refused fail-honest BEFORE any write (RED)", %{
      org: org,
      scope: scope
    } do
      {item, warehouse} = seed_pair(scope, org)

      so = new_so(scope, org, warehouse.id, [%{item_id: item.id, qty: 1, unit_price_cents: 900}])
      confirmed = confirm(so, scope)

      assert {:error, %Ash.Error.Invalid{} = err} =
               Ash.Changeset.for_update(confirmed, :fulfill, %{}, scope: scope)
               |> Ash.update()

      assert inspect(err) =~ "never stocked"

      # Fail-honest: no events, no invoice, the SO still confirmed.
      assert sale_events(so.id) == []
      assert invoices_for_org(org) == []
      assert Ash.get!(SalesOrder, so.id, authorize?: false).status == :confirmed

      # The positive twin: after stocking, the same order fulfills.
      stock_pair(scope, org, item, warehouse, 5, 400)

      fulfilled = Ash.update!(Ash.Changeset.for_update(confirmed, :fulfill, %{}, scope: scope))
      assert fulfilled.status == :fulfilled
      assert [event] = sale_events(so.id)
      assert event.unit_cost_cents == 400
    end

    test "selling past NegativeStock is refused with NOTHING landed (RED) — the allow_negative CONTROL lands", %{
      org: org,
      scope: scope
    } do
      item = new_item(scope, org)
      wh_fail_closed = new_warehouse(scope, org, %{allow_negative: false})
      wh_opted_out = new_warehouse(scope, org, %{allow_negative: true})

      stock_pair(scope, org, item, wh_fail_closed, 2, 500)
      stock_pair(scope, org, item, wh_opted_out, 2, 500)

      so_red =
        new_so(scope, org, wh_fail_closed.id, [%{item_id: item.id, qty: 9, unit_price_cents: 900}])
        |> confirm(scope)

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.Changeset.for_update(so_red, :fulfill, %{}, scope: scope)
               |> Ash.update()

      # Nothing landed anywhere: no events, no invoice, still confirmed.
      assert sale_events(so_red.id) == []
      assert invoices_for_org(org) == []
      assert Ash.get!(SalesOrder, so_red.id, authorize?: false).status == :confirmed

      # CONTROL: the opted-out warehouse takes the same oversell (E3's opt-out).
      so_ctrl =
        new_so(scope, org, wh_opted_out.id, [%{item_id: item.id, qty: 9, unit_price_cents: 900}])
        |> confirm(scope)

      assert {:ok, _} = Ash.Changeset.for_update(so_ctrl, :fulfill, %{}, scope: scope) |> Ash.update()
      assert [event] = sale_events(so_ctrl.id)
      assert event.qty == -9
    end

    test "re-fulfill is refused exactly-once (RED)", %{org: org, scope: scope} do
      {_item, _warehouse, so, _invoice} = seed_fulfilled(scope, org, qty: 1, price: 900)

      assert {:error, %Ash.Error.Invalid{}} =
               Ash.Changeset.for_update(so, :fulfill, %{}, scope: scope)
               |> Ash.update()

      # Exactly-once: still exactly one event, one invoice.
      assert [_] = sale_events(so.id)
      assert [_invoice] = invoices_for_org(org)
    end
  end

  # ── f4: R3-fulfillment green ─────────────────────────────────────────────────

  describe "f4 — R3-fulfillment: the two legs agree" do
    test "order/3 reads both legs; divergences/2 is empty over a fulfilled org (green)", %{
      org: org,
      scope: scope
    } do
      {item_a, warehouse} = seed_pair(scope, org)
      item_b = new_item(scope, org)

      stock_pair(scope, org, item_a, warehouse, 10, 500)
      stock_pair(scope, org, item_b, warehouse, 4, 1_000)

      so1 =
        new_so(scope, org, warehouse.id, [
          %{item_id: item_a.id, qty: 2, unit_price_cents: 900},
          %{item_id: item_b.id, qty: 1, unit_price_cents: 1_500}
        ])
        |> confirm(scope)
        |> fulfill(scope)

      so2 =
        new_so(scope, org, warehouse.id, [%{item_id: item_a.id, qty: 1, unit_price_cents: 950}])
        |> confirm(scope)
        |> fulfill(scope)

      # so1: stock leg = Σ -3 events, value = -(2×500 + 1×1000) = -2000
      #      (signed: value LEFT inventory); billing = 2×900 + 1×1500 = 3300.
      assert {:ok, %{stock: stock1, billing: billing1}} =
               fulfillment_order(org, so1.id)

      assert stock1.qty == -3
      assert stock1.value == -2_000
      assert billing1.amount_due_cents == 3_300
      assert billing1.status == :open

      assert {:ok, %{stock: stock2, billing: billing2}} =
               fulfillment_order(org, so2.id)

      assert stock2.qty == -1

      # so2's snapshot is the rollup's moving average AFTER so1's sale:
      # Σ(qty×cost)/Σ|qty| = (10×500 − 2×500)/(10+2) = 333 (the E3 formula).
      assert stock2.value == -333
      assert billing2.amount_due_cents == 950

      # The standing read: empty over the whole org.
      assert {:ok, []} = divergences(org)
    end

    test "the org-zero twin: a foreign org's chain is invisible to our reads", %{
      org: org,
      scope: _scope
    } do
      foreign_scope = tenant_scope(Ash.UUID.generate())
      foreign_org_id = foreign_scope.actor.org_id

      {_item, _wh, foreign_so, _invoice} = seed_fulfilled(foreign_scope, foreign_org_id, qty: 1, price: 700)

      _ = foreign_so

      # OUR org's standing read never flags the foreign chain.
      assert {:ok, []} = divergences(org)

      # The foreign order does not resolve from OUR org's context.
      assert {:error, :order_not_found} = fulfillment_order(org, foreign_so.id)

      # Sanity: the foreign org's own read sees its chain green.
      assert {:ok, []} = divergences(foreign_org_id)
    end
  end

  # ── f5: anti-tautology (the bypass is visible BY CONSTRUCTION) ───────────────

  describe "f5 — anti-tautology: the standing read catches a bypass and heals" do
    test "a FORGED raw-SQL :sale event on a confirmed SO flags; the sanctioned fulfill heals", %{
      org: org,
      scope: scope
    } do
      {item, warehouse} = seed_pair(scope, org)
      stock_pair(scope, org, item, warehouse, 10, 500)

      so =
        new_so(scope, org, warehouse.id, [%{item_id: item.id, qty: 2, unit_price_cents: 900}])
        |> confirm(scope)

      # The bypass simulation: a forged demand event lands WITHOUT the bridge
      # (INSERT is append — the ledger's own belt allows it; the rollup is not
      # synced, which is E3 s7's divergence, not this one).
      :ok =
        raw_sql!(
          """
          INSERT INTO skl_stock_ledger
            (skl_id, skl_org_id, skl_item_id, skl_warehouse_id, skl_kind, skl_qty,
             skl_unit_cost_cents, skl_source_key, skl_source_id, skl_inserted_at, skl_updated_at)
          VALUES ($1, $2, $3, $4, 'sale', -2, 500, 'sales_order', $5, now(), now())
          """,
          [
            Ecto.UUID.bingenerate(),
            Ecto.UUID.dump!(org),
            Ecto.UUID.dump!(item.id),
            Ecto.UUID.dump!(warehouse.id),
            Ecto.UUID.dump!(so.id)
          ]
        )

      assert {:ok, [flag]} = divergences(org)
      assert flag.sales_order_id == so.id
      assert flag.stock_qty == -2
      assert flag.invoice_id == nil

      # The heal: the sanctioned fulfill lands the real bridge; the order is
      # then fulfilled WITH its anchor — the forged event no longer diverges.
      # (The forged event never moved the rollup, so the sanctioned fulfill
      # still snapshots the moving average 500 — E3's heal discipline.)
      assert {:ok, _} = Ash.Changeset.for_update(so, :fulfill, %{}, scope: scope) |> Ash.update()

      assert {:ok, []} = divergences(org)
      assert length(sale_events(so.id)) == 2
    end

    test "a raw-SQL anchor wipe on a fulfilled SO flags (RED); re-stamping heals", %{
      org: org,
      scope: scope
    } do
      {_item, _warehouse, so, invoice} = seed_fulfilled(scope, org, qty: 1, price: 900)

      :ok =
        raw_sql!(
          "UPDATE slo_sales_order SET slo_invoice_id = NULL, slo_invoice_key = NULL WHERE slo_id = $1",
          [Ecto.UUID.dump!(so.id)]
        )

      assert {:ok, [flag]} = divergences(org)
      assert flag.sales_order_id == so.id
      assert flag.invoice_id == nil
      assert flag.stock_qty == -1

      # Heal: restore the anchor — the two legs agree again.
      :ok =
        raw_sql!(
          "UPDATE slo_sales_order SET slo_invoice_id = $2, slo_invoice_key = 'billing_invoice' WHERE slo_id = $1",
          [Ecto.UUID.dump!(so.id), Ecto.UUID.dump!(invoice.id)]
        )

      assert {:ok, []} = divergences(org)
    end
  end

  # ── f6: the DB belts ─────────────────────────────────────────────────────────

  describe "f6 — the DB belts refuse raw-SQL facts" do
    test "a raw-SQL draft→fulfilled flip is marker-refused (RED)", %{org: org, scope: scope} do
      {item, warehouse} = seed_pair(scope, org)
      stock_pair(scope, org, item, warehouse, 10, 500)

      so =
        new_so(scope, org, warehouse.id, [%{item_id: item.id, qty: 1, unit_price_cents: 900}])
        |> confirm(scope)

      assert {:error, _} =
               Ecto.Adapters.SQL.query(
                 @repo,
                 "UPDATE slo_sales_order SET slo_status = 'fulfilled' WHERE slo_id = $1",
                 [Ecto.UUID.dump!(so.id)]
               )

      assert Ash.get!(SalesOrder, so.id, authorize?: false).status == :confirmed
    end

    test "a SoLine is frozen once the SO leaves draft (RED) — draft edits stay open (CONTROL)", %{
      org: org,
      scope: scope
    } do
      {item, warehouse} = seed_pair(scope, org)

      draft_so = new_so(scope, org, warehouse.id, [%{item_id: item.id, qty: 1, unit_price_cents: 100}])
      [draft_line] = so_lines(draft_so.id)

      assert {:ok, _} =
               Ecto.Adapters.SQL.query(
                 @repo,
                 "UPDATE sol_so_line SET sol_qty = 2 WHERE sol_id = $1",
                 [Ecto.UUID.dump!(draft_line.id)]
               )

      {_item, _warehouse, so, _invoice} = seed_fulfilled(scope, org, qty: 1, price: 900)
      [frozen_line] = so_lines(so.id)

      assert {:error, _} =
               Ecto.Adapters.SQL.query(
                 @repo,
                 "UPDATE sol_so_line SET sol_qty = 99 WHERE sol_id = $1",
                 [Ecto.UUID.dump!(frozen_line.id)]
               )

      assert {:error, _} =
               Ecto.Adapters.SQL.query(
                 @repo,
                 "DELETE FROM sol_so_line WHERE sol_id = $1",
                 [Ecto.UUID.dump!(frozen_line.id)]
               )
    end
  end

  # ── f7: cross-org ────────────────────────────────────────────────────────────

  describe "f7 — cross-org" do
    test "a SO naming a FOREIGN org's warehouse is refused (RED); same-org lands (CONTROL)", %{
      org: org,
      scope: scope
    } do
      foreign_scope = tenant_scope(Ash.UUID.generate())
      foreign_org_id = foreign_scope.actor.org_id
      foreign_item = new_item(foreign_scope, foreign_org_id)
      foreign_wh = new_warehouse(foreign_scope, foreign_org_id)

      # SameOrgFk surfaces as an Invalid with the cross-org message (the E4 shape).
      assert {:error, %Ash.Error.Invalid{errors: xorg_errors}} =
               SalesOrder
               |> Ash.Changeset.for_create(:create, %{
                 org_id: org,
                 customer_id: Ash.UUID.generate(),
                 number: "SO-XORG",
                 order_date: ~D[2026-09-13],
                 warehouse_id: foreign_wh.id,
                 lines: [%{item_id: foreign_item.id, qty: 1, unit_price_cents: 100}]
               })
               |> Ash.create(scope: scope)

      assert Enum.any?(xorg_errors, fn e ->
               is_map(e) and to_string(e.message) =~ "same-org FK"
             end)

      {item, warehouse} = seed_pair(scope, org)
      so = new_so(scope, org, warehouse.id, [%{item_id: item.id, qty: 1, unit_price_cents: 100}])
      assert so.status == :draft
    end

    test "a foreign org's SOs and sale events are invisible (OrgScope) with the own-org CONTROL", %{
      org: _org,
      scope: scope
    } do
      foreign_scope = tenant_scope(Ash.UUID.generate())
      foreign_org_id = foreign_scope.actor.org_id
      {_item, _wh, _so, _invoice} = seed_fulfilled(foreign_scope, foreign_org_id, qty: 1, price: 700)

      # Scoped read: only our (empty) org.
      assert SalesOrder |> Ash.read!(scope: scope) == []

      # The unscoped org-zero control: the foreign rows DO exist.
      assert SalesOrder |> Ash.read!(authorize?: false) != []
      assert StockLedger |> Ash.Query.filter(kind == :sale) |> Ash.read!(authorize?: false) != []
    end
  end

  # ── f8: THE GOVERNED WALKTHROUGH ─────────────────────────────────────────────

  describe "f8 — the governed Lead → Opportunity → SO → Invoice → Receipt → GL walkthrough" do
    test "every link already has a home: the chain closes with the standing reads empty", %{
      org: org,
      scope: scope
    } do
      # ── 1. Lead (CRM entry, vaulted PII) ──────────────────────────────────
      lead =
        Lead
        |> Ash.Changeset.for_create(:create, %{
          org_id: org,
          full_name: %{first: "Grace", last: "Hopper"},
          emails: %{entries: [%{label: "work", address: "grace@example.com"}]},
          company_name: "Hopper Compilers",
          value: Money.new!(:USD, "5000.00")
        })
        |> Ash.create!(scope: scope)

      # ── 2. the sanctioned conversion → Contact + Opportunity ─────────────
      converted =
        lead
        |> Ash.Changeset.for_update(:convert, %{}, scope: scope)
        |> Ash.update!()

      assert converted.status == :converted

      person = Ash.get!(CrmScopeFixture.Person, converted.converted_person_id, authorize?: false)

      opportunity =
        Ash.get!(CrmScopeFixture.Opportunity, converted.converted_opportunity_id, authorize?: false)

      # ── 3. the SO anchored to the opportunity ─────────────────────────────
      {item, warehouse} = seed_pair(scope, org)
      stock_pair(scope, org, item, warehouse, 10, 500)

      so =
        new_so(scope, org, warehouse.id, [%{item_id: item.id, qty: 5, unit_price_cents: 1_000}],
          opportunity_id: opportunity.id,
          customer_id: person.id
        )
        |> confirm(scope)

      # ── 4. THE BRIDGE: fulfill → stock events + invoice + anchor ─────────
      fulfilled = fulfill(so, scope)

      assert fulfilled.status == :fulfilled
      assert [event] = sale_events(so.id)
      assert event.qty == -5
      assert event.unit_cost_cents == 500

      invoice = Ash.get!(InvoiceMirror, fulfilled.invoice_id, authorize?: false)
      assert invoice.status == :open
      assert invoice.amount_due_cents == 5_000

      # ── 5. the PaymentReceipt intakes the SAME anchor shape, then posts ──
      seed_posting_accounts(org)

      receipt =
        PaymentReceipt
        |> Ash.Changeset.for_create(:create, %{
          org_id: org,
          invoice_key: "billing_invoice",
          invoice_id: invoice.id,
          amount_cents: 5_000,
          paid_at: DateTime.utc_now() |> DateTime.truncate(:second)
        })
        |> Ash.create!(scope: scope)

      _posted =
        receipt
        |> Ash.Changeset.for_update(:post_receipt, %{}, scope: scope)
        |> Ash.update!()

      # ── 6. the GL leg: the POSTED cash+AR entry, the whole chain green ───
      assert {:ok, 5_000} = ReconcilePayments.receipts_total(org, @repo, receipt_resource: PaymentReceipt)

      assert {:ok, 5_000} =
               ReconcilePayments.posted_cash_total(org, @repo,
                 entry_resource: JournalEntry,
                 line_resource: JournalLine
               )

      # The R1 invariant holds through the chain: Σ debits == Σ credits.
      lines = JournalLine |> Ash.Query.filter(org_id == ^org) |> Ash.read!(authorize?: false)
      assert lines != []
      debit = lines |> Enum.map(& &1.debit_cents) |> Enum.sum()
      credit = lines |> Enum.map(& &1.credit_cents) |> Enum.sum()
      assert debit == credit
      assert debit == 5_000

      # ── 7. the standing fulfillment read: EMPTY over the whole chain ─────
      assert {:ok, []} = divergences(org)
    end
  end

  # ── helpers ──────────────────────────────────────────────────────────────────

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

  defp fulfillment_order(org, so_id) do
    ReconcileFulfillment.order(@repo, org,
      sales_order_id: so_id,
      ledger_resource: StockLedger,
      so_resource: SalesOrder,
      invoice_resource: InvoiceMirror
    )
  end

  defp divergences(org) do
    ReconcileFulfillment.divergences(@repo, org,
      so_resource: SalesOrder,
      ledger_resource: StockLedger,
      invoice_resource: InvoiceMirror
    )
  end

  defp new_item(scope, org, attrs \\ %{}) do
    Item
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{org_id: org, sku: "SKU-" <> binary_part(Ash.UUID.generate(), 0, 8), name: "A stocked item"},
        Map.new(attrs)
      ),
      scope: scope
    )
    |> Ash.create!()
  end

  defp new_warehouse(scope, org, attrs \\ %{}) do
    Warehouse
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{org_id: org, code: "WH-" <> binary_part(Ash.UUID.generate(), 0, 8), name: "Main"},
        Map.new(attrs)
      ),
      scope: scope
    )
    |> Ash.create!()
  end

  defp seed_pair(scope, org) do
    item = new_item(scope, org)
    warehouse = new_warehouse(scope, org)
    {item, warehouse}
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

  defp new_so(scope, org, warehouse_id, lines, attrs \\ %{}) do
    SalesOrder
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          org_id: org,
          customer_id: Ash.UUID.generate(),
          number: "SO-" <> binary_part(Ash.UUID.generate(), 0, 8),
          order_date: ~D[2026-09-13],
          warehouse_id: warehouse_id,
          lines: lines
        },
        Map.new(attrs)
      )
    )
    |> Ash.create!(scope: scope)
  end

  defp confirm(so, scope), do: Ash.update!(Ash.Changeset.for_update(so, :confirm, %{}, scope: scope))

  defp fulfill(so, scope), do: Ash.update!(Ash.Changeset.for_update(so, :fulfill, %{}, scope: scope))

  defp so_lines(so_id) do
    SoLine |> Ash.Query.filter(sales_order_id == ^so_id) |> Ash.read!(authorize?: false)
  end

  defp sale_events(so_id) do
    StockLedger
    |> Ash.Query.filter(source_key == "sales_order" and source_id == ^so_id)
    |> Ash.read!(authorize?: false)
    |> Enum.reverse()
  end

  defp invoices_for_org(org) do
    InvoiceMirror |> Ash.Query.filter(org_id == ^org) |> Ash.read!(authorize?: false)
  end

  defp seed_posting_accounts(org) do
    for {key, code} <- [ar_clearing: "1200", cash: "1000"] do
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

  # A confirmed+fulfilled SO over a stocked pair, fully through the sanctioned path.
  defp seed_fulfilled(scope, org, opts) do
    qty = Keyword.fetch!(opts, :qty)
    price = Keyword.fetch!(opts, :price)

    {item, warehouse} = seed_pair(scope, org)
    stock_pair(scope, org, item, warehouse, 10, 500)

    so =
      new_so(scope, org, warehouse.id, [%{item_id: item.id, qty: qty, unit_price_cents: price}])
      |> confirm(scope)
      |> fulfill(scope)

    [invoice] = invoices_for_org(org)
    {item, warehouse, so, invoice}
  end

  defp raw_sql!(sql, params) do
    case Ecto.Adapters.SQL.query(@repo, sql, params) do
      {:ok, _} -> :ok
      {:error, reason} -> flunk("raw SQL unexpectedly failed: #{inspect(reason)}\n#{sql}")
    end
  end
end
