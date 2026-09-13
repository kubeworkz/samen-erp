# ADR-049 — The ERP base scopes: Finance (event-sourced GL/AP/AR), Inventory (stock
ledger + procurement), Manufacturing (a posting facade over stock), and Hr (employment
ledger) — and the reconciliation spine that binds them to Billing and CRM

- **Status:** Accepted (design; WS-ERP phases E0–E8 implement per `docs/ws-erp/build-plan.md`).
- **Date:** 2026-09-12
- **Context:** the request to build a base ERP covering the seven canonical components
  (Financial Management · HR · SCM · CRM · Inventory/Warehouse · Manufacturing · BI).
  Grounding: the coverage audit in `docs/ws-erp/design.md` §0 — CRM and BI are largely
  served by existing scopes; Finance/Inventory/Manufacturing/Hr are not.
- **Deciders:** the operator (this design authored per the request; component map binding).
- **Consumes:** ADR-004 (scope packaging), ADR-014/024/026 (fail-honest adapters — the
  payroll boundary), ADR-017 (the `mov` ledger — the immutable-event precedent), ADR-002
  (hash-chained audit over the ledger), ADR-040 (approvals/lifecycle substrate), ADR-041
  (canonical work objects + the object-ref anchor shape), WS-B's rollup + reconciliation
  red-path discipline (ADR-018).

## Decisions

1. **Three new universal scopes, one absorbed:** `Samen.Scopes.Finance`,
   `Samen.Scopes.Inventory` (absorbs warehouse + procurement — stock doesn't move without
   a document), `Samen.Scopes.Hr`, and `Samen.Scopes.Manufacturing` (a superset mount over
   Inventory). CRM (C4) and BI (C7) ship as integration phases over existing scopes; the
   sales-order bridge lives INSIDE the Inventory scope (stock's demand document), not a
   seventh scope.
2. **The GL is event-sourced double entry; reports are derived.** Append-only
   `JournalEntry`/`JournalLine`, unbalanced entries refused, posted rows immutable
   (DB-enforced), voids are linked reversing entries. No mutable balance column anywhere;
   every balance/report is a sum or a `Samen.Rollup`. Same discipline as `mov`/consent.
3. **Billing stays untouched; the ERP treats it as a subledger.** `source_ref`
   (the ADR-041 polymorphic anchor) is the only join between documents and postings — the
   ledger names its upstream without coupling to it.
4. **Stock is a ledger too.** Append-only `StockLedger` (signed-integer base-UOM qty,
   moving-average cost snapshot per movement); `StockLevel` is a rollup, never hand-edited;
   negative stock refused by default with per-warehouse opt-out.
5. **Manufacturing is a posting facade over the stock ledger.** WorkOrders bundle
   `:production_consume`/`:production_in` events at BOM-snapshot quantities with a
   rolled-up actual cost — zero new quantity mechanisms, so it can never disagree with
   stock. No scheduling/capacity engine in the base system.
6. **Hr models EMPLOYMENT, not access.** `Employee`🔒 (vault-routed person fields,
   nullable `user_id`), an append-only `EmploymentEvent` ledger (comp history included),
   approvals-engine leave, reviews as Work-scope tasks. **No payroll computation** — a
   `Samen.Hr.PayrollProvider` behaviour with a `{:error, :not_configured}` default; the GL
   records payroll postings, never computes them.
7. **The reconciliation spine (LOAD-BEARING):** every document posts to exactly one ledger;
   R1 GL-balance · R2 Billing↔GL cash · R3 Inventory rollup↔ledger · R4 WorkOrder↔BOM
   consumption · R5 three-way match — each green + red-twin + committed sabotage patch.
8. **The honesty boundary (binding):** payroll, tax engines, multi-currency revaluation,
   lot/serial tracking, shop-floor scheduling, leave accrual, forecasting, depreciation →
   adapter-or-P2/P3 (design §7). An ERP that half-implements payroll is worse than one
   that says `:not_implemented`.

## Consequences

- ~20 new resources + abbrev rows (sanctioned allocator, verifier-enforced); no existing
  scope's schema changes; kernel stays web-free; all surfaces mount at ≈0 vertical LOC.
- Every new scope is archivable + vault-aware from birth and passes the standing verifier
  tiers; Finance/Inventory report modules never read current-state tables directly
  (derived-only), keeping the CDC/aggregate posture intact.
