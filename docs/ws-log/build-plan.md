# WS-LOG — Logistics & Supply Chain · Build Plan

- **Status:** PROPOSED. Follows `docs/ws-log/design.md`; phase L0 filed ADR-056 (this plan is the
  ADR's build half). On 2026-11-22 the operator RATIFIED OD-1, the L1 half of OD-2, OD-7, PF-1,
  PF-2 Option A and PF-3; OD-2's L1b half and OD-3–OD-6 remain DEFERRED and unratified. L1.1's
  migration contract (shipment resources, `lot_tracked`, scoped catalog sync/down and the
  reversible `:expand` migration) is implemented, as are L1's legacy `:fulfill` live lot refusal
  and L1.2's `ShipPosting`/`Shipment :ship` (lock/re-read/flip, frozen cost, stock/COGS/invoice)
  plus R6's `ReconcileShipment` read and the L1.4 concurrency/host-walkthrough proofs; the
  L1.3 surface is not authored by this plan.
- **Sizing:** one deliverable per unit, serialized by default, each phase independently
  committable and gate-able. Every phase ends with the adversarial gate: named tests flip under a
  committed sabotage patch, revert byte-exact, and the suites + verifiers stay green.
- **Standing gate:** R3 (stock), R4 (manufacturing), R5 (three-way match) stay green; each new
  reconciliation R6–R9 ships with a green path, a red-path twin and a sabotage patch.

---

## Dependency graph

```
L0 (ADR-056 + audit + decisions)
 └─> L1 (partial-fulfillment posting)
      ├─> L4 (ASN + variances + landed cost)
      ├─> L5 (transfers + cycle counts; bins decision)
      └─> L1b (shipment document: destination, packages, print)
            ├─> L2 (carrier adapter + tracking)
            └─> L3 (returns / RMA; needs shipment lines + destination)
 L2 + L3 + L4 + L5 ──> L6 (replenishment suggestions + supplier collaboration + EDI adapters)
 L2 + L3 + L4 + L5 ──> L7 (rollups/operator KPI + hardening + root gate)
```

L1 is the first milestone and must land before the rest. L1b is the shipment document's completion
(destination/recipient, packages, print, pick/pack/delivered, DB belts)—it is deliberately split
out so the first slice proves stock/COGS/invoice without PII or carrier work. L2–L5 are
parallel-safe after L1's branch/migration (and L1b where destination is needed), but the default is
still one unit at a time.

---

## Phase L0 — ADR-056, audit, and the decisions that bind the build

**Deliverables (docs only):**

1. Write `docs/adr/ADR-056-logistics-supply-chain.md` from design §2, with D1–D10 as numbered
   decisions and the rejected alternatives recorded.
2. Audit the E13/E14 skeletons and record the result in the ADR:
   - `TransferOrder :post` carries no change and never stamps `posted_at`; `TransferGuard` is
     wired to nothing (its only non-self mention is the allowlist) and calls
     `Samen.Scopes.Inventory.StockLevel`, a module that does not exist (host resources live in the
     host namespace). The `etn_transfer_order` table has only an
     org index — no FKs/checks — and there is no `warehouse_transfers_test.exs`; README's
     "14 tests" claim is stale (ADR-055 records the old test as vacuous).
   - `LandedCostAllocator.change/3` is a documented placeholder but is not wired to `:allocate`
     (the allocator's only non-self mention is the allowlist); `LandedCost :allocate` carries no
     change; there is no `LandedCostAllocation` resource/table; the migration has no FKs/checks
     and no value/GL posting. Only the pure `allocate_by_*` math is tested.
   **RATIFIED (OD-7): repair, not delete**; L4/L5 own the repair. Record that ADR-055's "live"
   means mounted/migrated/allowlisted, not "wired".
3. Record the ADR-056 decisions. On 2026-11-22 the operator RATIFIED:
   - **OD-1:** the Inventory `logistics:` branch, not a new scope (D1);
   - **OD-2 L1 half:** L1 adds a partial-shipment path and keeps `:fulfill`'s full-order shape,
     adding only the shared live lot refusal;
   - **OD-7:** repair the E13/E14 skeletons in L4/L5, not delete;
   - **PF-1, PF-2 Option A and PF-3:** the L1 row-lock protocol, defer lot-aware
     movement to L1b, and freeze the ship cost with the PF-3 no-entry rules.
   The following remain **DEFERRED and unratified**:
   - **OD-2 L1b half:** fulfillment unification and the SO invoice anchor, after L1 proves R6;
   - **OD-3 (L1b):** ship-to source — snapshot on Shipment, not a live CRM read;
   - **OD-4 (L2):** carrier credentials in host runtime config/secrets, never DB;
   - **OD-5 (L5):** bin grain, pending an ADR-056 amendment (D8);
   - **OD-6 (L3):** returns post a Finance `CreditNote`; no cash refund in the base.
   Binding, not open: L1 carries no PII (D9; ship-to/recipient and masking arrive in L1b);
   `StockValueAdjustment` is the landed-cost value leg (D6); D3's one-quantity/one-money truth
   applies to every phase.
4. Correct the stale claims this audit found: the ERP registry has 13 surfaces today, not six;
   it supports governed writes, so "read-only LiveView" is wrong; and `README.md`/claim-evidence
   must stop claiming the E13 transfer tests (`warehouse_transfers_test.exs`, 14 tests) exist or
   that E13 "coordinates transfer_out + transfer_in", and must not describe E14's allocation as a
   balance-guarded posting. Keep this a doc-only correction; do not "fix" it with new tests in L0.
5. Update `docs/adr/README.md` with the ADR row and `docs/ws-log/design.md` status if the ADR
   changes a decision.

**Gate:** doc-only; ADR numbering/README consistent; no abbrev rows touched; no code or migration.

---

## Phase L1 — Partial-fulfillment posting (the first milestone)

**Scope:** `Shipment` + `ShipmentLine`; the `ShipPosting` chokepoint; SO partial state; one minimal
shipment surface. **No** carrier, destination/recipient, packages, tracking, print, PII or DB
immutability belts — those are L1b/L2. `:fulfill`'s full-order shape is unchanged; the shared
lot guard is added.

### L1.1 Core resources and mount branch

- New `samen_core/lib/samen/scopes/inventory/blueprint_logistics.ex`:
  - only `define_shipment/…` and `define_shipment_line/…` in this phase;
  - `Shipment`: number (unique per org), sales_order_id, warehouse_id,
    status ∈ {draft, shipped}, shipped_at, invoice_key/invoice_id, memo;
  - `ShipmentLine`: shipment_id, so_line_id, item_id, positive qty, unit_price_cents snapshot,
    unit_cost_cents frozen at ship; unique `(shipment_id, so_line_id)`; create/read only for
    user-facing actions (no update/destroy); the private `:stamp_cost` action is the one internal
    update; frozen once the shipment leaves `:draft`;
  - L1 lot gate: `Item.lot_tracked` defaults `false`; the migration marks items with existing `Lot`
    rows. Both the `Shipment :ship` and legacy `SalesOrder :fulfill` preflights refuse a line for
    an item whose flag is true **or** which has any existing `Lot` row, with
    `:lot_tracked_requires_l1b`, before any invoice/stock/COGS write. `FulfillOrder` runs the check
    after its confirmed pre-state and before `emit_invoice`; the shipment path runs it after its
    locks. The live check is authoritative: a `Lot` inserted directly (bypassing `Lot :create`)
    after the backfill is still refused even though its item's flag remains `false`. No
    `StockLedger`/`ShipmentLine` lot columns in L1;
  - `SameOrgFk` on shipment→SO/warehouse and line→shipment/so_line/item; org-scoped policies
    (`RoleAtLeast :member` for writes), no destroy. No PII in this phase.
- Extend `Samen.Scopes.Inventory` (`samen_core/lib/samen/scopes/inventory.ex`) with an optional
  `logistics:` option: compiles the two resources only when `logistics: true` **and** `finance:` +
  `billing:` are wired; adds them to the mount's `resources` block; threads `abbrevs.shipment` and
  `abbrevs.shipment_line` at expansion time.
- Extend `SalesOrder`/`SoLine`:
  - add `:partially_fulfilled` to the status enum;
  - `qty_shipped` is a derived read (sum of posted shipment-line quantities), not a column;
  - `:fulfill` keeps E5's confirmed-only, full-order, one-invoice shape, adds the shared live lot
    refusal before any write, and is not converted to a shipment in this phase;
  - add a private internal `update :apply_shipment` (`accept([])`, `PostingMarker`,
    `require_atomic?(false)`) for `ShipPosting` to flip the SO; no UI route exposes it; `SoState`
    admits only `:confirmed → :partially_fulfilled` and
    `:partially_fulfilled → :fulfilled` for it and refuses every other pre-state. Do not reuse
    `:fulfill` or force-stamp the SO outside an action;
  - `SoState` already refuses `:fulfill` outside `:confirmed` and `:cancel` outside
    `:draft`/`:confirmed`; keep those semantics. The new action and the host belt learn the new
    state; `:fulfill`'s semantics do not.
- Extend the existing `Item` resource with `lot_tracked` (boolean, default `false`); define it on
  the generated resource, not only as a migration column. Add `:lot_tracked` to the `Item :update`
  accept with a validation/change that refuses clearing it while any `Lot` row exists
  (`:lot_tracked_has_lots`); setting it false is allowed only with no lots (positive control).
  Both L1 lot preflights read this attribute **and** perform a read-only live `Lot` existence
  check (backed by the existing `lot.item_id` index); a `false` flag alone never authorizes
  shipment. It adds no `ShipmentLine`/`StockLedger` lot columns.
- Maintain the flag on lot creation: extend the existing `Lot :create` action so it transactionally
  marks its item's `lot_tracked = true`; if the mark cannot be written, the lot create rolls back.
  This is resource-level maintenance, not a replacement for the live EXISTS belt below.
- Host migration `samenerp/priv/repo/migrations/20261122120000_mount_inventory_logistics.exs`
  (`Samenerp.Repo.Migrations.MountInventoryLogistics`):
  - `use Samen.Migration, phase: :expand`; explicit `down/0` (not `change/0`) so
    `Samen.Migration.DownCheck` discovers it. Do not set `@disable_ddl_transaction true`.
  - add the physical column `eni_item.eni_lot_tracked` (logical `lot_tracked`) as
    `boolean, null: false, default: false`; backfill it from existing `elt_lot` rows. The
    backfill is initial state only, not the safety boundary; the idempotent post-deploy
    reconciliation re-runs the same predicate after old writers drain (a one-off task, not a
    schema-migration rerun). Until then the live preflights on both paths are the safety belt.
  - create only `shp_shipment` and `shm_shipment_line`, with org indexes, same-org FKs, unique
    `(org_id, number)` and `(shipment_id, so_line_id)`; add `unit_cost_cents` to the line. Add no
    shipment/ledger lot columns in L1.
  - replace the `eso_status_valid` check with
    `draft|confirmed|partially_fulfilled|fulfilled|cancelled`; replace
    `eso_sales_order_enforce_state()` so the marker-armed `confirmed → partially_fulfilled` and
    `partially_fulfilled → fulfilled` transitions are the only new paths. Down restores the
    pre-L1 check and function body.
  - catalog in the migration transaction: `catalog_sync([Samenerp.Erp.Item], only: [:lot_tracked])`
    and `catalog_sync([Samenerp.Erp.Shipment, Samenerp.Erp.ShipmentLine])` after their DDL.
  - `down/0` order: `catalog_sync_down([Samenerp.Erp.Shipment,
    Samenerp.Erp.ShipmentLine])`; `catalog_sync_down([Samenerp.Erp.Item], only:
    [:lot_tracked])`; drop the L1 `eso_status_valid` check and restore the pre-L1
    `eso_status_valid` check; restore the pre-L1 `eso_sales_order_enforce_state()` body
    (removing the L1 statuses/transitions); `drop(table(:shm_shipment_line))`;
    `drop(table(:shp_shipment))`; remove `eni_item.eni_lot_tracked`.
  - no package/event/carrier tables and no shipment-line immutability triggers in L1 — those are
    L1b (lines are create/read only here, so there is no update path to freeze; the belt returns
    when L1b adds draft editing).
- Reserve only the two new abbrevs (`shp` and `shm`; `shl` is already owned by
  `Samenerp.Hr.LeaveRequest`) through `mix samen.abbrev.reserve`;
  refresh the goldens; never hand-edit `priv/abbrev_registry.json`.
- `mix samen.catalog.dump` so `schema.dict.json` matches the two tables; run
  `mix samen.verify.catalog_parity` and `mix samen.verify.migrations`.

### L1.2 `ShipPosting` — the partial chokepoint

- Extract the per-line stock/COGS/invoice mechanics from `FulfillOrder` into
  `samen_core/lib/samen/scopes/inventory/ship_posting.ex`; `FulfillOrder` calls the shared helper
  for stock/COGS/invoice and gains the same live lot guard in its preflight before `emit_invoice`
  or any stock/COGS write. Its full-order shape, invoice contract and existing non-lot tests are
  otherwise unchanged. Preserve its public `source_key/0` and `invoice_key/0` (or update every call
  site in the same commit).
- `Shipment :ship` uses that helper (the action carries `PostingMarker` + the `ShipPosting`
  change and `require_atomic?(false)`):
  - lock the org-pinned shipment row, then its SalesOrder row; re-read status and live remaining
    quantity after both locks; no reverse lock order;
  - preflight after the locks and before any write: shipment `:draft`, SO
    `:confirmed|:partially_fulfilled`, at least one line, every qty positive and ≤ remaining,
    same warehouse as the SO, item resolution, and a moving-average snapshot (a missing level row
    is refused; a nil average is a stocked zero-cost pair, not a missing cost); a lot-tracked or
    lot-backed line (flag true, or any existing `Lot` row including one created after the backfill)
    is refused with `:lot_tracked_requires_l1b`;
  - the live `Lot` check (backed by the existing `lot.item_id` index) remains authoritative even
    though `Lot :create` maintains the flag: it catches out-of-band rows and old writers during
    the rollout window;
  - per line: freeze `unit_cost_cents` through the private `:stamp_cost` action, then
    `StockLedger :sale` (negative qty, that snapshot, anchored `source_key: "shipment"`), running
    `NegativeStock` + `StockLevelSync`;
  - one COGS entry for the line's cost (skipped when zero) and one Billing invoice for the shipped
    lines, anchored on the shipment;
  - shipment → `:shipped` via conditional update; SO flipped through `:apply_shipment` →
    `:partially_fulfilled|:fulfilled` in the same transaction; `PostingMarker` is the belt;
    exactly-once is the lock/re-read/flip protocol.
- No `:fulfill` wrapper in this phase; E5 keeps its own entry point, tests and full-order shape,
  with only the shared lot refusal added. This is the deliberate split recorded in design D2.
- New `reconcile_shipment.ex` (R6), independent bare-SQL reads over stock events, COGS and invoice
  rows, sharing only the shipment id; `divergences/2` covers stock-without-lines,
  lines-without-stock, invoice total ≠ Σ qty × price, COGS total (zero when the entry is nil)
  ≠ Σ qty × stock cost, and an SO whose shipped + open exceeds ordered or open < 0.

### L1.3 Surface

- New `samen_web/lib/samen/web/logistics.ex` + `samen_web/lib/samen/web/logistics/shipment_live.ex`:
  list/detail, create-from-SO (choose remaining lines/qtys and warehouse), and the ship action.
  - org-pinned mount scope; writes only through resource actions; role `:member`;
  - list columns: number, status, ship date (no PII);
  - no print, carrier, destination, tracking or masking test in this phase;
  - `samen_logistics_routes/3` router macro (one line in `samenerp/lib/samenerp_web/router.ex`).
- `Samenerp.Erp` adds `logistics: true`; nav labels updated; `mix samen.verify.nav_links` green.
- `Samen.Web.Erp` is left alone. It is the bounded generic registry (13 surfaces, governed
  writes), not a read-only module; this workflow simply does not belong in its table.

### L1.4 Tests and gate

- `samen_core/test/inventory_shipment_test.exs`:
  - one order ships in two partials: stock events, COGS and invoices per shipment; SO states;
  - two concurrent `:ship` calls on one shipment produce one stock/COGS/invoice set; two
    concurrent shipments on one SO cannot both pass the remaining check (observe one conflict).
    `s8` runs the callers in Tasks over the shared sandbox connection: it proves action-level
    exactly-once/serialization and the shipment-state/posted-quantity re-reads (sabotages
    438/439). `s9` supplies the true two-session proof: committed fixtures, two unboxed
    connections, and a third-session SO-row barrier; sabotage 440 removes only the shipment
    `FOR UPDATE` lock (the SO lock remains the barrier) and must flip the named s9 test. The
    cleanup deletes the test org with `session_replication_role = replica` inside one cleanup
    transaction so the finance append-only journal triggers do not keep the fixtures behind;
  - `:apply_shipment` refuses a draft/cancelled/fulfilled SO before any write;
  - over-ship, zero-qty, unlinked item, missing level row (never stocked), and negative stock
    refused before any write (each paired with a positive control); a nil moving average is
    accepted as zero cost, matching E5, not refused as missing;
  - a lot-tracked line is refused with `:lot_tracked_requires_l1b` before any write; the non-lot
    positive control still ships;
  - a `Lot` inserted directly (bypassing `Lot :create`, so the item's `lot_tracked` stays
    `false`) after the L1 backfill is refused with `:lot_tracked_requires_l1b` before any write;
    the non-lot positive control still ships. The named test is `a Lot created after the L1
    backfill cannot ship as a non-lot item`; this proves the live existence check, not the
    maintained flag, is the deployment/out-of-band gate;
  - the frozen `unit_cost_cents` is used for COGS; zero-cost lines post no COGS and no zero-value
    journal; a missing item inventory/posting account refuses before any write;
  - replay/retry refused (exactly-once);
  - R6 green; `ReconcileShipment.divergences/3` empty for every shipped shipment;
  - **E5's existing non-lot `:fulfill` suite stays green**; the new legacy lot-refusal test is the
    only added behavior coverage;
  - legacy R3/R4/R5 suites unchanged green.
- `samen_core/test/inventory_lots_test.exs`: `Lot :create` transactionally marks its `Item`'s
  `lot_tracked = true`; an `Item` update refuses to clear the flag while a `Lot` exists with
  `:lot_tracked_has_lots`, while a no-lot item can still clear it. The named tests are
  `Lot :create marks its Item lot_tracked` and
  `an Item cannot clear lot_tracked while a Lot exists`.
- `samen_core/test/inventory_sales_order_test.exs`: the legacy `SalesOrder :fulfill` refuses a
  lot-tracked or lot-backed SO before `emit_invoice` or any stock/COGS write; assert
  `:lot_tracked_requires_l1b`, no invoice/stock/COGS/SO flip, then fulfill the non-lot control.
  Cover a `Lot` inserted directly (bypassing `Lot :create`) after the L1 backfill while
  `lot_tracked` is still `false`. The named test is `legacy :fulfill refuses a lot-backed item
  before any write`.
- `samen_web/test/samen/web/logistics_shipment_surface_test.exs`: the list renders, create-from-SO
  builds the remaining lines, and ship transitions the record; no masking assertions yet.
- `samenerp/test/logistics_migration_contract_test.exs`: assert
  `Samen.Migration.DownCheck.expand_migrations(Path.expand("../priv/repo/migrations", __DIR__))`
  contains `%{version: 20261122120000,
  name: "20261122120000_mount_inventory_logistics.exs", phase: :expand}`. This is target-specific;
  `--min-expand 1` is not sufficient once another expand exists. The named test is `the L1
  logistics migration is discovered as an :expand down-check target`.
- `samenerp/test/logistics_walkthrough_test.exs`: SO → partial shipment → invoice → second
  shipment → fulfilled, against the host mount.
- `samenerp/test/logistics_lot_tracked_backfill_test.exs` — **the migration proof only.** Seed an
  existing `Item` with a `Lot` row and one without before the L1 logistics migration, run the real
  source migration directory, and assert: (a) `lot_tracked = true` for the item with a `Lot` row;
  (b) `false` for the item without one; (c) the target version is recorded in `schema_migrations`
  (the real migration module ran, not a `_build` copy) and the physical
  `eni_item.eni_lot_tracked` column plus its `fld_field` row (`eni_lot_tracked` / `lot_tracked`)
  exist. The named test is `the L1 migration backfills Item.lot_tracked from existing Lot rows and
  leaves non-lot items false`; the header carries the full name, not a prefix, so no other test in
  the file can satisfy the anchor.
  Do **not** assert the live-`Lot` ship refusal here: that proof (a `Lot` inserted directly while
  `lot_tracked` is still `false` is refused, and the non-lot control still ships) is the core
  `samen_core/test/inventory_shipment_test.exs` named test above. A host test that also needs the
  full Shipment/Billing/Finance fixture would let an unrelated fixture failure obscure a migration
  regression, and each sabotage anchor needs exactly one home.

**Backfill harness (the executable seam).** `samenerp/test/test_helper.exs` boots the host schema
to head through `Samen.TestDb.boot!(Repo)` before ExUnit starts, so a pre-migration row cannot be
seeded in the shared test database. This test owns a scratch database and drives the real
migration directory itself. `async: false` is required — one scratch database and one migrator
advisory lock per module.

1. Derive the config from `Samenerp.Repo.config()`: delete `:pool` (the SQL sandbox must not wrap
   the DDL), give it a unique name
   (`samenerp_logistics_backfill_#{System.unique_integer([:positive])}`), and set a real pool
   (`DBConnection.ConnectionPool`, `pool_size: 3`) — Ecto's migrator needs two connections.
2. Create the database with `Samen.TestDb.ensure_up!(config)`. This is the repository's one
   tolerant create; the db-boot verifier rejects raw adapter `storage_up`/`storage_down` calls in
   any harness that owns a database, and this scratch path is no exception.
3. Start a scratch repo defined in the test module, using the same shape as
   `mix samen.verify.migrations`'s `define_scratch_repo/2` (`use Ecto.Repo,
   otp_app: :samenerp, adapter: Ecto.Adapters.Postgres`) and `start_link(config)`.
4. Migrate the real directory to the version immediately before L1:
   `Ecto.Migrator.run(ScratchRepo, @migrations, :up, to: @l1_version - 1, log: false)`, with
   `@migrations = Path.expand("../priv/repo/migrations", __DIR__)` and
   `@l1_version = 20_261_122_120_000`. `:to` is inclusive, so this runs everything strictly
   before the target. The path is the source directory, never a `_build` copy: a patched source
   migration must be the one that executes, so assert `File.regular?` on the L1 file first.
5. Seed the pre-migration state with raw SQL (`Ecto.Adapters.SQL.query!/3`). Ash actions would
   apply the post-L1 `lot_tracked` behavior, and the fixture exists to reproduce rows written
   before the column existed.
6. Run the target: `Ecto.Migrator.run(ScratchRepo, @migrations, :up, to: @l1_version, log: false)`.
7. Assert the loaded state, not the migration's return value: the lot-backed item's
   `eni_lot_tracked` is `true` and the control item's is `false`; the column is `boolean`,
   `NOT NULL`, default `false` (`information_schema.columns`); an item inserted after the
   migration defaults to `false`; and the catalog row (`fld_table_name = 'eni_item'`,
   `fld_column_name = 'eni_lot_tracked'`, `fld_type = 'Boolean'`) exists.
8. Tear down in `on_exit`: `Supervisor.stop(ScratchRepo)` when `Process.whereis(ScratchRepo)` is
   set, then `Ecto.Adapters.Postgres.storage_down(config)`. Never leave the scratch database
   behind. Wrap both migration runs in the module-conflict toggle
   (`Code.get_compiler_option(:ignore_module_conflict)` → `true`, restored in `after`) because
   the run compiles migration modules that may already be loaded.

**Fixture graph (four nodes, not two).** `elt_lot` carries `NOT NULL` FKs to `eni_item` and
`eco_cost_object`, so "an item and a lot" is not a seedable state. The minimum graph is:

```text
org_id (uuid)                — tenant pin; the org columns below carry no FK, so no org_org row is needed
├─ eco_cost_object           — eco_id, eco_org_id = org_id, eco_code (unique per org), eco_name, eco_kind
├─ eni_item (lot-backed)     — eni_id, eni_org_id = org_id, eni_sku, eni_name, eni_kind 'stocked', eni_uom 'unit'
│    └─ elt_lot              — elt_item_id = that item, elt_cost_object_id = that cost object,
│                              elt_code (unique per org), elt_stage 'design', counts 0
└─ eni_item (control)        — same shape, no elt_lot row
```

- `eco_cost_object`: `eco_code`, `eco_name` and `eco_kind` are non-null; `eco_kind` is
  host-defined (`project` works); both timestamps are non-null. One row covers every lot in the
  fixture.
- `eni_item`: `eni_sku` and `eni_name` are non-null and `(eni_org_id, eni_sku)` is unique; set
  `eni_kind 'stocked'`, `eni_uom 'unit'` and both timestamps. Do **not** write `eni_lot_tracked`
  — the migration under test adds it; the seed predates the column.
- `elt_lot`: `elt_item_id` → the lot-backed `eni_item` and `elt_cost_object_id` → the
  `eco_cost_object` are both `null: false` FKs (`elt_lot_elt_item_id_fkey`,
  `elt_lot_elt_cost_object_id_fkey`); `elt_code` is unique per org; `elt_stage` must be one of
  `design|mask|fab|dice|assembly|test|delivered`; the three count columns are `>= 0`; both
  timestamps are non-null. Insert exactly one lot for the lot-backed item and none for the
  control.
- The control is what makes the backfill's predicate observable: it stays `false` after the
  migration, so an `UPDATE` without the `EXISTS` guard (sabotage 432) fails this test instead of
  passing vacuously.

- New sabotage patches (next free number: 441; the R6 anchor is 437, the s8 re-read anchors
  are 438/439, and the s9 lock anchor is 440): 438 drops the posted-quantity re-read and flips
  the two-shipment s8 test; 439 drops the shipment draft-state re-read and flips the
  same-shipment s8 test; 440 drops only the shipment `FOR UPDATE` lock and flips the s9
  two-session test. One patch flips the named R6 tests (stock without invoice/COGS, and an
  accepted over-ship); two are the backfill mutations below (no-op and overbroad, both
  targeting the migration with the test unchanged); one removes the
  `Lot :create` flag maintenance and must fail `Lot :create marks its Item lot_tracked`; one
  removes the `Item` clear guard and must fail `an Item cannot clear lot_tracked while a Lot
  exists`; one removes `phase: :expand` from the host migration and must fail the target
  discovery test; one bypasses the live `Lot` existence check in `ship_posting.ex` and must fail
  the named post-backfill test; one bypasses the same guard in `fulfill_order.ex` and must fail
  the named legacy test. All must fail their named tests and restore byte-exact.

**Backfill sabotage headers (431/432):**

Two patches mutate the migration, not the assertion. The named test is unchanged, so the positive
lot assertion and the non-lot control must each catch a different direction.

```text
# SABOTAGE: Disable the L1 lot_tracked backfill so a lot-backed item stays false.
# APP: samenerp
# TEST_FILES: test/logistics_lot_tracked_backfill_test.exs
# MUST_FAIL: the L1 migration backfills Item.lot_tracked from existing Lot rows and leaves non-lot items false
```

No `# ENV:` line is required because this test is not opt-in. Remove or disable the `UPDATE`; the
lot-backed item stays `false`; restore the migration byte-exact.

```text
# SABOTAGE: Drop the EXISTS predicate so every item is marked lot-tracked.
# APP: samenerp
# TEST_FILES: test/logistics_lot_tracked_backfill_test.exs
# MUST_FAIL: the L1 migration backfills Item.lot_tracked from existing Lot rows and leaves non-lot items false
```

No `# ENV:` line is required because this test is not opt-in. Remove the `WHERE EXISTS` predicate
so every item becomes `true` and the non-lot control fails; restore the migration byte-exact. Both
patches target the migration, never the test's expected values. The test reads
`samenerp/priv/repo/migrations` directly (not a `_build` copy), so the patched source executes.

**Flag-maintenance sabotage headers (next free patch numbers):**

```text
# APP: samen_core
# TEST_FILES: test/inventory_lots_test.exs
# MUST_FAIL: Lot :create marks its Item lot_tracked
```

No `# ENV:` line is required because this test is not opt-in. Remove or bypass the flag-setting
change in `Lot :create`; the named test must fail; restore the source byte-exact.

```text
# APP: samen_core
# TEST_FILES: test/inventory_lots_test.exs
# MUST_FAIL: an Item cannot clear lot_tracked while a Lot exists
```

No `# ENV:` line is required because this test is not opt-in. Remove or bypass the clear guard in
`Item :update`; the named test must fail; restore the source byte-exact.

**Migration-discovery sabotage (433):**

```text
# APP: samenerp
# TEST_FILES: test/logistics_migration_contract_test.exs
# MUST_FAIL: the L1 logistics migration is discovered as an :expand down-check target
```

No `# ENV:` line is required because this test is not opt-in. Remove the `phase: :expand`
option from the migration; the named test must fail; restore the source byte-exact.

**Live-gate sabotage header (435):**

```text
# APP: samen_core
# TEST_FILES: test/inventory_shipment_test.exs
# MUST_FAIL: a Lot created after the L1 backfill cannot ship as a non-lot item
```

No `# ENV:` line is required because this test is not opt-in. Remove or bypass the live `Lot`
existence check in `ShipPosting`; the named test must fail; restore the source byte-exact.

**Remaining-quantity sabotage (436):**

```text
# APP: samen_core
# TEST_FILES: test/inventory_shipment_test.exs
# MUST_FAIL: an over-shipment is refused before any write, then a valid shipment lands
```

No `# ENV:` line is required. Drop the live remaining-quantity check in `ShipPosting`; the
named test must fail; restore the source byte-exact.

**R6 COGS sabotage (437):**

```text
# APP: samen_core
# TEST_FILES: test/inventory_shipment_test.exs
# MUST_FAIL: a shipped shipment reconciles stock, lines, invoice, COGS and the order's open qty
```

No `# ENV:` line is required. Skip the COGS entry while stock and invoice still post; the R6
green test must fail on the missing COGS leg; restore the source byte-exact.

**Legacy-gate sabotage header (434):**

```text
# APP: samen_core
# TEST_FILES: test/inventory_sales_order_test.exs
# MUST_FAIL: legacy :fulfill refuses a lot-backed item before any write
```

No `# ENV:` line is required because this test is not opt-in. Remove or bypass the live `Lot`
guard in `FulfillOrder`; the named test must fail; restore the source byte-exact.
- Runbook:

```bash
cd samen_core
MIX_ENV=test mix test test/inventory_shipment_test.exs --warnings-as-errors
MIX_ENV=test mix test test/inventory_sales_order_test.exs --warnings-as-errors
MIX_ENV=test mix test test/inventory_lots_test.exs --warnings-as-errors
MIX_ENV=test mix samen.verify.catalog_parity
MIX_ENV=test mix samen.verify.migrations
cd ../samen_web
MIX_ENV=test mix test test/samen/web/logistics_shipment_surface_test.exs --warnings-as-errors
cd ../samenerp
MIX_ENV=test mix test test/logistics_walkthrough_test.exs --warnings-as-errors
MIX_ENV=test mix test test/logistics_migration_contract_test.exs --warnings-as-errors
MIX_ENV=test mix test test/logistics_lot_tracked_backfill_test.exs --warnings-as-errors
MIX_ENV=test mix samen.verify.catalog_parity
MIX_ENV=test mix samen.verify.prefixes
MIX_ENV=test mix samen.verify.migrations --repo Samenerp.Repo --migrations priv/repo/migrations
cd ..
# The backfill sabotage pair mutates the migration itself; the test stays unchanged.
bash scripts/sabotage.sh --touching samenerp/priv/repo/migrations/20261122120000_mount_inventory_logistics.exs
bash scripts/sabotage.sh --touching samen_core/lib/samen/scopes/inventory/blueprint.ex
bash scripts/sabotage.sh --touching samen_core/lib/samen/scopes/inventory/ship_posting.ex
bash scripts/sabotage.sh --touching samen_core/lib/samen/scopes/inventory/fulfill_order.ex
```

**Full-harness certification (2026-11-24, `9d046bae`).** The opt-in parallel sweep
(`scripts/sabotage_parallel.sh --jobs 2`, the harness `ci.sh` runs when `SAMEN_SABOTAGE=1`) ran
every committed patch: 424 of 424 flipped their named tests across 8 slices — 666 named-test
confirmations, every patch restored sha-256 byte-exact, and every slice re-asserted the main
checkout byte-exact. Sabotage lint and the structural preflight (residue, EOLs, applicability,
test anchors) were clean, and the driver asserted slice coverage before the first patch ran.

```text
samen_core        207/207  ALL PASSED  (308 named-test confirmations, 207 byte-exact restores)
samen_web         171/171  ALL PASSED  (287, 171)
driftwood          17/17   ALL PASSED  (27, 17)
pawchart           13/13   ALL PASSED  (20, 13)
samenerp           11/11   ALL PASSED  (17, 11)
demo                3/3    ALL PASSED  (4, 3)
samen_postmark      1/1    ALL PASSED  (1, 1)
samen_stripe        1/1    ALL PASSED  (2, 1)
```

Log: `.agent_logs/sabotage_full_424.log`. The L1.4 anchors re-flipped there: 435 (live `Lot`
gate bypassed), 436 (remaining-quantity check dropped), 437 (COGS entry skipped), 438
(posted-quantity re-read dropped), 439 (shipment draft-state re-read dropped) and 440 (only the
shipment `FOR UPDATE` dropped) — each failing its named test and restoring byte-exact.

**L1 acceptance:** partial shipments produce correct stock/COGS/invoices; the order's shipped +
open equals ordered; over-ship, double-post and lot-tracked or lot-backed lines are refused before
any write on both `Shipment :ship` and legacy `:fulfill`; the `lot_tracked` flag is maintained
(`Lot :create` marks the item, clearing is refused while lots exist), the migration/backfill is
proven (existing `Lot` item true, non-lot control false), a direct post-backfill `Lot` cannot ship
as a non-lot item on either path, and the post-deploy reconciliation re-marks it; the host
migration is a `:expand` target discovered by the target-specific test, the physical
`eni_lot_tracked` column and its catalog row are present, and `down/0` reverses the status
check/trigger, shipment tables/catalog rows, and `eni_lot_tracked`; the frozen cost and
zero-cost/no-zero-journal rules hold; R6 + R3 + R4 + R5 green; E5's existing non-lot `:fulfill`
tests unchanged green; the new legacy lot refusal passes; host walkthrough green; sabotage flips
the named tests and restores byte-exact. No PII, carrier, print or tracking work is part of this
gate.

---

## Phase L1b — Shipment document completion

**Scope:** make the shipment a usable physical document after L1 proves the posting. Everything
here is deliberately absent from the first slice.

- Shipment gains the vaulted destination/recipient (`ship_to` Address, `recipient_name`, optional
  phone/email), a draft-only cancel action + `:cancelled`, statuses `:picked`/`:packed`/`:delivered`,
  and the `ShipmentPackage` resource.
- L1b lot movement: `ShipmentLine.lot_id`, the lot-aware line unique, `StockLedger.lot_id`, the
  `source_key: "lot"` backfill, lot-level `NegativeStock`, lot cost snapshots and the
  `ReconcileLot` extension. L1 has none of these.
- Packing-slip print surface (tenant plane; masked on operator), using the AP print-run precedent.
- Masking watch-list trio on shipment list/detail/print (the first PII on the workstream);
  sabotage twin flips a plane-dependent assertion.
- Shipment lines gain draft-only edit/delete; DB belts then freeze lines after `:draft` and make
  shipped shipments immutable (no DELETE); package immutability. These are deferred from L1, not
  lost.
- Decide and, if ratified, implement D2's unification: `:fulfill` creates one full shipment through
  `ShipPosting`, the SO invoice anchor is retired or aliased, and the E5 walkthrough is migrated.
  `:apply_shipment` then also admits `:confirmed → :fulfilled` for that full-shipment path. Until
  then the two entry points (`:fulfill`, `Shipment :ship`) are both live and separately tested.
- Tests: pick/pack/ship state machine, package/packing-slip rendering, masking trio, belt
  refusals, E5 walkthrough migration if unification lands; sabotage for the masking plane flip and
  the line-freeze bypass.
- Gate: core + `samen_web` + host suites; `catalog_parity`/`migrations`; registry goldens.

**L1b acceptance:** a shipment can carry a destination and packages, print a correct packing slip,
and cannot be mutated after shipping; operator-plane output is masked and sabotage-proven. If
unification is ratified, `:fulfill` and `Shipment :ship` share one posting path and E5 is migrated;
if not, the split is documented and both paths remain gated.

---

## Phase L2 — Carrier services, adapters and tracking

**Deliverables:**

- `Carrier` + `CarrierService` resources (the carrier master was deliberately not part of L1);
  carrier admin surface, and the optional `carrier_id`/`carrier_service_id`/`tracking_number`
  fields on `Shipment`, plus optional per-package tracking numbers.
- Kernel behaviour `Samen.Logistics.Carrier` + `Samen.Logistics.Carrier.NotConfigured`
  (`{:error, :not_configured}` for quote/buy/track/parse) and a conformance case that refuses a
  stub claiming work it did not do (ADR-014/024/026).
- Host adapter selection via runtime config (`:carrier_adapter`, per-carrier credentials); no
  credential column, no secret in logs/assets.
- Label purchase action (optional): adapter label bytes go through `Samen.Files.upload/3`
  (quarantine → scan → promote); a failed adapter leaves the shipment unshipped and says why.
- Tracking webhook route via `samen_webhook_routes`: per-carrier HMAC, append-only
  `ShipmentEvent` insert-if-absent by external id (a repeat is a no-op; a conflict is refused,
  never updated), closed `kind`/`exception_code`, no raw payload storage; unsigned/unknown events
  rejected.
- Tracking timeline UI; manual events remain available; exception rules create Work
  tasks/notifications (Automation), late-shipment age and tracking exception.
- Tests: conformance, signature refusal, duplicate event no-op, conflicting event refusal, unknown
  event refusal, no PII in events, masking on timeline/detail; sabotage flips a fake-`{:ok, _}`
  adapter and an unsigned-webhook acceptance.
- Gate: core suite + samen_web masking + `mix samen.verify.catalog_parity`/`migrations`; no new
  ledger mechanism.

**Acceptance:** a configured adapter can quote/label/track; an unconfigured one refuses honestly;
a repeated/forged webhook is rejected or idempotent; the timeline is append-only and PII-free.

---

## Phase L3 — Returns / RMA

**Deliverables:**

- `ReturnAuthorization` + `ReturnLine` resources (status machine, reason/condition/disposition
  enums, same-org links to shipment/SO/customer/warehouse; `shipment_id` required; `lot_id` on a
  lot-tracked return line).
- `ReturnPosting`:
  - `:authorize` (draft → authorized), `:receive` (quantity ≤ shipped − already returned; positive
    `StockLedger :receipt` into the receiving/quarantine warehouse; `ReturnLine` rows; COGS reversal
    at the shipment snapshot, with a zero-value leg posting no entry), `:disposition` (restock
    transfer / scrap issue / repair transfer), all anchored and exactly-once;
  - `:disposition` restock/repair are value-neutral transfer pairs and post no JournalEntry; scrap
    posts Dr `:write_down_expense` / Cr item inventory;
  - Finance `CreditNote` emission for accepted value at `:receive`; `:close` is state only; no cash
    refund in the base.
- Returns surface (list/detail, authorize/receive/disposition, credit-note print), tenant-plane
  PII masking; returns list has no recipient columns.
- R7 reconciliation + red twin: over-return, credit without stock, stock without receipt,
  over-credit; sabotage patch.
- Tests: full return of one line, partial return, scrap vs restock, credit total, exactly-once,
  COGS reversal equals the shipment snapshot, restock/repair post no JournalEntry, zero-value legs
  post no entry, R6 remains green; masking trio on the return detail/print.
- Gate: core suite + web masking + host walkthrough extended with a return.

**Acceptance:** a delivered shipment can be returned partially or fully; stock lands where the
disposition says; the credit note equals the accepted value; over-return is impossible; R7 green.

---

## Phase L4 — Inbound: ASN, receipt variances and landed cost

**Deliverables:**

- `Asn` + `AsnLine` resources (PO-backed expectation; no stock posting of its own).
- `GoodsReceipt` extension: optional `asn_id`; `:receive` accepts per-line accepted/rejected
  quantities; `ReceiptVariance` rows (over/short/damaged) with closed reasons; stock + GL post for
  accepted quantity only; over-receipt beyond PO + accepted tolerance refused (R5 stays the flag).
- Repair E14:
  - real `LandedCostAllocation` resource/table;
  - rewrite `LandedCostAllocator` to allocate over receipt lines by value/quantity with exact
    rounding balance, persist allocation rows, sum == amount;
  - `StockValueAdjustment` append-only ledger; `StockLevelSync`/`ReconcileStock` include the value
    leg; `:allocate` posts the value adjustment + GL entry in one transaction and flips the
    document; a failed allocation writes nothing.
- ASN and receiving surfaces; landed-cost preview/allocate surface; AP freight invoice link
  (`LandedCost.bill_id`).
- R8 + red twin: allocation drops/creates a cent, adjustment without GL, GL without adjustment,
  R3 value divergence; sabotage patch.
- Tests: ASN → receipt with accepted/rejected lines, variance rows, over-receipt refusal, landed
  cost allocation exactness (value and quantity methods), R3/R5/R8 green; masking on receiving
  (address only through the warehouse's vaulted field, no new PII).

**Acceptance:** receiving against an ASN records expectations vs actuals honestly; rejected units
never enter sellable stock; landed cost allocates to the cent and the inventory value/GL agree;
R8 green; the old placeholder behavior is gone (no fabricated status flip).

---

## Phase L5 — Warehouse execution: transfers, cycle counts, bins decision

**Deliverables:**

- Repair E13 `TransferOrder`:
  - wire `TransferGuard` to `:create`/`:post` using the host namespace's `StockLevel`/ledger (not
    the fixture module); validate same-org, same item, positive qty, distinct warehouses, source
    stock from the live ledger sum;
  - `TransferPosting`: paired `:transfer_out`/`:transfer_in` in one transaction, copying the source
    cost to both events and carrying the transfer's lot identity when present; a same-account
    transfer is value-neutral and posts no JournalEntry; anchored, `PostingMarker`, exactly-once;
  - R9 + red twin (half-post, mismatched item/qty/cost, direct level edit); sabotage patch.
- `CycleCount` + `CycleCountLine`: count sheet, approval above tolerance (Gate), `:post`
  re-reads live on-hand (and lot on-hand when `lot_id` is present) and refuses stale
  `system_qty`; a valued shortage/surplus posts the `:write_down_expense` entry, a nil shortage
  posts no value leg and a nil surplus refuses; R3 remains the arbiter; no direct level writes.
- Warehouse surfaces for transfers and counts; approval queue; operator plane read-only/masked.
- **Bins:** produce the ADR-056 amendment + migration/backfill plan; do not implement until
  ratified. If ratified, the ledger gains a nullable `bin_id`, the rollup grain changes and R3 is
  re-proven; otherwise bins stay out.
- Tests: transfer pair, source-cost equality, no JournalEntry, negative source, same-warehouse
  refusal, replay refusal; cycle count approval gate, stale-count refusal, valued/nil adjustment,
  zero-value no entry, R3/R9 green; sabotage flips the half-post/guard bypass.

**Acceptance:** transfers move stock atomically and net to zero; counts adjust only through
approval + ledger events; no bin feature ships before its amendment.

---

## Phase L6 — Planning and supplier collaboration

**Deliverables:**

- `ReplenishmentSuggestion` derived read: item reorder point vs on-hand + on-order, demand lookback
  window, suggested quantity; no auto-PO in this phase (a suggestion is information, not a write).
- Optional `:create_po_from_suggestion` action gated by role and approvals; emits a draft PO only
  when a host opts in (P2 behavior made explicit, not implied).
- Supplier collaboration: ASN status portal read, overdue-ASN exceptions, receipt variance
  follow-up tasks; supplier scorecard integration (existing Finance scorecards) without a new
  scorecard mechanism.
- EDI adapters (850/856/810/214) behind the fail-honest adapter boundary; default
  `{:error, :not_implemented}`; no built-in translator.
- Tests: suggestion arithmetic and floor, no write path from the read, draft-PO opt-in/approval,
  adapter conformance; no fabricated EDI success.

**Acceptance:** replenishment advice is explainable and read-only by default; auto-PO is opt-in and
Gate-gated; EDI is an adapter, never a claim.

---

## Phase L7 — Analytics, operator KPI, and the workstream gate

**Deliverables:**

- Rollups: shipments on-time %, exception count, return rate, receipt variance rate, landed-cost
  coverage — each a `Samen.Rollup.Spec` over append-only facts, no new BI mechanism.
- Operator aggregate projection with `CohortSpec` floors (k-anon min-5, l-div=2); a suppressed
  cohort renders `%Suppressed{}` (red-proven).
- Docs: update `docs/ws-erp/design.md`/`build-plan.md` cross-references, README/claim-evidence if
  the workstream claims new coverage; keep the §8 honesty list current.
- Full re-gate: R3–R9 re-flipped from the sabotage harness; masking trios re-run; root `./ci.sh`
  ends `ROOT CI: ALL PASSED`; `samenerp/ci.sh` green.

**Acceptance:** logistics KPIs are derived, floored and sabotage-proven; the root gate is green;
no half-built TMS/WMS claim remains in the docs.

---

## Definition of done (every phase)

- Green path + red-path twin + committed sabotage patch; the named tests flip and revert
  byte-exact (harness-certified).
- No chokepoint, guard, masking or ledger rule weakened to pass a gate.
- No hand-edited `priv/abbrev_registry.json`; allocator-only, goldens updated.
- `catalog_parity`, `migrations`, `prefixes`, `no_pii_columns`, `same_org_fk`, `nav_links` green.
- PII surfaces (phases that have PII): the three masking proofs (tenant clear, operator masked,
  sabotage twin); no plaintext in DOM/CSV/print/events/logs. L1 has no PII and no masking gate.
- Exactly-once + one-transaction postings proven; reconciliation reads share no code path with the
  writer.
- Host proof: `Samenerp.Erp` mounts the new branch and the host walkthrough covers the workflow.
- No scope/abbrev/table invented outside ADR-056; any new decision is recorded before code.
