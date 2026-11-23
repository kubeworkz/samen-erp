# WS-LOG — Logistics & Supply Chain · Design

- **Status:** PROPOSED (L1.1 migration contract implemented — shipment resources, `lot_tracked`,
  scoped catalog sync/down and the reversible `:expand` migration; plus L1's legacy `:fulfill`
  live lot refusal. The rest of L1.2+ is design only). ADR-056 is filed;
  on 2026-11-22 the operator RATIFIED OD-1 (the Inventory `logistics:` branch), the L1 half of
  OD-2 (`:fulfill` keeps its full-order shape with the shared lot refusal; `Shipment :ship` is the
  partial path) and OD-7 (repair E13/E14 in
  L4/L5). The operator also RATIFIED PF-1, PF-2 Option A and PF-3 on 2026-11-22. OD-2's L1b half
  and OD-3–OD-6 remain DEFERRED and unratified.
- **Date:** 2026-11-21.
- **Reads:** `docs/adr/ADR-049-erp-base-scopes.md`, `docs/adr/ADR-054-fabless-accounting-books.md`,
  `docs/adr/ADR-004-scope-packaging.md`, `docs/adr/ADR-014/024/026` (fail-honest adapters),
  `docs/adr/ADR-039` (automation), `docs/adr/ADR-041` (canonical work objects),
  `docs/ws-erp/design.md`, `docs/ws-erp/build-plan.md`, `docs/ws-acct/design.md`,
  `samen_core/lib/samen/scopes/inventory.ex`, `samen_core/lib/samen/scopes/inventory/*`,
  `samen_web/lib/samen/web/erp.ex`, `samenerp/lib/samenerp/erp.ex`.
- **Mission:** make SamenERP operable for the physical side of the business — ship what was sold,
  track it, receive what was bought, return what came back — without inventing a second stock
  truth, a second invoice truth, or a second ledger.

---

## 0 · Grounding — what already ships, and what is actually missing

WS-ERP E1–E8 is **done and execution-verified** (build-plan, 2026-09-14). `Samenerp.Erp` mounts
Finance + Inventory over one host namespace, and `samen_erp_routes(:erp, …)` serves the bounded
ERP tenant surfaces (`Samen.Web.Erp` — **13 today**: the original six grew with the AP/AR/expense
work; the E8 "six-surface" wording in older docs is stale). The base already includes:

| Capability | Where it lives today | Verdict |
|---|---|---|
| Item master, warehouses, append-only stock ledger, derived level + moving-average value | `Samen.Scopes.Inventory` (`Item`, `Warehouse`, `StockLedger`, `StockLevel`), `NegativeStock`, `StockLevelSync`, `ReconcileStock` | **Strong.** R3 green + sabotaged. |
| Procurement | `PurchaseOrder`/`PoLine`, `GoodsReceipt`/`ReceiptLine`, `GoodsPosting` (stock + GL in one transaction), `ThreeWayMatch` | **Strong.** R3-full + R5 green + sabotaged. |
| Sales bridge | `SalesOrder`/`SoLine`, `FulfillOrder` (`:fulfill` = stock `:sale` + Billing invoice + COGS, one transaction) | **Strong for full orders.** Explicitly **no partial shipments** — the documented P2 carry. |
| Manufacturing | `Bom`/`BomLine`, `WorkOrder`, `ProductionLog` over the same stock ledger | **Strong.** R4 green + sabotaged. |
| Finance/AR/AP substrate | GL, COGS, AP invoices, credit notes, fiscal periods, close | **Strong.** Logistics consumes it; never rebuilds it. |
| Lots / supplier-located stock | `Lot`, `Warehouse.kind ∈ {owned, consignment, supplier}`, `ReconcileLot` | **Strong for the fabless case**, no serials. |
| Transfers | `TransferOrder` + `etn_transfer_order` table | **Incomplete, despite being "live".** ADR-055 keeps E13/E14 (mounted and migrated; the helper modules are allowlisted), but `:post` carries no change; `TransferGuard` is wired to nothing (only the allowlist names it) and queries `Samen.Scopes.Inventory.StockLevel`, **which does not exist**, so it would raise if invoked. The migration has only an org index (no FKs/checks), and `warehouse_transfers_test.exs` is gone; `README.md`'s "14 tests" is stale (ADR-055 calls the old test vacuous). |
| Landed cost | `LandedCost` + `eld_landed_cost`, `LandedCostAllocator` | **Placeholder.** `allocate_by_value/by_quantity` are pure functions tested by `landed_costs_test.exs` (its other two tests assert literal enum lists), but `change/3` is a documented placeholder not wired to `:allocate`, which carries no change; there is no `LandedCostAllocation` resource/table and the migration adds no FKs/checks or GL/value posting. |
| Shipments, carriers, tracking, RMA, ASN, bins, cycle counts | — | **Absent.** No `Shipment`/`Carrier`/`ShipmentEvent`/`ReturnAuthorization`/`Asn` resource exists in `samen_core/lib/samen/scopes` (verified by search); Driftwood's freight domain is a vertical, not reusable kernel code. |
| Warehouse execution | `Warehouse` is a whole-site location; no bins, picks, packs, waves or counts | **Absent.** |

**Read ADR-055's "live" label carefully.** It means E13/E14 are mounted, migrated and (for the
helpers) allowlisted — not that their workflows are wired.
L0 records this distinction so nobody builds on a placeholder.

**The honest delta.** The quantity ledger, procurement chokepoint, manufacturing facade and
finance postings are already the hard part. What is missing is the **document layer that authorizes
and evidences physical movement**: shipment, tracking, return, advance ship notice, cycle count —
plus the carrier integration boundary. That is WS-LOG.

**Non-negotiable thesis (inherited from ADR-049 §3):** stock moves only through `StockLedger`
events guarded by `NegativeStock`, rolled up by `StockLevelSync` and reconciled by
`ReconcileStock`. A shipment is a *document over that ledger*, never a second quantity table.

---

## 1 · Capability map (binding)

| # | Capability | Ships as | New resources | Reuses | Phase |
|---|---|---|---|---|---|
| L1 | **Partial-fulfillment posting (first slice)** | optional `logistics:` branch on `Samen.Scopes.Inventory` | `Shipment`, `ShipmentLine` | `SalesOrder`/`SoLine`, `StockLedger`, `StockLevel`, the posting helper extracted from `FulfillOrder`, Billing invoice, COGS posting | L1 |
| L1b | **Shipment document completion** | same branch + `samen_web` | `ShipmentPackage`; ship-to/recipient fields on `Shipment` | packing-slip print, pick/pack/delivered states, DB belts, masking | L1b |
| L2 | **Carrier integration + tracking** | kernel behaviour + `samen_web` webhook + surfaces | `Carrier`, `CarrierService`, `ShipmentEvent` | `Samen.Web.Webhook` ingress, `Samen.Files`, Automation/Notifications/Work | L2 |
| L3 | **Returns / RMA** | same branch | `ReturnAuthorization`, `ReturnLine` | `ShipmentLine`, `StockLedger` `:receipt`, Finance `CreditNote`, Files (POD/photos) | L3 |
| L4 | **Inbound logistics / ASN + landed cost** | same branch (inbound half) | `Asn`, `AsnLine`, `ReceiptVariance`, `LandedCostAllocation`, `StockValueAdjustment` | `PurchaseOrder`, `GoodsReceipt`, `GoodsPosting`, `LandedCost` (repaired), AP invoice, R3/R5 | L4 |
| L5 | **Warehouse execution** | same branch | `CycleCount`, `CycleCountLine`; `WarehouseBin` only after amendment | `TransferOrder` (repaired), `StockLedger :adjust`, approvals Gate | L5 |
| L6 | **Planning & supplier collaboration** | reads + adapters, no new quantity mechanism | `ReplenishmentSuggestion` (derived read) | `Item.reorder_point`, Automation, supplier scorecards, EDI adapters | L6 |
| L7 | **Analytics / operator cockpit** | `Samen.Rollup` + aggregate floors | — | existing rollup/aggregate machinery | L7 |

**No new universal scope is added.** ADR-049 §1 deliberately put warehouse + procurement inside
`Inventory` because "stock doesn't move without a document to authorize it"; the SalesOrder lives
there by the same decision (build-plan standing carry: *"do not grow a seventh scope for it"*).
Shipments, returns and counts are the same shape. A new `Samen.Scopes.Logistics` scope is rejected
in §2 D1, not left implicit.

---

## 2 · Architecture decisions (for ADR-056)

### D1 — Extend `Samen.Scopes.Inventory` with an optional `logistics:` branch

**RATIFIED (2026-11-22, OD-1).**

Shipments/returns/ASN/counts are stock documents. They belong beside `SalesOrder`, not in a new
scope that would need its own copy of moving-average reads, NegativeStock, rollup sync and
reconciliation. The branch is optional exactly like `finance:`/`billing:`:

- resources compile only when the mount passes `logistics: true` **and** already wires
  `finance:` + `billing:` (a shipment posts COGS and an invoice; a mount without those cannot
  ship honestly);
- the resource definitions live in a new `samen_core/lib/samen/scopes/inventory/blueprint_logistics.ex`,
  keeping `blueprint.ex` from growing further;
- an Inventory-only host (stock, PO, manufacturing) mounts none of it.

**Rejected:** a standalone `Samen.Scopes.Logistics` scope. It reads cleanly, but it would duplicate
the quantity chokepoint's private helpers or reach across a scope boundary to write another
scope's ledger — the same coupling ADR-049 avoided when it absorbed procurement. Carrier adapters
are still separated (§D4): they are kernel behaviour, not scope resources.

### D2 — The Shipment is the fulfillment event for partials; E5's `:fulfill` keeps its full-order shape in L1

**RATIFIED for L1 (2026-11-22, OD-2 L1 half); the L1b half below stays DEFERRED.**

E5's `:fulfill` consumes the order's own frozen lines, emits one invoice and posts COGS in one
transaction. That is the correct *shape* but the wrong *grain* for partial delivery. L1 adds the
partial grain beside it, without changing E5's full-order shape:

- `Shipment :ship` is the chokepoint for a partial shipment: per line a negative
  `StockLedger :sale`, a COGS entry for the line's cost (skipped when zero), and one Billing
  invoice for the shipped lines — all in the action's transaction.
- **L1 keeps `:fulfill`'s full-order shape**: confirmed-only, full order, one invoice, no shipment
  row. Its only L1 behavior change on this path is the same live lot guard: after the confirmed
  pre-state and
  before `emit_invoice` or any stock/COGS write, every SO line is checked; a lot-tracked or
  lot-backed line is refused with `:lot_tracked_requires_l1b` and nothing lands. The
  stock/invoice/COGS helper is extracted from `FulfillOrder` and both paths call it, so there is
  one money/stock mechanism; E5's existing non-lot tests stay green, with the new legacy
  lot-refusal test added.
- `SoState` keeps `:fulfill` confirmed-only. Once a shipment leaves the order
  `:partially_fulfilled`, the remainder is shipped through `Shipment`, not `:fulfill`; this avoids
  weakening the E5 state machine in the first slice.
- The status flip runs through a new **private internal** `SalesOrder :apply_shipment` action
  (`accept([])` + `PostingMarker`, not exposed by any UI), never by force-stamping outside an
  action. `SoState` admits only
  `:confirmed → :partially_fulfilled` and `:partially_fulfilled → :fulfilled` for it, and refuses
  every other pre-state; `:fulfill` remains confirmed-only. L1b may admit the single
  `:confirmed → :fulfilled` transition for the unified full-shipment path, if it ratifies that
  change.
- `SalesOrder.status` grows `:partially_fulfilled`; the final shipment flips `:fulfilled`.
  `:cancel` stays draft/confirmed-only, so a partially fulfilled order is not cancellable.
- Shipped quantity is **derived** from posted shipment lines (`qty_shipped` read), never a mutable
  column. Over-ship is refused against the live remaining quantity in the transaction.
- Invoice anchors: a shipment carries its own (`Shipment.invoice_key`/`invoice_id`); the SO's
  legacy anchor is written only by E5's full-order `:fulfill`. Partial orders therefore have no SO
  anchor. L1b decides whether to unify `:fulfill` through a full shipment and retire the SO anchor.

**Why this order:** partial fulfillment is the explicit P2 carry, it unlocks returns (you cannot
return what was never shipped), and it needs no external carrier account or PII capture to prove
the chokepoint. Unifying the full-order path and adding the destination/carrier document are L1b.

**Explicitly deferred:** making `:fulfill` create a full shipment, moving the SO invoice anchor,
and migrating E5's walkthrough. They are L1b work, after the partial path is proven.

### D3 — One quantity truth, one money truth

Every stock-affecting action posts its `StockLedger` events through the existing resource changes:
`NegativeStock` (live-sum, fail-closed), `StockLevelSync` (in-transaction rollup) and the DB belt.
No new path may create/update a `StockLevel` row directly. Every money-affecting action posts one
`JournalEntry` in the same transaction (COGS, inventory value, freight/landed cost) and anchors it
with the existing `source_key`/`source_id` shape. Value-neutral movements (same-account transfers
and return restock/repair) and zero-value legs post no `JournalEntry`; a zero-value leg never posts
a zero journal. `PostingMarker` is armed on every state flip that the DB belt gates.

### D4 — Carrier integrations are fail-honest kernel behaviours

`samen_core/lib/samen/logistics/carrier.ex` declares:

```elixir
@callback quote(request, config) :: {:ok, quote} | {:error, :not_configured | term}
@callback buy_label(request, config) :: {:ok, label} | {:error, :not_configured | term}
@callback track(request, config) :: {:ok, [event]} | {:error, :not_configured | term}
@callback parse_webhook(headers, raw_body, config) :: {:ok, [event]} | {:error, term}
```

The default implementation returns `{:error, :not_configured}` for every callback (ADR-014/024/026
posture). A host opts in with a module + per-carrier config; credentials come from runtime
configuration/secrets, **never** from a database column, a log line or a shipment row. A
conformance case proves a stub cannot return `{:ok, _}` for work it did not do.

### D5 — Tracking is append-only and idempotent

`ShipmentEvent` rows are appended (no update/delete), keyed by `(shipment_id, source,
external_event_id)` with a partial unique index for carrier events. The webhook ingress uses the
existing `samen_webhook_routes` machinery with signature verification, rejects unsigned/unknown
events, and stores only normalized bounded fields — never the raw carrier payload (which can
contain recipient details). A repeated event is an insert-if-absent no-op; a conflicting event is
refused, never updated or silently overwritten.

### D6 — Landed cost needs a value-only adjustment ledger

`LandedCostAllocator`'s current `change/3` is a placeholder. L4 replaces it with real
`LandedCostAllocation` rows (one per receipt line, sums exactly to the landed cost) and posts a
**value-only** adjustment. The stock ledger's quantity semantics stay pure: a zero-quantity
"movement" would make `Σ qty × unit_cost` nonsense. Recommended shape: an append-only
`StockValueAdjustment` resource (`item`, `warehouse`, signed `amount_cents`, `source_ref`), with
`StockLevelSync` and `ReconcileStock` extended so

```
stock_value = Σ (ledger qty × ledger unit_cost) + Σ value_adjustment.amount_cents
```

The alternative (a `:revalue` StockLedger kind with qty 0) is rejected unless the ADR explicitly
widens the ledger contract.

### D7 — E13/E14 are not usable as-is

`TransferOrder` and `LandedCost` are compiled, mounted and allowlisted (ADR-055), but that is the
extent of it:

- `TransferOrder :post` carries no change and never stamps `posted_at`; `TransferGuard` is
  referenced by nothing and its stock check calls `Samen.Scopes.Inventory.StockLevel`, which is a
  **non-existent module** (host resources are generated in the host namespace), so invoking it
  would raise. The `etn_transfer_order` table has only an org index — no FKs, no checks, no
  transfer-posting events.
- `LandedCostAllocator.change/3` is explicitly a "design placeholder" that fabricates a map and
  flips status; `LandedCost :allocate` carries no change; there is no `LandedCostAllocation`
  resource/table; `eld_landed_cost` has no FKs/checks or GL/value posting. Only the pure
  `allocate_by_*` arithmetic is tested (`landed_costs_test.exs`).
- `README.md` claims `warehouse_transfers_test.exs` (14 tests) and a `transfer_order.ex` file; the
test does not exist and ADR-055 records the old one as vacuous.

ADR-056 records this audit and RATIFIES repair in L4/L5 (OD-7, 2026-11-22); removal is not the
chosen path. No surface advertises a transfer/landed-cost workflow until the repair ships with its
reconciliation test.

### D8 — Bin-level stock is a later, explicit schema decision

A warehouse-wide `StockLevel` grain is what R3 proves today. Adding bins changes the ledger grain,
the rollup key, every reconciliation and the migration/backfill story. L5 ships cycle counts and
transfers at warehouse grain first; bin-level stock requires an ADR-056 amendment and its own
migration plan, not a nullable column slipped into L1.

### D9 — PII stays at the edge; events stay bounded

L1 carries **no PII**. In L1b, shipment ship-to and recipient fields are vaulted
(`Samen.Type.Address` with `pii_address`, `Samen.Type.FullName`/`Phones`/`Emails` as applicable).
Every surface that exposes them follows the masking watch-list trio. Tracking events, exception codes and shipment numbers are bounded business
fields; carrier free-text descriptions are **not persisted** (they routinely contain recipient
addresses). Labels are generated in memory or through Files; nothing logs a plaintext address.

### D10 — Carrier is its own master, optionally linked to a Vendor

A carrier is an operational entity (SCAC, modes, services, tracking template) and an AP payee. Keep
`Carrier` separate with an optional `vendor_id` (the `SalesOps.Vendor` row used for freight bills).
Reusing Vendor as the carrier master would put service/SCAC/tracking semantics into an AP noun; a
pure link keeps both clean.

---

## 3 · Data model

All resources are org-scoped, use the host namespace via the scope macro, carry permanent abbrevs
reserved through `mix samen.abbrev.reserve` (candidate names below are **not** reserved), and have
no destroy action.

### 3.1 Partial fulfillment (L1)

**`Shipment`** — `number` (unique per org), `sales_order_id` (same-org), `warehouse_id`
(ship-from), `status ∈ {:draft, :shipped}`, `shipped_at`,
`invoice_key`/`invoice_id` (the emitted invoice anchor), `memo` (bounded). **No PII, no
destination, no carrier, no packages and no tracking in L1** — those are L1b/L2. Cancellation is
L1b too: a draft can simply be left unposted.

**`ShipmentLine`** — `shipment_id`, `so_line_id`, `item_id`, `qty` (positive integer),
`unit_price_cents` (snapshot from the SO line), `unit_cost_cents` (frozen at `:ship`), unique
`(shipment_id, so_line_id)`. Create/read only for user-facing actions: no line updates or deletes
in L1; the private `:stamp_cost` action inside `ShipPosting` is the one internal update.

**L1 lot gate** — extend the `Item` resource with `lot_tracked` (boolean, default `false`; the
migration marks existing items with `Lot` rows as lot-tracked). Make the flag a maintained
invariant: every `Lot :create` transactionally marks its item's flag `true` (the lot rolls back if
the mark fails), and the `Item` update action refuses to clear it while any `Lot` exists
(`:lot_tracked_has_lots`). Both the `ShipPosting` and legacy `SalesOrder :fulfill` preflights
still use the live guard: refuse a line for an item whose flag is true **or** which has any
existing `Lot` row, before any invoice/stock/COGS write, with `:lot_tracked_requires_l1b`.
`FulfillOrder` runs it after the confirmed pre-state and before `emit_invoice`; `ShipPosting`
runs it after its locks. The live `Lot` check (backed by the existing `lot.item_id` index) is the
authoritative belt for out-of-band rows and old writers during rollout; the one-time backfill
only initializes the flag, and an idempotent post-deploy reconciliation re-marks flags after the
old writers drain. The check is read-only; L1
adds no `StockLedger` or `ShipmentLine` lot columns, and L1b owns the lot-aware movement.

### 3.2 Shipment document completion (L1b)

**`Shipment` additions** — `ship_to` (🔒 `Samen.Type.Address`), `recipient_name` (🔒
`Samen.Type.FullName`), optional `recipient_phone`/`recipient_email`; a draft-only cancel action
and status `:cancelled`, plus `:picked`, `:packed`, `:delivered`; draft-only line edit/delete;
`delivered_at`; the packing-slip print surface. Carrier, service, tracking number and freight cost arrive with L2.

**`ShipmentLine` lot additions** — `lot_id` (required when the item is lot-tracked; one line per
lot), the `(shipment_id, so_line_id, lot_id)` unique with partial indexes for nil/non-nil, lot
cost snapshots, lot-level `NegativeStock`, and the `source_key: "lot"` backfill for
`StockLedger.lot_id`. `ReconcileLot` reads `lot_id` after the backfill. L1 adds none of these.

**`ShipmentPackage`** — `shipment_id`, `package_number`, `weight_grams`, `length_mm`, `width_mm`,
`height_mm`. The packing slip's package block; no PII. Package tracking numbers arrive with L2.

### 3.3 Carrier integration (L2)

**`Carrier`** — `name`, `code` (unique per org), `scac` (optional), `modes`
(`:parcel | :ltl | :ftl | :ocean | :air | :rail`, array), `tracking_url_template` (optional),
`status ∈ {:active, :inactive}`, `vendor_id` (optional same-org link). No credentials.

**`CarrierService`** — `carrier_id`, `code` (unique per carrier), `name`, `mode`, `transit_days`.

**`ShipmentEvent`** — append-only: `shipment_id`, `kind ∈ {:label_created, :picked_up,
:in_transit, :out_for_delivery, :delivered, :exception, :returned, :note}`, `occurred_at`,
`location_code`, `exception_code` (closed enum), `source ∈ {:manual, :carrier, :webhook}`,
`external_event_id` (unique per shipment/source when present). No free text. Recorded_by is a
bounded id.

### 3.4 Returns (L3)

**`ReturnAuthorization`** — `number` (unique per org), `sales_order_id`, `shipment_id` (required),
`customer_id`, `warehouse_id` (receiving/quarantine), `status ∈ {:draft, :authorized, :received,
:closed, :cancelled}`, `reason ∈ {:damaged, :wrong_item, :not_as_described, :late, :quality,
:other}`, `requested_at`, `received_at`, `credit_note_key`/`credit_note_id` (Finance `CreditNote`
anchor).

**`ReturnLine`** — `rma_id`, `shipment_line_id`, `item_id`, `qty` (positive), `lot_id` (required
when the item is lot-tracked), `condition ∈ {:new, :usable, :damaged, :defective}`,
`disposition ∈ {:restock, :quarantine, :scrap, :repair}`, `restock_warehouse_id` (optional).
Return receipt posts a positive `:receipt` into the receiving warehouse and reverses COGS at the
shipment snapshot; the disposition action moves it (transfer/issue) or quarantines it. The credit
note is issued at `:receive` for accepted value.

### 3.5 Inbound (L4)

**`Asn`** (advance ship notice) — `number`, `purchase_order_id`, `vendor_id`, `warehouse_id`,
`expected_at`, `carrier_id`, `tracking_number`, `status ∈ {:draft, :in_transit, :arrived,
:received, :cancelled}`.

**`AsnLine`** — `asn_id`, `po_line_id`, `item_id`, `qty`, optional `lot_id`.

**`ReceiptVariance`** — append-only: `goods_receipt_line_id`, `kind ∈ {:over, :short, :damaged}`,
`qty`, `resolution ∈ {:accepted, :rejected, :replacement}`, `reason_code` (closed enum).
`GoodsReceipt` gains an optional `asn_id`; its `:receive` accepts per-line accepted/rejected
quantities and posts stock only for accepted units (rejected units are recorded, never silently
stocked).

**`LandedCostAllocation`** — `landed_cost_id`, `receipt_line_id`, `allocated_cents`; sum must equal
the landed cost amount (±0; the allocator balances the rounding remainder deterministically).

**`StockValueAdjustment`** — append-only: `item_id`, `warehouse_id`, optional `lot_id`, signed
`amount_cents`, `source_key`/`source_id`, `reason_code`, `posted_at`. R3's value leg includes it
(D6).

### 3.6 Warehouse execution (L5)

**`CycleCount`** — `warehouse_id`, `status ∈ {:draft, :counting, :submitted, :approved, :posted}`,
`counted_at`, `approved_by`, `note` (bounded).

**`CycleCountLine`** — `cycle_count_id`, `item_id`, `lot_id` (required when the item is
lot-tracked), `system_qty` (snapshot), `counted_qty`, `variance` (derived), `reason_code` (closed
enum). `:post` requires approval above a configured tolerance, re-reads live on-hand and refuses a
stale `system_qty`, and emits `StockLedger :adjust` events through the same chokepoint.

**`WarehouseBin`** — deferred (D8).

### 3.7 Existing resources to extend

- `SalesOrder`: `:partially_fulfilled` status and derived `qty_shipped`; `:fulfill` keeps its
  confirmed-only, full-order behavior in L1, plus the shared live lot refusal before any write.
  The SO invoice anchor stays for that path; shipments carry their own. L1b decides whether to
  unify them.
- `GoodsReceipt`: optional `asn_id`, variance-aware receipt (accepted vs rejected quantities).
- `TransferOrder`: real `:post` posting (L5), with lot identity when lot-tracked.
- `LandedCost`: real `:allocate` posting (L4).
- `StockLevel` / `ReconcileStock`: value leg includes `StockValueAdjustment` (L4).
- `Item`: extend the resource with `lot_tracked` boolean default `false`; L1 migration adds the
  column and marks existing `Lot` items. The flag is maintained by `Lot :create` and the
  no-clear-while-lots guard (`:lot_tracked_has_lots`); both L1 preflights still perform the live
  `Lot` existence check, because an out-of-band row or rollout window can leave the flag false.
- `StockLedger`: optional `lot_id` in L1b; backfill `source_key: "lot"` rows.

### 3.8 Candidate abbrevs (allocator decides)

| Resource | Candidate | Phase |
|---|---|---|
| `Shipment` | `shp` | L1 |
| `ShipmentLine` | `shm` | L1 (the `shl` candidate is already owned by `Samenerp.Hr.LeaveRequest`) |
| `ShipmentPackage` | `spk` | L1b |
| `Carrier` | `car` | L2 |
| `CarrierService` | `crs` | L2 |
| `ShipmentEvent` | `she` | L2 |
| `ReturnAuthorization` | `rma` | L3 |
| `ReturnLine` | `rml` | L3 |
| `Asn` | `asn` | L4 |
| `AsnLine` | `anl` | L4 |
| `ReceiptVariance` | `rcv` | L4 |
| `LandedCostAllocation` | `lca` | L4 |
| `StockValueAdjustment` | `sva` | L4 |
| `CycleCount` | `cyc` | L5 |
| `CycleCountLine` | `cyl` | L5 |

None may be hand-added to `priv/abbrev_registry.json`; every one goes through the sanctioned
allocator and the registry goldens/CI verifiers.

---

## 4 · Chokepoints and invariants

### 4.1 `ShipPosting` (L1 — the load-bearing change)

`Shipment :ship` executes, in one transaction. The action first takes `SELECT ... FOR UPDATE` on
the org-pinned shipment row, then on its `SalesOrder` row, and re-reads the shipment status, SO
status and live remaining quantity only after both locks. No new path may take those locks in
reverse order; `PostingMarker` remains the finance belt, not the mutex.

1. **Preflight, after the locks and before any write:** shipment is `:draft`; SO is
   `:confirmed|:partially_fulfilled`;
   at least one line;
   every line's `qty > 0`; every line's `qty ≤ remaining` where remaining =
   SO line qty − Σ posted shipment qty (live, in-transaction); shipment warehouse matches the
   SO's fulfilling warehouse in L1; item links and moving-average costs resolve; a lot-tracked or
   lot-backed line (flag true, or any existing `Lot` row including one created after the
   backfill) is refused with `:lot_tracked_requires_l1b` before any stock/invoice/COGS write.
2. Per line: freeze `ShipmentLine.unit_cost_cents` through the private `:stamp_cost` action, then
   `StockLedger :record` with `kind: :sale`, negative qty, that snapshot, anchored
   `source_key: "shipment"`, `source_id: shipment.id`. `NegativeStock` and `StockLevelSync` run as
   they do for any ledger create.
3. **COGS:** one posted journal entry Dr `:cogs` / Cr each item's inventory account for the same
   qty × snapshot (skip a zero-cost entry exactly as E5 does); anchored to the shipment.
4. **Invoice:** issue one Billing invoice for the shipped lines (`amount_due` = Σ qty × SO line
   price), anchored on the shipment. Partial shipments therefore produce partial invoices; the
   SO's legacy anchor is written only by E5's full-order `:fulfill`.
5. **State:** shipment → `:shipped` via a conditional update from `:draft`; zero rows updated
   aborts. SO → `:partially_fulfilled` or `:fulfilled`, all in the same transaction. Exactly-once
   is enforced by the Shipment → SalesOrder row locks, the post-lock re-read and the conditional
   flip; `PostingMarker` is the finance belt, not the mutex. A lock timeout is a refusal, not an
   in-action retry.

Refusals are fail-honest with distinct reasons, before any stock/invoice write. Over-ship,
zero-qty, unlinked item, a missing level row (never stocked) and negative stock all abort the whole
action. A nil moving average is a stocked zero-cost pair, not a missing cost; it posts no COGS entry,
exactly as E5 does.

The stock/COGS/invoice mechanics are extracted from `FulfillOrder` into a shared posting helper
that both `ShipPosting` and E5's `:fulfill` call. `:fulfill` keeps its confirmed-only, full-order
behavior in L1 — it does not create a shipment. Both paths apply the shared live lot guard.

**Legacy `:fulfill` lot preflight.** `FulfillOrder` applies the same live lot guard to every SO
line after its confirmed pre-state and before `emit_invoice` or any stock/COGS write. A
lot-tracked or lot-backed line refuses with `:lot_tracked_requires_l1b`; no invoice, stock event,
COGS entry, or SO flip lands. Its full-order, one-invoice, no-shipment semantics are otherwise
unchanged. The live `Lot` check remains mandatory even though `Lot :create` maintains the flag:
it is the out-of-band and rollout-window belt.

Unifying `:fulfill` through a full shipment (and deciding the SO anchor's fate) is L1b, after the
partial path is proven.

### 4.2 `ReturnPosting` (L3)

`:receive` validates `qty ≤ shipped qty − already returned qty` per shipment line, posts a
positive `:receipt` into the receiving/quarantine warehouse anchored `source_key: "return_authorization"`,
records the return lines, posts the COGS reversal Dr item inventory / Cr `:cogs` at the shipment
snapshot (zero-value leg posts no entry), and issues a Finance `CreditNote` at `:receive` for
accepted value (AR reduction; no cash refund in the base). `:disposition` moves each line: restock
(paired transfer; no JournalEntry), scrap (`:issue`/`:adjust`; Dr `:write_down_expense` / Cr item
inventory), repair (transfer; no JournalEntry). Over-return and over-credit are refused before any
write; exactly-once by status + marker.

### 4.3 `AsnReceipt` (L4)

ASN is an expectation, not a stock document. `GoodsReceipt :receive` remains the one chokepoint;
when created from an ASN it carries `asn_id`, accepts per-line accepted/rejected quantities, and
records `ReceiptVariance` rows for the difference. Accepted qty posts stock + GL exactly as today;
rejected qty posts nothing and is visible for supplier follow-up. Over-receipt beyond PO ordered
+ accepted tolerance is refused (R5 remains the flag, not a silent block).

### 4.4 `LandedCostAllocation` (L4)

`:allocate` computes allocations over the receipt lines by value or quantity, persists
`LandedCostAllocation` rows, requires Σ allocations == the landed cost amount, posts one
`StockValueAdjustment` per line (and the GL entry Dr inventory / Cr landed-cost clearing or AP),
and flips the landed cost to `:allocated`. A failed allocation writes nothing. R8 proves the
three sums agree; R3's value leg must stay green after the adjustment.

### 4.5 `TransferPosting` (L5 — repair of E13)

`:post` validates same-org source/destination/item, positive qty, source ≠ destination, and source
stock from the **live ledger sum** (not a fixture resource). It copies the source cost to both events;
a same-account transfer is value-neutral and posts no `JournalEntry`. It writes one `:transfer_out`
and one `:transfer_in` event in one transaction, anchored to the transfer, with `PostingMarker`
arming the posted flip. A half-posted transfer is structurally impossible; R9 proves the pair.

### 4.6 `CycleCountPosting` (L5)

`:post` requires `:approved` status (Gate above the configured tolerance), a reason on every
non-zero variance, and re-reads live on-hand (and lot on-hand when `lot_id` is present); it refuses
a stale `system_qty` and emits `:adjust` events through the normal ledger create. A valued shortage
posts Dr `:write_down_expense` / Cr inventory; a nil shortage posts no value leg. A valued surplus
posts Dr inventory / Cr `:write_down_expense`; a nil surplus refuses. No direct level writes; R3
remains the arbiter.

### 4.7 Reconciliation spine (new R6–R9)

| ID | Invariant | Red-path / sabotage shape |
|---|---|---|
| **R6** | Per shipment: stock events == shipment lines == invoice total, and the posted COGS entry == Σ shipped qty × the stock events' cost snapshot (a zero-cost shipment posts no entry). Per order: Σ shipped + open == ordered; open never negative. | Post stock but skip invoice/COGS; accept over-ship; two postings for one shipment. |
| **R7** | Σ returned qty ≤ Σ shipped qty; credit note total == accepted returned value; stock events == disposition; COGS reversal == returned snapshot; restock/repair post no JournalEntry and scrap posts `:write_down_expense`. | Over-return accepted; credit without stock; restock without receipt; missing reversal. |
| **R8** | Σ landed-cost allocations == landed cost; Σ value adjustments == allocations; inventory GL delta == adjustments; R3 value still holds. | Allocation drops/creates a cent; adjustment without GL; GL without adjustment. |
| **R9** | Per transfer: `transfer_out` qty == −`transfer_in` qty, same item, same source cost, same transaction; aggregate rollup unchanged; no JournalEntry. | Half-posted transfer; mismatched item/qty/cost; direct level edit. |

R3 (quantity/value), R4 (manufacturing), R5 (three-way match) remain green and are re-run at every
phase gate. R5 is extended in L4 to account for rejected receipt quantities and freight invoices.

---

## 5 · PII, masking and erasure

- **L1 has no PII.** The first slice's `Shipment` carries no destination, recipient, carrier or
  tracking. This is deliberate: it keeps the chokepoint slice free of a new vault class and the
  masking gate.
- **L1b adds the vaulted fields:** `Shipment.ship_to` (`pii_address`), `recipient_name`
  (`pii_name`), optional `recipient_phone` (`pii_phone`)/`recipient_email` (`pii_email`).
  Everything else on a shipment is bounded business data.
- **Surfaces (L1b):** the shipment list shows number/status/dates only (no PII); detail/print
  resolve the address/recipient through `Samen.Api.PiiResolution` on the acting plane. Every
  surface gets the three masking proofs: tenant plane clear (with grant where required), operator
  plane `••••` (never plaintext, never a `vt_*` token in DOM/CSV/print), and a sabotage twin that
  flips a plane-dependent assertion.
- **Print/CSV (L1b):** packing slips and return labels are tenant-plane print surfaces; an
  operator print is masked. Any CSV export uses `Samen.Web.Csv` with a column allowlist that omits
  PII (mask-by-omission), and a widen attempt is refused.
- **Carrier payloads:** the adapter receives only the fields it needs at call time; request/response
  bodies are never logged. `ShipmentEvent` carries no free text; carrier descriptions are
  normalized into closed enums and dropped otherwise.
- **Erasure:** vaulted shipment/return fields crypto-shred through the standard subject path; the
  append-only business facts (shipment number, dates, quantities, tracking id, GL/stock anchors)
  survive as bounded records, exactly like consent/employment events.

---

## 6 · Surfaces and workflows

Framework-first, ≈0-LOC host mount. A new `samen_web` module (working name
`Samen.Web.Logistics`) declares one router macro (`samen_logistics_routes/3`) and the bounded
surfaces; `samenerp` mounts it with one line. `Samen.Web.Erp` is the bounded generic registry (13
surfaces today) and it DOES support governed create/edit/transition forms — it is not read-only —
but logistics workflows (create a partial shipment from a SO, later pick/pack/ship and receive a
return) are too workflow-shaped for the generic table, so they get their own LiveViews.

| Surface | Phase | Workflow |
|---|---|---|
| Shipments (list/detail) | L1 | From SO: choose remaining lines/qtys and warehouse; draft → shipped. No cancel, carrier, destination, tracking or print in L1. |
| Packing slip + destination | L1b | Capture ship-to/recipient, add packages and pick/pack/delivered states; tenant-plane print with the masked-on-operator recipient block (AP print-run precedent). |
| Carriers / services | L2 | Admin-bounded master; adapter config is host config, not a UI secret field. |
| Tracking timeline + exceptions | L2 | Carrier webhook events; manual correction; exception task/notification. |
| Returns (list/detail) | L3 | Authorize against a shipment, receive into quarantine, disposition, credit note. |
| ASN + receiving | L4 | Expected inbound list; receive with accepted/rejected quantities and variance reasons. |
| Landed costs | L4 | Allocate a freight/duty bill across receipt lines; preview allocations before posting. |
| Transfers / cycle counts | L5 | Transfer post; count sheet; approval + adjustment. |

Every write goes through the resource's governed action with the org-pinned mount scope; the UI is
never a write path of its own. Role gates (`:member` for operational writes, `:admin` for carrier
config/cycle-count approval) and the operator-plane read-only posture are policy, not cosmetics.
Operator act-as uses the existing tenant-plane crossing; the operator plane renders masked.

**Exception ownership:** late shipments, tracking exceptions, overdue ASNs, receipt variances and
cycle-count approvals create Work tasks/notifications through the existing Automation engine
(ADR-039/041), with the shipment/return/ASN as an object-ref anchor. No new task mechanism.

---

## 7 · Integrations

- **Billing:** partial invoices per shipment via the host's existing invoice module; shipping
  charges are a separate invoice line in a later phase, not silently folded into item price.
- **Finance:** COGS, inventory value adjustments, landed cost clearing, credit notes and fiscal
  periods/close (ADR-054). Every posting is anchored and one-transaction with its document.
- **AP:** freight invoices are ordinary `ApInvoice` rows; `LandedCost.bill_id` links an inbound
  freight/duty bill to its allocation. Three-way match (R5) sees accepted receipt quantities.
- **CRM / SalesOps:** customer/company ids and vendor ids are same-org references; carrier has an
  optional vendor link; no CRM address is copied into the ledger.
- **Files:** BOLs, labels, packing slips and POD photos go through `Samen.Files.upload/3`
  (quarantine → scan → promote); no direct `storage_key` minting.
- **Webhooks:** `samen_webhook_routes` ingress with per-carrier HMAC, idempotency and bounded
  normalization; no raw payload retention.
- **Operator/BI:** shipment/return/ASN KPIs ride `Samen.Rollup` and the aggregate floors
  (k-anon/l-div); no new cross-tenant mechanism. Deferred to L7.
- **EDI:** 850/856/810/214 are adapters behind the carrier/supplier boundary in L6, not a built-in
  translator, and fail `{:error, :not_implemented}` until a host provides one.

---

## 8 · Deliberately out of scope (honesty list)

1. **Full TMS / route optimization / load planning** — no solver, no dispatch board.
2. **Fleet telematics / GPS / driver mobile app** — integration or P3.
3. **Customs brokerage, duty calculation, HS classification** — landed cost records amounts;
   it does not compute tariffs or file customs.
4. **Tax engines / VAT/GST filing** — the existing boundary stays.
5. **MRP, demand forecasting, automatic PO generation** — L6 ships a derived replenishment
   *suggestion*; auto-PO remains P2 and gated.
6. **Serial-number traceability** — lots exist; serials are a later ADR.
7. **Bin-level stock** until the D8 amendment is ratified.
8. **Multi-currency freight and FX revaluation of logistics documents** — finance's existing
   boundaries apply; no silent conversion.
9. **3PL billing reconciliation / warehouse robotics / WMS task engines** — later integrations.
10. **Marketplace/shipping aggregator integrations and label resale** — adapter territory, not the
    base scope.

Every "just also compute X" belongs here, in an adapter, or in a later ADR — never half-built in a
ledger.

---

## 9 · Risks and decision status

| Risk / decision | Position |
|---|---|
| **Two posting paths in L1** | L1 keeps `:fulfill` and adds `ShipPosting`; both call one extracted stock/COGS/invoice helper and the same live lot guard. **L1b DEFERRED:** decide whether to unify them through a full shipment. Gate L1 on R6 plus both paths' lot refusals and E5's existing non-lot suite so the split cannot drift silently. |
| **Invoice atomics** | Shipments anchor their own invoices; the SO anchor remains for E5's full-order path. Partial orders have no SO anchor by design. L1b ratifies whether to retire it. |
| **Landed-cost value ledger** | D6 chooses `StockValueAdjustment`; R3's value formula changes and must be re-proven with R3 + R8. |
| **Carrier API heterogeneity** | Closed callback set + conformance case; unsupported capability returns `:not_configured`, never a fabricated rate/label/event. |
| **PII on labels/events** | None in L1; L1b vaults ship-to/recipient and adds the masking trio; L2 keeps events bounded and raw payloads out. |
| **E13/E14 debt (OD-7)** | Audit in L0 (including the nonexistent `StockLevel` reference and the stale README claim); **RATIFIED (2026-11-22): repair in L4/L5, not delete.** Do not expose a surface over a placeholder. |
| **L1 preflight (PF-1–PF-3)** | **RATIFIED 2026-11-22:** PF-1 row locks; PF-2 Option A (defer lots; live `Lot` existence check); PF-3 frozen snapshot and no-entry rules. Option B is not selected. |
| **Abbrev budget** | ~15 new resources; L1 reserves only `shp`/`shm` (the `shl` candidate was taken by HR); the rest follow their phase via the allocator and registry goldens/CI. |
| **Scope creep** | The §8 list is binding; logistics is documents over stock, not a WMS/TMS. |
| **Rollup freshness** | Reads serve the rollup; chokepoints use the live ledger sum in-transaction (the existing posture), never a stale level. |
| **Scope boundary (OD-1)** | **RATIFIED (2026-11-22):** Inventory `logistics:` branch (D1); not a standalone Logistics scope. |
| **Fulfillment unification (OD-2)** | **L1 half RATIFIED (2026-11-22):** `:fulfill` keeps its full-order, one-invoice shape with the shared lot refusal, and `Shipment :ship` is the partial path. **L1b half DEFERRED:** unify `:fulfill` through one full shipment and retire or alias the SO anchor after L1 proves R6. |
| **Ship-to source (OD-3, L1b)** | **DEFERRED to L1b:** snapshot on Shipment (historical accuracy), not a live CRM read. |
| **Carrier credentials (OD-4, L2)** | **DEFERRED to L2:** host runtime config/secrets keyed by org + carrier code; never a DB secret. |
| **Bin grain (OD-5, L5)** | **DEFERRED to L5:** amendment required (D8). |
| **Return refunds (OD-6, L3)** | **DEFERRED to L3:** credit note only in the base; cash refund/payment reversal is Finance's existing path, later. |

---

## 10 · First milestone (what "start implementing" means)

**L1 — partial-fulfillment posting.** This is deliberately narrower than "a shipment feature": it
closes the explicit E5 P2 carry and proves the stock/COGS/invoice chokepoint. It needs no carrier
account, no destination capture, no PII and no print. Acceptance is defined in
`docs/ws-log/build-plan.md`; the short version:

- a confirmed SO can ship in two partial shipments, each posting its own stock events, COGS and
  invoice, with the order flipping `:partially_fulfilled` then `:fulfilled`;
- over-ship, zero-qty, unlinked-item and negative-stock attempts are refused before any write;
- `:fulfill` keeps its full-order, no-shipment shape, adds the shared live lot refusal, and its
  existing non-lot E5 suite stays green;
- R6 green, R3/R4/R5 unchanged green, the new sabotage patch flips the named R6 tests and reverts
  byte-exact;
- **L1b next:** destination/recipient + masking, packages, packing slip, pick/pack/delivered,
  DB belts, and the `:fulfill` unification decision.
