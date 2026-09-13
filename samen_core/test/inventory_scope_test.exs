defmodule Samen.InventoryScopeTest do
  @moduledoc """
  The Inventory scope + the R3 reconciliation red-path suite (WS-ERP E3;
  design §3.1 + §6.3), mounted via `test/support/inventory_fixture.ex`.

  Every red-path pairs denial with a positive control (anti-tautology, the
  house `RedPath` style). Blocks:

    * s1 Item: member CRUD CONTROL, duplicate sku refused (RED).
    * s2 Warehouse: `address` vault-routes (a `vt_*` token at rest, plaintext
      nowhere — the Locations c5 proof over the Inventory mount);
      `allow_negative` defaults fail-closed.
    * s3 append-only: raw-SQL UPDATE/DELETE of a ledger event is refused
      outright (RED) — a stock event is a fact; the sanctioned `:record`
      create is the CONTROL.
    * s4 NegativeStock (fail-closed): an issue below the floor is refused at
      the Ash guard (RED) AND at the DB trigger (raw-SQL RED twin); the
      `allow_negative` warehouse opts out (CONTROL); pairs are independent.
    * s5 the rollup: `StockLevelSync` maintains the level in-transaction —
      multi-event accumulation and the moving-average math.
    * s6 **R3 green**: the rollup == Σ ledger (qty AND value) per pair and
      org-wide; `ReconcileStock.divergences/3` is empty.
    * s7 **R3 anti-tautology**: a raw-SQL ledger event (no sync — the
      sabotage simulation) makes the sums DIVERGE; the next sanctioned event
      on the pair heals the rollup (the divergence is real and visible).
    * s8 the rollup belt: a write without the marker is refused (RED); a
      MARKER-ARMED write that diverges from the ledger is STILL refused —
      the belt re-derives the truth (RED); a matching armed write lands
      (CONTROL).
    * s9 the `:hand_edit` door: even an admin-gated raw edit of a level row
      is belt-refused — the rollup is derived, never asserted (RED). This is
      the door sabotage 304 opens.
    * s10 cross-org: SameOrgFk refuses a foreign-org item (RED); a foreign
      org's ledger rows are invisible (OrgScope) with the own-org CONTROL.
    * s11 catalog registration: every E3 fixture column is catalogued (the
      d11 twin, scoped to the four new tables).
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Scopes.Inventory.ReconcileStock
  alias SamenCore.Support.InventoryFixture.{Item, StockLedger, StockLevel, Warehouse}

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()
    {:ok, org: org, scope: tenant_scope(org)}
  end

  # ── s1: Item ─────────────────────────────────────────────────────────────────

  describe "s1 — Item master" do
    test "a member creates an item (CONTROL) with the bounded enums", %{org: org, scope: scope} do
      item = new_item(scope, org, "SKU-1")

      assert item.sku == "SKU-1"
      assert item.kind == :stocked
      assert item.uom == :unit
    end

    test "a duplicate sku in the org is refused (RED)", %{org: org, scope: scope} do
      new_item(scope, org, "DUP-1")

      assert {:error, _} =
               Item
               |> Ash.Changeset.for_create(:create, %{
                 org_id: org,
                 sku: "DUP-1",
                 name: "the second one"
               })
               |> Ash.create(scope: scope)
    end
  end

  # ── s2: Warehouse + the vaulted address ──────────────────────────────────────

  describe "s2 — Warehouse (the vaulted Address composite)" do
    test "the address vault-routes: vt_ token at rest, plaintext nowhere (RED surface)", %{
      org: org,
      scope: scope
    } do
      wh = new_warehouse(scope, org, "WH-1", %{address: %{"city" => "Springfield", "country" => "US"}})

      Samen.RedPath.assert_vault_routed!(@repo, Warehouse, wh.id, [:address], ["Springfield"])
    end

    test "allow_negative defaults fail-closed (false)", %{org: org, scope: scope} do
      wh = new_warehouse(scope, org, "WH-FC")
      assert wh.allow_negative == false
      assert wh.is_sellable == true
    end
  end

  # ── s3: append-only at the DB ────────────────────────────────────────────────

  describe "s3 — the ledger is append-only at the DB" do
    test "a sanctioned :record create lands (CONTROL)", %{org: org, scope: scope} do
      {item, wh} = seed_pair(scope, org)

      event = record_event(scope, org, item, wh, :receipt, 10, 100)
      assert event.qty == 10
      assert event.kind == :receipt
    end

    test "raw-SQL UPDATE and DELETE of a ledger event are refused outright (RED)", %{
      org: org,
      scope: scope
    } do
      {item, wh} = seed_pair(scope, org)
      event = record_event(scope, org, item, wh, :receipt, 5, 100)

      assert {:error, _} =
               Ecto.Adapters.SQL.query(
                 @repo,
                 "UPDATE skl_stock_ledger SET skl_qty = 999 WHERE skl_id = $1",
                 [Ecto.UUID.dump!(event.id)]
               )

      assert {:error, _} =
               Ecto.Adapters.SQL.query(
                 @repo,
                 "DELETE FROM skl_stock_ledger WHERE skl_id = $1",
                 [Ecto.UUID.dump!(event.id)]
               )
    end
  end

  # ── s4: NegativeStock (fail-closed) ─────────────────────────────────────────

  describe "s4 — the NegativeStock guard (fail-closed)" do
    test "an issue below the floor is refused at the Ash guard (RED) with the in-range CONTROL", %{
      org: org,
      scope: scope
    } do
      {item, wh} = seed_pair(scope, org)
      record_event(scope, org, item, wh, :receipt, 10, 100)

      assert {:error, %Ash.Error.Invalid{}} =
               StockLedger
               |> Ash.Changeset.for_create(:record, %{
                 org_id: org,
                 item_id: item.id,
                 warehouse_id: wh.id,
                 kind: :issue,
                 qty: -11
               })
               |> Ash.create(scope: scope)

      # CONTROL: exactly at the floor is legal.
      assert %StockLedger{} =
               StockLedger
               |> Ash.Changeset.for_create(:record, %{
                 org_id: org,
                 item_id: item.id,
                 warehouse_id: wh.id,
                 kind: :issue,
                 qty: -10
               })
               |> Ash.create!(scope: scope)
    end

    test "the DB trigger is the RED twin: a raw-SQL event below the floor is refused", %{
      org: org,
      scope: scope
    } do
      {item, wh} = seed_pair(scope, org)
      record_event(scope, org, item, wh, :receipt, 10, 100)

      assert {:error, _} =
               Ecto.Adapters.SQL.query(
                 @repo,
                 """
                 INSERT INTO skl_stock_ledger
                   (skl_id, skl_org_id, skl_item_id, skl_warehouse_id, skl_kind, skl_qty,
                    skl_unit_cost_cents, skl_inserted_at, skl_updated_at)
                 VALUES ($1, $2, $3, $4, 'issue', -25, 0,
                         now() at time zone 'utc', now() at time zone 'utc')
                 """,
                 [
                   Ecto.UUID.dump!(Ash.UUID.generate()),
                   Ecto.UUID.dump!(org),
                   Ecto.UUID.dump!(item.id),
                   Ecto.UUID.dump!(wh.id)
                 ]
               )
    end

    test "the per-warehouse allow_negative opt-out admits the negative (CONTROL)", %{
      org: org,
      scope: scope
    } do
      {item, wh} = seed_pair(scope, org)
      wh = set_allow_negative(org, wh)
      record_event(scope, org, item, wh, :receipt, 10, 100)

      assert %StockLedger{} =
               StockLedger
               |> Ash.Changeset.for_create(:record, %{
                 org_id: org,
                 item_id: item.id,
                 warehouse_id: wh.id,
                 kind: :adjust,
                 qty: -15
               })
               |> Ash.create!(scope: scope)
    end

    test "pairs are independent: a deep pair does not block another pair's issue", %{
      org: org,
      scope: scope
    } do
      {item_a, wh1} = seed_pair(scope, org)
      wh2 = new_warehouse(scope, org, "WH-2")
      record_event(scope, org, item_a, wh1, :receipt, 1, 100)

      # wh2 has NOTHING of item_a — the floor there is 0, so any issue is refused,
      # and the 1 unit in wh1 does not lend it depth.
      assert {:error, _} =
               StockLedger
               |> Ash.Changeset.for_create(:record, %{
                 org_id: org,
                 item_id: item_a.id,
                 warehouse_id: wh2.id,
                 kind: :issue,
                 qty: -1
               })
               |> Ash.create(scope: scope)
    end
  end

  # ── s5: the rollup ───────────────────────────────────────────────────────────

  describe "s5 — StockLevelSync maintains the rollup in-transaction" do
    test "multi-event accumulation + the moving-average math", %{org: org, scope: scope} do
      {item, wh} = seed_pair(scope, org)

      record_event(scope, org, item, wh, :receipt, 10, 100)
      record_event(scope, org, item, wh, :receipt, 10, 300)
      record_event(scope, org, item, wh, :issue, -5, 0)

      level = level_row(org, item, wh)
      # on_hand: 10 + 10 - 5 = 15
      assert level.qty_on_hand == 15
      # moving average over VALUED events: (10*100 + 10*300) / 20 = 200
      assert level.avg_unit_cost_cents == 200
      # value: Σ(qty*cost) = 1000 + 3000 = 4000
      assert level.stock_value_cents == 4000
    end

    test "a pair with no valued events carries a NULL average", %{org: org, scope: scope} do
      {item, wh} = seed_pair(scope, org)
      record_event(scope, org, item, wh, :adjust, 3, 0)

      level = level_row(org, item, wh)
      assert level.qty_on_hand == 3
      assert level.avg_unit_cost_cents == nil
      assert level.stock_value_cents == 0
    end
  end

  # ── s6: R3 green ─────────────────────────────────────────────────────────────

  describe "s6 — R3 green: the rollup equals the ledger" do
    test "per-pair sums, org-wide totals, and an empty divergence set", %{org: org, scope: scope} do
      {item_a, wh1} = seed_pair(scope, org)
      wh2 = new_warehouse(scope, org, "WH-2")
      item_b = new_item(scope, org, "SKU-B")

      record_event(scope, org, item_a, wh1, :receipt, 10, 100)
      record_event(scope, org, item_a, wh2, :receipt, 4, 250)
      record_event(scope, org, item_b, wh1, :receipt, 2, 500)

      # Per-pair: the reconciler's independent sum == the synced level row.
      {:ok, a1} = ReconcileStock.level(@repo, StockLedger, org, item_a.id, wh1.id)
      assert a1 == %{on_hand: 10, stock_value: 1_000}
      level_a1 = level_row(org, item_a, wh1)
      assert level_a1.qty_on_hand == a1.on_hand
      assert level_a1.stock_value_cents == a1.stock_value

      # Org-wide.
      {:ok, totals} = ReconcileStock.org_totals(@repo, StockLedger, org)
      assert totals == %{on_hand: 16, stock_value: 1_000 + 1_000 + 1_000}

      # The standing reconciliation read is EMPTY.
      assert {:ok, []} = ReconcileStock.divergences(@repo, StockLedger, StockLevel, org)
    end
  end

  # ── s7: R3 anti-tautology ────────────────────────────────────────────────────

  describe "s7 — R3 anti-tautology: a bypass DIVERGES the sums" do
    test "a raw-SQL ledger event (no sync) diverges; the next sanctioned event heals", %{
      org: org,
      scope: scope
    } do
      {item, wh} = seed_pair(scope, org)
      record_event(scope, org, item, wh, :receipt, 10, 100)

      # The bypass: a ledger event written under the guards (raw SQL — the
      # sabotage simulation), so no sync runs. The rollup goes stale.
      assert {:ok, _} =
               Ecto.Adapters.SQL.query(
                 @repo,
                 """
                 INSERT INTO skl_stock_ledger
                   (skl_id, skl_org_id, skl_item_id, skl_warehouse_id, skl_kind, skl_qty,
                    skl_unit_cost_cents, skl_inserted_at, skl_updated_at)
                 VALUES ($1, $2, $3, $4, 'receipt', 50, 100,
                         now() at time zone 'utc', now() at time zone 'utc')
                 """,
                 [
                   Ecto.UUID.dump!(Ash.UUID.generate()),
                   Ecto.UUID.dump!(org),
                   Ecto.UUID.dump!(item.id),
                   Ecto.UUID.dump!(wh.id)
                 ]
               )

      assert {:ok, [d]} = ReconcileStock.divergences(@repo, StockLedger, StockLevel, org)
      assert d.ledger_qty == 60
      assert d.level_qty == 10
      assert d.ledger_value == 6_000
      assert d.level_value == 1_000

      # The next sanctioned event on the pair re-syncs from the FULL ledger
      # tail — the divergence heals (and was visible while it existed).
      record_event(scope, org, item, wh, :adjust, 1, 0)
      assert {:ok, []} = ReconcileStock.divergences(@repo, StockLedger, StockLevel, org)
    end
  end

  # ── s8: the rollup belt ──────────────────────────────────────────────────────

  describe "s8 — the rollup belt refuses writes (armed or not) that diverge" do
    test "a write without the marker is refused (RED)", %{org: org, scope: scope} do
      {item, wh} = seed_pair(scope, org)
      record_event(scope, org, item, wh, :receipt, 10, 100)

      assert {:error, _} =
               Ecto.Adapters.SQL.query(
                 @repo,
                 "UPDATE slv_stock_level SET slv_qty_on_hand = 999 WHERE slv_org_id = $1",
                 [Ecto.UUID.dump!(org)]
               )
    end

    test "a MARKER-ARMED write that DIVERGES from the ledger is still refused (RED)", %{
      org: org,
      scope: scope
    } do
      {item, wh} = seed_pair(scope, org)
      record_event(scope, org, item, wh, :receipt, 10, 100)

      arm_sync_marker()

      assert {:error, _} =
               Ecto.Adapters.SQL.query(
                 @repo,
                 "UPDATE slv_stock_level SET slv_qty_on_hand = 999 WHERE slv_org_id = $1",
                 [Ecto.UUID.dump!(org)]
               )

      disarm_sync_marker()
    end

    test "a marker-armed write that MATCHES the ledger lands (CONTROL)", %{org: org, scope: scope} do
      {item, wh} = seed_pair(scope, org)
      record_event(scope, org, item, wh, :receipt, 10, 100)

      arm_sync_marker()

      assert {:ok, _} =
               Ecto.Adapters.SQL.query(
                 @repo,
                 "UPDATE slv_stock_level SET slv_qty_on_hand = 10, slv_stock_value_cents = 1000 WHERE slv_org_id = $1",
                 [Ecto.UUID.dump!(org)]
               )

      disarm_sync_marker()
    end
  end

  # ── s9: the hand-edit door ───────────────────────────────────────────────────

  describe "s9 — the :hand_edit door is belt-refused" do
    test "even an admin-gated raw edit of a level row is refused (RED)", %{org: org, scope: scope} do
      {item, wh} = seed_pair(scope, org)
      record_event(scope, org, item, wh, :receipt, 10, 100)
      level = level_row(org, item, wh)

      # The belt's RAISE surfaces as Ash.Error.Unknown-wrapped (the E2 d6
      # lesson) — the assertion matches the class, and the message is the
      # belt's own (a raise with the marker's name proves WHICH net fired).
      assert {:error, %Ash.Error.Unknown{}} =
               level
               |> Ash.Changeset.for_update(:hand_edit, %{qty_on_hand: 999}, scope: admin_scope(org))
               |> Ash.update()

      # The rollup still says what the ledger says.
      assert level_row(org, item, wh).qty_on_hand == 10
    end
  end

  # ── s10: cross-org ───────────────────────────────────────────────────────────

  describe "s10 — cross-org discipline" do
    test "a ledger event cannot name a FOREIGN org's item (SameOrgFk RED)", %{org: org, scope: scope} do
      foreign_org = Ash.UUID.generate()
      foreign_scope = tenant_scope(foreign_org)
      foreign_item = new_item(foreign_scope, foreign_org, "FOREIGN-1")
      wh = new_warehouse(scope, org, "WH-MINE")

      assert {:error, _} =
               StockLedger
               |> Ash.Changeset.for_create(:record, %{
                 org_id: org,
                 item_id: foreign_item.id,
                 warehouse_id: wh.id,
                 kind: :receipt,
                 qty: 5
               })
               |> Ash.create(scope: scope)
    end

    test "a foreign org's ledger rows are invisible (OrgScope) with the own-org CONTROL", %{
      org: org,
      scope: scope
    } do
      foreign_org = Ash.UUID.generate()
      foreign_scope = tenant_scope(foreign_org)
      {foreign_item, foreign_wh} = seed_pair(foreign_scope, foreign_org)
      record_event(foreign_scope, foreign_org, foreign_item, foreign_wh, :receipt, 77, 100)

      {item, wh} = seed_pair(scope, org)
      record_event(scope, org, item, wh, :receipt, 5, 100)

      seen =
        StockLedger
        |> Ash.Query.filter(item_id == ^foreign_item.id)
        |> Ash.read!(scope: scope)

      assert seen == []

      mine =
        StockLedger
        |> Ash.Query.filter(item_id == ^item.id)
        |> Ash.read!(scope: scope)

      assert mine != []

      # The E1 org-zero discipline applied to stock: an org's R3 totals sum
      # ITS ledger only — the foreign org's 77 units (7_700 value) never leak
      # into them.
      assert {:ok, %{on_hand: 5, stock_value: 500}} =
               ReconcileStock.org_totals(@repo, StockLedger, org)

      assert {:ok, %{on_hand: 77, stock_value: 7_700}} =
               ReconcileStock.org_totals(@repo, StockLedger, foreign_org)
    end
  end

  # ── s11: catalog registration ────────────────────────────────────────────────

  describe "s11 — catalog registration (mix samen.verify.catalog_parity is green)" do
    test "every E3 fixture column is catalogued in fld_field" do
      tables = %{
        "sit_item" => ["sit_sku", "sit_name", "sit_kind", "sit_uom", "sit_org_id"],
        "swh_warehouse" => ["swh_code", "swh_name", "swh_allow_negative", "swh_address", "swh_org_id"],
        "skl_stock_ledger" => [
          "skl_kind",
          "skl_qty",
          "skl_unit_cost_cents",
          "skl_item_id",
          "skl_warehouse_id",
          "skl_org_id"
        ],
        "slv_stock_level" => [
          "slv_qty_on_hand",
          "slv_qty_on_order",
          "slv_avg_unit_cost_cents",
          "slv_stock_value_cents",
          "slv_item_id",
          "slv_warehouse_id",
          "slv_org_id"
        ]
      }

      rows =
        for {table, columns} <- tables, column <- columns do
          {table, column}
        end

      for {table, column} <- rows do
        %{rows: found} =
          @repo.query!(
            "SELECT 1 FROM fld_field WHERE fld_table_name = $1 AND fld_column_name = $2",
            [table, column]
          )

        assert found != [], "#{table}.#{column} is not catalogued in fld_field"
      end
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

  defp new_item(scope, org, sku, attrs \\ %{}) do
    Item
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{org_id: org, sku: sku, name: "Item #{sku}"}, Map.new(attrs)),
      scope: scope
    )
    |> Ash.create!()
  end

  defp new_warehouse(scope, org, code, attrs \\ %{}) do
    Warehouse
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{org_id: org, code: code, name: "Warehouse #{code}"}, Map.new(attrs)),
      scope: scope
    )
    |> Ash.create!()
  end

  defp seed_pair(scope, org) do
    item = new_item(scope, org, "SKU-" <> binary_part(Ash.UUID.generate(), 0, 8))
    wh = new_warehouse(scope, org, "WH-" <> binary_part(Ash.UUID.generate(), 0, 8))
    {item, wh}
  end

  defp record_event(scope, org, item, wh, kind, qty, unit_cost, attrs \\ %{}) do
    StockLedger
    |> Ash.Changeset.for_create(
      :record,
      Map.merge(
        %{
          org_id: org,
          item_id: item.id,
          warehouse_id: wh.id,
          kind: kind,
          qty: qty,
          unit_cost_cents: unit_cost
        },
        Map.new(attrs)
      ),
      scope: scope
    )
    |> Ash.create!()
  end

  defp set_allow_negative(org, wh) do
    wh
    |> Ash.Changeset.for_update(:update, %{allow_negative: true}, scope: admin_scope(org))
    |> Ash.update!()
  end

  defp level_row(org, item, wh) do
    StockLevel
    |> Ash.Query.filter(org_id == ^org and item_id == ^item.id and warehouse_id == ^wh.id)
    |> Ash.read_one!(authorize?: false)
  end

  # The belt marker: transaction-local, so within the sandboxed test it stays
  # armed for the rest of the test transaction unless disarmed (the E1 lesson —
  # the sandbox has no savepoint isolation; arm and disarm explicitly).
  defp arm_sync_marker do
    {:ok, _} =
      Ecto.Adapters.SQL.query(@repo, "SELECT set_config('samen.stock_sync', 'on', true)", [])

    :ok
  end

  defp disarm_sync_marker do
    {:ok, _} =
      Ecto.Adapters.SQL.query(@repo, "SELECT set_config('samen.stock_sync', 'off', true)", [])

    :ok
  end
end
