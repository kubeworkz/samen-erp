# WS-ACCT — the Kubeworkz books · Design Spec

**A fabless semiconductor accounting workstream: opening a real set of accounting books for
Kubeworkz in samenerp, from the outline in `docs/chip_manufacturing_accounting_setup.md`.**

- **Status:** Design (proposed, not built). Build phases follow this spec + **ADR-054** (phase 0's
  deliverable — this plan is the ADR's build half).
- **Date:** 2026-10-27
- **Source request:** `docs/chip_manufacturing_accounting_setup.md` — 6,168 lines, 18 workbooks
  (business model + COA · fab manifest · project/chip overview · JE playbook JE-001…JE-081 ·
  variance playbook · rolling forecast · board-ready summary · grant compliance · monthly close
  checklist · grant application tracker · foundry scorecard · grant budget-vs-actual · supplier
  risk matrix · multi-source qualification roadmap · supplier onboarding).
- **Reads:** ADR-049 (the ERP base scopes — the estate this extends), `docs/ws-erp/design.md`
  (§0's coverage-audit method, §6.3's reconciliation spine, §7's honesty list),
  `docs/ws-erp/build-plan.md`, ADR-004 (scope packaging), ADR-014/024/026 (fail-honest adapters),
  ADR-018 (rollups), ADR-023 (the abbrev allocator), ADR-040 (the approvals Gate), ADR-041
  (canonical work objects + the object-ref anchor), ADR-002 (the hash-chained audit over a
  ledger), the live scope tree under `samen_core/lib/samen/scopes/` and surface tree under
  `samen_web/lib/samen/web/`.
- **Mission:** the doc is not a feature request for an ERP — it is the **accounting policy and
  procedure manual** for one specific company. Kubeworkz is fabless, so its books are
  subcontracting + WIP-at-supplier + lot yield + standard-cost variance + restricted grant funds.
  WS-ACCT's job is to make those policies *executable* in samenerp: the COA opened, the JE
  playbook posting, WIP real by lot, variances computed and disposed, grants tracked against
  allowable costs, the close gated by period, and the board pack derived from the ledger — by
  **extending the E1–E12 estate, never by re-implementing it.**

**One sentence of scope discipline:** everything in this workstream is either *data* (the COA,
the posting map, the standard cost cards, the drivers) or *a bounded extension of an existing
ledger* (a dimension seam, a period, a schedule, a lot, a variance) — nothing is a second
ledger, a second quantity mechanism, or a second reporting engine.

---

## §0 Grounding — the estate audit

Method: same as WS-ERP §0 — cite what is actually on disk, not what the workstream docs claim.
**The workstream docs are stale:** `docs/ws-erp/build-plan.md` ends at E8 and says DONE, but the
tree carries phases through **E38**. Grounding therefore reads the code, not the plan.

### 0.1 What is real and mounted (verified against the tree)

| Scope | Resources (`use Samen.Scopes.X` → host namespace) | Mounted in samenerp? |
|---|---|---|
| **Finance** (`finance.ex`, `finance/blueprint.ex`, `finance/budget_blueprint.ex`, `finance/credit_note_blueprint.ex`) | `Account`, `JournalEntry`, `JournalLine`, `ApInvoice`, `PaymentReceipt`, `PostingAccount`, `Budget`, `BudgetLine`, `ExchangeRate`, `OrgFxSettings`, `CreditNote`, `VendorCredit`, `TaxRate` | ✅ |
| **Inventory** (`inventory.ex`, `inventory/blueprint.ex`, `inventory/blueprint_e6.ex`) | `Item`, `Warehouse`, `StockLedger`, `StockLevel`, `PurchaseOrder`, `PoLine`, `GoodsReceipt`, `ReceiptLine`, `SalesOrder`, `SoLine`, `Bom`, `BomLine`, `WorkOrder`, `ProductionLog`, `TransferOrder`, `LandedCost` | ✅ |
| **Banking** (`banking.ex`) | `BankAccount`, `StatementLine`, `StatementImport`, `Match`, `Rule` | ✅ |
| **Hr** (`hr.ex`) | `Employee`🔒, `EmploymentEvent`, `LeaveRequest`, `LeaveType`, `LeaveBalance`, `PayRun`, `Payslip`, `SalaryStructure` | ❌ **not mounted** |
| **Billing** | customer🔒/subscription/plan/price/invoice/payment/usage/entitlement + the `mov` ledger | ✅ |
| **Work** | tasks/projects/owners (**no timesheets** — see §0.2) | ✅ |
| Substrate | `Samen.Approvals` (ADR-040 Gate: `gate.ex`/`registry.ex`/`handler.ex`) — real, and Finance's `:approve` already rides it | ✅ |

Finance reports already shipped: `TrialBalance`, `BalanceSheet`, `ProfitLoss`, `BudgetVsActual`,
`Reconcile`, `ReconcilePayments`; FX: `FxConvert` + guard. The finance guards are real code
(`UnbalancedEntry`, `PostGuard`, `PostBalance`, `VoidGuard`, `CycleGuard`, `LineAmounts`,
`EntryLines`, `PostingMarker`). The E8 surfaces are a **closed six-surface registry**
(`Samen.Web.Erp` → `:coa | :entries | :ap_invoices | :stock | :purchase_orders | :work_orders`)
served by one generic LiveView and mounted by one router line.

### 0.2 The trap: E13–E38 are mostly dormant shelf-ware

`samen_core/lib/samen/scopes/` contains directories for `consolidation`, `expenses`, `quality`,
`planning`, `pos`, `ecommerce`, `elearning`, `appointments`, `documents`, `iot`,
`custom_fields`, `survey`, `livechat`, `social`, `dataclean`, `community`, `esign`,
`email_marketing`, `sms_marketing`, `social_marketing`, `marketing_automation`, `approvals` —
tagged `WS-ERP E13…E38`. **They are not scopes.** Verified:

- **No scope macro** for any of them (`grep -l "defmodule Samen.Scopes.Consolidation"` → none, and
  there is no `scopes/consolidation.ex`); **no blueprint** for any of them;
- **referenced by nothing** — no domain, no host mount, no test;
- `scopes/approvals/{request,rule,step}.ex` (E35) is a *duplicate* of the kernel
  `Samen.Approvals` substrate, which is what Finance actually uses;
- `scopes/work/timesheet_{entry,guard,summary}.ex` (E15) is **not wired into the Work scope**
  (`work.ex` and `work/blueprint.ex` never mention it).

**Ruling (binding on this plan):** dormant sets are **not reusables**. If WS-ACCT wants the
doc's multi-entity consolidation, expense reports, supplier quality or timesheets, that is
*wiring* work (scope macro + blueprint + migration + mount + tests per ADR-004), costed as such —
not a reuse. Where a dormant set is *close* to a doc need, the plan says so and prices the wiring
(§1 D13, D14). The separate hygiene question — whether ~26 dormant module sets should be deleted
or completed — was raised as a carry (§7) and is now **answered: DELETE** (ADR-055), which also
establishes that the frontier is per **module**, not per directory or phase range (E13/E14 are live;
E11 and E15 are not).

### 0.3 The chart of accounts is DATA, not code

The doc's COA (codes `1000`–`8000`, §"Chart of Accounts Reference") maps **1:1** onto the
existing `Account` resource: `code` (unique per org), `name`, `kind ∈ {asset,liability,equity,
income,expense}`, `normal_side ∈ {:debit,:credit}`, `parent_id` (self-referential tree,
`CycleGuard`-protected). The doc's contra account `1510 · Accumulated Amortization – PDK License`
is an asset-kind row with `normal_side: :credit` — expressible with no schema change.

**Consequence:** *opening the books is a seed, not a feature* (`Account` rows + `PostingAccount`
rows + `Budget`/`BudgetLine`). What is **code** is the *posting map*: `PostingAccount.key` is a
closed `one_of: [:ap_clearing, :ar_clearing, :cash, :income]` — **four meanings**, where the
doc's flows need roughly two dozen (§1 D2).

### 0.4 The keystone gap: the GL has no cost-object seam

`JournalLine` carries exactly `debit_cents`, `credit_cents`, `memo`, and `belongs_to :entry` /
`:account` (verified in `finance/blueprint.ex`). `docs/ws-erp/design.md` §2.1 specified
`dimension_refs` ("jsonb bounded dimensions — dept / project / item, the ERP analytics join
keys"); **E1 shipped without it.**

This is load-bearing for the whole doc, because the doc's books are dimensioned **everywhere**:

- every JE in the playbook is a *per-chip* or *per-cost-pool* fact (RISC-V64 SoC, GPU, PTA, PDB);
- the variance workbook is per cost element, per chip, per period;
- WIP "by lot and process step", grant funds, and board KPI variance bridges are all
  dimension-grouped reads.

Without a dimension seam you can post the doc's journal entries but cannot answer a single
question the doc's reports ask. **It is Phase 1 and everything else waits on it.**

### 0.5 Gap table — the doc's workbooks, and what ships each

| Doc workbook | Ships as | Status |
|---|---|---|
| Business-model + COA (2 workbooks) | `Account` rows (seed) + 1 posting-map widening | **Alter + data** |
| Fab manifest (slot · schedule · commercial terms · route) | `PurchaseOrder`/`PoLine` + a small `FabOrder` extension (lot slot, shuttle, deadlines, DRC/ship terms) | **Add (small)** |
| Project + per-chip overview (4 chips, cost cards) | `CostObject` (`:chip`/`:project`) + per-chip SKUs/`Item` + BOMs | **Add + data** |
| JE playbook (JE-001…JE-081) | existing `JournalEntry`/`JournalLine` + the additions below | **Partial today** |
| Variance playbook (standard costing, PPV/yield/labor/BOM/OH, disposition) | `CostStandard` + `CostStandardLine` + variance reads + variance posting | **Add (largest)** |
| Rolling forecast (drivers, P&L, cash, scenarios, KPIs) | `ForecastVersion` + `ForecastDriver` + runway/scenario reads | **Add (large)** |
| Board-ready summary (8 pages) | reads/rollups + a bounded export package | **Add (reads only)** |
| Grant compliance reporting | `Grant` + fund dimension + compliance read (personnel report = masked) | **Add** |
| Monthly close checklist (10 phases, 12 roles) | `FiscalPeriod` + `CloseRun` + checklist as Work tasks | **Add** |
| Grant application tracker (pipeline, deadlines) | `GrantOpportunity` (deadline-driven pipeline row) | **Add (small)** |
| Foundry partner scorecard (weighted, quarterly) | `SupplierScorecard` + dimensions | **Add (small)** |
| Grant budget vs actual (incl. burn/runway) | existing `Budget`/`BudgetVsActual` + fund dimension, reuse | **Reuse + dimension** |
| Supplier risk matrix (5×5 register) | `SupplierRisk` + reads | **Add (small)** |
| Multi-source qualification roadmap | Work projects + milestones (reuse) | **Reuse** |
| Supplier onboarding checklist | Work tasks from a seeded checklist (reuse) | **Reuse** |
| *E1–E5 Items Overview* (line 5912) | **not accounting** — an MLPerf-style acceptance/quantization/golden-vector spec | **Flag: out of scope** (§5) |

---

## §1 Decisions

Each is a numbered ADR-054 decision, and **all are now TAKEN** — ADR-054 is ACCEPTED as of
2026-10-27, with the five operator-facing calls ruled in its "Ratification" section. Note the two
numberings: the ADR carries **eighteen** decisions (it promotes the allocation step and the PII
posture to numbered decisions), while this spec lists **D1–D16**, which is what the build plan
cites. ADR-054's Decisions section opens with the mapping; neither numbering is a typo.

### D1 — The cost-object seam lives on `JournalLine` as a bounded jsonb; cost objects are a Tier-0 row
`JournalLine` gains `dimension_refs` (jsonb) validated by a new `DimensionGuard`: keys are drawn
from a **frozen four-key vocabulary** (`"project" | "lot" | "fund" | "cost_pool"`), values are
same-org **`CostObject`** ids, and the map is PII-free **by construction** (ids only — never free
text, never a name). `CostObject` is a new Finance Tier-0 row: `{code, name, kind ∈ {:project,
:chip, :cost_pool, :fund}}`, org-scoped, archivable, unique `code` per org.

**Why not FKs per dimension:** four nullable FK columns on every line is schema sprawl that grows
with every new analysis axis, and it hard-couples Finance to four resource shapes.
**Why not reuse `Work.Project`:** the kernel posture is plain-uuid cross-scope references with
*no runtime coupling* (ADR-049 §8), and a GP180MCU lot or a grant fund is not a task project.
A `CostObject` registry keeps Finance self-contained and lets the axes be host data.
**Cost:** every cost-by-chip / cost-by-lot / cost-by-fund read is `GROUP BY
dimension_refs->>'project'` over the append-only lines — derived, never stored (ADR-049 §2).

### D2 — `PostingAccount.key` is widened in place; no invented meanings
The closed enum grows from 4 to the meanings the doc's flows need — at minimum
`wip_foundry`, `wip_photonics`, `wip_assembly`, `finished_goods_chip`, `finished_goods_board`,
`deferred_revenue`, `grant_deferred`, `accrued_liabilities`, `inventory_reserve`,
`amortization_expense`, `accumulated_amortization`, `depreciation_expense`,
`write_down_expense`, `variance_ppv`, `variance_yield`, `variance_labor`, `variance_overhead`,
`mask_expense`, `eda_expense`. The enum stays **closed and fail-honest** (an unmapped meaning
refuses the posting — accounts are a host decision, never invented by the scope); the change is a
bounded migration + CHECK update + abbrev-golden/fixture refresh.

### D3 — Lots and foundry WIP reuse the stock ledger, never a parallel WIP register
`Lot` (Inventory): `{code, item_id, supplier_id, stage ∈ {:design, :mask, :fab, :dice,
:assembly, :test, :delivered}, wafer_count, die_expected, die_actual, fab_order_id}`. `Warehouse`
gains `kind ∈ {:owned, :consignment, :supplier}`, so **wafers at the foundry are stock at a
supplier location** and "WIP – Foundry" is a *GL presentation* of that stock, valued by the
existing moving-average ledger. Lot cost accumulation = Σ `StockLedger` events whose `ref` names
the lot; stage-wise cost = Σ GL lines dimensioned by the lot. **Why:** ADR-049 §4 makes stock a
ledger; a second WIP register would be a second source of truth that *can* disagree with stock.
Nothing new to reconcile.
Integer base-UOM stays binding (design §7.4): wafers and dies are countable — **no schema
change**.

### D4 — Standard costing is a variance layer, never a second valuation
`Item.unit_cost` (moving average) remains the one stock valuation. Standards ship as
`CostStandard` + `CostStandardLine` (per item × cost element: standard qty, standard price,
expected yield). The engine computes, per period per cost object: material **price** (PPV),
material **usage/yield**, **labor rate**, **labor efficiency**, **overhead spending**,
**overhead volume**, and **BOM** variance; variances post as **their own journal entries** into
the `variance_*` accounts under the manual's **per-type disposition table, adopted verbatim**
(ratified — ADR-054 Ratification 2: yield and PDB BOM absorb into inventory, PPV and overhead
volume write off to COGS, labour and overhead spending write off to R&D expense, residual balances
close at year-end), and the cost-of-yield dashboard is a derived read. Standards **never** revalue the
stock ledger. **Why:** revaluing stock off standard is exactly the "two truths" failure the
reconciliation spine exists to prevent.

### D5 — Deferred revenue and recognition schedules are one mechanism with two methods
`RevenueSchedule` (anchored by the ADR-041 `source_ref` shape): `{total_cents, start_on, months,
method ∈ {:straight_line, :cost_incurred}}`, with `recognized_to_date` **derived** (Σ posted
recognitions). One Automation-driven run posts the period's recognition exactly once (the E2
partial-unique anchor pattern the `PaymentReceipt` posting already proves). `:straight_line`
covers JE-053; `:cost_incurred` covers JE-072 (grant revenue "as allowable costs are incurred").
**No ASC 606 multi-element contract engine** (§5).

### D6 — Accruals are a posted pair with a linked automatic reversal
A `:post_accrual` action on the entry creates the accrual **and** its linked reversal
(`reversal_of_entry_id`, the `VoidGuard` reversing-entry precedent reused), with an Automation job
flipping the reversal to posted on its date. This encodes the doc's own control (Key Controls §7:
"reverse all month-end accruals on the first day of the following month to avoid double-counting")
as a mechanism rather than a human habit. Covers JE-024/025, JE-060/061, JE-064.

### D7 — Fiscal periods, and close control at the posting gate
`FiscalPeriod` `{year, month, status ∈ {:open, :soft_closed, :closed}, closed_at, closed_by}`,
and `PostGuard` extended so a post whose `entry_date` lands in a **`:closed`** period is refused
fail-honest. `:soft_closed` refuses posts **carrying a document `source_ref`** (no new bills or
receipts land) while still admitting journal-only close adjustments. **Why soft-close exists:** a
close is not an instant; the checklist's Days 1–7 need the document window shut before the
adjustment window is.
`CloseRun` = one row per period + the doc's ten phases as **Work tasks anchored to it**
(ADR-041 object-ref — no new task engine), with the doc's twelve role assignments.

### D8 — Grants are a document plus a fund dimension, not a fund-accounting subsystem
`Grant` `{funder, program, award_ref, award_cents, period_start/end, restricted?: true, status,
budget_id}` — the grant budget **reuses `Budget`/`BudgetLine`** — plus `GrantMilestone`/`GrantClaim`
`{due_on, claimed_on, amount, evidence_files}`. Fund accounting is the `fund` dimension on
postings (D1) + a `CostObject(kind: :fund)`. Compliance reporting is a **read** (§ "must not
invent"); the personnel report is a **masking watch-list surface** (§4). The grant-application
*tracker* is a separate, small `GrantOpportunity` row (deadline-driven pipeline with its own
stages — CRM `Opportunity` stays the sales pipeline's SoT, per ADR-049 §6.1's precedent of not
bending one scope's SoT into another's).

### D9 — Asset schedules are derived; the run is exactly-once per period
`Asset` `{name, kind ∈ {:intangible, :equipment}, cost_cents, acquired_on, method ∈
{:straight_line}, life_months, salvage_cents, status, disposal}`. **No schedule table** — the
schedule is derived from `{cost, life, method, start}` (the derived-state discipline), and a
monthly `DepreciationRun` posts once per period behind a period-keyed anchor. Covers the PDK
license (JE-003/004), lab equipment (JE-063), and the accumulated-amortization contra account.

### D10 — Obsolescence is a policy row plus a gated write-down, never an automatic posting
`InventoryReserve` `{name, basis ∈ {:age, :item}, age_months, pct, applies_to}`; the quarterly
assessment is a **derived read** (excess/obsolete candidates at NRV) that **drafts** a write-down
journal entry, which a human clears through the ADR-040 Gate. NRV is an estimate; auto-posting an
estimate into the GL is the kind of lie the fail-honest rules exist to prevent.

### D11 — Forecasting is a bounded driver model with append-only versions
`ForecastVersion` `{name, version, starts_on, ends_on, status ∈ {:draft, :published, :archived},
scenario_weights}` + `ForecastDriver` rows (the doc's driver tree: slot price, die yield, EDA
spend, headcount, burn, grant pipeline). Materialized P&L / cash-flow / runway / scenario-compare
/ variance-to-forecast bridge are **reads**. Rolling the forecast **appends a new version**;
a `:published` version is immutable. **No formula engine** — the doc's Excel reference is a
specification of *which arithmetic*, not a request for a spreadsheet evaluator (§5).

### D12 — The board pack ships its *numbers*, not its prose
Exec summary, condensed statements, KPI/variance bridge, runway waterfall and the variance
appendix are reads over the ledger + rollups, exported through the existing bounded `Csv` posture
with the `Samen.Web.Erp` registry extended by the new surfaces. Risks/opportunities, commentary
and board resolutions stay **authored documents** — generating narrative from numbers is not a
feature this workstream claims.

### D13 — Consolidation stays dormant; single-entity is the honest default
Kubeworkz is one legal entity today. `scopes/consolidation/*` (E24) is dormant (§0.2) and is the
documented path when a second entity exists — **not** a phase here. The doc's "Multi-Entity
Consolidation" ERP requirement is answered as: *the estate has the module set, unwired; the books
do not need it yet.* The fleet/operator plane already covers portfolio-level views.

### D14 — Labor cost is allocated by timesheet share, which means authoring timesheets into Work
JE-001/002/071 dimension design-engineering labor by chip. The only truthful source for that split
is timesheets, and E15's `timesheet_{entry,guard,summary}` were **dormant** (§0.2) and are now
**deleted** (ADR-055 §6 — unmigrated, unreferenced, untested, so they were not a head start). So
this is a priced *authoring* task, neither a reuse nor a wiring: `Samen.Scopes.Work` grows the
timesheet resources fresh, plus a `cost_object` dimension, and the payroll posting allocates
`PayRun` cost by timesheet share.
**Authorized** (ADR-054 Ratification 5), because the manual's labour variances and its grant
cost-incurred recognition are not facts without actual hours — with the binding proviso that every
labour-derived figure stays **labelled ratio-based** until the driver lands (build plan Phase 10.2).

### D15 — One functional currency (CAD), set by host config
The doc's header reads "Currency: **CA**" (an evident truncation of CAD) while
`Account.currency` defaults to `"USD"`. Decision: the default comes from **host config**, and
Kubeworkz's org is seeded CAD. FX revaluation / gain-loss stays P2 (design §7.3) — `ExchangeRate`
and `FxConvert` exist for converted *reporting*, not for revaluation.

### D16 — The books are seeded under `Kubeworkz`, not the doc's placeholder
The doc's JE playbook header names "**Gridworkz** Fabless AI Chip Company" while the company is
**Kubeworkz**. The seed uses Kubeworkz; the discrepancy is noted so the COA/JE seed is not
transcribed verbatim from a template entity. (The doc also contains a self-corrected JE — JE-055
carries a wrong original entry and a "Corrected Entry" — so the playbook must be transcribed from
its corrected forms, not blindly.)

---

## §2 The JE playbook, mapped

Proof that the model fits: every section of the doc's playbook, and what posts it.

| Doc section | JEs | Posts via |
|---|---|---|
| §1 R&D | JE-001 labor · JE-002 EDA/IP · JE-003 PDK license · JE-004 amortization · JE-005 mask/reticle · JE-006 prototype | `ApInvoice`→GL (E2), `Asset`+run (D9), `CostObject` dimension (D1); labor via D14; mask cost allocated across chips by D-alloc (§Phase 10) |
| §2 Slot/order | JE-010…JE-013 | `FabOrder`/`PoLine` → prepaid assets (`1200`/`1210`) — PO + AP, existing chokepoint |
| §3 Fabrication (WIP) | JE-020…JE-025 | `Lot` at a `:supplier` warehouse (D3) + monthly accrual pair (D6) |
| §4 Delivery & inventory | JE-030…JE-034 | `GoodsReceipt` moving lot stock into finished goods; NRV write-down via D10 |
| §5 PDB assembly | JE-040…JE-044 | `Bom`/`WorkOrder`/`ProductionLog` (E6) with the board as the produced item |
| §6 Revenue & COGS | JE-050…JE-055 | `SalesOrder` `:fulfill` → stock `:sale` + Billing invoice (E5) + COGS; deferred leg via D5 |
| §7 Period-end | JE-060…JE-064 | accrual pairs (D6), reserve (D10), depreciation (D9) |
| §8 Grant accounting | JE-070…JE-072 | `Grant` + `fund` dimension + `:cost_incurred` schedule (D5/D8) |
| §9 Year-end close | JE-080…JE-081 | derived closing reads + `FiscalPeriod :closed` (D7) |

---

## §3 The extended reconciliation spine (LOAD-BEARING)

WS-ERP's R1–R5 already exist as green tests + red twins + committed sabotage patches. WS-ACCT
adds the invariants its new machinery needs, same discipline (**each = green test + red-path twin
+ committed sabotage patch**: the guarantee is only claimed when its refutation is replayed).

- **R6 — dimension balance.** Σ debits = Σ credits **per cost object**, always. *Sabotage:* post
  an entry that balances org-wide but not per cost object.
- **R7 — WIP ↔ lot.** Σ WIP GL lines by lot == Σ supplier-location stock value by lot == Σ lot
  stage costs. *Sabotage:* a lot whose stock and GL disagree.
- **R8 — standard ↔ actual.** Σ variance accounts == Σ (actual − standard) for the period.
  *Sabotage:* a variance posting that does not tie to its standard card.
- **R9 — recognition ↔ deferred.** Σ recognized == Σ deferred released, and a schedule's derived
  `recognized_to_date` == the posted recognitions. *Sabotage:* double-recognition (the exactly-once
  anchor dropped).
- **R10 — close ↔ period.** No posted entry dated inside a `:closed` period, including via raw
  SQL (the DB belt, not only the Ash guard). *Sabotage:* the period guard dropped.
- **R11 — grant ↔ fund.** Σ fund postings == Σ recognized grant revenue == Σ claimed allowable
  costs. *Sabotage:* recognition exceeding incurred cost.

---

## §4 PII and the masking watch-list

The ledger stays **PII-free by construction** (ADR-049 §2.3): every new accounting resource is
bounded ids/enums/integers/dates, and `dimension_refs` carries **ids, never names** (D1) — this is
what keeps a cost-object join from becoming a de-anonymisation channel.

Two new PII-adjacent surfaces, each needing the full **green / red / sabotage** trio
(`Samen.MaskingCase`):

1. **Grant personnel report** — the doc's personnel report names people and their effort. It
   resolves through `Samen.Api.PiiResolution` on the actor's plane (the HR roster precedent) or
   reports only bounded employment facts. **No third path.**
2. **Supplier contacts** — already vaulted in `SalesOps.Vendor`; the scorecard/risk resources
   reference `vendor_id` and **never re-declare the person** (ADR-049 §2.3's rule, restated
   because two new supplier resources are exactly where it would get broken).

---

## §5 Out of scope (the honesty list)

1. **ASC 606 multi-element contract machinery** — the schedules in D5 are single-obligation
   (straight-line or cost-incurred). Multi-element allocation is P3.
2. **Tax computation and filing** — `TaxRate`/`TaxCalculator` exist; jurisdictions do not. Rates
   are host data, filing is an adapter (ADR-014 shape), both P3.
3. **FX revaluation and gain/loss** — reporting conversion only ([design §7.3] parity).
4. **Serials, fractional UOM, recall genealogy** — lots land (D3); unit-level serials do not.
5. **MRP / shop-floor scheduling / capacity planning** — unchanged from the base system (P3).
6. **A formula/spreadsheet engine** — the rolling forecast is a bounded driver model (D11).
7. **Generated narrative** — the board pack's prose is authored (D12).
8. **Intercompany elimination** — consolidation stays dormant (D13).
9. **Payroll computation** — unchanged: `PayRun`/`Payslip` produce the posting; the GL never
   computes pay (ADR-049 §6).
10. **The doc's `E1–E5 Items Overview`** (line 5912: MLPerf acceptance model, ONNX quantization,
    golden vectors, power/energy boundaries) — **not accounting**. It appears to be from a
    different conversation. Excluded pending the operator's confirmation (§7 carry).

---

## §6 Mounting shape

Every addition follows ADR-004: new resources land in the **existing** scopes (Finance,
Inventory, Work) via their blueprints; abbrevs via the sanctioned allocator only (ADR-023); the
six-surface registry grows by declaration, and each new surface is a bounded column list with no
export path (the E8 posture). The Kubeworkz books are then **host data**: a seed task opening the
COA, posting map, cost objects, standard cards, grants and drivers — so "using samenerp to run
our business" is a mount + a seed, not a fork (§0.3).

**Hr must be mounted** for JE-001/064: it is not mounted in samenerp today (§0.1). That is one
router/domain line plus its surfaces — and it is the change that makes payroll postings possible
in-app.

---

## §7 Risks and carries

- **The keystone sequence is real.** D1 (dimension) precedes *everything* dimensional; D2
  (posting map) precedes every new posting. Landing the COA first would open books nothing can
  report on. The build plan orders accordingly and says so at each phase.
- **Dormant-code hygiene** (§0.2): ~26 unwired module sets, plus a duplicate approvals set.
  Neither this plan's friend nor its enemy — but a reader who greps "consolidation" will find code
  that looks built. Recommend a separate, tiny workstream: delete or complete. **Carry.**
- **Abbrev budget.** ~25 new resources ≈ 25 registry rows via the allocator (+ goldens). This is
  the largest single registry movement since WS-ERP; per-phase reservation, never batched.
- **Doc data quality.** The source is an LLM-assembled manual: a placeholder entity name
  (Gridworkz), `Currency: CA`, a self-corrected JE-055, a non-accounting appendix (§5.10), and
  numbers that are illustrative rather than Kubeworkz's actuals. **The structure is the
  deliverable; the figures are placeholders to be replaced with real policy values** — seeded as
  defaults and reviewed by the operator, not treated as facts.
- **Effort honesty.** This is a multi-week programme on top of a mature estate. The build plan
  sizes it phase by phase, and phases 12–15 deliver reporting depth that is worthless before
  phases 1–11 do.
