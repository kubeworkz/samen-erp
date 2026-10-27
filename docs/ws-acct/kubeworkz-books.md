# The Kubeworkz books — coverage ledger

**What this file is:** the permanent answer to *"where is workbook N of
`docs/chip_manufacturing_accounting_setup.md` actually implemented?"* — so the source manual is
never re-grepped to find out, and so a reviewer can see at a glance what is **shipped today**,
what this workstream **adds or alters**, and what is **deliberately refused**.

- **Status:** phase 0 deliverable of `docs/ws-acct/build-plan.md`; the ledger for **ADR-054**
  (PROPOSED, build not started). Verdicts describe the *plan*; they are not claims of built work.
- **Date:** 2026-10-27
- **Source:** `docs/chip_manufacturing_accounting_setup.md` — 6,168 lines, 18 sections. Line
  ranges below are the source's own headings, so the mapping survives the file being edited above
  or below a section only if the range is re-checked (see §"Re-deriving this ledger").

## Verdict vocabulary

| Verdict | Means |
|---|---|
| **DATA** | No code: the requirement is satisfied by seeding rows (COA, cost objects, standards). |
| **REUSE** | Shipped machinery already does it; the phase only wires or seeds it. |
| **ALTER** | Shipped structure must change (a widening). Named explicitly — these are the four. |
| **ADD** | New resources/reads. Sized in the build plan. |
| **REFERENCE** | Background that informs decisions but ships nothing. |
| **OUT OF SCOPE** | Deliberately refused, with the reason recorded (ADR-054 §Honesty / design §5). |

## The ledger

### 1 · Opening guide — the generic chip-manufacturer framing (lines 1–85) — **REFERENCE**

Foundry-vs-IDM-vs-fabless framing, a COA-modification list, the costing-method menu
(standard / weighted-average / FIFO), inventory write-down policy, and the ERP functional
requirements (five-level lot traceability, process costing with variance roll-up, subcontracting
management, multi-entity consolidation).

Ships nothing. **Its decisions are already taken elsewhere and stay taken:** cost flow is
moving-average with a per-movement cost snapshot (ADR-049 §4, shipped), standards are a variance
layer and never a valuation (ADR-054 D4), consolidation is dormant until a second entity exists
(ADR-054 D16). The foundry/IDM half of this section describes a business Kubeworkz is not — read
the next section instead.

### 2 · Fabless business model (lines 86–170) — **DATA + ALTER**

The fabless COA, the accounting policies and workflows, and the fabless-specific ERP
requirement set. This is the section the books are actually built from.

| Requirement | Today | Verdict | Phase |
|---|---|---|---|
| The fabless COA (`1200` WIP-foundry, `1210` WIP-photonics, `1220` WIP-assembly, `1230` finished boards, `5000`–`5040` COGS pools, `6000`–`6030` R&D pools) | `Account` = `code`/`name`/`kind`/`normal_side`/`parent_id` — maps 1:1, **including contra accounts** | **DATA** | 2 |
| The posting map binding each cost pool to a real account | `PostingAccount.key` is a closed **4**-value enum (`:ap_clearing`/`:ar_clearing`/`:cash`/`:income`) | **ALTER** (D2) | 1 |
| MPW slot purchase is a prepayment/deposit until fabrication begins | `PurchaseOrder`/`PoLine` → AP → prepaid asset accounts | **REUSE** + posting keys | 1 / 4 |
| Per-chip cost tracking (the COA can't answer "what did the GPU cost") | `JournalLine` has **no dimension seam** | **ALTER** — `dimension_refs` (D1) | 1 |
| Capitalize-vs-expense policy (MPW cost into a board's inventory when the chips are for a product; R&D expense when internal) | `Item` + `WorkOrder`/`ProductionLog` cost roll-up; the disposition is a seeding/policy decision | **REUSE** + policy (`Budget`/standards) | 7 |
| ASC-606-flavoured revenue recognition for university sales (point-in-time on control transfer; deferral when a support obligation exists) | `SalesOrder :fulfill` → stock `:sale` + Billing invoice (point-in-time, shipped) | **ADD** for the deferral leg (D5) | 6 |

### 3 · GlobalFoundries photonics fab (lines 171–205) — **REFERENCE**

Where GF fabricates photonics (Malta NY; the acquired AMF Singapore 200mm line), and the
SMART Photonics open-access route that splits silicon and InP work between two partners.

Ships nothing, but it decides **how many photonics pools the books need**: a `CostObject` for
photonics, and — if the open-access route is taken — a second one for the InP partner, because the
doc's own accounting note says to keep separate WIP/cost accounts per partner in the value chain.
Given the reported general-availability target (H2 2027), the plan seeds **one** photonics pool
now and records the second as a two-line addition.

### 4 · Fab manifest (lines 206–321) — **ADD (small)**

Slot/order, schedule, commercial terms, route-specific submission, and the manifest template — the
commercial header of a shuttle run, with the accounting implication spelled out in each part
(slot purchase = prepayment; milestone payments matched against WIP; cancellation risk to
deposits; dicing/packaging cost pools).

| Requirement | Today | Verdict | Phase |
|---|---|---|---|
| Slot/order reservation, shuttle deadlines (slot purchase, GDS submission, delivery), DRC-iteration limit, submission route, ship terms | `PurchaseOrder` carries vendor/dates/status/lines, but not a shuttle/deadline/ship-terms header | **ADD** `FabOrder` (rides `PurchaseOrder`; the lot's commercial header) | 4 |
| Milestone-based payment schedule matched against WIP as fabrication progresses | AP bills + the goods-receipt chokepoint | **REUSE** | 4 |
| Separate **dicing** and **packaging** cost pools (the doc's route-implication note: a route that bundles packaging vs one that orders it separately shifts *when* the cost is incurred) | COGS pools are CoA data | **DATA** + posting keys | 2 |

### 5 · Project overview — the four programmes (lines 322–588) — **DATA + ADD**

Chip 1 (Quad-core RISC-V64 SoC + NPU), Chip 2 (full GPU), Chip 3 (photonics tensor accelerator),
and the PDB development board — each with slot/order, schedule, commercial terms, route, and its
own "Accounting Journal Entries" block; then a consolidated manifest and the key policy decisions.

| Requirement | Today | Verdict | Phase |
|---|---|---|---|
| Four programme cost objects | — | **DATA** `CostObject(kind: :chip)` | 2 |
| Per-chip items, wafers/dies as countable UOM, boards built from chips | `Item` (`uom` enum), `Bom`/`BomLine`, `WorkOrder` | **REUSE** (integer UOM stays binding) | 4 / 5 |
| The per-chip journal-entry blocks | the same entries as workbook 6 | see workbook 6 | — |
| MPW cost allocation across designs (a stated policy decision) | — | **ADD** — the allocation step (D11) | 10 |

### 6 · Journal Entry Playbook — JE-001…JE-081 (lines 589–1297) — **the spine**

COA reference, nine sections of journal entries, the stage-flow summary, and the seven key controls.
This is what "the books" means in practice.

| Doc section | Posts via | Verdict | Phase |
|---|---|---|---|
| COA reference (`1000`–`8000`) | `Account` | **DATA** | 2 |
| §1 R&D (JE-001 labour · 002 EDA/IP · 003 PDK licence · 004 amortization · 005 mask/reticle · 006 prototype & test) | AP→GL, `Asset` + run (D9), cost-object dimension (D1), labour via D17 | **ADD** D9/D17, rest **REUSE** | 8 / 1 / 17 |
| §2 Slot/order (JE-010…013) | `FabOrder` → prepaid assets via AP | **REUSE** + ADD (wkbk 4) | 4 |
| §3 Fabrication (JE-020…025: submission to WIP, month-end accrual, invoice reversal) | `Lot` at a `:supplier` warehouse (D3) + the accrual pair (D6) | **ADD** | 4 / 5 |
| §4 Delivery & inventory (JE-030…034: chips received, packaging allocated, obsolete write-down) | `GoodsReceipt` into finished goods; NRV reserve (D10) | **REUSE** + **ADD** D10 | 4 / 9 |
| §5 PDB assembly (JE-040…044: PCB NRE, chip transfer to board WIP, components, labour/overhead, completion) | `Bom`/`WorkOrder`/`ProductionLog` cost roll-up (shipped) | **REUSE** | — |
| §6 Revenue & COGS (JE-050…055) | `SalesOrder :fulfill` → stock + Billing invoice + COGS (shipped); deferral leg D5 | **REUSE** + **ADD** D5 | 6 |
| §7 Period-end (JE-060…064: accrued foundry/photonics, obsolescence, depreciation, accrued vacation) | accrual pairs (D6), reserve (D10), depreciation run (D9) | **ADD** | 5 / 9 / 8 |
| §8 Grant accounting (JE-070…072: restricted receipt, expenditure, recognition) | `Grant` + fund dimension + `:cost_incurred` schedule (D5/D8) | **ADD** | 11 |
| §9 Year-end close (JE-080…081: close P&L to retained earnings) | derived closing reads; `FiscalPeriod :closed` (D7) | **ADD** (D7's period lock) + derived reads | 3 |
| Key controls — three-way match | `ThreeWayMatch` (shipped, tolerance-flagging) | **REUSE** | — |
| Key controls — WIP reconciliation vs supplier statements | the WIP↔lot invariant R7 | **ADD** | 4 |
| Key controls — quarterly physical count reconciled to perpetual records | `StockLevel` rollup vs `StockLedger`; the revaluation/`ReconcileStock` reads (shipped) | **REUSE** | — |
| Key controls — grant funds tracked separately, allowable-cost documentation | fund dimension + `GrantClaim` evidence files | **ADD** | 11 |
| Key controls — revenue cut-off by shipping terms | `FabOrder`/`SalesOrder` ship terms + recognition on fulfillment | **REUSE** + wk 4 | — |
| Key controls — **reverse all month-end accruals on the first day of the next month** | — | **ADD** — mechanised (D6), not left as a habit | 5 |

### 7 · Variance Analysis Playbook (lines 1298–1800) — **ADD (largest)**

Standard cost cards, the variance taxonomy, PPV, yield variance (incl. reticle stitching), labour
and efficiency variance, BOM variance, overhead volume/spending variance, the month-end workflow,
reporting templates, disposition policy, KPIs and a reduction action plan.

| Requirement | Today | Verdict | Phase |
|---|---|---|---|
| Standard cost cards (+ expected yield per element) | `Item.unit_cost` moving average only | **ADD** `CostStandard`/`CostStandardLine` (DATA per card) | 7 |
| PPV · yield · labour rate/efficiency · OH volume/spending · BOM variance | — | **ADD** the engine (D4) | 7 |
| Variance journal entries + **disposition policy** (write off vs capitalize) | — | **ADD**; the disposition is an **open operator decision** (ADR-054 ratification #2) | 7 |
| Cost-of-yield / COY dashboard, variance investigation threshold, variance trend chart | `Samen.Rollup` + the aggregate plane | **ADD** reads | 7 / 13 |
| Month-end variance workflow + investigation triggers | `CloseRun` tasks + Automation | **REUSE** (wk 11) + **ADD** reads | 12 |
| **A standard never revalues stock** | — | **ADD** as a *regression guard*, not a feature | 7 |

### 8 · Rolling Forecast Template (lines 1801–2223) — **ADD**

Design principles, the driver tree, the driver input sheet, the rolling P&L, the cash-flow
forecast and runway dashboard, scenario analysis, the executive KPI dashboard, the
variance-to-forecast bridge, the monthly rollover process, an Excel formula reference, forecasting
policies, and the doc's own eight-phase implementation roadmap.

| Requirement | Today | Verdict | Phase |
|---|---|---|---|
| Driver tree + driver input sheet | — | **ADD** `ForecastDriver` (DATA for the drivers) | 14 |
| Rolling P&L · cash-flow forecast · runway dashboard (+ runway sensitivity) | banking/cash accounts + GL reads | **ADD** reads (D12) | 14 |
| Scenario analysis + weights (+ a scenario toggle) | — | **ADD** `ForecastVersion.scenario_weights` | 14 |
| Variance-to-forecast bridge · forecast accuracy tracking · version archive | — | **ADD** reads over append-only versions | 14 |
| Version control / commentary thresholds | — | **ADD** (threshold is a config row) | 14 |
| The doc's own implementation roadmap (its Phases 1–8, "build it in Excel") | — | **REFERENCE** — superseded: its Phase 5, "integrate with the accounting system for actuals pull", is exactly what the reads above replace | — |

### 9 · Board-Ready Financial Summary (lines 2224–2613) — **ADD (reads) + AUTHORED (prose)**

Eight pages: exec snapshot and traffic-light dashboard, condensed statements, operational KPIs and
the EBITDA variance bridge, the runway waterfall and sensitivity, the rolling forecast and scenario
outlook, risks/opportunities/board asks, a variance appendix, plus board-resolution and
meeting-agenda templates.

| Requirement | Today | Verdict | Phase |
|---|---|---|---|
| Exec snapshot · condensed income statement · balance sheet · cash flow | `TrialBalance`, `BalanceSheet`, `ProfitLoss` (shipped) | **REUSE** + **ADD** the rollup packaging | 13 |
| Semiconductor operational KPIs · EBITDA variance bridge · runway waterfall/sensitivity | Phase 7 reads + Phase 14 reads | **ADD** presentation reads (D13) | 13 |
| Variance appendix · forecast-accuracy trend · cash-runway detail · grant pipeline detail | Phases 7/11/14 reads | **ADD** | 13 |
| Risks · opportunities · board asks · **resolutions and agenda** | — | **AUTHORED** (D13) — narrative is not generated from numbers | — |

### 10 · Grant Compliance Reporting Template (lines 2614–2988) — **ADD**

The Canadian grant landscape (federal: NRC IRAP, NSERC, FABrIC, CFI; provincial: Ontario CTI), the
compliance-report template (cover/certification, exec summary, milestone tracking, statement of
account, **personnel report**, IP report, compliance certifications, variance explanation, cash-flow
and liquidity statement, attachments checklist), agency-specific requirements, a compliance calendar,
and compliance policies.

| Requirement | Today | Verdict | Phase |
|---|---|---|---|
| Grant identity, award, period, restricted flag, milestones and claims with evidence | — | **ADD** `Grant`/`GrantMilestone`/`GrantClaim` | 11 |
| Statement of account · expenditure vs budget by category | `Budget`/`BudgetVsActual` + fund dimension | **REUSE** + dimension | 11 |
| Budget-vs-actual **variance explanation** | Phase 7's variance reads | **REUSE** + **ADD** presentation | 11 / 13 |
| **Personnel report** (names, effort) | Hr is **not mounted** in samenerp; `Employee` fields are 🔒 | **ADD** — a **masking watch-list surface** (green/red/sabotage trio mandatory) | 11 |
| IP report · compliance certifications · attachments checklist | Files + Docs | **REUSE** | 11 |
| Compliance calendar · agency-specific requirements | Automation reminders + `Grant` deadlines | **REUSE** + seed | 11 |

### 11 · Monthly Close Checklist (lines 2989–3682) — **ADD**

Ten phases over ten days (pre-close cut-off through board reporting), a close dashboard, a
role-by-role checklist (controller, AP, AR, payroll, foundry ops, photonics eng, supply chain,
grant admin, FP&A, treasury, CFO), and a quick-reference calendar.

| Requirement | Today | Verdict | Phase |
|---|---|---|---|
| The close as a governed, period-scoped run with gating | — | **ADD** `CloseRun` + `FiscalPeriod` (D7) | 3 |
| Phase gating (documents shut at soft-close; adjustments still allowed) | `PostGuard` | **ALTER** — the period rule (D7) | 3 |
| The ten phases as checkable work with twelve role assignments | Work tasks + the approvals engine | **REUSE** (one Work task per phase item, anchored to the `CloseRun`) | 12 |
| Bank reconciliations (Phase 2.4) | `BankAccount`/`StatementImport`/`Match`/`Rule` (shipped, mounted) | **REUSE** | — |
| Inventory & WIP reconciliation (Phase 3, incl. foundry/photonics/assembly) | WR7 (wkkb 4) + shipped tiered reconciles | **REUSE** + **ADD** R7 | 4 |
| Grant close tasks (Phase 5) | Phase 11 | **REUSE** | 11 |
| Close dashboard · trial-balance review (Phase 7.3) | shipped TB + **ADD** the dashboard read | **REUSE** + **ADD** | 12 |

### 13 · Foundry Partner Scorecard (lines 4061–4537) — **ADD (small)**

Weighted scoring dimensions (quality/yield 35%, delivery 25%, cost 20%, support 12%, compliance
8%), KPI definitions, a 1–5 scoring guide, per-partner scorecards with corrective-action plans, a
comparative dashboard, the calculation reference and a grade mapping, the quarterly review process,
feedback templates, an escalation matrix, and integration notes.

| Requirement | Today | Verdict | Phase |
|---|---|---|---|
| Weighted composite score + grade per partner per quarter | — | **ADD** `SupplierScorecard` (+ a dimension row per weight) | 15 |
| Corrective-action plan · escalation matrix · review agenda/feedback templates | Work tasks + Automation | **REUSE** | 15 |
| Vendor identity and contact | `SalesOps.Vendor` (contact 🔒) | **REUSE** — reference `vendor_id`; **never re-declare the person** | 15 |

### 12 · Grant Application Tracker (lines 3683–4060) — **ADD (small)**

Opportunity master tracker, active-grant profiles, deadline calendar, pipeline dashboard,
compliance matrix, expenditure tracking, audit-readiness checklist, the four-phase application
workflow, a dashboard, key contacts, policy notes and governance.

| Requirement | Today | Verdict | Phase |
|---|---|---|---|
| Opportunity pipeline with stages, deadlines and probabilities | — | **ADD** `GrantOpportunity` (deadline-driven; CRM `Opportunity` stays the sales SoT) | 11 |
| Active-grant profiles · compliance matrix · expenditure tracking | Phase 11 | **REUSE** | 11 |
| The four-phase application workflow (identify→prepare→submit→post-award) | Work tasks | **REUSE** | 11 |
| Audit-readiness checklist · key contacts | Work + Files; contacts stay vaulted in `SalesOps.Vendor` | **REUSE** | 11 |

### 14 · Grant Budget vs Actual (lines 4538–4813) — **REUSE + dimension**

Award header, budget-vs-actual summary, monthly variance detail (personnel / direct materials /
other direct costs), burn rate and runway, close integration (with the journal entries flowing from
it), Canadian agency considerations, a modification/no-cost-extension tracker, audit readiness, a
multi-year view and a report calendar.

| Requirement | Today | Verdict | Phase |
|---|---|---|---|
| Budget vs actual by category, over the award period | `Budget`/`BudgetLine` + `BudgetVsActual` (shipped) | **REUSE** + the `fund` dimension | 11 |
| Burn rate · runway for the award | Phase 14's runway reads, scoped to a fund | **REUSE** | 14 |
| Variance detail by category | Phase 7's engine scoped to the fund | **REUSE** + dimension | 7 / 11 |
| The journal entries the doc lists as flowing from this template | workbook 6's JE-070…JE-072 | **ADD** (wk 6) | 11 |
| Multi-year view · modification tracker | `Budget.period` (integer year) + Work tasks | **REUSE** | 11 |

### 15 · Supplier Risk Assessment Matrix (lines 4814–5162) — **ADD (small)**

An executive risk dashboard, the likelihood/impact scales and a 5×5 matrix, per-supplier risk
registers, cross-supplier comparison and heat map, a mitigation plan, contingency plans, monthly
monitoring, a quarterly review agenda, a board escalation protocol, governance and an appetite
statement.

| Requirement | Today | Verdict | Phase |
|---|---|---|---|
| Risk register with derived rating (likelihood × impact), owner, mitigation, status | — | **ADD** `SupplierRisk` | 15 |
| Heat map · comparative dashboard · monitoring indicators | reads over the register (+ `Rollup`) | **ADD** reads | 15 |
| Escalation triggers → board summary | Automation + the board pack | **REUSE** | 13 / 15 |
| Contingency plans | Work tasks + Docs | **REUSE** | 15 |

### 16 · Multi-Source Qualification Roadmap (lines 5163–5522) — **REUSE**

Purpose, qualification tiers and decision matrix, candidate alternate partners (MPW aggregators;
alternate photonics foundries), a four-phase, 24-month roadmap, the budget, resources and funding
sources, a risk register with decision gates, integration notes and governance.

| Requirement | Today | Verdict | Phase |
|---|---|---|---|
| The phased programme with decision gates and a 24-month timeline | Work projects + tasks + milestones (ADR-041) | **REUSE** — one project per qualification track; sprint scheduling stays out of scope | 15 |
| The roadmap's own budget | `Budget`/`BudgetLine` | **REUSE** | 15 |
| Candidate partner evaluation | workbook 13's scorecard | **REUSE** | 15 |
| Careful: this workbook's "Integration with Existing Processes" points at the scorecard, the risk register, the rolling forecast and board reporting — all covered by workbooks 13/15/8/9 | — | — | — |

### 17 · Supplier Onboarding Checklist (lines 5523–5911) — **REUSE**

Onboarding philosophy, six phases (pre-onboarding/NDA, legal & compliance, technical/PDK, commercial
& operational, operational integration, first-shuttle + post-onboarding review), partner-specific
notes for six candidate suppliers, a role summary and a timeline.

| Requirement | Today | Verdict | Phase |
|---|---|---|---|
| The six phases as a runnable onboarding instance per supplier | Work tasks from a seeded checklist template | **REUSE** — seed the items; no new resource | 15 |
| NDA/contract execution · compliance documents · PDK access | Files/Docs + e-sign is **dormant** (E26) — do not assume it | **REUSE** (Files/Docs); e-sign is out of scope unless wired separately | 15 |
| Payment schedule setup · slot configuration (Phase 4) | workbook 4's `FabOrder` + AP terms | **REUSE** | 4 / 15 |
| ERP systems integration (Phase 5.2) — the doc asks what the ERP must receive | this ledger is the answer | — | — |

### 18 · E1-E5 Items Overview (lines 5912–6168) — **OUT OF SCOPE**

A reference acceptance-model specification (version/source/hash, preprocessing and ONNX
quantization, boundary shapes, reference semantics/rounding/golden vectors, quality/latency/power
thresholds and measurement boundaries, a versioned spec and data manifest with content hashing).
It is an MLPerf-style benchmark contract and has **nothing to do with accounting**. Excluded from
this workstream pending the operator's confirmation (ADR-054 ratification #6) — most likely it
belongs to a different conversation about the chips themselves.

## The four alterations, in one place

These are the only changes to **shipped** structure (ADR-054 §Consequences). Everything else is a
new resource, a read, or a seed.

| # | Change | Why it cannot be avoided |
|---|---|---|
| 1 | `JournalLine` gains `dimension_refs` (+ `CostObject`, + `DimensionGuard`) | The doc is dimensioned everywhere; the ledger cannot answer any of its reports without a cost-object seam. |
| 2 | `PostingAccount.key`'s closed enum widens (~4 → ~two dozen meanings) | The doc's flows post to pools the shipped enum cannot name, and an invented meaning is exactly what the fail-honest posture forbids. |
| 3 | `Warehouse` gains `kind ∈ {:owned, :consignment, :supplier}` | Foundry WIP has to live somewhere; putting it in the stock ledger keeps one quantity truth. |
| 4 | `PostGuard` gains the fiscal-period rule | The doc's close gates posting by period; without it the close is advisory. |

## What must NOT be reused (dormant code)

Verified dormant — **no scope macro, no blueprint, no domain, no host mount, no test**: the E13–E38
module sets. A grep finds plausible-looking code for `consolidation`, `expenses`, `quality`,
`planning`, `pos`, `ecommerce`, `elearning`, `appointments`, `documents`, `iot`, `custom_fields`,
`survey`, `livechat`, `social`, `dataclean`, `community`, `esign`, `email_marketing`,
`sms_marketing`, `social_marketing`, `marketing_automation` — plus `scopes/work/timesheet_*` (E15,
labour) and `scopes/approvals/*` (E35, a duplicate of the kernel `Samen.Approvals` that Finance
actually uses). **Wiring any of them is priced work, not a reuse** (design §0.2). This ledger's
verdicts above already account for that: the one place it matters is **workbook 17's e-sign step**
and **the labour dimension of workbook 6** (ADR-054 decision 17).

## Invariants this ledger relies on

Each ships a green test **+ a red-path twin + a committed sabotage patch**.

| # | Invariant | Phase |
|---|---|---|
| R1–R5 | the shipped ADR-049 §6.3 spine (GL balance · Billing↔cash · stock rollup↔ledger · WO↔BOM · three-way match) | shipped |
| R6 | Σ debits = Σ credits **per cost object** | 1 |
| R7 | WIP: GL by lot == supplier-located stock by lot == lot stage costs | 4 |
| R8 | Σ variance accounts == Σ (actual − standard) for the period | 7 |
| R9 | Σ recognized == Σ deferred released (no double recognition) | 6 |
| R10 | no posted entry dated inside a `:closed` period, including via raw SQL | 3 |
| R11 | Σ fund postings == Σ recognized grant revenue == Σ claimed allowable costs | 11 |

## Source-manual data-quality notes

The source is an LLM-assembled manual, so the **structure** is the deliverable and the **figures**
are placeholders (ADR-054 decision 18). Recorded so nobody transcribes an artefact as policy:

1. **Placeholder entity name** — the JE playbook and variance workbook are headed "Gridworkz
   Fabless AI Chip Company"; the company is **Kubeworkz**.
2. **`Currency: CA`** — almost certainly a truncation of CAD; the plan seeds CAD and takes the
   default from host config rather than the blueprint's `"USD"`.
3. **JE-055 is self-corrected in place** — it carries a wrong original entry (which credits COGS on
   the debit side and double-credits inventory) followed by a "Corrected Entry". Transcribe from
   the correction only.
4. **Reconcile the scorecard arithmetic on seeding** — workbook 13's two partners are shown as
   composite `0.91 / 5.0` and `0.90 / 5.0`, both graded **F**. That can be right on a 1–5 scale
   with poor dimension scores, but the weighted dimensions listed alongside read closer to 1/5
   each; check the scale and rounding against the scorecard's own grade mapping before seeding a
   policy.
5. **Workbook 18 is not accounting** (see above) — the only section excluded on content grounds.

## Re-deriving this ledger

The verdicts are auditable in seconds and should be re-checked whenever the ERP estate moves (the
WS-ERP doc went stale exactly this way — it says E8 "DONE" while the tree carries E38).

<!-- The fence below is deliberately `text`, not `bash`: these are audit recipes, not documented
     commands. `Samen.Gen.DocCommands` extracts `bash`/`sh`/`shell`/`console` fences from the docs
     in its `@doc_paths` list and fails CI on any command no probe executes — so if this file is
     ever added to that list, a `bash` fence here would be read as an aspirational command set.
     Do not "fix" the fence back to bash. -->

```text
# every resource the mounted scopes actually ship (the "REUSE" column's basis)
grep -nE "^  defmacro define_" samen_core/lib/samen/scopes/finance/blueprint.ex \
  samen_core/lib/samen/scopes/finance/budget_blueprint.ex \
  samen_core/lib/samen/scopes/finance/credit_note_blueprint.ex \
  samen_core/lib/samen/scopes/inventory/blueprint.ex \
  samen_core/lib/samen/scopes/inventory/blueprint_e6.ex \
  samen_core/lib/samen/scopes/banking/blueprint.ex \
  samen_core/lib/samen/scopes/hr/blueprint.ex

# which scopes a host actually MOUNTS (the "Today" column's basis)
grep -rhoE "use Samen.Scopes.[A-Za-z.]+" samenerp/lib/ | sort -u

# the dormant-code claim: a scope with no macro, no blueprint, no mount, no test
for s in consolidation expenses quality planning pos ecommerce elearning appointments \
         documents iot custom_fields; do
  printf "%-14s scope=%s blueprint=%s\n" "$s" \
    "$([ -f samen_core/lib/samen/scopes/$s.ex ] && echo yes || echo NO)" \
    "$([ -f samen_core/lib/samen/scopes/$s/blueprint.ex ] && echo yes || echo NO)"
done
```

If a line above starts returning `yes`, this ledger's REUSE/ADD verdicts for the affected workbook
are stale — fix the ledger in the same pass that landed the change.
