# WS-ERP — "The ERP Base System" · Build Plan

- **Status:** Buildable. Follows `docs/ws-erp/design.md` + ADR-049 (write the ADR as
  phase E0's deliverable — this plan is the ADR's build half).
- **Date:** 2026-09-12
- **Sizing principle:** SMALL serialized workflow units — each unit banks in ~10–20 min and
  each PHASE is independently committable + gate-able (WS-B convention). Default fan-out
  concurrency 1. The reconciliation red-path suite (design §6.3, R1–R5) is the standing
  gate target: each ledger ships with its R-test + red twin + committed sabotage patch.
- **Gate cadence:** adversarial phase-gate after each phase; workstream-wide re-gate at E8.

---

## Dependency graph (phases)

```
E0 (ADR + scope scaffolds skeleton) ──> E1 (Finance ledger core: Account/Entry/Line + R1)
E1 ──> E2 (AP + AR documents + posting actions + R2, R5-part)
E1 ──> E3 (Inventory: Item/Warehouse/StockLedger + rollup + R3)   [parallel with E2]
E2+E3 ──> E4 (Procurement: PO/GoodsReceipt — the Finance↔Inventory chokepoint + R3 full)
E3 ──> E5 (SalesOrder bridge → Billing; R5-part)
E4+E5 ──> E6 (Manufacturing: Bom/WorkOrder/ProductionLog over the StockLedger + R4)
E1 ──> E7 (HR scope + approvals + payroll adapter boundary)        [parallel with E4–E6]
E6+E7 ──> E8 (Budget/report reads, BI rollups, surfaces, ERP host inheritance proof, gate)
```

E2 ∥ E3 ∥ E7 are independent after E1. E4–E6 serialize on the StockLedger. E8 gates all.

---

## Phase E0 — ADR-049 + scope skeletons · default
Write `docs/adr/ADR-049-erp-base-scopes.md` (design §1–§9 condensed, each §-decision as a
numbered ADR decision). Scaffold nothing else — scope blueprints land with their phases.
**Gate:** doc-only; claim-sweep clean; no abbrev rows touched (the allocator runs per-phase
with each scope's first mount).

## Phase E1 — Finance ledger core (C1 core) · opus
`Samen.Scopes.Finance` blueprint: `Account` (CoA tree + CycleGuard), `JournalEntry`
(draft/posted/void), `JournalLine` (debit/credit exactly-one-nonzero), the `:post` freeze
+ `:void` reversing-entry actions. **R1 red-path suite + sabotage patch.** Abbrevs via
allocator. Verifiers green (`no_pii_columns`, `sink_schema`, `prefixes`, `catalog_parity`).
**AC:** R1 green+red+sabotage; posted rows immutable (DB-level, red-proven).

**Implementation (2026-09-13):** lib (`lib/samen/scopes/finance/`: blueprint + 8 guard/read
modules), fixture (`test/support/finance_fixture.ex`, abbrevs `sac`/`sje`/`sjl`), migration
belt (`priv/test_repo/migrations/20260912100000_finance_scope_fixture.exs`), suite
(`test/finance_scope_test.exs`, c1–c11 incl. the c8 anti-tautology), sabotage
`scripts/sabotages/302-e1-r1-unbalanced-entry-refusal-bypass.patch` (auto-discovered,
MUST_FAIL anchors match the suite's test names, forward-applies onto the final files).
Verification on the Elixir box — in order:

```bash
cd samen_core
# 1. Sanctioned abbrev reservation (the registry is allocator-only; NEVER hand-edit):
mix samen.abbrev.reserve --host samen_core \
  --owner SamenCore.Support.FinanceFixture.Account --abbrev sac
mix samen.abbrev.reserve --host samen_core \
  --owner SamenCore.Support.FinanceFixture.JournalEntry --abbrev sje
mix samen.abbrev.reserve --host samen_core \
  --owner SamenCore.Support.FinanceFixture.JournalLine --abbrev sjl
# 2. First compile runs the migration; the test DB is dropped+migrated by test_helper.
mix deps.get && mix compile --warnings-as-errors
mix test --warnings-as-errors
# 3. Gate + sabotage harness (302 flips the two R1 RED paths, then reverts):
mix ecto.migrate && mix samen.verify
MIX_ENV=test bash ci.sh
```

## Phase E2 — AP + AR documents (C1 documents) · opus
`ApInvoice` (+ADR-040 `:approve`), `PaymentReceipt`, posting actions → journal entries via
`source_ref` anchors; the Billing→GL revenue-recognition posting seam. **R2 red-path +
sabotage** (receipts reconcile to the Billing Payment mirror per period). Three-way-match
read helper stubs (R5 completes in E4). Masking: AP list shows vendor contact only through
the SalesOps vault row — a mask-by-omission red-path on the AP surface.

## Phase E3 — Inventory core (C3 stock half) · opus
`Item`, `Warehouse` (Address type), append-only `StockLedger` (signed-integer qty,
moving-average unit_cost snapshot), `StockLevel` rollup spec (design §3.1), the
NegativeStock guard (+ per-warehouse opt-out red-path). **R3-ledger half: rollup ==
Σ ledger, value == Σ valued events; sabotage = a hand-edit path that bypasses the ledger.**
Parallel-safe with E2.

## Phase E4 — Procurement (C3 SCM half) · opus
`PurchaseOrder`/`PoLine` (+approvals), `GoodsReceipt` — the ONE-transaction chokepoint:
stock event + journal entry commit/roll back together. **R3-full + R5 red-paths + sabotage**
(a receipt that posts stock but not the journal → divergence → FAIL). Receiving UI mounts.

## Phase E5 — Sales order bridge (C4 delta) · default
`SalesOrder`/`SoLine` in the Inventory scope (design §3.3): stock `:sale` consumption on
fulfillment, Billing Invoice emission, `PaymentReceipt` intake; Lead→Opportunity→SO→Invoice
→Receipt→GL documented as the governed chain (a walkthrough test, not new machinery).

## Phase E6 — Manufacturing (C6) · opus
`Bom`/`BomLine` (+BomCycle refusal), `WorkOrder` (BOM snapshot-frozen at release),
`ProductionLog` append-only over StockLedger `:production_consume`/`:production_in` with
the cost roll-up. **R4 red-path + sabotage** (a completion whose consumption doesn't match
BOM×qty → FAIL). No scheduling engine (design §7).

## Phase E7 — HR (C2) · default (opus reviews masking)
`Samen.Scopes.Hr`: `Employee`🔒 (FullName/Emails/Phones + `user_id` nullable),
`EmploymentEvent` ledger, `LeaveRequest` (+approvals + Automation reminders), ReviewCycle =
Work tasks with employee object-ref anchor. `Samen.Hr.PayrollProvider` behaviour +
`{:error, :not_configured}` default (fail-honest, ADR-014 shape) + a declared-not-built
test. **Masking watch-list trio on the roster surface + HR CSV export** (mask-by-omission
red-path mandatory, WS-E discipline). Parallel-safe with E4–E6.

## Phase E8 — Reports, BI, surfaces, host proof, workstream gate · mixed
Budget/BudgetLine + budget-vs-actual pure read; rollup registrations (TB, WIP, headcount)
on the existing Rollup/refresh machinery; cross-tenant views ride `operator_aggregate` +
CohortSpec floors (a <5 cohort renders `%Suppressed{}` — red-proven); mountable tenant
surfaces (CoA/entries, AP inbox, stock, PO receive, work orders, HR roster) declared in the
router macros; the `samenerp` host mounts all scopes + surfaces at ≈0 authored LOC
(pawchart-shaped proof); README/claim-evidence/roadmap updates. **Workstream-wide
adversarial re-gate:** R1–R5 re-flipped from the sabotage harness, masking trios re-run,
root `./ci.sh` ends `ROOT CI: ALL PASSED`.

---

## Standing carries (do not lose)
- Design §7 honesty list is binding: payroll/tax/multi-currency/lots/scheduling/accruals/
  forecasting/depreciation are adapter-or-P2/P3 — every "just also compute X" gets refused
  into that list.
- E5's SalesOrder lives in the Inventory scope by decision (design §3.3); do not grow a
  seventh scope for it.
- Rollup freshness: StockLevel check at post time is in-transaction live-sum; the rollup
  serves reads (design §9) — document, don't fake real-time.
