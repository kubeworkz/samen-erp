# ADR-056 — Logistics & supply chain: an optional Inventory `logistics:` branch,
# shipments as stock documents, and a fail-honest carrier boundary

- **Status:** **PROPOSED (2026-11-22) — design record only; no code, abbrev rows,
  migrations or L1 work authored. D1–D10 are proposed and the seven open
  decisions in §6 remain OPEN.** This ADR transcribes the WS-LOG design (§2 and
  §9) and closes the documentation half of L0; it does not ratify the build.
- **Date:** 2026-11-22
- **Deciders:** the operator (ratification pending); the audit evidence is from
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
labels both as skeletons; this ADR is the formal record and the L4/L5 repair
charter.

The non-negotiable thesis is inherited from ADR-049: stock moves only through
`StockLedger` events guarded by `NegativeStock`, rolled up by `StockLevelSync`, and
reconciled by `ReconcileStock`. A shipment is a document over that ledger, never a
second quantity table.

## Decisions

### D1 — Extend `Samen.Scopes.Inventory` with an optional `logistics:` branch

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

### D2 — The Shipment is the fulfillment event for partials; E5's `:fulfill` stays untouched in L1

E5's `:fulfill` consumes the order's own frozen lines, emits one invoice and posts
COGS in one transaction. That is the correct shape but the wrong grain for partial
delivery. L1 adds the partial grain beside it:

- `Shipment :ship` is the chokepoint for a partial shipment: per line a negative
  `StockLedger :sale`, a COGS entry, and one Billing invoice for the shipped lines,
  all in the action's transaction.
- **L1 leaves `:fulfill` exactly as it is**: confirmed-only, full order, one
  invoice, no shipment row. The stock/invoice/COGS helper is extracted from
  `FulfillOrder` and both paths call it, so there is one money/stock mechanism,
  but no E5 behavior or test changes.
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

Every stock-affecting action posts a `StockLedger` event through the existing
resource changes: `NegativeStock` (live-sum, fail-closed), `StockLevelSync`
(in-transaction rollup) and the DB belt. No new path may create or update a
`StockLevel` row directly. Every money-affecting action posts one `JournalEntry`
in the same transaction (COGS, inventory value, freight/landed cost) and anchors
it with the existing `source_key`/`source_id` shape. `PostingMarker` is armed on
every state flip that the DB belt gates.

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

**Decision:** repair the skeletons in L4/L5 (recommended) or remove them; do not
expose a transfer/landed-cost workflow until the repair ships with its
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

## Open decisions

These are **OPEN**; the recommendations are the design's, not ratified decisions.

| ID | Open decision | Recommendation |
|---|---|---|
| OD-1 | Scope boundary: Inventory `logistics:` branch vs a standalone Logistics scope | Ratify D1: the Inventory branch. A standalone scope duplicates the quantity chokepoint. |
| OD-2 | Fulfillment unification: keep two posting paths in L1, then decide whether `:fulfill` creates a full shipment and whether the SO invoice anchor is retired or aliased | Unify in L1b, after L1 proves the partial path and R6. |
| OD-3 | Ship-to source in L1b: snapshot the address/recipient on the Shipment or read live from CRM | Snapshot for historical accuracy. |
| OD-4 | Carrier credentials: host runtime configuration/secrets vs a database column | Runtime config/secrets keyed by org + carrier code; never a DB secret, log line or shipment row. |
| OD-5 | Bin grain: warehouse-level stock first, then a bin-level amendment | Defer bins; require an ADR-056 amendment plus migration/backfill and a re-proven R3. |
| OD-6 | Return refunds: credit note only vs a cash refund/payment reversal in the base | Credit note only in the base; cash refunds use Finance's existing path later. |
| OD-7 | E13/E14 disposition: repair the skeletons vs delete them | Repair in L4/L5; do not expose a surface over a placeholder. |

## Consequences

- **No new universal scope.** The logic stays in Inventory; carrier adapters are
  kernel behaviours.
- **L1 is the first milestone.** Partial fulfillment must land before L1b, L2–L5,
  and ultimately L6/L7. The L1 gate is R6 plus unchanged E5, R3, R4 and R5 suites.
- **No code, abbreviations or migrations are created by this ADR.** L1 reserves
  only `shp`/`shl` through the sanctioned allocator; the remaining ~13 resources
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
