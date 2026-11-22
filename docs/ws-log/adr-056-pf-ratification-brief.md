# ADR-056 PF-1–PF-3 ratification brief

**Status:** RATIFIED 2026-11-22 — retained as the decision record. The ADR/design/build-plan were updated; ADR-056 remains **PROPOSED**. Docs-only; no code, migration, abbreviation allocation or commit.
**Current ADR state:** OD-1, OD-2's L1 half and OD-7 are ratified; PF-1, PF-2 Option A and PF-3 are ratified; OD-2's L1b half and OD-3–OD-6 remain deferred.
**Ratified package:** **PF-1**, **PF-2 Option A (defer lots)**, and **PF-3** with `:write_down_expense` shared by shrinkage and scrap. This did not ratify the ADR or start L1.
**Record note:** the “if ratified” instructions below are the pre-ratification checklist; they have now been applied to ADR-056, design and build-plan.

## Decision summary

| ID | Choice | Recommendation | Consequence |
|---|---|---|---|
| **PF-1** | Ratify the Shipment → SalesOrder row-lock protocol, or amend/reject it | **Ratify** | Replaces the insufficient “pre-state + `PostingMarker`” exactly-once claim. No schema change. |
| **PF-2** | Option A: defer lot-aware movement to L1b; or Option B: add it to L1 | **Option A** | L1 refuses lot-tracked lines fail-honestly; L1b owns lot columns, backfill, lot stock and lot cost. Option B expands L1 but supports lot SKUs immediately. |
| **PF-3** | Ratify the frozen cost snapshot and GL/no-entry rules, or amend them | **Ratify** | Returns use the shipment cost snapshot; restock/repair and same-account transfers post no JournalEntry; zero-value legs post none; credit note at `:receive`. |
| **PF-3 accounts** | Reuse `:write_down_expense` for both shrinkage and scrap, or split the closed enum | **Reuse now** | Split only if the operator wants `:inventory_shrinkage` and `:scrap_expense` before L3/L5; that is a separate Finance enum amendment. |

## PF-1 — Exactly-once is row locks; `PostingMarker` is the belt

**Choice.** Ratify the protocol as written, or amend/reject it. The protocol is:

1. Lock the org-pinned Shipment row with `SELECT ... FOR UPDATE`.
2. Lock its SalesOrder row in the same order.
3. Re-read shipment status, SO status and live remaining quantity only after both locks.
4. Keep all preflight refusals after the locks.
5. Flip Shipment from `:draft` with a conditional update; zero rows updated aborts the transaction.
6. Keep `PostingMarker` as the finance belt, never as the mutex.

**Recommendation: ratify.** A pre-state read plus `PostingMarker` is not exactly-once under concurrent READ COMMITTED. The lock order must remain Shipment → SalesOrder; no new path may reverse it.

**Exact updates if ratified:**

- **ADR-056:** mark PF-1 `RATIFIED (date)`; remove only its `DRAFT` label. Keep the ADR `PROPOSED` and the OD register unchanged.
- **`docs/ws-log/design.md` §4.1:** replace the step-5 sentence “exactly-once is enforced by the pre-state + `PostingMarker`” with the lock/re-read/conditional-update protocol. Add the Shipment → SalesOrder lock order and the no-reverse rule to the preflight description.
- **`docs/ws-log/design.md` §9:** record PF-1 as the L1 concurrency decision; leave OD-2-L1b and the other OD rows untouched.
- **`docs/ws-log/build-plan.md` L1.2:** add the two row locks and post-lock re-read before any write; make the draft flip conditional; state that a lock timeout is a refusal, not an in-action retry.
- **`docs/ws-log/build-plan.md` L1.4:** add the concurrency gate: two `:ship` calls on one shipment produce one stock/COGS/invoice set, and two concurrent shipments on one SO cannot both pass the remaining check. The test must observe one conflict, not serial success.

No migration or schema update follows from PF-1 alone.

## PF-2 — Lot policy

### Option A — DEFER (recommended)

L1 adds only the lot-related `Item.lot_tracked` flag and refuses every shipment line for a lot-tracked item before stock/invoice/COGS writes with `:lot_tracked_requires_l1b`. L1 adds no `StockLedger` or `ShipmentLine` lot columns. L1b owns the lot-aware movement.

**Why recommend A:** it keeps L1 a narrow partial-posting chokepoint, avoids a lot backfill and lot-level guard in the first milestone, and makes the limitation explicit rather than silently shipping nil lots. The cost is that the first host walkthrough must use a non-lot item. Choose B only if that host must ship lot-tracked SKUs in L1.

**Exact updates if A is chosen:**

- **ADR-056:** mark PF-2 `RATIFIED — Option A`; record Option B as not selected for this build. State that L1b remains deferred work, but its lot scope is now fixed. Keep the ADR `PROPOSED`.
- **`docs/ws-log/design.md` §3.1:** add the L1 lot gate: `Item.lot_tracked` defaults to `false`; a truthy flag refuses the line before any write with `:lot_tracked_requires_l1b`; no `ShipmentLine.lot_id` in L1.
- **`docs/ws-log/design.md` §3.7:** add `Item.lot_tracked` to the existing-resource extensions; state that no `StockLedger` lot column exists until L1b.
- **`docs/ws-log/design.md` §3.2:** in the L1b section, add `ShipmentLine.lot_id`, the lot-aware line unique, lot cost snapshots and lot-level negative-stock behavior.
- **`docs/ws-log/design.md` §4.1:** add the lot-tracked refusal to L1 preflight; keep the non-lot path unchanged.
- **`docs/ws-log/design.md` §4.7:** extend R6/`ReconcileLot` obligations when L1b lands; do not claim lot coverage in the L1 gate.
- **`docs/ws-log/design.md` §9:** record Option A, the first-host limitation, and L1b as a hard prerequisite for L3 returns.
- **`docs/ws-log/build-plan.md` L1.1:** add the `Item.lot_tracked` migration (default `false`; mark existing items with `Lot` rows as lot-tracked). Add no `StockLedger` or `ShipmentLine` lot columns.
- **`docs/ws-log/build-plan.md` L1.4:** add the refusal test and the non-lot positive control.
- **`docs/ws-log/build-plan.md` L1b:** add `StockLedger.lot_id`, `ShipmentLine.lot_id`, lot-aware line uniqueness, lot-level `NegativeStock`, lot cost snapshots, the `ReconcileLot` extension and the `source_key: "lot"` backfill.
- **`docs/ws-log/build-plan.md` L3 and L5:** when those phases are written, add lot identity to `ReturnLine`, `TransferOrder` and `CycleCountLine`; L3 cannot start before the L1b lot gate is proven.

**Migration scope for A:** one `item.lot_tracked` column and its backfill. No lot columns, no ledger backfill and no lot-aware unique index in L1.

### Option B — LOT-AWARE L1

L1 carries lot identity through the movement path before a lot-tracked item can ship.

**Exact updates if B is chosen:**

- **ADR-056:** mark PF-2 `RATIFIED — Option B`; record Option A as not selected. Keep the ADR `PROPOSED`.
- **`docs/ws-log/design.md` §3.1:** add `ShipmentLine.lot_id` (required for lot-tracked items; a lot-tracked SO line may produce one line per lot) and replace the `(shipment_id, so_line_id)` unique with `(shipment_id, so_line_id, lot_id)`, using partial unique indexes for the nil and non-nil cases.
- **`docs/ws-log/design.md` §3.4:** add `ReturnLine.lot_id` so the same lot travels through returns.
- **`docs/ws-log/design.md` §3.5:** add `lot_id` to `StockValueAdjustment` when landed cost is allocated to a lot.
- **`docs/ws-log/design.md` §3.6:** add `CycleCountLine.lot_id`.
- **`docs/ws-log/design.md` §3.7:** add `Item.lot_tracked`, `StockLedger.lot_id` and the `TransferOrder` lot field; state that existing `source_key: "lot"` rows backfill `lot_id = source_id`.
- **`docs/ws-log/design.md` §4.1:** make lot cost and lot-level negative stock part of L1 preflight; add the lot-required refusal for a lot-tracked line with a nil lot.
- **`docs/ws-log/design.md` §4.7:** make R6 sum by line/lot and require `ReconcileLot` to see the shipment decrement.
- **`docs/ws-log/design.md` §9:** record B as the larger L1 scope and the lot backfill risk.
- **`docs/ws-log/build-plan.md` L1.1:** add `Item.lot_tracked`, `StockLedger.lot_id`, `ShipmentLine.lot_id`, the lot-aware unique indexes, the existing-`Lot`-row backfill and the `source_key: "lot"` ledger backfill.
- **`docs/ws-log/build-plan.md` L1.2:** use the lot's own valued-ledger unit cost for lot lines; run the lot-level `NegativeStock` guard; refuse a lot line with no lot before any write.
- **`docs/ws-log/build-plan.md` L1.4:** add lot-required, lot-level negative-stock and `ReconcileLot` tests; R6 must sum by line/lot.
- **`docs/ws-log/build-plan.md` L1b:** keep document completion work; do not repeat the lot work already landed in L1.
- **`docs/ws-log/build-plan.md` L3 and L5:** consume the existing `lot_id` through return, transfer and count documents.

**Migration scope for B:** `item.lot_tracked`, `stock_ledger.lot_id`, `shipment_line.lot_id`, the lot-aware unique indexes and the `source_key: "lot"` backfill. This is the main reason B is a larger L1.

## PF-3 — Cost snapshot, returns, transfers and counts

**Choice.** Ratify the package as written, or amend the cost/GL rules. The package is:

- `ShipmentLine.unit_cost_cents` is frozen at `:ship` from the same item/warehouse moving-average snapshot used for COGS; for a lot line, use the lot's own valued-ledger unit cost in the shipping warehouse. A return line without a snapshot is refused.
- A private internal `ShipmentLine :stamp_cost` action inside `ShipPosting` writes the snapshot; it is the only internal line update in L1, and no user-facing line edit exists.
- Returns use that snapshot, never the current average. The return credit note is issued at `:receive` for accepted quantity/value; `:close` is a state transition only.
- L3 returns are shipment-backed: `ReturnAuthorization.shipment_id` is required and every `ReturnLine` names a `ShipmentLine`.
- Return restock and repair are value-neutral transfer pairs and post no JournalEntry; same-account transfers are value-neutral and post none; a zero-value leg in any flow posts no JournalEntry.
- Return scrap and cycle-count shortages/surpluses use `:write_down_expense`; return receipt posts Dr inventory / Cr `:cogs`; the return credit note uses the existing `:credit` cascade.
- Cycle-count `:post` re-reads live on-hand and refuses a stale `system_qty`; a nil shortage average posts no value leg, and a nil surplus average is refused.
- Missing item inventory accounts or unmapped posting accounts refuse the action before any write.

**Recommendation: ratify.** Keep `:write_down_expense` shared for now. If the operator wants separate shrinkage and scrap accounts, decide that before L3/L5 by widening the closed `PostingAccount` enum; do not ship an unmapped placeholder.

**Exact updates if ratified:**

- **ADR-056:** mark PF-3 `RATIFIED (date)`; keep the ADR `PROPOSED`. Add or confirm the no-entry rule: value-neutral restock/repair/transfer and zero-value legs post no `JournalEntry`. Record the account choice.
- **`docs/ws-log/design.md` §2 D3:** add the value-neutral exception and the zero-value no-entry sentence so D3 matches PF-3.
- **`docs/ws-log/design.md` §3.1:** add `ShipmentLine.unit_cost_cents`, frozen at `:ship`; add the private `:stamp_cost` action as the one internal line-update exception.
- **`docs/ws-log/design.md` §3.4:** make `ReturnAuthorization.shipment_id` required; add the snapshot/credit-note linkage and the return line's shipment-line requirement.
- **`docs/ws-log/design.md` §4.1:** add the cost stamp to `ShipPosting`; state that zero-cost COGS is skipped and no zero-value journal is posted.
- **`docs/ws-log/design.md` §4.2:** set the credit note to `:receive`; add the COGS reversal, shipment-backed return validation, and the no-GL disposition pair for restock/repair; scrap uses `:write_down_expense`.
- **`docs/ws-log/design.md` §4.5:** copy the source cost to both transfer events; state that a same-account transfer is value-neutral and posts no JournalEntry.
- **`docs/ws-log/design.md` §4.6:** add the stale-count re-read/refusal, valued shortage/surplus entries and the nil-average behavior.
- **`docs/ws-log/design.md` §4.7:** add the R7 COGS-reversal/scrap legs and the R9 cost/lot equality checks; include `ReconcileLot` for lot lines.
- **`docs/ws-log/build-plan.md` L1.1:** add `unit_cost_cents` and the private `:stamp_cost` action; preserve the create/read-only rule for every user-facing line action.
- **`docs/ws-log/build-plan.md` L1.2:** stamp the frozen cost at ship; keep the zero-cost COGS skip and the “no zero-value journal” rule.
- **`docs/ws-log/build-plan.md` L1.4:** add frozen-cost, zero-cost, missing-account and no-zero-journal assertions.
- **`docs/ws-log/build-plan.md` L3:** require shipment-backed returns, issue the credit note at `:receive`, add the COGS reversal, use the snapshot for disposition, and keep restock/repair as no-GL transfer pairs.
- **`docs/ws-log/build-plan.md` L5:** add source-cost copying and no-GL behavior to transfers; add stale-count refusal and the valued/nil cycle-count rules.
- **Finance, only if splitting accounts:** widen the `PostingAccount` enum and update the affected L3/L5 account mapping in the same amendment. This is not part of PF-3 ratification otherwise.

## Sequencing

1. **PF-2 first** because it determines L1 schema and whether L1b is a hard prerequisite for L3.
2. **PF-1 independently**; it changes concurrency wording and tests, not schema.
3. **PF-3 now**; its lot-specific rows are L1b work under Option A and L1 work under Option B. PF-3's non-lot rules apply either way.
4. After ratification, update ADR/design/build-plan in one docs pass, then commit/track the result. The ADR remains `PROPOSED`; ratification of PF-1–PF-3 is not ratification of the build.

**Not in scope for this brief:** code, migrations, abbreviation reservations, coverage claims or commits. The current working tree stays uncommitted.
