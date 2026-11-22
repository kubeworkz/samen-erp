# ADR-056 — Logistics & supply chain: an optional Inventory `logistics:` branch,
# shipments as stock documents, and a fail-honest carrier boundary

- **Status:** **PROPOSED (2026-11-22) — the L1.1 migration contract is
  IMPLEMENTED (the two shipment resources, `lot_tracked`/`eni_lot_tracked`,
  scoped catalog sync/down and the reversible `:expand` migration); L1.2+ work
  is not. The operator RATIFIED three of its seven
  decisions on 2026-11-22 — OD-1 (an Inventory `logistics:` branch), the L1 half
  of OD-2 (`:fulfill` keeps its full-order shape with the L1 lot guard;
  `Shipment :ship` is the partial path) and OD-7
  (repair E13/E14 in L4/L5); OD-2's L1b half and OD-3–OD-6 remain DEFERRED and
  unratified. The operator also RATIFIED the L1 preflight decisions PF-1, PF-2
  Option A and PF-3 on 2026-11-22; those are build-level choices, not additional
  OD register decisions.** This ADR transcribes the WS-LOG design (§2 and §9) and
  closes the documentation half of L0; it does not ratify the build. The L1
  preflight decisions are ratified; the ADR remains `PROPOSED`.
- **Date:** 2026-11-22
- **Deciders:** the operator (RATIFIED OD-1, the L1 half of OD-2, OD-7, PF-1,
  PF-2 Option A and PF-3 on 2026-11-22; the ADR itself, OD-2's L1b half and
  OD-3–OD-6 remain pending). The audit
  evidence is from
  `docs/ws-log/design.md` and `docs/ws-log/build-plan.md`.
- **Consumes:** ADR-049 (the ERP base scopes and reconciliation spine), ADR-054
  (lots/supplier-located stock, fiscal periods, value postings), ADR-055 (the
  E13/E14 disposition context), ADR-004 (scope packaging), ADR-014/024/026
  (fail-honest adapters), ADR-039 (automation), ADR-041 (canonical work objects),
  ADR-018 (rollups), ADR-023 (the abbrev allocator), and ADR-016 (masking-aware
  surfaces).
- **Answers:** the L0 gap in `docs/ws-log/build-plan.md` — the design existed,
  but no ADR recorded it. The build remains **NOT STARTED**.

## Context

WS-ERP E1–E8 is done and execution-verified. The existing Inventory scope already
has the hard part of the physical business:

- item master, warehouses, append-only `StockLedger`, derived `StockLevel`,
  moving-average value, `NegativeStock`, `StockLevelSync`, and `ReconcileStock`
  (R3);
- procurement through `PurchaseOrder`/`PoLine`, `GoodsReceipt`/`ReceiptLine`,
  `GoodsPosting` (stock + GL in one transaction), and `ThreeWayMatch` (R5);
- full-order sales fulfillment through `FulfillOrder` (`:fulfill` posts stock,
  Billing invoice and COGS in one transaction), with BOMs, work orders,
  production logs, lots, and consignment/supplier warehouses.

What is missing is the **document layer that authorizes and evidences physical
movement**: shipment, tracking, return, advance ship notice, cycle count, and the
carrier integration boundary. `FulfillOrder` is explicitly full-order only; there
is no partial-shipment path. No `Shipment`, `Carrier`, `ShipmentEvent`,
`ReturnAuthorization`, `Asn`, or `CycleCount` resource exists in the kernel.
Driftwood's freight domain is a vertical-specific CRM composition, not reusable
kernel logistics.

The audit also found that two "live" E13/E14 resources are skeletons:
`TransferOrder :post` carries no change, `TransferGuard` is unwired and references
a nonexistent `Samen.Scopes.Inventory.StockLevel`, and the transfer table has only
an org index and no test. `LandedCostAllocator.change/3` is a documented
placeholder; `LandedCost :allocate` carries no change, there is no
`LandedCostAllocation` table, and there is no value/GL posting. `README.md` already
labels both as skeletons; this ADR is the formal record and the L4/L5
disposition charter.

The non-negotiable thesis is inherited from ADR-049: stock moves only through
`StockLedger` events guarded by `NegativeStock`, rolled up by `StockLevelSync`, and
reconciled by `ReconcileStock`. A shipment is a document over that ledger, never a
second quantity table.

## Decisions

### D1 — Extend `Samen.Scopes.Inventory` with an optional `logistics:` branch

**RATIFIED (2026-11-22, OD-1).**

Shipments, returns, ASNs and counts are stock documents. They belong beside
`SalesOrder`, not in a new scope that would need its own copy of moving-average
reads, `NegativeStock`, rollup sync and reconciliation.

- Resources compile only when the mount passes `logistics: true` **and** already
  wires `finance:` + `billing:`; a mount without those cannot ship honestly
  (a shipment posts COGS and an invoice).
- Resource definitions live in a new
  `samen_core/lib/samen/scopes/inventory/blueprint_logistics.ex`, keeping
  `blueprint.ex` from growing further.
- An Inventory-only host (stock, PO, manufacturing) mounts none of it.

**Rejected:** a standalone `Samen.Scopes.Logistics` scope. It reads cleanly but
would duplicate the quantity chokepoint's private helpers or reach across a scope
boundary to write another scope's ledger — the coupling ADR-049 avoided when it
absorbed procurement. Carrier adapters remain separate (D4): they are kernel
behaviour, not scope resources.

### D2 — The Shipment is the fulfillment event for partials; E5's `:fulfill` keeps its full-order shape in L1

**RATIFIED for L1 (2026-11-22, OD-2 L1 half); the L1b half below stays
DEFERRED.**

E5's `:fulfill` consumes the order's own frozen lines, emits one invoice and posts
COGS in one transaction. That is the correct shape but the wrong grain for partial
delivery. L1 adds the partial grain beside it:

- `Shipment :ship` is the chokepoint for a partial shipment: per line a negative
  `StockLedger :sale`, a COGS entry for the line's cost (skipped when that cost is
  zero), and one Billing invoice for the shipped lines, all in the action's
  transaction.
- **L1 keeps `:fulfill`'s full-order shape**: confirmed-only, full order, one
  invoice, no shipment row. Its only L1 behavior change on this path is the same live lot
  guard: after the confirmed pre-state and before the invoice emission or any
  stock/COGS write, every SO line is checked; a lot-tracked or lot-backed line is
  refused with `:lot_tracked_requires_l1b` and nothing lands. The
  stock/invoice/COGS helper is extracted from `FulfillOrder` and both paths call
  it, so there is one money/stock mechanism; E5's existing non-lot tests stay
  green, with the new legacy lot-refusal test added.
- `SoState` keeps `:fulfill` confirmed-only. Once a shipment leaves the order
  `:partially_fulfilled`, the remainder is shipped through `Shipment`, not
  `:fulfill`.
- The status flip runs through a new **private internal** `SalesOrder
  :apply_shipment` action (`accept([])` + `PostingMarker`, not exposed by any UI),
  never by force-stamping outside an action. `SoState` admits only
  `:confirmed → :partially_fulfilled` and `:partially_fulfilled → :fulfilled` for
  it, and refuses every other pre-state. L1b may admit the single
  `:confirmed → :fulfilled` transition for the unified full-shipment path, if it
  ratifies that change.
- `SalesOrder.status` grows `:partially_fulfilled`; the final shipment flips
  `:fulfilled`. `:cancel` stays draft/confirmed-only, so a partially fulfilled
  order is not cancellable.
- Shipped quantity is **derived** from posted shipment lines (`qty_shipped` read),
  never a mutable column. Over-ship is refused against the live remaining quantity
  in the transaction.
- Invoice anchors: a shipment carries its own
  (`Shipment.invoice_key`/`invoice_id`); the SO's legacy anchor is written only by
  E5's full-order `:fulfill`. Partial orders therefore have no SO anchor. L1b
  decides whether to unify `:fulfill` through a full shipment and retire the SO
  anchor.

**Why this order:** partial fulfillment is the explicit P2 carry, it unlocks
returns (you cannot return what was never shipped), and it needs no external
carrier account or PII capture to prove the chokepoint.

**Explicitly deferred to L1b:** making `:fulfill` create a full shipment, moving
the SO invoice anchor, and migrating E5's walkthrough.

### D3 — One quantity truth, one money truth

Every stock-affecting action posts its `StockLedger` events through the existing
resource changes: `NegativeStock` (live-sum, fail-closed), `StockLevelSync`
(in-transaction rollup) and the DB belt. No new path may create or update a
`StockLevel` row directly. Every money-affecting action posts one `JournalEntry`
in the same transaction (COGS, inventory value, freight/landed cost) and anchors
it with the existing `source_key`/`source_id` shape. Value-neutral movements
(same-account transfers and return restock/repair) and zero-value legs post no
`JournalEntry`; a zero-value leg never posts a zero journal. `PostingMarker` is
armed on every state flip that the DB belt gates.

### D4 — Carrier integrations are fail-honest kernel behaviours

`samen_core/lib/samen/logistics/carrier.ex` declares:

```elixir
@callback quote(request, config) :: {:ok, quote} | {:error, :not_configured | term}
@callback buy_label(request, config) :: {:ok, label} | {:error, :not_configured | term}
@callback track(request, config) :: {:ok, [event]} | {:error, :not_configured | term}
@callback parse_webhook(headers, raw_body, config) :: {:ok, [event]} | {:error, term}
```

The default implementation returns `{:error, :not_configured}` for every callback
(ADR-014/024/026 posture). A host opts in with a module and per-carrier config;
credentials come from runtime configuration/secrets, **never** from a database
column, a log line or a shipment row. A conformance case proves a stub cannot
return `{:ok, _}` for work it did not do.

### D5 — Tracking is append-only and idempotent

`ShipmentEvent` rows are appended (no update/delete), keyed by
`(shipment_id, source, external_event_id)` with a partial unique index for carrier
events. The webhook ingress uses the existing `samen_webhook_routes` machinery
with signature verification, rejects unsigned/unknown events, and stores only
normalized bounded fields — never the raw carrier payload, which can contain
recipient details. A repeated event is a no-op; a conflicting event is refused,
not silently overwritten.

### D6 — Landed cost needs a value-only adjustment ledger

`LandedCostAllocator`'s current `change/3` is a placeholder. L4 replaces it with
real `LandedCostAllocation` rows (one per receipt line, sums exactly to the landed
cost) and posts a **value-only** adjustment. The stock ledger's quantity semantics
stay pure: a zero-quantity "movement" would make `Σ qty × unit_cost` nonsense.
`StockValueAdjustment` is an append-only resource (`item`, `warehouse`, signed
`amount_cents`, `source_ref`), and `StockLevelSync` / `ReconcileStock` extend so:

```
stock_value = Σ (ledger qty × ledger unit_cost) + Σ value_adjustment.amount_cents
```

**Rejected:** a `:revalue` StockLedger kind with qty 0, unless a later amendment
explicitly widens the ledger contract.

### D7 — E13/E14 are not usable as-is

`TransferOrder` and `LandedCost` are compiled, mounted and allowlisted (ADR-055),
but that is the extent of it:

- `TransferOrder :post` carries no change and never stamps `posted_at`;
  `TransferGuard` is unreferenced outside the allowlist, and its stock check calls
  `Samen.Scopes.Inventory.StockLevel`, which does not exist because host resources
  are generated in the host namespace. The `etn_transfer_order` table has only an
  org index — no FKs, no checks, no transfer-posting events. There is no
  `warehouse_transfers_test.exs`.
- `LandedCostAllocator.change/3` fabricates a map and flips status;
  `LandedCost :allocate` carries no change; there is no `LandedCostAllocation`
  resource/table; `eld_landed_cost` has no FKs/checks or GL/value posting. Only
  the pure `allocate_by_*` arithmetic is tested.
- `README.md` claims `warehouse_transfers_test.exs` (14 tests) and a
  `transfer_order.ex` file; the test does not exist and ADR-055 records the old
  one as vacuous.

**Disposition (RATIFIED 2026-11-22, OD-7):** repair the skeletons in L4/L5;
removal is not the chosen path. Repair is a phase obligation, not a claim that
either resource works today: no workflow is exposed until it ships with its
reconciliation test. ADR-055's "live" means mounted, migrated and allowlisted —
not wired. No surface may advertise a placeholder as a live workflow.

### D8 — Bin-level stock is a later, explicit schema decision

A warehouse-wide `StockLevel` grain is what R3 proves today. Adding bins changes
the ledger grain, the rollup key, every reconciliation and the migration/backfill
story. L5 ships cycle counts and transfers at warehouse grain first; bin-level
stock requires an ADR-056 amendment and its own migration plan, not a nullable
column slipped into L1.

### D9 — PII stays at the edge; events stay bounded

L1 carries **no PII**. In L1b, shipment ship-to and recipient fields are vaulted
(`Samen.Type.Address` with `pii_address`,
`Samen.Type.FullName`/`Phones`/`Emails` as applicable). Every surface that exposes
them follows the masking watch-list trio. Tracking events, exception codes and
shipment numbers are bounded business fields; carrier free-text descriptions are
**not persisted** because they routinely contain recipient addresses. Labels are
generated in memory or through Files; nothing logs a plaintext address.

### D10 — Carrier is its own master, optionally linked to a Vendor

A carrier is an operational entity (SCAC, modes, services, tracking template) and
an AP payee. Keep `Carrier` separate with an optional `vendor_id` (the
`SalesOps.Vendor` row used for freight bills). Reusing Vendor as the carrier
master would put service/SCAC/tracking semantics into an AP noun; a pure link
keeps both clean.

## Decision register

Three of the seven register decisions are RATIFIED — OD-1, OD-2's L1 half and
OD-7 — and the rest are DEFERRED and unratified. The L1 preflight decisions
PF-1, PF-2 Option A and PF-3 are separately RATIFIED (2026-11-22). The ADR
itself remains `PROPOSED` and the build is not ratified. D3 (one quantity truth,
one money truth) and D9 (no PII in L1) are not open questions; they are binding
L1 constraints.

| ID | Decision | Disposition |
|---|---|---|
| OD-1 | Scope boundary: Inventory `logistics:` branch vs a standalone Logistics scope | **RATIFIED (2026-11-22) — Inventory `logistics:` branch.** A standalone scope would duplicate the quantity chokepoint. |
| OD-2 | Fulfillment unification: keep two posting paths in L1, then decide whether `:fulfill` creates a full shipment and whether the SO invoice anchor is retired or aliased | **L1 half RATIFIED (2026-11-22):** keep `:fulfill`'s full-order, one-invoice shape, adding only the shared live lot guard; `Shipment :ship` is the partial path. **L1b half DEFERRED:** decide unification and the SO anchor after L1 proves R6. |
| OD-3 | Ship-to source in L1b: snapshot the address/recipient on the Shipment or read live from CRM | **DEFERRED to L1b.** Snapshot for historical accuracy. |
| OD-4 | Carrier credentials: host runtime configuration/secrets vs a database column | **DEFERRED to L2.** Runtime config/secrets keyed by org + carrier code; never a DB secret, log line or shipment row. |
| OD-5 | Bin grain: warehouse-level stock first, then a bin-level amendment | **DEFERRED to L5.** Require an ADR-056 amendment plus migration/backfill and a re-proven R3 before bins. |
| OD-6 | Return refunds: credit note only vs a cash refund/payment reversal in the base | **DEFERRED to L3.** Credit note only in the base; cash refunds use Finance's existing path later. |
| OD-7 | E13/E14 disposition: repair the skeletons vs delete them | **RATIFIED (2026-11-22) — repair in L4/L5, not delete.** Do not expose a surface over a placeholder. |

## L1 preflight decisions (RATIFIED 2026-11-22)

These decisions sit outside the OD-1–OD-7 register: they are the build-level
choices L1 needs before code. The operator **RATIFIED PF-1, PF-2 Option A and
PF-3 on 2026-11-22**. They do not change the ADR's `PROPOSED` status or ratify
L1. Option A adds `Item.lot_tracked`, maintains it (`Lot :create` marks the item;
an `Item` update cannot clear it while lots exist), and adds the refusal gate to
design §3.1 and build-plan L1.1/L1.2/L1.4. It also adds lot-aware movement to L1b;
Option B is not selected. The refusal gate is live: it checks both the flag and
any existing `Lot` row, so a `Lot` inserted after the backfill cannot bypass it.
PF-1 replaces
design §4.1 and build-plan L1.2's "pre-state + `PostingMarker`" exactly-once
sentence with the row-lock protocol. PF-3 adds
the private `ShipmentLine` cost stamp to L1 and amends design
§3.4/§4.2/§4.5/§4.6 plus the L3/L5 gates for shipment-backed returns and the
cost/GL rules, and settles the L3 credit-note timing. Any change now requires
an ADR-056 amendment.

### PF-1 — Exactly-once is enforced by row locks; `PostingMarker` is only the belt

**RATIFIED (2026-11-22).**

`PostingMarker` arms the finance DB belt; `StockLevelSync` arms the stock belt.
Neither is a mutex, and a pre-state read alone is not exactly-once under READ
COMMITTED. `Shipment :ship` takes locks in this order:

1. `SELECT ... FOR UPDATE` on the org-pinned shipment row;
2. `SELECT ... FOR UPDATE` on the shipment's `SalesOrder` row.

Only after both locks does it re-read the shipment status, the SO status and the
live remaining quantity (`SO line qty − Σ posted shipment-line qty`). Every
preflight refusal happens after the locks. The final shipment flip is a
conditional update from `:draft`; zero rows updated aborts the whole transaction.
The internal `SalesOrder :apply_shipment` transition runs in the same
transaction, after the SO lock, with `PostingMarker` still armed.

Lock order for the new cross-document locks is **Shipment → SalesOrder**; no new
path may take them in the reverse order. Downstream writes keep the existing
`FulfillOrder` ordering (invoice/AR, then stock/COGS), with both locks held
before any of them. A lock timeout is a refusal, not an automatic retry inside
the action. `PostingMarker` remains the finance belt marker, never the
concurrency control.

**L1 gate:** two concurrent `:ship` calls on one shipment produce exactly one
stock/COGS/invoice set; two concurrent shipments on one SO cannot both pass the
remaining check. The test must observe one conflict, not merely a serial success.

### PF-2 — Lot policy: defer lot-aware movement to L1b, or add it to L1

**RATIFIED — Option A (2026-11-22).**

Two paths were viable; the operator ratified Option A. Option B remains the
recorded fallback but is not selected for this build.

**Option A — DEFER (RATIFIED for L1).** L1 extends the `Item` resource with the
lot-related `lot_tracked` boolean attribute (default `false`; the migration
marks existing items with `Lot` rows as lot-tracked) and refuses every line
for a lot-tracked or lot-backed item before any stock/invoice/COGS write,
with a distinct `:lot_tracked_requires_l1b` reason. **Lot-backed** means any
`Lot` row for the item. The same live guard runs in the legacy
`SalesOrder :fulfill` preflight after its confirmed pre-state and before the
invoice emission; its full-order shape is otherwise unchanged.

L1 makes the flag a **maintained invariant**, not a one-time backfill:
every `Lot :create` transactionally marks its item's `lot_tracked = true` (the
lot create rolls back if the mark cannot be written), and an `Item` update that
would clear `lot_tracked` while any `Lot` row references the item is refused with
`:lot_tracked_has_lots`. The preflight still tests both the flag and a live
`Lot` existence query; that read-only EXISTS (backed by the existing
`lot.item_id` index) is the authoritative belt for out-of-band rows and old
writers during rollout, so a stale `false` flag never
authorizes shipment. The migration backfill is initial state, not the safety
boundary; an idempotent post-deploy reconciliation re-marks flags after the old
writers drain, while the live EXISTS gate covers shipments until it does. The
query adds no `StockLedger` or `ShipmentLine` lot columns. L1b
owns the lot-aware movement: `StockLedger.lot_id`, `ShipmentLine.lot_id` (one line per lot; the
lot-aware unique), lot-level `NegativeStock`, lot cost snapshots and the
`ReconcileLot` extension.

- **Trade-off:** L1 cannot ship lot-tracked or lot-backed SKUs, so the host
  walkthrough must use a non-lot item and no surface may claim lot coverage. In
  exchange, L1 stays a narrow chokepoint proof and cannot silently corrupt lot
  balances.
- **Gate:** L1 refuses a lot-tracked or lot-backed line before any write on both
  `Shipment :ship` and legacy `SalesOrder :fulfill`; each non-lot positive
  control still lands. The proof includes `Lot :create` marking its item, an
  `Item` clear refused while a `Lot` exists (with a no-lot positive control), a
  post-deploy reconciliation re-marking a direct post-backfill `Lot`, and that
  direct `Lot` being refused on both paths while the flag is still `false`. L1b
  must prove the lot-aware shipment,
  the lot-level negative-stock refusal and the `ReconcileLot` agreement before
  L3 returns start; no lot item may ship with a nil lot.

**Option B — LOT-AWARE L1 (NOT SELECTED).** L1 adds lot identity to the movement
path before any lot-tracked item can ship:

- `Item.lot_tracked` is a boolean, default `false`, admin-set. The migration
  marks existing items that already have `Lot` rows as lot-tracked.
- `StockLedger.lot_id` is a nullable, same-org FK populated on every movement of
  a lot-tracked item. Existing `source_key: "lot"` rows are backfilled with
  `lot_id = source_id`; `ReconcileLot` reads `lot_id` after the backfill.
- `ShipmentLine.lot_id` is required when the item is lot-tracked; a lot-tracked
  SO line may produce one shipment line per lot. This **replaces** L1's
  `(shipment_id, so_line_id)` unique with `(shipment_id, so_line_id, lot_id)`,
  using partial unique indexes for the `NULL` and non-`NULL` cases. Non-lot lines
  keep `lot_id = nil`.
- `NegativeStock` extends to the lot level when `lot_id` is present: a shipment
  cannot take a lot/warehouse below zero even when the item-wide balance is
  positive.
- The same `lot_id` travels through `ReturnLine`, `TransferOrder`,
  `CycleCountLine` and their ledger events. L4 extends `StockValueAdjustment`
  when landed cost is allocated to a lot.

**Rejected (under Option B):** shipping a lot-tracked item with `lot_id = nil`
and reconstructing the lot later. `source_key`/`source_id` can carry either a
shipment or a lot, not both; a later match by item/date/quantity would be a
guess, and it would make `ReconcileLot` and returns dishonest.

- **Trade-off (Option B):** expands L1 with a ledger column, lot-aware line
  uniqueness, backfill, a lot-level guard and lot cost; it delays the first
  milestone but avoids a temporary product limitation.
- **Gate (Option B):** a lot-tracked item requires a lot, a lot cannot go
  negative, R6 sums by line/lot, and `ReconcileLot` sees the shipment's lot
  decrement. Non-lot items still ship with no lot and no new required input.

**Ratified choice:** **Option A (defer)** for L1. The first milestone is the
partial-posting chokepoint; adding lot identity, backfill, lot-level negative
stock and lot cost to that slice would expand the risk surface and delay the
milestone. The fail-honest refusal keeps the books correct until L1b. Option B
was considered only if the operator's first host must ship lot-tracked items in
the L1 walkthrough; it is not selected. Either way, L1b is a hard prerequisite
for L3 returns.

### PF-3 — Returns, transfers and cycle counts use one cost snapshot and explicit GL legs

**RATIFIED (2026-11-22).**

**Cost basis.** For an untracked item, `ShipmentLine.unit_cost_cents` is set at
`:ship` from the item/warehouse moving-average snapshot used for COGS. For a
lot-tracked item it is the lot's own valued-ledger unit cost in the shipping
warehouse (the same events `ReconcileLot` sums), not the item-wide blend; a lot
with no valued movement is refused. Both are frozen at `:ship`. The snapshot is
written by a private internal `ShipmentLine :stamp_cost` action inside
`ShipPosting`; it is the one internal line update L1 adds, and no user-facing
line edit exists. Returns use that snapshot, never the current average; a return
line without one is refused. A transfer copies the source cost to both events;
a cycle count uses the current item or lot moving average at posting.

L3 returns are shipment-backed: `ReturnAuthorization.shipment_id` is required
and every `ReturnLine` names a `ShipmentLine`, because cost, credit and invoice
linkage come from that shipment; the design's former "optional" header wording
is corrected in §3.4.

| Flow | Stock event | Cost | JournalEntry |
|---|---|---|---|
| Return `:receive` | positive `:receipt` into quarantine, with `lot_id` | `ShipmentLine.unit_cost_cents` | Dr item inventory / Cr `:cogs` for the returned cost |
| Return `:disposition` restock | `:transfer_out` + `:transfer_in` quarantine → sellable, with `lot_id` | the same snapshot | none — value-neutral, same item inventory account |
| Return `:disposition` scrap | negative `:issue`, with `lot_id` | the same snapshot | Dr `:write_down_expense` / Cr item inventory |
| Return `:disposition` repair | `:transfer_out` + `:transfer_in` to the repair warehouse, with `lot_id` | the same snapshot | none — still inventory |
| Return credit note | none | accepted sales value | existing `:credit` cascade: Dr `:credit_note_clearing` / Cr `:ar_clearing`, `invoice_id = Shipment.invoice_id`; no cash |
| Transfer `:post` | `:transfer_out` + `:transfer_in`, with `lot_id` | the source snapshot on both events | none — value-neutral; both warehouses use the item's inventory account |
| Cycle-count shortage | negative `:adjust`, with `lot_id` | current item or lot moving average; nil average posts no value leg | Dr `:write_down_expense` / Cr item inventory when valued; no entry when nil |
| Cycle-count surplus | positive `:adjust`, with `lot_id` | current item or lot moving average; nil average refuses | Dr item inventory / Cr `:write_down_expense` |

A zero-value leg in any row posts no `JournalEntry`; the Dr/Cr column shows the
valued case. The `none` rows are value-neutral, not zero-value.

The return disposition pair is a return-scoped movement implemented in L3 and
anchored to the return; it does not wait for L5's `TransferOrder` repair. L5
reuses the same event helper for its transfer document. R7 owns the return pair;
R9 owns `TransferOrder`. The value-neutral movements — a same-account transfer
and the return restock/repair movements — post no JournalEntry; they are the D3
value-neutral exception, and D3's one-money-truth applies to the value-changing
legs.

PF-3 assumes the lot-aware movement from PF-2's L1b gate has landed; under
Option A, lot columns and lot cost are not L1 deliverables.

The return credit note is issued at `:receive` for the accepted quantity and
accepted sales value; `:close` is a state transition only. The credit note and
the inventory/COGS reversal are separate entries: the credit note is AR-side,
the reversal puts the returned cost back on the balance sheet. Over-return and
over-credit are refused before any write.

A cycle-count `:post` re-reads the live on-hand (and lot on-hand when
`lot_id` is present). If it differs from the line's `system_qty`, the post is
refused as stale and a recount is required; it never posts a variance against a
snapshot that has drifted.

`:write_down_expense` is the existing `PostingAccount` meaning used for both
shrinkage and scrap; the operator ratified this shared mapping. Separate
`:inventory_shrinkage`/`:scrap_expense` accounts require an ADR-056 amendment
and a Finance enum change before L3/L5; do not ship an unmapped placeholder.

Account resolution is fail-honest: a missing item inventory account or an
unmapped `:cogs`/`:write_down_expense` (or the credit note's
`:credit_note_clearing`/`:ar_clearing`) refuses the whole action before any write;
no account is invented.

Every journal entry is posted in the document's transaction, anchored to the
document (`source_key`/`source_id`) and armed with `PostingMarker`. A zero-value
leg posts no entry, exactly as the zero-cost COGS skip does; it never posts a
zero-value journal.

**Reconciliation additions:** R7 adds the COGS reversal and scrap GL legs; R9
adds cost and lot equality across the transfer pair; the cycle-count post is
included in R3's value check (and `ReconcileLot` for lot lines).

## Consequences

- **No new universal scope.** The logic stays in Inventory; carrier adapters are
  kernel behaviours.
- **L1 is the first milestone.** Partial fulfillment must land before L1b, L2–L5,
  and ultimately L6/L7. The L1 gate is R6 plus unchanged E5, R3, R4 and R5 suites.
- **No code, abbreviations or migrations are created by this ADR.** L1 reserves
  only `shp`/`shm` through the sanctioned allocator (`shl` is already owned by
  `Samenerp.Hr.LeaveRequest`); the remaining ~13 resources
  follow their phases. `priv/abbrev_registry.json` stays hands-off.
- **New reconciliation obligations:** R6 shipment lines ↔ stock ↔ invoice; R7
  returns ↔ stock ↔ credit; R8 landed-cost allocation ↔ value adjustment ↔ GL; R9
  transfer-out ↔ transfer-in. R3/R4/R5 remain green and are re-run at every phase
  gate.
- **PII is introduced only in L1b.** L1 has no destination, recipient, carrier,
  packages or tracking; L1b adds the vaulted fields and the masking trio.
- **Documentation stays honest.** E13/E14 are recorded as skeletons; no surface
  may describe them as wired. `README.md`/claim-evidence must be updated only when
  a phase actually ships new coverage.

## Out of scope (binding honesty list)

1. Full TMS / route optimization / load planning.
2. Fleet telematics / GPS / driver mobile app.
3. Customs brokerage, duty calculation, HS classification.
4. Tax engines / VAT/GST filing.
5. MRP, demand forecasting and automatic PO generation (L6 ships a derived
   replenishment suggestion; auto-PO remains P2 and gated).
6. Serial-number traceability (lots exist; serials are a later ADR).
7. Bin-level stock until the D8 amendment is ratified.
8. Multi-currency freight and FX revaluation of logistics documents.
9. 3PL billing reconciliation / warehouse robotics / WMS task engines.
10. Marketplace/shipping aggregator integrations and label resale.

## References

- `docs/ws-log/design.md` — the full design, D1–D10, data model, chokepoints and
  R6–R9.
- `docs/ws-log/build-plan.md` — L0–L7, acceptance gates and the L1 first milestone.
- ADR-049 — ERP base scopes, Inventory and the reconciliation spine.
- ADR-054 — lots, supplier-located stock, fiscal periods and value postings.
- ADR-055 — the dormant ERP module sets and the E13/E14 context.
- ADR-014/024/026 — fail-honest adapter contract.
- ADR-039/041 — Automation and canonical Work objects.
- `README.md` — the E13/E14 skeleton disclosure and the current ERP claim set.
