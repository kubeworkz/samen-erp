defmodule Samen.InventoryLotsTest do
  @moduledoc """
  WS-ACCT Phase 4 (ADR-054 D3, design §3 R7) — lots, warehouses that know where
  they are, and the WIP ↔ lot reconciliation, mounted via
  `test/support/inventory_fixture.ex`.

  Every refusal is paired with a positive control (anti-tautology, `Samen.RedPath`
  discipline):

    * l1 `Lot` — create/read, `code` unique per org, the stage enum closed, and
      `SameOrgFk` refusing another org's item or cost object;
    * l2 `Warehouse.kind` — `:owned` default, `:supplier` accepted (CONTROL), an
      unknown kind refused;
    * l3 **R7 green** — a foundry receipt into a supplier location plus its
      dimensioned WIP entry reconcile to zero, and R3 still reads clean (no
      second quantity mechanism moved);
    * l4 **R7 red** — a lot whose supplier stock has no GL leg, and a WIP
      balance with no stock, are both DETECTED with both numbers named;
    * l5 the WIP **boundary** — owned stock and consignment stock are NOT
      supplier WIP: a delivered lot and a consignment lot each reconcile clean.
      (These are sabotage 405's named tests: drop the `kind = 'supplier'`
      predicate and every location's stock counts as WIP.)
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Scopes.Inventory.{ReconcileLot, ReconcileStock}

  alias SamenCore.Support.InventoryFixture.{
    Item,
    Lot,
    StockLedger,
    StockLevel,
    Warehouse
  }

  alias SamenCore.Support.FinanceFixture.{
    Account,
    CostObject,
    JournalEntry,
    JournalLine,
    PostingAccount
  }

  @repo SamenCore.TestRepo

  @read [
    lot_resource: Lot,
    ledger_resource: StockLedger,
    warehouse_resource: Warehouse,
    line_resource: JournalLine,
    posting_account_resource: PostingAccount
  ]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()
    {:ok, org: org, scope: tenant_scope(org), admin: admin_scope(org)}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp tenant_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, kind: :tenant, plane: :tenant}
    }
  end

  defp admin_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :admin, kind: :tenant, plane: :tenant}
    }
  end

  defp new_item(scope, org, sku) do
    Item
    |> Ash.Changeset.for_create(:create, %{org_id: org, sku: sku, name: "Item #{sku}"},
      scope: scope
    )
    |> Ash.create!()
  end

  defp warehouse_changeset(scope, org, code, kind) do
    Warehouse
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, code: code, name: "Warehouse #{code}", kind: kind},
      scope: scope
    )
  end

  defp new_warehouse(scope, org, code, kind),
    do: warehouse_changeset(scope, org, code, kind) |> Ash.create!()

  defp new_cost_object(admin, org, code) do
    CostObject
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, code: code, name: "Cost object #{code}", kind: :chip},
      scope: admin
    )
    |> Ash.create!()
  end

  defp lot_changeset(scope, org, attrs) do
    Lot
    |> Ash.Changeset.for_create(:create, Map.merge(%{org_id: org}, attrs), scope: scope)
  end

  defp new_lot(scope, org, item, cost_object, code, attrs \\ %{}) do
    lot_changeset(
      scope,
      org,
      Map.merge(
        %{code: code, item_id: item.id, cost_object_id: cost_object.id, wafer_count: 10},
        attrs
      )
    )
    |> Ash.create!()
  end

  defp new_account(scope, org, code, kind, side) do
    Account
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, code: code, name: "Account #{code}", kind: kind, normal_side: side},
      scope: scope
    )
    |> Ash.create!()
  end

  defp map_posting_account(admin, org, key, account) do
    PostingAccount
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, key: key, account_id: account.id},
      scope: admin
    )
    |> Ash.create!()
  end

  # A stock movement whose object-ref NAMES the lot (ADR-054 D3: the lot's cost
  # is the Σ of these, never a second register).
  defp move_stock(scope, org, item, warehouse, lot, kind, qty, unit_cost_cents) do
    StockLedger
    |> Ash.Changeset.for_create(
      :record,
      %{
        org_id: org,
        kind: kind,
        qty: qty,
        unit_cost_cents: unit_cost_cents,
        item_id: item.id,
        warehouse_id: warehouse.id,
        source_key: "lot",
        source_id: lot.id
      },
      scope: scope
    )
    |> Ash.create!()
  end

  defp post_lot_entry(scope, org, lot, debit_account, credit_account, cents) do
    refs = %{"lot" => lot.cost_object_id}

    {:ok, entry} =
      JournalEntry
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org,
          entry_date: ~D[2026-10-30],
          memo: "lot #{lot.code}",
          lines: [
            %{account_id: debit_account.id, debit_cents: cents, dimension_refs: refs},
            %{account_id: credit_account.id, credit_cents: cents, dimension_refs: refs}
          ]
        },
        scope: scope
      )
      |> Ash.create()

    entry |> Ash.Changeset.for_update(:post, %{}, scope: scope) |> Ash.update!()
  end

  # The books as the manual's fabless flows leave them: a foundry receipt into
  # a SUPPLIER location + its dimensioned WIP entry, then a delivery out of the
  # supplier location with the WIP → finished-goods transfer.
  defp open_lot_books(scope, admin, org) do
    item = new_item(scope, org, "GP180MCU-WAFER")
    supplier_wh = new_warehouse(scope, org, "FOUNDRY", :supplier)
    owned_wh = new_warehouse(scope, org, "MAIN", :owned)
    cost_object = new_cost_object(admin, org, "GP180MCU")

    wip = new_account(scope, org, "1300", :asset, :debit)
    _ = map_posting_account(admin, org, :wip_foundry, wip)
    ap = new_account(scope, org, "2000", :liability, :credit)
    fg = new_account(scope, org, "1310", :asset, :debit)

    lot = new_lot(scope, org, item, cost_object, "LOT-GP180-001")

    %{
      item: item,
      supplier_wh: supplier_wh,
      owned_wh: owned_wh,
      cost_object: cost_object,
      wip: wip,
      ap: ap,
      fg: fg,
      lot: lot
    }
  end

  # ── l1: the lot ────────────────────────────────────────────────────────────

  describe "l1 — Lot: one physical production lot" do
    test "a lot is created and read back on the tenant plane", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      item = new_item(scope, org, "GPU-X1")
      co = new_cost_object(admin, org, "GPU")
      lot = new_lot(scope, org, item, co, "LOT-GPU-001", %{wafer_count: 25, die_expected: 5000})

      assert lot.stage == :design
      assert lot.wafer_count == 25
      assert lot.die_expected == 5000

      assert [read] = Lot |> Ash.Query.filter(code: "LOT-GPU-001") |> Ash.read!(scope: scope)
      assert read.id == lot.id
      assert read.cost_object_id == co.id
    end

    test "code is unique per org (RED) — a second lot with the same code is refused", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      item = new_item(scope, org, "PTA-A")
      co = new_cost_object(admin, org, "PTA")
      _ = new_lot(scope, org, item, co, "LOT-1")

      dup = lot_changeset(scope, org, %{code: "LOT-1", item_id: item.id, cost_object_id: co.id})
      assert {:error, _} = Ash.create(dup)
      assert length(Lot |> Ash.read!(scope: scope)) == 1
    end

    test "the stage enum is closed (RED) and every documented stage is accepted (CONTROL)", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      item = new_item(scope, org, "RISCV-A")

      for {stage, n} <-
            Enum.with_index([:design, :mask, :fab, :dice, :assembly, :test, :delivered]) do
        co = new_cost_object(admin, org, "RISCV-#{n}")
        lot = new_lot(scope, org, item, co, "LOT-STAGE-#{n}", %{stage: stage})
        assert lot.stage == stage
      end

      co = new_cost_object(admin, org, "RISCV-BAD")

      bad =
        lot_changeset(scope, org, %{
          code: "BAD",
          stage: :packaging,
          item_id: item.id,
          cost_object_id: co.id
        })

      assert {:error, %Ash.Error.Invalid{}} = Ash.create(bad)
    end

    test "a lot cannot name another org's item or cost object (RED — SameOrgFk)", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      other_org = Ash.UUID.generate()
      other_admin = admin_scope(other_org)
      foreign_item = new_item(scope_for(other_org), other_org, "FOREIGN")
      foreign_co = new_cost_object(other_admin, other_org, "FOREIGN-CO")

      co = new_cost_object(admin, org, "MINE")
      item = new_item(scope, org, "MINE-ITEM")

      wrong_item =
        lot_changeset(scope, org, %{code: "X-1", item_id: foreign_item.id, cost_object_id: co.id})

      wrong_co =
        lot_changeset(scope, org, %{code: "X-2", item_id: item.id, cost_object_id: foreign_co.id})

      assert {:error, _} = Ash.create(wrong_item)
      assert {:error, _} = Ash.create(wrong_co)
      assert Lot |> Ash.read!(scope: scope) == []
    end
  end

  # ── l2: the warehouse knows where it is ────────────────────────────────────

  describe "l2 — Warehouse.kind" do
    test "kind defaults to :owned and a :supplier location is accepted (CONTROL)", %{
      org: org,
      scope: scope
    } do
      default =
        Warehouse
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org, code: "DEFAULT", name: "Default"},
          scope: scope
        )
        |> Ash.create!()

      assert default.kind == :owned

      supplier = new_warehouse(scope, org, "FOUNDRY", :supplier)
      assert supplier.kind == :supplier

      consignment = new_warehouse(scope, org, "CONSIGNED", :consignment)
      assert consignment.kind == :consignment
    end

    test "an unknown kind is refused (RED)", %{org: org, scope: scope} do
      assert {:error, %Ash.Error.Invalid{}} =
               Warehouse
               |> Ash.Changeset.for_create(
                 :create,
                 %{org_id: org, code: "NOWHERE", name: "Nowhere", kind: :somewhere},
                 scope: scope
               )
               |> Ash.create()
    end
  end

  # ── l3: R7 green ──────────────────────────────────────────────────────────

  describe "l3 — R7: supplier-location stock reconciles to its WIP balance" do
    test "a foundry receipt at a supplier location is WIP, and stock == GL", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      books = open_lot_books(scope, admin, org)

      _ = move_stock(scope, org, books.item, books.supplier_wh, books.lot, :receipt, 10, 5_000)
      _ = post_lot_entry(scope, org, books.lot, books.wip, books.ap, 50_000)

      # Stock is the only quantity truth: the level moved, and R3 stays clean.
      assert [level] = StockLevel |> Ash.read!(scope: scope)
      assert level.qty_on_hand == 10

      assert {:ok, []} =
               ReconcileStock.divergences(@repo, StockLedger, StockLevel, org)

      assert {:ok, true} = ReconcileLot.reconciled?(org, @repo, @read)
      assert {:ok, []} = ReconcileLot.divergences(org, @repo, @read)

      assert {:ok, [row]} = ReconcileLot.lots(org, @repo, @read)
      assert row.lot_id == books.lot.id
      assert row.supplier_value_cents == 50_000
      assert row.stage_value_cents == 50_000
      assert row.wip_balance_cents == 50_000
    end

    test "an undimensioned WIP posting does not count as lot WIP (CONTROL)", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      books = open_lot_books(scope, admin, org)
      _ = move_stock(scope, org, books.item, books.supplier_wh, books.lot, :receipt, 10, 5_000)

      # The stock exists but the GL was posted with NO lot dimension at all: the
      # read must not credit the lot with it (that is the divergence it reports).
      {:ok, entry} =
        JournalEntry
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: org,
            entry_date: ~D[2026-10-30],
            memo: "undimensioned",
            lines: [
              %{account_id: books.wip.id, debit_cents: 50_000},
              %{account_id: books.ap.id, credit_cents: 50_000}
            ]
          },
          scope: scope
        )
        |> Ash.create()

      _ = entry |> Ash.Changeset.for_update(:post, %{}, scope: scope) |> Ash.update!()

      assert {:ok, [row]} = ReconcileLot.lots(org, @repo, @read)
      assert row.supplier_value_cents == 50_000
      assert row.wip_balance_cents == 0
      assert {:ok, false} = ReconcileLot.reconciled?(org, @repo, @read)
    end
  end

  # ── l4: R7 red ────────────────────────────────────────────────────────────

  describe "l4 — R7: a lot whose stock and GL disagree is DETECTED" do
    test "supplier stock with no WIP leg is a divergence, with both numbers named", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      books = open_lot_books(scope, admin, org)
      _ = move_stock(scope, org, books.item, books.supplier_wh, books.lot, :receipt, 10, 5_000)

      assert {:ok, false} = ReconcileLot.reconciled?(org, @repo, @read)

      assert {:ok, [divergent]} = ReconcileLot.divergences(org, @repo, @read)
      assert divergent.code == "LOT-GP180-001"
      assert divergent.supplier_value_cents == 50_000
      assert divergent.wip_balance_cents == 0
    end

    test "a WIP balance with no stock behind it is a divergence (RED)", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      books = open_lot_books(scope, admin, org)
      _ = post_lot_entry(scope, org, books.lot, books.wip, books.ap, 50_000)

      assert {:ok, [divergent]} = ReconcileLot.divergences(org, @repo, @read)
      assert divergent.supplier_value_cents == 0
      assert divergent.wip_balance_cents == 50_000
    end
  end

  # ── l5: the WIP boundary (sabotage 405's named tests) ──────────────────────

  describe "l5 — only SUPPLIER-location stock is WIP" do
    test "owned stock is NOT WIP — a delivered lot reconciles clean", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      books = open_lot_books(scope, admin, org)

      # Foundry receipt: 10 wafers into the supplier location, WIP on the GL.
      _ = move_stock(scope, org, books.item, books.supplier_wh, books.lot, :receipt, 10, 5_000)
      _ = post_lot_entry(scope, org, books.lot, books.wip, books.ap, 50_000)

      # Delivery: the lot leaves the supplier and arrives owned; the GL moves
      # WIP → finished goods. Supplier stock is now zero and so is WIP.
      _ =
        move_stock(
          scope,
          org,
          books.item,
          books.supplier_wh,
          books.lot,
          :transfer_out,
          -10,
          5_000
        )

      _ = move_stock(scope, org, books.item, books.owned_wh, books.lot, :transfer_in, 10, 5_000)
      _ = post_lot_entry(scope, org, books.lot, books.fg, books.wip, 50_000)

      assert {:ok, [row]} = ReconcileLot.lots(org, @repo, @read)
      assert row.stage_value_cents == 50_000
      assert row.supplier_value_cents == 0
      assert row.wip_balance_cents == 0
      assert {:ok, true} = ReconcileLot.reconciled?(org, @repo, @read)
    end

    test "consignment stock is NOT supplier WIP — it reconciles clean", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      books = open_lot_books(scope, admin, org)
      consigned = new_warehouse(scope, org, "PARTNER-CONSIGNMENT", :consignment)

      # The partner holds the wafers on consignment; no WIP was ever posted for
      # them (title moved at shipment), so the lot reads clean.
      _ = move_stock(scope, org, books.item, consigned, books.lot, :receipt, 10, 5_000)

      assert {:ok, [row]} = ReconcileLot.lots(org, @repo, @read)
      assert row.stage_value_cents == 50_000
      assert row.supplier_value_cents == 0
      assert row.wip_balance_cents == 0
      assert {:ok, true} = ReconcileLot.reconciled?(org, @repo, @read)
    end
  end

  defp scope_for(org_id), do: tenant_scope(org_id)
end
