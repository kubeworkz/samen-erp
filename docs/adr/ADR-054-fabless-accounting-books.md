# ADR-054 — The fabless accounting books: a cost-object seam on the GL, fiscal periods and
# close control, lots as supplier-located stock, standard costing as a variance layer, schedules
# for deferral and amortization, grants as a fund dimension, and a bounded forecast — extending
# the ADR-049 ERP base scopes to run one real company's books

- **Status:** **PROPOSED (2026-10-27) — design filed with its build plan; build NOT STARTED
  (phase 0 only: this ADR + the coverage ledger). No code authored, no abbrev rows reserved.**
  The eighteen decisions below are the operator's to ratify; the ones that are genuinely operator
  calls rather than engineering consequences are flagged in "Awaiting ratification" below.
- **Date:** 2026-10-27
- **Context:** the operator supplied `docs/chip_manufacturing_accounting_setup.md` (6,168 lines,
  18 workbooks) — the accounting policy and procedure manual for **Kubeworkz**, a fabless
  semiconductor design house — and asked for a plan to make it real books in samenerp, expecting
  that accounting features would need to be added or altered. The audit that grounds this ADR is
  `docs/ws-acct/design.md` §0, and it found three things that decide the shape of the work:
  (1) the estate is **larger but more fragile** than WS-ERP's own build plan claims — the plan ends
  at E8 "DONE" while the tree carries phases to **E38**, and **E13–E38 are not scopes at all** (no
  scope macro, no blueprint, no domain, no mount, no test: dormant shelf-ware that a grep will
  mislead you into reusing); (2) the **chart of accounts is DATA, not code** — the doc's COA maps
  1:1 onto the shipped `Account` resource including its credit-normal contra account, so opening
  the books is a seed; and (3) the ledger has **no cost-object seam** — `JournalLine` carries only
  `debit_cents`/`credit_cents`/`memo` plus its entry/account FKs, though `docs/ws-erp/design.md`
  §2.1 specified `dimension_refs`, and every JE in the doc is dimensioned by chip programme or cost
  pool. Two smaller findings also bite: `PostingAccount.key` is a closed **four**-value enum where
  the doc's flows need ~two dozen meanings, and **Hr is not mounted in samenerp**, so payroll has
  nowhere to post from in-app.
- **Deciders:** the operator (this design authored per the request; the 18 decisions are filed for
  ratification — the workstream is not started until they are ruled on).
- **Consumes:** ADR-049 (the ERP base scopes this extends — its §2 event-sourcing discipline,
  §6.3 reconciliation spine and §7 honesty list all carry forward unamended), ADR-004 (scope
  packaging), ADR-014/024/026 (fail-honest adapters — the tax/payroll boundaries), ADR-018
  (rollups), ADR-023 (the sanctioned abbrev allocator), ADR-040 (the approvals Gate + lifecycle
  substrate), ADR-041 (canonical work objects + the object-ref anchor), ADR-002 (the hash-chained
  audit that sits over a ledger), ADR-015 (the default-deny CDC classifier the new jsonb must
  respect), ADR-016 (the masking-aware kit/surface posture).

## Decisions

**Numbering.** These eighteen are the normative ADR decisions. `docs/ws-acct/design.md` §1 states
sixteen of them as **D1–D16** in a different order and `docs/ws-acct/build-plan.md` cites those
D-numbers, so both numberings are live and neither is a typo: ADR **1–10 = D1–D10**; ADR **11**
(cost allocation) is specified only in the build plan's Phase 10; ADR **12–13 = D11–D12**; ADR
**14** (the PII / masking posture) is design §4, promoted here because it binds two new surfaces;
ADR **15 = D15**; ADR **16 = D13**; ADR **17 = D14**; ADR **18 = D16**.

1. **The cost-object seam is a bounded jsonb on `JournalLine`; cost objects are a Tier-0 row.**
   `JournalLine` gains `dimension_refs` guarded by a new `Samen.Scopes.Finance.DimensionGuard`:
   keys are drawn from a **frozen four-key vocabulary** (`project` · `lot` · `fund` ·
   `cost_pool`), every value is a **same-org `CostObject` id** (`SameOrgFk` at value level), and
   the map is **ids only — never free text, never a name** (the rule that stops a cost-object join
   becoming a de-anonymisation channel). `CostObject` is a new Finance Tier-0 row
   (`code`/`name`/`kind ∈ {:project, :chip, :cost_pool, :fund}`), org-scoped, archivable, unique
   `code` per org. Rejected: four nullable FK columns per analysis axis (schema sprawl that grows
   with every axis and hard-couples Finance to four resource shapes); reusing `Work.Project` (a
   GP180MCU lot or a grant fund is not a task project, and the kernel posture is plain-uuid
   cross-scope references with no runtime coupling). **Every dimensional report is a `GROUP BY`
   over the append-only lines — derived, never stored.**
2. **`PostingAccount.key` widens in place and stays closed.** The enum grows from four meanings to
   the ~two dozen the doc's flows need (WIP by stage, finished goods, deferred revenue, grant
   deferral, accrued liabilities, inventory reserve, amortization + accumulated amortization,
   depreciation, write-down, the four variance accounts, mask/EDA expense). Fail-honest is
   preserved: an unmapped meaning still refuses the posting, because accounts are a host decision
   and are never invented by the scope. The change is a bounded migration + CHECK update +
   fixture/golden refresh — it is an **alteration of shipped structure**, not a new feature.
3. **Lots and foundry WIP reuse the stock ledger.** New `Lot` (`code`, `item_id`, `supplier_id`,
   `stage ∈ {:design, :mask, :fab, :dice, :assembly, :test, :delivered}`, `wafer_count`,
   `die_expected`, `die_actual`, `fab_order_id`) plus `Warehouse.kind ∈ {:owned, :consignment,
   :supplier}` — so **wafers at the foundry are stock at a supplier location**, and "WIP – Foundry"
   is a GL *presentation* of that stock valued by the existing moving-average ledger. A parallel
   WIP register is refused: ADR-049 §4 makes stock a ledger, and a second register would be a
   second truth that can disagree. Integer base-UOM stays binding (wafers and dies are countable —
   no schema change).
4. **Standard costing is a variance layer, never a second valuation.** `Item.unit_cost`'s moving
   average remains the one stock valuation. Standards ship as `CostStandard` + `CostStandardLine`
   (per item × cost element: standard qty, standard price, expected yield); the engine computes
   PPV, yield, labor-rate, labor-efficiency, overhead-spending, overhead-volume and BOM variance
   per period per cost object; variances post as **their own** journal entries into the variance
   accounts under a declared disposition policy (write off vs capitalize); cost-of-yield is a
   derived read. **A standard never revalues the stock ledger** — that would be the two-truths
   failure the spine exists to prevent.
5. **Deferred revenue and recognition schedules are one mechanism with two methods.**
   `RevenueSchedule` (anchored by ADR-041's `source_ref`) carries `total_cents`, `start_on`,
   `months`, `method ∈ {:straight_line, :cost_incurred}`, with `recognized_to_date` **derived**
   from posted recognitions, and one Automation-driven run posting each period exactly once (the
   E2 partial-unique anchor pattern). `:straight_line` covers the doc's deferred board sale;
   `:cost_incurred` covers grant revenue recognized as allowable costs are incurred. No ASC 606
   multi-element contract engine (see the honesty list).
6. **Accruals are a posted pair with a linked automatic reversal.** A `:post_accrual` action
   creates the accrual and its linked reversal (`reversal_of_entry_id`, the `VoidGuard` reversing-
   entry precedent reused), with an Automation job posting the reversal on its date. This encodes
   the doc's own control ("reverse all month-end accruals on the first day of the following month
   to avoid double-counting") as mechanism rather than habit.
7. **Fiscal periods, with close control enforced at the posting gate.** New `FiscalPeriod`
   (`year`, `month`, `status ∈ {:open, :soft_closed, :closed}`, `closed_at`, `closed_by`), and
   `PostGuard` extended so a post dated inside a **`:closed`** period is refused — at the DB belt,
   not only the Ash guard. `:soft_closed` refuses posts carrying a **document** `source_ref` while
   still admitting journal-only close adjustments, because a close is not an instant: the
   checklist's early days need the document window shut before the adjustment window is.
   `CloseRun` is one row per period, with the doc's ten phases as **Work tasks anchored to it**
   (ADR-041's object-ref — no new task engine) and the doc's twelve role assignments.
8. **Grants are a document plus a fund dimension, not a fund-accounting subsystem.** `Grant`
   (`funder`, `program`, `award_ref`, `award_cents`, `period_start/end`, `restricted?`, `status`,
   `budget_id`) reuses **`Budget`/`BudgetLine`** for the grant budget; `GrantMilestone`/`GrantClaim`
   carry dues, claims and evidence. Fund accounting is the `fund` dimension (decision 1) plus a
   `CostObject(kind: :fund)`; compliance reporting is a **read**, and the grant personnel report is
   a masking watch-list surface (Decision 14). The grant *application tracker* is a small,
   separate `GrantOpportunity` row — CRM `Opportunity` remains the sales pipeline's source of
   truth, per ADR-049 §6.1's precedent of not bending one scope's SoT into another's.
9. **Asset schedules are derived; the run is exactly-once per period.** New `Asset` (`kind ∈
   {:intangible, :equipment}`, cost, `acquired_on`, `method ∈ {:straight_line}`, `life_months`,
   salvage, status, disposal) with **no schedule table** — the schedule is derived from
   `{cost, life, method, start}` and a monthly run posts once per period behind a period-keyed
   anchor. This lifts ADR-049 §7.9's explicit deferral ("fixed-asset depreciation schedules —
   P2") for the one asset class the doc's books require: the photonics PDK licence and lab
   equipment.
10. **Obsolescence is a policy row plus a gated write-down, never an automatic posting.**
    `InventoryReserve` (`basis ∈ {:age, :item}`, `age_months`, `pct`, `applies_to`); the quarterly
    assessment is a derived read that **drafts** a write-down entry, which a human clears through
    the ADR-040 Gate. NRV is an estimate, and auto-posting an estimate into the GL is the kind of
    claim the fail-honest rules exist to prevent.
11. **Allocation is one reusable step, not per-document arithmetic.** One AP bill's cost allocates
    across N cost objects by a declared basis (die-area share, wafer share, or headcount for
    labour), posting **once to N cost objects** — never N posts — with shares summing exactly to
    the invoice total (rounding may not lose or invent a cent). This is what the doc's MPW
    mask/wafer-cost-across-designs policy needs. It generalizes the *pattern* of the shipped
    `inventory/landed_cost_allocator.ex`; it does not reach into any dormant set.
12. **Forecasting is a bounded driver model with append-only versions.** `ForecastVersion`
    (`version`, range, `status ∈ {:draft, :published, :archived}`, `scenario_weights`) plus
    `ForecastDriver` rows (the doc's driver tree: slot price, die yield, EDA spend, headcount, burn,
    grant pipeline). The rolling P&L, cash flow, runway, scenario comparison, variance-to-forecast
    bridge and forecast-accuracy reads are all derived; rolling **appends** a version and a
    `:published` version is immutable. **No formula engine** — the doc's Excel reference specifies
    *which arithmetic*, not a request for a spreadsheet evaluator. This lifts ADR-049 §7.8's
    deferral ("revenue forecasting — P3") for a driver-based, non-revenue-forecasting scope.
13. **The board pack ships its numbers, not its prose.** Exec snapshot, condensed statements, KPI +
    variance bridge, runway waterfall and the variance appendix are reads over the ledger and
    rollups, exported through the existing bounded `Csv` posture with the `Samen.Web.Erp` registry
    extended by declaration. Risks, commentary and board resolutions stay **authored documents** —
    generating narrative from numbers is not a capability this ADR claims.
14. **The ledger stays PII-free; the two PII-adjacent surfaces carry the masking trio.** Every new
    accounting resource is bounded ids/enums/integers/dates, and `dimension_refs` carries ids only
    (decision 1) — which is precisely what keeps the cost-object join from becoming a
    de-anonymisation channel. Two new surfaces are PII-adjacent and each needs the full
    green/red/sabotage trio via `Samen.MaskingCase`: the **grant personnel report** (resolving
    through `Samen.Api.PiiResolution` on the actor's plane, or reporting bounded employment facts
    only — no third path) and **supplier contacts** (which stay vaulted in `SalesOps.Vendor`; the
    scorecard and risk resources reference `vendor_id` and never re-declare the person).
15. **Single functional currency (CAD), set by host config.** The doc's header reads "Currency:
    **CA**" while `Account.currency` defaults to `"USD"`. The default comes from host config and
    Kubeworkz's org is seeded CAD. `ExchangeRate`/`FxConvert` serve converted *reporting*;
    revaluation and FX gain/loss stay deferred (ADR-049 §7.3 unchanged).
16. **Consolidation stays dormant; single-entity is the default.** Kubeworkz is one legal entity.
    `samen_core/lib/samen/scopes/consolidation/*` (E24) is dormant and unwired, and is the
    documented path **when** a second entity exists — not a phase here. The doc's "multi-entity
    consolidation" ERP requirement is answered as: the module set exists, unwired, and the books do
    not need it yet.
17. **Labour cost is allocated by timesheet share, which prices the wiring of E15 into Work.**
    The doc dimensions design-engineering labour by chip; the only truthful source for that split
    is timesheets, and `scopes/work/timesheet_{entry,guard,summary}.ex` (E15) are **dormant**. So
    this is *wiring* work, not a reuse: `Samen.Scopes.Work` grows the timesheet resources and a
    cost-object dimension, and the payroll posting allocates `PayRun` cost by timesheet share. If
    the operator declines, the fallback is a documented manual ratio per posting — stated, never
    silently dropped.
18. **The books are seeded under `Kubeworkz`, and the source manual's figures are placeholders.**
    The doc names a template entity ("Gridworkz") and carries an LLM-assembled manual's artefacts
    — `Currency: CA`, a self-corrected journal entry (JE-055 has a wrong original and a "Corrected
    Entry"), and figures that are illustrative rather than Kubeworkz's actuals. The **structure**
    ships; the numbers are seeded as reviewable defaults the operator replaces with real policy
    values, and the ledger is transcribed from the manual's corrected forms — never verbatim.

## Consequences

- **Nothing existing is re-scoped.** Every addition lands in the shipped Finance, Inventory and
  Work scopes via their own blueprints (ADR-004); no host forks, and the ledger remains web-free.
  The changes to *shipped* structure are exactly four and all are widenings: `JournalLine` gains
  `dimension_refs`; `PostingAccount.key`'s enum widens; `Warehouse` gains `kind`; `PostGuard` gains
  the period rule. There is no new ledger, no new quantity mechanism and no new reporting engine.
- **The keystone sequence is binding.** Decision 1 precedes every dimensional phase and decision 2
  precedes every new posting, so the build order is not free: the seam lands first, then the books
  are opened, then the cost model. A phase that starts dimensional work before the seam is
  misplaced, not merely early.
- **Six new reconciliation invariants extend ADR-049 §6.3** — R6 per-cost-object balance, R7 WIP↔lot,
  R8 standard↔actual, R9 recognition↔deferred, R10 close↔period, R11 grant↔fund — each shipping a
  green test, a red-path twin and a committed sabotage patch, per the house discipline that a
  guarantee is only claimed when its refutation is replayed.
- **Abbrev budget:** ~25 new resources ≈ 25 registry rows, reserved per phase through the sanctioned
  allocator (ADR-023) and never hand-edited — the largest registry movement since WS-ERP, and
  therefore the most likely place to break a golden.
- **Dormant code is not reuse.** E13–E38 have no scope macro, no blueprint, no mount and no test;
  a reader who greps "consolidation" or "expenses" finds code that *looks* built. ADR-049 §1's
  scope-count decision therefore stands unamended — this ADR adds no scope macro at all. Whether
  the ~26 dormant sets should be deleted or completed is explicitly **out of scope here** and
  carried as a separate hygiene item.
- **The honesty list carries forward and grows.** ADR-049 §7 remains binding (payroll computation,
  tax filing, FX revaluation, serials/fractional UOM, scheduling, leave accrual), and this ADR adds
  its own refusals: no ASC 606 multi-element contracts, no formula engine, no generated narrative,
  no intercompany elimination (decision 16), no payroll computation in the GL. Where this ADR lifts
  a deferral it is named and bounded — depreciation (decision 9) and driver-based forecasting
  (decision 12) — and neither is the full generality ADR-049 parked.

## Awaiting ratification

Filed for the operator; the workstream does not start until these are ruled on. Most of the eighteen
are engineering consequences of the doc plus the existing architecture — the line needs an analysis
seam (1), the posting map must be able to name the doc's pools (2), a foundry lot has to be stock
somewhere (3), and a standard must not become a second valuation (4). The operator-facing calls are:

1. **Decision 1's axis vocabulary** — is the frozen four-key set (`project` · `lot` · `fund` ·
   `cost_pool`) the whole analysis surface Kubeworkz needs, or should a fifth axis be reserved now
   (a migration is cheaper than a vocabulary change later)?
2. **Decision 4's disposition policy** — write off variances to the P&L, or capitalize them into
   inventory? The doc names both as live options; the books cannot be closed until one is chosen.
3. **Decision 10** — confirm that an NRV write-down must stay human-cleared (never scheduled).
4. **Decision 15** — confirm CAD as the functional currency and the single-currency posture.
5. **Decision 17** — authorize (or decline) the timesheet wiring into the Work scope, which is the
   difference between labour cost per chip being a fact and being a stated ratio.
Two further confirmations — scope questions rather than decisions:

- **The source manual's §"E1–E5 Items Overview"** (doc line 5912: an MLPerf-style acceptance model,
  ONNX quantization, golden vectors, power/energy measurement boundaries) is **not accounting** and
  is excluded from this workstream pending confirmation that it came from a different conversation.
- **The coverage ledger's completeness** — `docs/ws-acct/kubeworkz-books.md` accounts for all 18
  workbooks; if a workbook is missing from it, the ledger is wrong, not the doc.
