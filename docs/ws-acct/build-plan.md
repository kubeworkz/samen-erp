# WS-ACCT — the Kubeworkz books · Build Plan

- **Status:** Buildable. **Phase 0 is COMPLETE (2026-10-27) and ADR-054 is ACCEPTED** — all
  eighteen decisions taken, the five operator-facing calls ruled in the ADR's "Ratification"
  section. Phases 1–16 are not started. Follows `docs/ws-acct/design.md` + ADR-054, whose build
  half this plan is.
- **Date:** 2026-10-27
- **Sizing principle:** SMALL serialized units — each banks in ~15–30 min and each **PHASE** is
  independently committable + gate-able (WS-B/WS-ERP convention). Default fan-out concurrency 1.
- **Gate cadence:** adversarial phase-gate after each phase; workstream-wide re-gate at Phase 16.
- **The standing gate target** is the extended spine (design §3, R6–R11): every new mechanism
  ships its R-invariant as a green test **+ a red-path twin + a committed sabotage patch**.

---

## Dependency graph

```
Phase 0 (ADR-054 + coverage ledger, doc-only)
   └──> Phase 1 (the cost-object seam + the posting map)   ← THE KEYSTONE
           ├──> Phase 2 (open the Kubeworkz books: COA/posting/cost-object seed)
           ├──> Phase 3 (fiscal periods + close control, R10)
           ├──> Phase 4 (lots + supplier WIP, R7)
           │      ├──> Phase 5 (accruals + auto-reversal)
           │      ├──> Phase 6 (deferred revenue + recognition schedules, R9)
           │      ├──> Phase 7 (standard costing + variance, R8)   ← largest
           │      └──> Phase 10 (cost allocation: MPW mask/wafer across chips)
           ├──> Phase 8 (asset register + amortization/depreciation runs)
           ├──> Phase 9 (obsolescence / NRV reserve)
           └──> Phase 11 (grants + restricted funds, R11)
Phase 3 + 7 + 11 ──> Phase 12 (the close run, executed end to end)
Phase 12 ──> Phase 13 (board reporting package)
Phase 11 ──> Phase 14 (rolling forecast + scenarios + runway)   [parallel-safe with 12–13]
Phase 11 ──> Phase 15 (supplier governance: scorecard/risk/onboarding)  [parallel-safe]
Phase 14 + 15 ──> Phase 16 (the Kubeworkz host proof + workstream gate)
```

Phases 8 ∥ 9 ∥ 11 are independent after Phase 1. Phases 12–15 need the cost model done.
**Nothing dimensional starts before Phase 1.**

---

## Phase 0 — ADR-054 + the coverage ledger · default · doc-only — **DONE (2026-10-27)**

Landed as commit `b55c5799`: the ADR (ACCEPTED, eighteen decisions, all ratified), the coverage
ledger, the pair indexed in `docs/README.md`, and ADR-054's row in `docs/adr/README.md` (total
54 → 55) — verified by `samen_core/test/adr_index_test.exs` (all four checks) +
`doc_commands_test.exs` (18 passed) and `scripts/eol_preflight.sh` (exit 0).

The original scope:

Write `docs/adr/ADR-054-fabless-accounting-books.md` (design §1 D1–D16 as numbered decisions).
Write `docs/ws-acct/kubeworkz-books.md`: the doc's 18 workbooks mapped to *ships-with* — the
permanent answer to "where is workbook N implemented?", so the source manual is never re-grepped.
**Also (hygiene, 1 line each):** index the pair in `docs/README.md`'s workstream section.
**Gate:** doc-only; claim-sweep clean; **no abbrev rows touched**; no code.

**AC:** ADR-054 exists with all eighteen decisions and every operator-facing call ruled; the
coverage ledger names every one of the 18 workbooks with a verdict (reuse / alter / add /
reference / out-of-scope). **MET.**

---

## Phase 1 — THE KEYSTONE: the cost-object seam + the posting map · opus · 2–3 sessions

1. **`CostObject`** (Finance Tier-0): `{code, name, kind ∈ {:project, :chip, :cost_pool, :fund}}`,
   org-scoped, `code` unique per org, archivable, no PII.
2. **`JournalLine.dimension_refs`** (jsonb) + **`Samen.Scopes.Finance.DimensionGuard`**:
   - keys ⊆ the frozen vocabulary `["project", "lot", "fund", "cost_pool"]` — an unknown key is
     REFUSED (fail-closed: the analysis axes are a kernel decision, not caller input);
   - every value is a **same-org `CostObject` id** (`SameOrgFk` at value level) — a cross-org
     dimension is refused;
   - **ids only** — a free-text value is refused, which is what keeps the dimension from becoming
     a de-anonymisation channel (design §4);
   - the guard runs on the LINE create path and in-transaction with the entry's balance check.
3. **`PostingAccount.key`** widened per design D2 (bounded enum + migration/CHECK + fixtures).
4. **R6 + sabotage 403**: the per-cost-object balance invariant. The sabotage posts an entry that
   balances org-wide but not within a cost object → R6's named assertions flip → byte-exact revert.

**AC:** `mix test` green on the finance suites with **zero warnings**; R6 green + red + sabotage
certified through `bash scripts/sabotage.sh --range 403-403`; abbrevs reserved via the allocator
(registry goldens updated); `MIX_ENV=test mix samen.verify.catalog_parity` +
`samen.verify.migrations` green.
**Do NOT** land the COA before this — books nobody can report on are worse than no books (design §7).

---

## Phase 2 — Open the Kubeworkz books · default · 1–2 sessions

**This phase is data, not schema** (design §0.3). A seed task
(`samenerp/lib/mix/tasks/kubeworkz.books.ex`, or extending `samenerp.seed`):
- the doc's COA transcribed from its **corrected** forms (design D16) — `1000`…`8000` + the
  fabless variant, including the credit-normal contra `1510`;
- `PostingAccount` rows binding every new meaning from Phase 1 to a real COA row;
- `CostObject` rows for the four programmes (RISC-V64 SoC, GPU, PTA, PDB) + cost pools
  (foundry, photonics, assembly & test, board BOM) + a placeholder fund;
- a `Budget`/`BudgetLine` skeleton for the current fiscal year;
- functional currency CAD (design D15).
**Deliverable:** a test asserting the doc's codes, the four cost objects and every posting meaning
resolve on a freshly seeded org — i.e. **the books are open**.

**AC:** seed idempotent (re-runnable, no duplicate rows); the seed test green; the ERP `:coa`
surface renders the seeded chart.

---

## Phase 3 — Fiscal periods + close control (R10) · opus · 1–2 sessions

`FiscalPeriod` + the `PostGuard` extension (design D7): `:closed` refuses any post dated inside it
(the DB belt as well as the Ash guard — a raw-SQL post into a closed period is refused);
`:soft_closed` refuses posts carrying a document `source_ref` while admitting journal-only
adjustments. `CloseRun` per period. **R10 + sabotage 404.** Also: a `samen.verify` read or an
extended guard test that a period cannot be un-closed (one-way state machine, the `PostGuard`
precedent).

**AC:** R10 green + red + sabotage; the one-way close transition red-proven; existing AP/AR/stock
postings unaffected on open periods (no regression in the E1–E8 suites).

---

## Phase 4 — Lots and foundry WIP (R7) · opus · 2 sessions

`Lot` + `Warehouse.kind ∈ {:owned, :consignment, :supplier}` (design D3). Foundry/photonics WIP =
stock at a `:supplier` warehouse, so **the stock ledger remains the only quantity truth**. A `lot`
dimension path onto the ledger's `ref`; the WIP-by-lot read (Σ stock value by lot == Σ GL by lot).
**R7 + sabotage 405:** a lot whose stock and GL legs disagree.

**AC:** R7 green + red + sabotage; a foundry receipt at a `:supplier` location moves WIP without
touching a second register; `ReconcileStock` still green (no regression).

---

## Phase 5 — Accruals with automatic reversal · default · 1 session

`:post_accrual` creating the accrual + its linked reversal (design D6), the Automation job posting
the reversal on its date, exactly-once (the `PaymentReceipt` anchor pattern). Covers JE-024/025,
JE-060/061, JE-064.

**AC:** a reversal cannot post twice (red-proven); an accrual in a `:closed` period cannot be
created (Phase 3's guard holds); the pair nets to zero across the period boundary.

---

## Phase 6 — Deferred revenue + recognition schedules (R9) · opus · 1–2 sessions

`RevenueSchedule` with `method ∈ {:straight_line, :cost_incurred}` + the period recognition run
(design D5). `:cost_incurred` reads incurred allowable cost — for grants this is the same read
Phase 11's R11 uses, so **build it once, here**. **R9 + sabotage 406:** double-recognition.

**AC:** a schedule's derived `recognized_to_date` == Σ posted recognitions; straight-line and
cost-incurred both proven; a zero-incurrence period recognizes zero (the fail-honest red path —
never recognizes ahead of cost).

---

## Phase 7 — Standard costing + the variance engine (R8) · opus · 3–4 sessions ← the largest

`CostStandard` + `CostStandardLine` (per item × cost element: standard qty, standard price,
expected yield). The engine (design D4) computes per period per cost object: **PPV**, **yield**,
**labor rate**, **labor efficiency**, **overhead spending**, **overhead volume**, **BOM**
variance; the **disposition policy** posts them into the variance accounts under the manual's
**per-type table, adopted verbatim** (ADR-054 D4 + Ratification 2): yield and PDB BOM variances
**absorb into inventory**, PPV and overhead volume write off to **COGS**, labour rate/efficiency
and overhead spending write off to **R&D expense**, and residual balances close at year-end.
**R8 + sabotage 407** — a variance posting that does not tie to its standard card, and the
disposition variant: a yield variance **written off instead of absorbed** must also flip, because
R8 asserts each variance reaches the account its row names, not merely that the arithmetic nets.
The **cost-of-yield** and **COY dashboard** reads.
Standards **never** revalue stock (D4): a regression test asserts `Item.unit_cost`'s moving
average is untouched by a standard-cost run.

**AC:** every one of the doc's variance classes is computable and shown in a read; R8 green + red
+ sabotage; the disposed variance survives the period close.

---

## Phase 8 — Asset register (intangibles + equipment) · default · 1–2 sessions

`Asset` + **derived** schedules + the monthly `DepreciationRun` (design D9), exactly-once per
period behind a period-keyed anchor. Covers JE-003/004 (PDK license over 36 months) and JE-063
(lab equipment). No schedule table — the derived-state discipline.

**AC:** amortization accumulates to the contra account and rolls off at end-of-life (red-proven:
idempotent re-run, and a disposal that stops the run); the PDK license schedule reproduces the
doc's JE-004 arithmetic exactly.

---

## Phase 9 — Obsolescence / NRV reserve · default · 1 session

`InventoryReserve` policy + the quarterly assessment read + a **gated** drafted write-down
(design D10). Covers JE-034/062 into `8000`.

**AC:** an assessment drafts but never auto-posts; the Gate refuses an ungated write-down; the
reserve read flags age-eligible stock without mutating it.

---

## Phase 10 — Cost allocation, and the labour driver · default · 2–3 sessions

**Unit 10.1 — the allocation step.** The doc's policy §3.3 ("define a methodology for allocating
the cost of a single MPW shuttle across multiple chip designs"). Generalise the *pattern* from the
E14 landed-cost allocator (`inventory/landed_cost_allocator.ex`) into a reusable allocation step:
allocate one AP bill's cost across N cost objects by a declared basis (**die area share**, wafer
share, or effort share for labour). NOTE (design §0.2): E14 itself is wired and reusable as a
*pattern*, but this is a new Finance-side allocation — do not reach into the dormant sets.

**Unit 10.2 — the labour driver (ADR-054 D17, ratified).** **Author** timesheet capture inside the
SHIPPED `Samen.Scopes.Work` scope — blueprint resources, migration, host mount, surfaces, plus a
`cost_object` dimension — so payroll cost allocates by **timesheet share** rather than a headcount
ratio. NOTE (ADR-055 §6): the dormant `scopes/work/timesheet_{entry,guard,summary}.ex` (E15) stubs
are **deleted** by that ruling rather than wired — no migration, no reference and no test, so
"wiring" them meant auditing and re-shaping them first; authoring fresh is the cheaper and honest
path, and the labour-driver decision is unaffected (only its starting point changes). This unit is
load-bearing, not polish: Phase 7's labour rate/efficiency variances and Phase 11's grant
cost-incurred recognition are **not facts** without actual hours. It therefore lands **before
those legs are allowed to claim anything**, and every labour-derived figure stays labelled
ratio-based until it does (the binding proviso in ADR-054 Ratification 5).

**AC:** one mask invoice allocates across the RISC-V64/GPU/PTA programmes with the shares summing
to exactly the invoice total (red path: rounding must not lose or invent a cent); the allocation
is dimension-only (it posts once, to N cost objects — never N posts).

---

## Phase 11 — Grants + restricted funds (R11) · opus · 2–3 sessions

`Grant`, `GrantMilestone`/`GrantClaim`, the `fund` dimension end-to-end, `Budget` reuse for the
grant budget, `GrantOpportunity` (the tracker). Recognition by `:cost_incurred` (Phase 6).
Compliance reporting as a read. **R11 + sabotage 408.** **The grant personnel report is a masking
watch-list surface** — full green/red/sabotage trio (design §4).

**AC:** R11 green + red + sabotage; fund postings reconcile to recognized grant revenue and to
claimed allowable costs; the personnel report's red leg refutes both plaintext and `vt_` tokens
in DOM/CSV/API.

---

## Phase 12 — The close run, executed end to end · default · 2 sessions

`CloseRun` + the doc's ten phases as Work tasks anchored to it, with the twelve role assignments.
The deliverable is an **executable walkthrough** (`samenerp/test/close_walkthrough_test.exs`) that
drives one real month through the checklist: cut-off → AP/AR → inventory & WIP → accruals →
grants → variance → reconciliations → statements → forecast roll-in → reporting, with the close
dashboard read at the end. Soft-close must block new documents and admit adjustments (Phase 3).

**AC:** the walkthrough passes on the host; a document posted after soft-close is refused; the
close dashboard reports the period's completeness honestly (an open task shows as open, never as
done).

---

## Phase 13 — Board reporting package · default · 1–2 sessions

Reads/rollups for the doc's Pages 1–3 and 6 (exec snapshot, condensed statements, KPI + variance
bridge, runway waterfall, variance appendix) + a bounded export through the existing `Csv`
posture. Narrative pages and resolutions stay authored (design D12). Extend the
`Samen.Web.Erp` surface registry by declaration (closed allowlist, no export path per surface).

**AC:** every number on the pack traces to a ledger/rollup read (no hand-figured sheet); the new
surfaces render no PII column; a k-anon floor holds on any cohort view (the `%Suppressed{}` path).

---

## Phase 14 — Rolling forecast, scenarios and cash runway · opus · 2–3 sessions

`ForecastVersion` (append-only, `:published` immutable) + `ForecastDriver` rows (design D11) +
reads: rolling P&L, cash flow, runway, scenario comparison, **variance-to-forecast bridge** and
forecast-accuracy tracking. No formula engine.

**AC:** rolling a version appends and never mutates a published one (red-proven); scenario weights
sum to 1 (refused otherwise); runway reads reconcile to the bank/cash accounts; the accuracy read
compares versions without a second store.

---

## Phase 15 — Supplier governance · default · 1–2 sessions · parallel-safe

`SupplierScorecard` (weighted dimensions, quarterly composite + grade) + `SupplierRisk` (5×5
register, mitigation, owner, escalation triggers). Onboarding and the multi-source qualification
roadmap ride **Work** tasks/projects from seeded checklists (reuse — no new task engine).
Supplier contacts stay vaulted in `SalesOps.Vendor`; both new resources reference `vendor_id` and
never re-declare a person (design §4).

**AC:** a composite score derives from its weighted dimensions (red-proven refutability); a risk
row's rating derives from likelihood × impact; **no PII column on either resource**; the
scorecard surface masked-or-omitted per the watch-list discipline.

---

## Phase 16 — The Kubeworkz host proof + workstream gate · mixed · 2–3 sessions

1. **Mount Hr in samenerp** (design §6) — payroll postings become possible in-app.
2. **Replay the whole JE playbook** as one executable host test
   (`samenerp/test/kubeworkz_books_walkthrough_test.exs`): JE-001 → JE-081 across a real fiscal
   period on the mounted host, checking the balances the doc asserts at each stage.
3. **The extended spine re-gate:** R6–R11 re-flipped from the sabotage harness, byte-exact.
4. **Root gate:** `./ci.sh` ends **`ROOT CI: ALL PASSED`**; the workstream-wide adversarial gate
   written up in `docs/gate-ws-acct.md`; claim-evidence + roadmap updated.

**AC:** the playbook walkthrough green on the host; R6–R11 sabotage-certified; root CI ALL PASSED;
the coverage ledger (phase 0) has no workbook left without a verdict.

---

## Sabotage allocation

| Patch | Phase | Flips |
|---|---|---|
| 403 | 1 | R6 — per-cost-object balance |
| 404 | 3 | R10 — the period guard |
| 405 | 4 | R7 — WIP ↔ lot |
| 406 | 6 | R9 — recognition exactly-once |
| 407 | 7 | R8 — variance ↔ standard card, and the per-type disposition |
| 408 | 11 | R11 — grant ↔ fund |

Plus the masking trio's sabotage twin on the grant personnel report (Phase 11) and the
posting-map widening's own red path (an unmapped meaning must refuse) in Phase 1. Numbers are
provisional: the harness discovers patches by filename, and each phase reserves its own at
commit time.

---

## Effort (serialized, includes the phase gates)

| Stage | Phases | Sessions |
|---|---|---|
| Foundations (ADR, seam, books, periods) | 0–3 | 5–8 |
| The chip cost model (lots, accruals, recognition, variance, assets, NRV, allocation, labour driver) | 4–10 | 12–18 |
| Compliance & reporting (grants, close, board pack, forecast, suppliers) | 11–15 | 8–12 |
| Host proof + workstream gate | 16 | 2–3 |
| **Total** | | **~27–41 sessions** (phases 12–15 are parallel-safe in pairs, so wall-clock is shorter) |

---

## Definition of done

1. A freshly seeded org is a **complete set of Kubeworkz books**: the doc's COA, the posting map,
   the four programme cost objects, a budget, standard cards, the grants, and the drivers.
2. Every JE section in the doc's playbook posts through governed machinery, and the whole playbook
   replays as one green host test.
3. Every dimensional question the doc asks (cost by chip, WIP by lot, variance by cost element,
   fund by grant, actual vs forecast) is a **derived read** — no stored balance, no second ledger.
4. R6–R11 are each green **and** refutable through the committed harness.
5. Zero new PII surfaces; the two PII-adjacent surfaces carry the full masking trio.
6. Root `./ci.sh` ends `ROOT CI: ALL PASSED` with the host proof included.
7. The coverage ledger (phase 0) accounts for all 18 workbooks — implemented, reused or explicitly
   out of scope, with nothing silently dropped.

## Carries (do not lose)

- **Do not start a dimensional phase before Phase 1.**
- **Dormant code is not reuse** (design §0.2). Wiring a dormant set is priced work; the ~26-set
  hygiene question is a separate workstream, not a phase here.
- **Standards never revalue stock** (D4). If a phase is tempted to write `Item.unit_cost` from a
  standard, that is R8's sabotage inverted.
- **The disposition table is binding, per variance type** (ADR-054 Ratification 2). Yield and PDB
  BOM variances absorb into inventory; PPV and overhead volume go to COGS; labour and overhead
  spending go to R&D expense. "Variance" is not a single bucket and no phase may net them together.
- **Labour-derived figures are ratio-based until Phase 10.2 lands** and must be labelled so
  (ADR-054 Ratification 5). That covers Phase 7's labour rate/efficiency legs and Phase 11's
  grant cost-incurred recognition — neither may claim a fact before the driver exists.
- **The doc's figures are placeholders** — the *structure* ships; the numbers get reviewed by the
  operator before they are called Kubeworkz's policy (design §7).
- **The doc's §E1–E5 appendix is not accounting** — the operator confirmed its exclusion
  (ADR-054 Ratification 6); it stays out of scope in the ledger.
