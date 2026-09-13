# WS-ERP — "The ERP Base System" · Design Spec

- **Status:** Design (buildable). Build phases follow this spec + ADR-049 (this workstream's
  ADR). Each phase is independently committable + gate-able.
- **Date:** 2026-09-12
- **Scope owner:** WS-ERP design (Claude). Design only — no code touched in this pass.
- **Reads:** `docs/saas-gap-roadmap.md` (method + honesty discipline), `docs/ws-b/design.md`
  (the closest workstream shape: read/compute layers over governed data, reconciliation
  red-paths), `docs/adr/ADR-004-scope-packaging.md` (blueprint macro seam), `ADR-040`
  (lifecycle substrate), `ADR-041` (canonical work objects), the live scope tree under
  `samen_core/lib/samen/scopes/`, the live surface tree under `samen_web/lib/samen/web/`.
- **Mission:** a **base ERP system** — the seven canonical ERP components from the request
  (Financial Management · HR · SCM · CRM · Inventory/Warehouse · Manufacturing · BI) — built
  the Samen way: framework-first, ≈0-LOC vertical mounts, every ledger event-sourced and
  reconciling to the cent, every PII surface per-plane masked, every claim green/red/sabotaged.

---

## 0 · Grounding — what Samen already covers (cited, from this pass)

An ERP is not built from zero here; the request's component list maps onto an unusually
large existing estate. What follows is the honest coverage audit that sizes the delta:

| Requested ERP component | Existing Samen substrate | Coverage verdict |
|---|---|---|
| **Financial Management** | `Samen.Scopes.Billing` (customer🔒, subscription, plan, price, invoice, payment, usage, entitlement + the append-only `mov` movement ledger, ADR-017); rich `Samen.Type.Money` (Decimal cents, INV-2); `WS-B` MRR waterfall/NRR/churn; `StatusChange`/`SubscriptionMovement` change seams | **Partial.** Strong on recurring-revenue billing (SaaS-shaped), missing: a **GL chart of accounts**, **AP**, and the **AR bridge** from invoices/receipts into ledger postings. Billing scope stays untouched — the ERP ledger CONSUMES it. |
| **HR / HCM** | `Samen.Scopes.Identity` (org/user/membership/role), `Samen.Scopes.Work` (tasks/projects/owners), automation reminders | **Thin.** An `Employee` is not a `User`: employment records (hire/term dates, comp, leave, reviews) have no home. Membership = *access*, not *employment*. |
| **Supply Chain (SCM)** | `Samen.Scopes.SalesOps.Vendor` (F6) — vendors a tenant buys from, with vaulted contact; Work tasks; Files | **Thin.** A vendor noun exists; **purchase orders** and **receipts** do not. |
| **CRM** | `Samen.Scopes.Crm` (person🔒/company/opportunity + attachment), `Samen.Scopes.SalesOps.Lead` with `:convert`, `ADR-011` CRM enrichment, Marketing (consent ledger), Support desk | **Strong — nearly the whole component.** Sales pipeline = CRM Opportunity (+ Lead conversion); marketing automation = Automation engine + Marketing sequences; support = Desk. ERP adds only the **quote→order bridge** (§3). |
| **Inventory & Warehouse** | `Samen.Scopes.Locations` (T47 — object-ref location anchor), Files, CSV import/export | **Thin.** Locations = labels for other objects, not **stock**. No item master, no stock ledger, no valuation. |
| **Manufacturing** | Nothing (no BOM, no work order, no routing anywhere in the tree) | **Absent.** This is the largest genuinely new scope. |
| **BI & Analytics** | Token-blind aggregate + k-anon floors (`Samen.Aggregate`, `min_cohort=5`, l-div=2), `Samen.Rollup` + `RollupRefreshWorker` (ADR-007 + the `:source` generalization, ADR-018), CDC default-deny projection, WS-B operator cockpit, HealthScore, pae product events, Catalog (machine-readable schema dictionary) | **Strong.** The BI component is mostly an *application* of existing floors: every ERP rollup rides `Samen.Rollup`, every cross-tenant view rides the aggregate actor. **No new BI mechanism is built in WS-ERP.** |

**The honest shape:** three components are largely *integration* work (CRM, BI, and half of
Finance), three need new kernel scopes (GL/AP/AR core, Inventory+SCM, Manufacturing), and
one (HR) is a modest scope on top of Identity. That is the same leverage pattern pawchart
proved for surfaces — but at the *data-model* level, which is why the two new scopes below
carry most of the weight.

---

## 1 · The component map (binding)

| # | ERP component | Ships as | New resources | Mostly reuses |
|---|---|---|---|---|
| C1 | Financial Mgmt | **`Samen.Scopes.Finance`** (new kernel scope) | `Account` (CoA), `JournalEntry` + `JournalLine`, `Budget`, `BudgetLine`, `ApInvoice` (AP), `PaymentReceipt` (AR) | Billing Invoice/Payment, Money type, mov ledger precedent, Lifecycle substrate |
| C2 | HR / HCM | **`Samen.Scopes.Hr`** (new kernel scope) | `Employee` 🔒, `EmploymentEvent` (append-only ledger), `LeaveRequest`, `ReviewCycle` | Identity Membership, Work tasks, automation reminders, approvals engine (ADR-040) |
| C3 | SCM | **`Samen.Scopes.Inventory`** (new kernel scope, with SalesOps consuming it) | `Item` (item master), `StockLedger` (append-only), `Warehouse`, `StockLevel` (rollup), `PurchaseOrder` + `PoLine`, `GoodsReceipt` | SalesOps.Vendor, Locations, Files, approvals |
| C4 | CRM | (no new scope) | — | Crm, SalesOps, Marketing, Support, Automation; + the §3 quote/order bridge |
| C5 | Inventory ops | (the operational face of C3's scope) | — | StockLevel rollup, CSV import/export, masked rendering |
| C6 | Manufacturing | **`Samen.Scopes.Manufacturing`** (new kernel scope) | `Bom` + `BomLine`, `WorkOrder`, `ProductionLog` (append-only) | Inventory StockLedger (consumption/completion postings), Work tasks, pae events |
| C7 | BI & Analytics | (no new scope) | rollup tables (raw, `rol`-precedent) | Rollup specs + refresh worker, Aggregate floors, operator plane, Catalog |

**Scope-count decision:** THREE new universal scopes (`Finance`, `Hr`, `Inventory`),
ONE more (`Manufacturing`), plus integration phases. `Inventory` deliberately ABSORBS the
warehouse + procurement half of SCM (warehouse/stock/PO/receipt are one domain — stock
doesn't move without a document to authorize it), keeping SCM = Inventory + Vendor +
PurchaseOrder rather than two overlapping scopes. A host wanting "SCM without Manufacturing"
mounts `Inventory`; `Manufacturing` is a strict superset mount.

---

## 2 · C1 — `Samen.Scopes.Finance` (the ledger is the product)

### 2.1 The load-bearing decision — event-sourced double entry, report = derived (ADR-049 §3)

Every money movement is an **append-only `JournalEntry`** carrying balanced `JournalLine`s
(sum of debits = sum of credits, refused otherwise — `Samen.Scopes.Finance.UnbalancedEntry`).
There is NO mutable "balance" column anywhere: every balance is the SUM of its account's
lines, and every financial report (TB, BS, IS, budget-vs-actual) is a **derived read or a
`Samen.Rollup`** over the ledger. This is the same discipline as the `mov` ledger
(WS-B/ADR-017) and the consent ledger (F3b): **immutable events, derived state.**

- **`Account`** — the chart of accounts (Tier-0 config row, malleability-ladder bottom
  rung): `code` (unique per org), `name`, `kind ∈ {asset, liability, equity, income,
  expense}`, `normal_side ∈ {:debit, :credit}`, `parent_id` (self-referential CoA tree,
  `CycleGuard` per ADR-041 §3.4 precedent), `currency` (bounded, defaults host currency;
  **multi-currency is a documented P2 carry** — G24-adjacent), `archivable`.
- **`JournalEntry`** — `entry_date`, `memo` (freeform → default-deny CDC), `status ∈
  {:draft, :posted, :void}`, `source_ref` (polymorphic `(source_key, source_id)` anchor —
  the ADR-041 §3.2 object-ref shape, NOT an FK into Billing: the ledger must exist before
  and independent of what feeds it), `posted_at`, `voided_entry_id`.
- **`JournalLine`** — `entry_id`, `account_id`, `debit_cents`/`credit_cents` (Money-typed
  integers, exactly one non-zero), `dimension_refs` (jsonb bounded dimensions — dept /
  project / item, the ERP analytics join keys), `memo`.
- **Posting discipline:** a `:draft` entry can be edited; `:post` is a governed action that
  freezes the entry (no update action exists on posted rows — DB trigger + Ash policy
  refuse), and `:void` posts a *reversing* entry linked back (`voided_entry_id`) — nothing
  is ever destroyed or rewritten. This is the audit posture the hash-chained audit log
  (ADR-002) already gives us for free on top.
- **`Budget` / `BudgetLine`** — per-account, per-period planned amounts (Tier-0 config
  rows); budget-vs-actual = a pure function over rollup vs BudgetLine. No approvals
  machinery of its own — variance alerts ride the Automation engine.

### 2.2 AP and AR — documents that POST, not ledgers of their own

- **`ApInvoice`** (accounts payable) — a vendor bill: `vendor_id` (→ SalesOps.Vendor),
  `number`, `dates`, `lines` (embedded jsonb lines with account_id + amount — AP bills are
  low-volume, one-row-per-line is a P2 promote-if-hot carry), `status ∈ {:draft, :approved,
  :paid, :void}`. `:approve` rides the **ADR-040 approvals engine** (requester ≠ approver).
  On approval → posts the expense+liability journal entry (`source_key: "ap_invoice"`).
- **`PaymentReceipt`** (AR) — money actually received against a Billing Invoice (the
  SaaS-shaped billing scope remains the AR document SoT): allocates amount(s) to invoice(s),
  posts the cash+AR-clearing entry (`source_key: "billing_payment"`).
- **The AR bridge (the one non-obvious integration):** Billing.Invoice stays exactly as it
  is. `PaymentReceipt` + a periodic **revenue-recognition posting** (`Invoice` → income/AR)
  are what bind SaaS billing into the GL. Samen's billing is provider-mirror-shaped; the
  ERP treats it as a **subledger** that feeds postings, the same way Stripe invoices feed a
  real GL. `source_ref` is the join key — the ledger names its upstream without coupling to
  it.

### 2.3 PII map — empty by construction (INV-1)

Accounts, entries, lines, budgets, AP bills carry **no vault-routed field**: every column is
a bounded id/enum/integer/timestamp/jsonb-of-bounded. Freeform `memo` fields are
default-deny-CDC-excluded freeform (Work-scope parity). A vendor's 🔒 contact stays vaulted
WHERE IT LIVES (SalesOps.Vendor) — Finance references `vendor_id`, never re-declares the
person. AP bills are business records, not subject records.

---

## 3 · C3+C5 — `Samen.Scopes.Inventory` (stock is a ledger too)

### 3.1 The same event-sourcing discipline, applied to quantity

- **`Item`** — the item master (Tier-0): `sku` (unique per org), `name`, `kind ∈ {:stocked,
  :non_stocked, :service}`, `uom` (bounded enum: unit/case/kg/hour), `unit_cost` (Money,
  moving-average carried by the ledger), `reorder_point` (a floor, not an engine —
  replenishment suggestions are a pure read; auto-PO generation is a P2 carry),
  `default_income_account_id` / `default_expense_account_id` / `default_inventory_account_id`
  (the Finance integration seam — optional FKs; an unlinked item simply never posts).
- **`Warehouse`** — a stock location with real quantity semantics: `code`, `name`,
  `address` (the existing `Samen.Type.Address` composite; `pii_address` vault class per the
  rich-types table — a warehouse address is a place, but the vault class exists so hosts
  that treat locations as sensitive keep the posture), `is_sellable`.
- **`StockLedger`** (abbrev `stk`) — THE append-only movement event: `item_id`, `warehouse_id`,
  `kind ∈ {:receipt, :issue, :transfer_out, :transfer_in, :adjust, :sale, :production_in,
  :production_consume}`, `qty` (signed integer in the item's UOM — integer base-UOM is the
  binding decision; fractional UOM is a documented non-goal), `unit_cost_cents` (snapshot
  at movement time — moving-average cost basis), `ref` (polymorphic `(source_key,
  source_id)`: goods receipt / PO / work order / sales order / manual adjust), `note`.
  **No `stock_level` column is ever updated by hand** — `StockLevel` is a ROLLUP
  (`(org_id, item_id, warehouse_id)` → `sum(qty)`, valued at moving average), rebuilt by the
  `RollupRefreshWorker` and read by every surface. Real-time stock = ledger event + rollup
  freshness, the exact pattern the MRR waterfall proved.
- **Negative-stock guard:** a posting that would take `(item, warehouse)` below zero is
  REFUSED (`Samen.Scopes.Inventory.NegativeStock`) — with an explicit `:allow_negative`
  per-warehouse opt-out for cycle-count realities. Fail-closed default.

### 3.2 Procurement — PurchaseOrder + GoodsReceipt (the SCM document pair)

- **`PurchaseOrder` / `PoLine`** — `vendor_id` (→ SalesOps.Vendor), `status ∈ {:draft,
  :approved, :sent, :received, :closed, :void}`, lines carry `item_id`, `qty`, `unit_cost`.
  `:approve` rides the ADR-040 approvals engine. A PO posts NOTHING (committed-not-realized)
  until goods arrive.
- **`GoodsReceipt`** — receiving against a PO line: creates the `StockLedger :receipt`
  event (qty in, cost = PO line cost) AND posts the inventory-asset + AP-clearing journal
  entry (`source_key: "goods_receipt"`). This is the Finance↔Inventory chokepoint where the
  two scopes meet, and it must be ONE transaction: stock event + journal entry commit or
  roll back together (tested as the reconciliation red-path).
- **Three-way match (P1, phase I4):** PO qty → GoodsReceipt qty → AP invoice amount
  consistency check surfaced on the AP bill (variance flag, not a hard block — documented
  tolerance config).

### 3.3 The quote→order→invoice bridge (C4's ERP delta)

CRM Opportunity stays the pipeline SoT. The bridge is `source_ref`-anchored: a **Sales
Order** is NOT a new scope — an ERP sales order is a CRM-adjacent document that (a)
reserves/consumes stock via `StockLedger :sale` on fulfillment and (b) emits a Billing
Invoice on delivery. WS-ERP ships it as a **minimal `SalesOrder` + `SoLine` pair inside the
Inventory scope** (it is stock's demand document; scope-independence beats conceptual
purity), posting on fulfillment and invoicing through the existing Billing surface. Lead →
Opportunity → SalesOrder → Invoice → PaymentReceipt → GL is then ONE governed chain where
every link already has a home.

---

## 4 · C6 — `Samen.Scopes.Manufacturing` (built ON Inventory, not beside it)

- **`Bom` / `BomLine`** — the bill of materials: a `Bom` for an Item (versioned via
  `version` int + `is_active`; **no BOM revision history engine — P2 carry**), lines carry
  `component_item_id`, `qty_per`, `scrap_pct`. Cycle refusal: a BOM whose expansion contains
  its own item is REFUSED at save (`Samen.Scopes.Manufacturing.BomCycle`, same
  CycleGuard lineage as Work.Subtask and Finance CoA).
- **`WorkOrder`** — `item_id`, `bom_id` (snapshot-frozen at release: WIP never re-prices
  when a BOM changes), `qty`, `status ∈ {:draft, :released, :in_progress, :completed,
  :cancelled}`, `warehouse_id` (the completion sink), `scheduled_for`.
- **`ProductionLog`** (append-only) — material consumption (`:production_consume` StockLedger
  events per BOM line) and completion (`:production_in` of the finished item at the rolled-up
  actual cost: Σ component consumption cost + labor/overhead lines carried as Money
  adjustments). **Manufacturing is thus a posting facade over the Inventory ledger** —
  zero new quantity mechanisms; a work order is just a bundle of StockLedger events with a
  cost roll-up. That is what makes it a *base* system: it can never disagree with stock.
- Shop-floor scheduling/capacity: OUT OF SCOPE for the base system (documented non-goal,
  P3). WorkOrder `scheduled_for` + Work-scope tasks cover the base need.

---

## 5 · C2 — `Samen.Scopes.Hr` (employment ≠ access)

- **`Employee`** — 🔒: `employee_number` (bounded, unique per org), `full_name`
  (`Samen.Type.FullName`, `:pii_name`), `work_emails`/`work_phones`
  (`:pii_email`/`:pii_phone`), `dob` optional (`pii_dob` class per rich-types), `hired_at`,
  `terminated_at` (nullable), `employment_type ∈ {:full_time, :part_time, :contract,
  :intern}`, `manager_id` (self-ref, CycleGuard), `user_id` (nullable FK → Identity.User —
  employment may exist without a login; a login without employment is fine too), `archivable`.
  **Compensation is NOT a free column** — it lives on `EmploymentEvent` (below), because
  comp history is exactly the kind of data that must be ledgered, not overwritten.
- **`EmploymentEvent`** (append-only ledger, `emp` abbrev) — `kind ∈ {:hired, :comp_changed,
  :promoted, :transferred, :on_leave, :returned, :terminated}`, `effective_at`, `payload`
  (jsonb of bounded fields; comp amounts are Money, never freeform), `note`. HR "current
  state" = latest event per employee (derived), mirroring `Consent.state/3` latest-event-wins.
- **`LeaveRequest`** — `employee_id`, `kind ∈ {:vacation, :sick, :unpaid, :other}`,
  `start_date`/`end_date`, `status ∈ {:pending, :approved, :rejected, :cancelled}`;
  `:approve` rides the ADR-040 approvals engine + Automation reminders. Balance tracking:
  derived from events; a full accrual engine is a P2 carry (documented).
- **`ReviewCycle`** — `name`, `period_start`/`period_end`, `status`; a review = a Work-scope
  Task with an object-ref anchor to the Employee (ADR-041 §3.2 shape). **No new review
  resource** — reuse the canonical work objects, per ADR-041's own thesis.
- **Payroll: fail-honest by construction.** WS-ERP ships NO payroll calculation engine —
  tax/withholding is jurisdiction-specific and half-claimed payroll is the worst kind of
  lie. `EmploymentEvent :comp_changed` carries the comp facts; an **adapter boundary**
  (`Samen.Hr.PayrollProvider` behaviour, ADR-014/024/026 shape) is DECLARED with a
  `{:error, :not_configured}` default implementation, so a host brings a payroll provider
  (or journals comp expense through Finance manually). The Journals (GL) DO record payroll
  *postings*; they never *compute* them.
- **PII posture:** Employee is the scope's only 🔒 resource; per-plane masking tests are
  MANDATORY (watch-list discipline) on every HR surface + the HR CSV export
  (mask-by-omission red-path per the WS-E discipline). Erasure: a former employee's vaulted
  fields crypto-shred through the standard subject path; the EmploymentEvent ledger survives
  (bounded, non-PII) — employment facts outlive the person's PII, exactly like consent
  events.

---

## 6 · C4 + C7 — the integration components (build NOTHING, wire EVERYTHING)

### 6.1 CRM (C4) — already ≈complete

Pipeline = Opportunity (+ Lead `:convert`); marketing automation = Automation engine +
Marketing sequences; support = Desk. WS-ERP's only CRM surface work is the §3.3 sales-order
chain. No CRM code is touched.

### 6.2 BI (C7) — rollups + floors, never a new mechanism

ERP analytics = `Samen.Rollup` specs (GL trial balance, stock levels, MRR-vs-budget, WIP,
HR headcount) refreshed by the existing `RollupRefreshWorker` cron; every cross-tenant /
portfolio view routes through the `operator_aggregate` actor + `aggregate_cohort_spec/0`
(k-anon min-5, l-div-2 — a department, product line, or warehouse cohort under floor renders
`%Suppressed{}`). Forecasts: OUT OF SCOPE for the base system (same call WS-B made on
revenue forecasting — documented non-goal, P3).

### 6.3 The cross-scope invariant (the ERP spine, LOAD-BEARING)

**Every document that moves money or stock POSTS to exactly one ledger, and every ledger
reconciles to its subledgers.** Concretely, the reconciliation red-path suite (the
workstream's non-negotiable gate):

- **R1 (GL balance):** Σ debits = Σ credits, per entry AND org-wide, always. Sabotage:
  accept an unbalanced entry → refused.
- **R2 (Finance↔Billing):** for any period, Σ(`PaymentReceipt` cash) == Σ(Billing Payment
  mirror amounts) — the MRR-reconciliation red-path (WS-B §1.5) restated at the GL level.
- **R3 (Inventory↔Ledger):** `(item, warehouse)` rollup qty == Σ StockLedger qty, and the
  moving-average value == Σ valued events. Sabotage: a posting that skips the ledger
  event (or the journal entry) → divergence → FAIL.
- **R4 (Manufacturing↔Inventory):** a completed WorkOrder's component consumption exists
  in the ledger at the BOM quantities; finished-goods receipt carries the rolled-up cost.
- **R5 (three-way match):** AP bill ≤ PO + GR at tolerance, flagged otherwise.

Each R is a green test + a red-path twin + a committed sabotage patch, exactly the
WS-B/B2 reconciliation discipline.

---

## 7 · What is deliberately OUT of scope for the base system (the honesty list)

1. **Payroll computation** (§5 adapter boundary instead) — worst half-claim risk in ERP.
2. **Tax engines / VAT filing** — rates/rules are jurisdictional; GL handles tax accounts,
   calculation is an adapter/P3.
3. **Multi-currency revaluation, FX gain/loss** — single-currency base; `Account.currency`
   field exists so the schema doesn't lie, revaluation is P2.
4. **Fractional/serial/lot inventory** (integer base-UOM binding decision) — lot/serial
   tracking (recall traceability) is P2.
5. **Shop-floor scheduling / capacity planning / MES** — P3.
6. **BOM revision history engine** — versioned-active-row only; full engineering-change
   control is P2.
7. **Leave accrual engine** — derived balances only; accrual rules P2.
8. **Revenue forecasting** — P3 (WS-B parity).
9. **Fixed-asset depreciation schedules** — CoA + manual journal entries cover the base;
   an asset register with depreciation runs is P2.

Each is an honest boundary with an adapter or P2/P3 path, per the fail-honest house rule —
an ERP that half-implements payroll or tax is worse than one that says `:not_implemented`.

---

## 8 · Mounting shape (the ≈0-LOC inheritance proof)

Every new scope follows ADR-004 exactly (`use Samen.Scopes.Finance` inside a host domain →
host-namespace resources, host abbrevs via the sanctioned allocator). The web surfaces
(GL/CoA browser, AP inbox, stock levels, PO receive, work orders, HR roster) are
`samen_web` mountables declared in `samen_tenants_routes`/`samen_operator_routes` so a
vertical adopts the ERP with scope mounts + router lines, and the **ERP host**
(`samenerp`, gen.app-emitted with `--modules` additions) proves the whole fleet mounts.
Cross-scope FKs (PO→Vendor, Receipt→PO, WorkOrder→Item) follow the SalesOps precedent:
compile-time module parameters passed at mount, never runtime coupling between scope
files.

---

## 9 · Risks & carries

- **Ledger breadth creep.** The GL can absorb anything (payroll, tax, assets). The §7
  honesty list is the dam: every "just also compute X" gets routed to an adapter or the
  P2/P3 list, never into the base scopes.
- **Integer-UOM regret.** Bounded now, documented; converting to fractional quantities
  later is a migration, not a redesign (signed-integer qty column, UOM enum).
- **Rollup freshness.** Derived reads go stale between cron ticks (10 min). The base system
  documents read-your-writes exceptions (StockLevel check runs ledger-sum live at
  receive/post time inside the transaction; the rollup serves the UI).
- **Abbrev budget.** ~20 new resources ≈ 20 registry rows — reserved via the sanctioned
  allocator per host, verifier-enforced, nothing hand-edited.
