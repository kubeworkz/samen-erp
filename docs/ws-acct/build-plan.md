# WS-ACCT — the Kubeworkz books · Build Plan

- **Status:** **COMPLETE and gated GO (2026-11-06)** — Phases 0–16 landed; ADR-054 is ACCEPTED
  (all eighteen decisions taken). The final root run ended `==> ROOT CI: ALL PASSED` with
  `EXIT=0` (**1:59:54**), and the opt-in full 411-patch sabotage sweep passed **411/411**
  (**649 named-test confirmations**, byte-exact restores, **3:02:05**, 2026-11-08); evidence is
  `docs/gate-ws-acct.md`, and the roadmap state is `docs/saas-gap-roadmap.md` §"State after
  WS-ACCT". Follows `docs/ws-acct/design.md` + ADR-054, whose build half this plan is.
- **Date:** 2026-10-27 (phases 1–2 landed 2026-10-28/29; Phase 16 gate 2026-11-06; full sweep
  2026-11-08)
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

## Phase 1 — THE KEYSTONE: the cost-object seam + the posting map · opus · 2–3 sessions — **DONE (2026-10-28)**

Landed as `83708539` (+ `1ef9b303`, the `samenerp/schema.dict.json` refresh the host needed once
Finance grew a table — without it the host's drift baseline rejected the tree). `CostObject`
(`eco_*`), `JournalLine.dimension_refs` (`ecl_dimension_refs`), the frozen four-key vocabulary,
`DimensionGuard` (write) / `DimensionBalance` (R6a whole-entry + R6b per-cost-object, over both the
lines argument and the persisted rows at `:post`) / `DimensionReconcile` (the independent READ
mirror), the posting enum widened in place from four meanings to twenty-three, and **R6 + sabotage
403**. Certified by the full root gate (`ROOT CI: ALL PASSED` on `1ef9b303`).

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

## Phase 2 — Open the Kubeworkz books · default · 1–2 sessions — **DONE (2026-10-29)**

Landed as `Samenerp.Kubeworkz.Books` + `mix kubeworkz.books --org <slug|uuid>` +
`samenerp/test/kubeworkz_books_test.exs` (10 tests). **Data only — no schema, no abbrev rows.**

Four decisions the phase had to take, all recorded in the module's moduledoc:

1. **The reference table wins.** The manual carries two conflicting COAs; the
   `Chart of Accounts Reference` (`1000`…`8000`) is the one every JE in the playbook posts against,
   so its numbering (WIP at `1300`/`1310`/`1320`, *prepaid* at `1200`/`1210`) is what opens. The
   earlier summary's `1200 = WIP` / `1230 = FG` reading is not seeded.
2. **The variance family opens too** (`5100`…`5190`) — the playbook posts to ten accounts, per type
   and per chip. `1520 · Accumulated Depreciation – Lab Equipment` is the ONE row not in the
   manual: JE-063 reuses `1510`, which is already the PDK contra, and `code` is unique per org.
3. **Five meanings stay UNMAPPED on purpose** (`inventory_reserve` + the four `variance_*`): the
   manual gives them no single account, and binding one anyway would post a silently wrong default
   later. The closed enum refuses instead. `Books.pending_meanings/0` states each reason, and the
   suite asserts they are absent from the map.
4. **Drift is reported, never overwritten.** A row that exists but disagrees with the manual lands
   in the summary's `:drifted` list; a re-seed never re-points an operator's edit.

`verify/1` closes the AC honestly: it re-reads the org and fails a bare org with every gap named
(the red path that keeps "the books are open" from being a tautology), then agrees after a seed.
The mounted `:coa` surface renders the seeded chart — and an unopened org still shows the empty
state, never a neighbour's chart.

The original scope:

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

## Phase 3 — Fiscal periods + close control (R10) · opus · 1–2 sessions — **DONE (2026-10-29)**

Landed as `Samen.Scopes.Finance.{FiscalPeriod,CloseRun}` (blueprint
`samen_core/lib/samen/scopes/finance/period_blueprint.ex`), the posting gate
`Samen.Scopes.Finance.PeriodGuard`, the one-way state machine
`Samen.Scopes.Finance.PeriodTransition`, the close-checklist lifecycle
`Samen.Scopes.Finance.CloseRunGuard` over `Samen.Scopes.Finance.ClosePhases`, and the R10 read
mirror `Samen.Scopes.Finance.PeriodReconcile` — plus three migrations (fixture, `samen_web`,
`samenerp`), `samen_core/test/finance_periods_test.exs` (18 tests) and sabotage **404**. Abbrevs
`cfp`/`clr`, `fpe`/`fcr`, `efp`/`efq`, all allocator-reserved.

Five decisions the phase had to take:

1. **A missing period row is OPEN.** The guard adds no obligation to a host that never opens a
   period, which is what keeps every existing AP/AR/stock/sales posting and every existing suite
   byte-for-byte unaffected (the AC's regression clause). Protection is for what is DECLARED.
2. **R10 is checkable only with two stamps, so the read pins them.** Read literally, "no posted
   entry dated inside a closed period" would flag every period the moment it closed — its own
   entries are dated inside it, and they were posted before it closed. The write side gates new
   postings; the read mirror (`PeriodReconcile`) reports the real violation, `posted_at >
   closed_at`, which is the one the write layers cannot see after the fact.
3. **Soft-close lives in Ash only, deliberately.** The database belt implements `:closed` (R10's
   absolute) and does NOT implement soft-close: telling a document anchor from a journal-only
   adjustment is a policy decision that needs the row's source, and a belt that guessed would
   either block the close's own adjustments or admit the supplier bill. That split is what makes
   sabotage 404 attributable — the belt legs stay green while the two Ash-layer legs flip.
4. **A reversal is not a document.** VoidGuard's reversal carries `source_key: "journal_entry"`;
   soft-close admits it (the `@ledger_internal_sources` allowlist), because correcting a fact the
   ledger already holds is exactly the adjustment window soft-close exists to leave open. Without
   the distinction every void in a soft-closed month would be refused.
5. **The gate fails CLOSED on a lookup error.** The first draft treated a period read failure as
   "open"; the suite caught it the other way round — an unreadable period table is not permission.

One pre-existing quirk surfaced and is documented rather than papered over: the posted-born factory
`create_reversal` is only safe when its caller has already armed the `PostingMarker` (AP, stock,
sales and VoidGuard all do). Called standalone its marker restore lands before `EntryLines`' inserts,
so it refuses its own lines. Nothing in the tree calls it that way; the suite calls it the way the
cascades do.

The original scope:

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

## Phase 7 — Standard costing + the variance engine (R8) · opus · 3–4 sessions ← the largest — **DONE (2026-11-01)**

Landed as `Samen.Scopes.Finance.{CostStandard,CostStandardLine,CostVariance}` (blueprint
`samen_core/lib/samen/scopes/finance/variance_blueprint.ex`), the pure arithmetic
`VarianceMath`, the binding policy `VarianceDisposition`, the in-force resolver `StandardCard`,
the run `VarianceEngine`, the posting cascade `VariancePosting`, the R8 read
`ReconcileVariance`, and the two presentation reads `VarianceReport` + `CostOfYield` — plus
three migrations (fixture `fsx`/`fsy`/`fsv`, web `fst`/`fsu`/`fsw`, erp `esc`/`esm`/`esv`),
nine allocator-reserved abbrevs, `samen_core/test/finance_variance_test.exs` (12 tests),
`samenerp/test/variance_standard_cost_test.exs`, and sabotage **407**.

Seven decisions the phase had to take:

1. **A measured zero IS a fact; an unmeasured class is not.** A class the card measures is
   recorded even when its difference is exactly nil — "March's labour variance was nil" is a
   real period-end finding, and the row is the run's marker, so a retry is a clean no-op even
   after a zero-variance period. A class the card has no line for records nothing. Only a
   non-zero row posts an entry; a measured-zero row names its accounts and posts none. This is
   why the phase needs no separate `VarianceRun` header: the rows are the run.
2. **The card in force is resolved TWICE, deliberately.** The engine resolves it and refuses
   any other card (`:standard_not_in_force`); R8 re-resolves it independently and flags
   `{:off_card, …}`. The sabotage removes the engine guard (the plausible "the caller passes
   the right card" deletion); only R8's independent resolution then catches the retroactive
   repricing.
3. **Four family variance accounts, per-type + per-chip detail as a dimension.** The manual
   carries ten variance rows (per type AND per chip); ADR-054 D2 carries four meanings. The
   four families hold the postings, the variance ROW keeps the type, and the cost object rides
   both entry legs (`dimension_key => cost_object_id`, which also keeps R6 exact). Phase 2's
   five pending meanings resolved here: `variance_ppv/yield/labor/overhead` now bind to the
   manual's family heads (5100/5120/5150/5180) and the two disposition targets arrived as
   `:cogs` (5000) and `:rd_expense` (6020); `inventory_reserve` remains pending for Phase 9.
4. **A variance row NAMES its accounts.** The posting cascade forces `variance_account_id`,
   `disposition`, `disposition_account_id` and `entry_id` onto the row, so R8 compares the
   posting to the row without re-deriving policy. The table itself is pinned by the suite's
   policy assertion — a hand-inserted row and a row whose entry pays a different account are
   the read's independent red paths.
5. **Inputs are strict, fail-honest.** Every card line must carry an actual
   (`:missing_actual_line`) and every actual must name a card line (`:unknown_actual_line`); a
   cost the period did not report is not zero, it is unknown. An empty card is refused too.
6. **Labour is labelled, per the ADR's binding proviso.** Until Phase 10's timesheet driver,
   the report carries `labour_basis: :declared_pending_driver`; no surface presents a labour
   variance as a fact before then.
7. **Standards never revalue stock, and the host test proves it.** The samenerp regression
   records a real receipt (moving average 300 000), runs a variance, and asserts
   `StockLevel.avg_unit_cost_cents` / `stock_value_cents` / `qty_on_hand` are byte-identical.

The original scope:


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

## Phase 8 — Asset register (intangibles + equipment) · default · 1–2 sessions — **DONE (2026-11-01)**

Landed as `Samen.Scopes.Finance.{Asset,AssetPosting}` (blueprint
`samen_core/lib/samen/scopes/finance/asset_blueprint.ex`), the pure derived schedule
`AssetSchedule`, the posting cascade `DepreciationPosting`, the run `DepreciationRun`, the
monthly `DepreciationWorker`, the register read `AssetRegister`, the independent audit
`ReconcileAssets`, and the two guards `AssetShape`/`AssetDisposal` — plus three migrations
(fixture `fsf`/`fsp`, web `fas`/`fad`, erp `eas`/`ead`), six allocator-reserved abbrevs,
`samen_core/test/finance_assets_test.exs` (24 tests), the Kubeworkz asset seed + host test, and
sabotage **408**. The 2026-11-14 extension adds `AssetEntry`, the `AssetCreate`/
`AssetTransfer`/`AssetInService` lifecycle changes, one ALTER migration per host, and the eleven
lifecycle tests (disposal gain/loss, CIP, pre-ledger transfer, two failure-rollback cases, the
posted-period disposal refusal, two transfer-restriction red paths, and two legacy mixed-dimension
disposal refusals).

Seven decisions the phase had to take:

1. **The schedule is the CONTRACT, never a table.** `{cost, salvage, life, acquired_on}`
   derives every month; the only persisted per-period fact is the posting. A stored schedule
   would be a second truth that a re-seeded life or a rolled-back post could contradict, and no
   read could say which was right. `AssetRegister` re-derives the whole register from the row
   plus Σ postings.
2. **The last month absorbs the division remainder.** 600 000.00 / 36 is not an integer number
   of cents. The schedule carries 16 666.66 for 35 months and 16 666.90 for the last, so the
   term releases the cost exactly; the manual's 16 666.67 is the average, not a slice. This is
   what makes JE-004 reproducible in a ledger that may not lose or invent a cent.
3. **The cascade re-derives the amount and refuses any other.** A caller holding a posting id
   cannot choose what a period costs: `DepreciationPosting` computes the slice from the asset
   and requires the posting to match, requires the period's last day as the entry date, and
   requires the period to be inside the term. That is the safety that makes the no-schedule-table
   discipline hold — the persisted fact cannot disagree with the contract.
4. **Exactly-once is two layers, and the read is the contract.** A retried sweep must be a clean
   no-op, so the run reads `{asset, period}` first; the unique index is the belt for a racing or
   regressed caller. Removing the read turns a retry into a loud failure (the belt refuses), which
   is exactly what sabotage 408's first leg demonstrates — the belt alone is not the caller-facing
   guarantee.
5. **A disposal is prospective and posts its own entry.** `:dispose` records the date, posts
   proceeds/accumulated/cost/gain-loss, is one-way, and stops the schedule from that month; the
   months already posted stay. There is no catch-up: the run never invents a slice for a month
   nobody reviewed. Sabotage 408's second leg removes the stop and every number stays exact —
   only the future months nobody wanted keep posting.
6. **Equipment needed its own contra meaning.** The manual reuses `1510`, but `Account.code` is
   unique per org and the reference table names `1520` for lab equipment (D16's corrected form),
   so the `PostingAccount` enum widened with `:accumulated_depreciation` and the books bind it to
   `1520`. The pairing is by kind: intangible → `amortization_expense`/`accumulated_amortization`
   (7000/1510), equipment → `depreciation_expense`/`accumulated_depreciation` (6030/1520).
7. **The audit checks the NAMED legs, not a re-resolved policy.** Each posting row names the two
   accounts it paid. `ReconcileAssets` follows the anchor and compares the entry's persisted lines
   to those names, then checks the amount against the derived schedule, the term, the disposal
   date, the cap, the posting's backing entry, and Σ slices against the contra account's GL
   movement. A hand-inserted unbacked row and an orphaned anchored entry are the red paths.

The original scope:

`Asset` + **derived** schedules + the monthly `DepreciationRun` (design D9), exactly-once per
period behind a period-keyed anchor. Covers JE-003/004 (PDK license over 36 months) and JE-063
(lab equipment). No schedule table — the derived-state discipline.

**AC:** amortization accumulates to the contra account and rolls off at end-of-life (red-proven:
idempotent re-run, and a disposal that stops the run); the PDK license schedule reproduces the
doc's JE-004 arithmetic exactly.

### Phase 8 extension — disposal gain/loss, transfers, CIP (2026-11-14)

Three lifecycle gaps were closed without changing the derived-schedule discipline:

1. **Disposal posts the standard entry.** `:dispose` resolves `asset_cost_intangible` /
   `asset_cost_equipment` (or `construction_in_progress` for a CIP), accumulated contra, cash
   proceeds and `disposal_gain_loss`, anchored `asset_disposal` to the asset id. `proceeds_cents`
   is the only caller-supplied amount; the gain/loss is `proceeds - NBV`. The entry is in the
   same transaction as the status/disposal fact. Before posting, `:dispose` reads the
   asset-owned entry lines and refuses a legacy asset whose posted slice or in-service entry
   carries a dimension different from the current one; those prior balances cannot be cleared
   on the current dimension.
2. **Transfers are pre-ledger assignments.** `:transfer` changes the asset's current cost
   object/dimension, appends a dated from/to record, and posts nothing. It is allowed only before
   the asset has any ledger history — no depreciation posting and no CIP in-service entry. R6
   cannot move a balance between cost objects, so a transfer after posting would leave the cost
   and accumulated on the old dimension; disposal clears only the current dimension. Once an
   asset is in service or depreciated, changing its cost object is a new-asset or
   correcting-entry decision, not a subledger edit.
3. **CIP is a lifecycle state, not a second asset class.** `under_construction: true` creates a
   status-`:under_construction` asset with no schedule. `:place_in_service` requires a date,
   reclassifies cost from `construction_in_progress` to the kind's asset-cost account, and starts
   the derived schedule at that month. `DepreciationRun` reports `:under_construction` until then.

### Phase 8 extension — prepaid expense schedules and releases (2026-11-14)

Prepaid accounts (`1200`/`1210` in the Kubeworkz books) existed but had no release mechanism
comparable to the asset register. The slice adds `Samen.Scopes.Finance.{PrepaidSchedule,
PrepaidRelease}` (blueprint `prepaid_blueprint.ex`), the derived arithmetic `PrepaidSchedule`,
the account guard `PrepaidShape`, the posting cascade `PrepaidReleasePosting`, the monthly run
`PrepaidReleaseRun`, the `PrepaidReleaseWorker` on the canonical crontab (`50 0 1 * *`), and
the register read `PrepaidRegister` — plus three migrations (fixture `spf`/`psf`, web
`wep`/`ewp`, erp `sep`/`spe`), six allocator-reserved abbrevs, and
`samen_core/test/finance_prepaids_test.exs` (9 tests), and the Kubeworkz host
release regression in `samenerp/test/kubeworkz_books_test.exs`.

Decisions the slice had to take:

1. **Prepaid is its own resource, not an `Asset.kind`.** A prepaid is a current asset released
   to expense; the asset register's accumulated contra, disposal and CIP semantics do not fit.
   `PrepaidSchedule` stores `prepaid_account_id`/`expense_account_id` directly (the AP-line
   precedent — the chart is host data), so no new `PostingAccount` meanings or host seeds were
   needed.
2. **The schedule is a contract, never a table.** `{total_cents, months, start_on}` derives
   every monthly slice; `PrepaidRelease` is the only per-period fact. The last month absorbs the
   division remainder, so the term sums to the contract exactly. `PrepaidRegister` re-derives
   released, remaining, the next open period and completion from the contract plus Σ releases.
3. **Exactly-once is a read plus a unique index.** The run reads `{schedule, period}` first and
   reports `:already_released` as a caller-facing no-op; the unique index is the belt for a
   racing or regressed caller. The release cascade forces the accounts from the schedule and
   refuses a date outside the term or before the first month.
4. **Append-only facts, closed-period gate.** The release table's trigger refuses UPDATE and
   DELETE; a correction is a reversing entry. The release posts through the same `PostGuard` as
   every entry, so a closed period refuses the release and leaves no fact behind.
5. **The shape guard names both sides.** `PrepaidShape` requires a same-org debit-normal asset
   prepaid account, a same-org debit-normal expense or asset/WIP release target, and distinct
   accounts. `SameOrgFk` keeps the schedule and release dimensions inside the org.

---

## Phase 9 — Obsolescence / NRV reserve · default · 1 session

`InventoryReserve` policy + the quarterly assessment read + a **gated** drafted write-down
(design D10). Covers JE-034/062 into `8000`.

> **DONE** (2026-11-01) — `samen_core/test/finance_reserve_test.exs` (13 tests),
> `samenerp/test/kubeworkz_reserve_test.exs` (1), sabotage **411** certified through
> the harness. Abbrevs `fsr`/`fsq`/`fsz` (fixture), `fro`/`frv`/`frw` (web),
> `ear`/`eav`/`eaw` (samenerp), all allocator-reserved.

1. **The policy is a rule, not a balance.** `InventoryReserve` stores basis, threshold,
   percentage and the item ids it covers. The manual's JE-034/062 write `Dr 8000` straight off
   inventory and carry no reserve contra, so `:inventory_reserve` stays **unmapped as a
   decision** — binding it would let a caller park money in an account the chart never opens.
2. **The assessment is a read with a date.** `ReserveAssessment` derives the candidates from the
   stock levels and the append-only ledger, at an explicit `as_of`, and writes nothing — the
   phase's first AC is proven by running it twice and comparing the level/ledger rows byte-for-byte.
3. **FIFO layers, not an average age.** The age basis walks inbound/outbound ledger events as
   layers: an outbound movement consumes the oldest layer, so "what is still here and how old"
   is answerable. The pure `aged_quantity/3` is tested with stated layers and a cut; the DB test
   changes only `as_of`, proving fresh stock is not flagged and aged stock is.
4. **Net of every posted write-down.** The estimate applies to the item's REMAINING carrying
   value (gross eligible cost minus all posted write-downs for that item, under any policy). A
   second quarterly review therefore proposes only what is left; a fully written-down item drafts
   nothing (`nothing to draft`) instead of repeating the same cents forever.
5. **The draft is derived; the post re-derives it.** `:draft` accepts no amounts — it runs the
   assessment, refuses an empty result or an item with no inventory account (naming the SKU), and
   materializes the lines. `:post` re-runs the assessment inside the decision transaction and
   refuses any line whose item, quantity, cents or account no longer match (`assessment_drift`),
   so an approval consents to the stock that is there.
6. **The Gate is the only route to the GL.** `:post` carries the ADR-040 Gate; an unwrapped call
   is `ApprovalRequired` and opens a pending approval, and a distinct approver's decision
   re-invokes it as the requester. The draft-only validation sits IN FRONT of the Gate, so a
   re-post is refused as `already posted` instead of queueing an approval that can never execute.
   Sabotage 411 removes exactly that Gate; every arithmetic test stays green and only the
   approval test reds — which is the point.
7. **The posting is one entry, two-legs-per-account.** Debit `write_down_expense` (8000) for the
   total, credit each line's inventory account for its share (JE-062's 1400/1410 shape), anchored
   `source_key: "reserve_write_down"`. Lines and posting columns are append-only in the DB, and
   the belts are red-proven with raw SQL.
8. **Host wiring is explicit and fail-honest.** Reserve posting needs the host's Inventory
   resources, passed at mount time (`inventory: [item:, level:, ledger:]`); without it the
   actions refuse `:inventory_not_wired` rather than assessing nothing.

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

> **UNIT 10.1 DONE** (2026-11-01) — `CostAllocation` + `CostAllocationShare`
> (`cost_allocation_blueprint.ex`), the pure largest-remainder
> `AllocationMath`, the drafting cascade (`cost_allocation_drafting.ex`) and
> the one-entry posting cascade (`cost_allocation_posting.ex`), three
> migrations, `samen_core/test/finance_allocation_test.exs` (13 tests),
> `samenerp/test/kubeworkz_allocation_test.exs` (1), sabotage **412**
> certified through the harness. Abbrevs `fcs`/`csf` (fixture), `wec`/`ewc`
> (web), `sec`/`cse` (samenerp), all allocator-reserved. **Unit 10.2 (the
> labour driver) is NOT started** — every labour-derived figure stays labelled
> ratio-based under ADR-054 Ratification 5.

> **UNIT 10.2 DONE** (2026-11-01) — `Timesheet` + `TimesheetEntry` authored
> inside the shipped Work scope (`timesheet_blueprint.ex`, opt-in `timesheets:`
> with the host's `cost_object:` module; draft → submitted → approved, entries
> one day × one cost object), and `LabourAllocation` + `LabourAllocationShare`
> in Finance with the `LabourDriver` read. The drafting cascade freezes approved
> minutes into an exact largest-remainder split; the posting cascade re-derives
> the driver and refuses `labour_drift`, then lands ONE dimensioned entry.
> Three migrations; `samen_core/test/work_timesheet_test.exs` (9 tests),
> `samen_core/test/finance_labour_test.exs` (13), and
> `samenerp/test/kubeworkz_labour_test.exs` (1: September design-engineering
> payroll across RISC-V64/GPU/PTA). Sabotage **413** certified through the
> harness. Abbrevs `wts`/`tsw`/`sfl`/`slf` (fixture), `wel`/`wle` (web),
> `tws`/`aaa`/`sel`/`sle` (samenerp), all allocator-reserved. The driver now
> EXISTS; the Phase 7 variance layer still takes declared actuals, so its
> labour figures remain labelled until a later unit consumes the driver.

Seven decisions the allocation step had to take:

1. **The bill must have posted.** Allocation moves cost already on the books; a draft bill has no
   posting to reclass. The amount is re-read from the bill's own LINE for the source account — not
   from the AP entry, and never accepted from a caller.
2. **One source account, by declaration or by fact.** A single-account bill defaults to it; a
   multi-account bill must name `source_account_id`, and an account the bill never debited is
   refused. The target account must differ: a same-account allocation moves nothing.
3. **Largest remainder, not `round/1`.** Each share takes the floor of its exact proportion; the
   leftover cents go one each to the largest remainders (tie-break: larger driver, then cost-object
   id). 120 000.01 split 52/31/17 therefore lands 6 240 001 / 3 720 000 / 2 040 000 — the extra
   cent on the 52% programme, never lost or invented. A zero-cent share is refused rather than
   materialized (the DB belt refuses one anyway).
4. **The basis is recorded, the drivers are the arithmetic.** `:die_area` / `:wafer` / `:effort`
   labels the declared unit for the audit; only the drivers' proportions move cents. Fewer than two
   targets is a reclass, not an allocation, and is refused.
5. **ONE entry, N targets.** Each share contributes a debit to the target account and a credit to
   the source account, BOTH tagged with that share's cost object. That is what makes the posting
   R6-clean (each programme nets to zero) and dimension-only: the accounts move the invoice once,
   and three programmes never become three posts.
6. **One allocation per bill and source account.** The table's unique index is the belt; the
   drafting pre-read is the caller-facing refusal. A correction is a reversing entry, never a
   second allocation of the same cost. Shares are append-only and a posted header is final.
7. **The axis is the frozen vocabulary, defaulting to `project`.** The programmes are cost objects
   under the `project` axis (the `chip` kind names what they are, not where the ledger files them);
   a host may declare `lot`/`fund`/`cost_pool` instead. R10 comes free: the entry is created through
   the posted-born factory, so a closed period refuses the allocation and leaves the draft alone.

**AC:** one mask invoice allocates across the RISC-V64/GPU/PTA programmes with the shares summing
to exactly the invoice total (red path: rounding must not lose or invent a cent); the allocation
is dimension-only (it posts once, to N cost objects — never N posts).

Seven decisions the labour driver had to take:

1. **Approved hours are the fact; everything else is zero.** The driver reads `:approved` sheets
   only, and only entries whose `worked_on` falls inside the pay period (a sheet is an overlap
   envelope, an entry is the unit of time). A draft or submitted sheet contributes no minutes, so
   unapproved time can never move payroll cost. `:submit` requires at least one entry; `:approve`
   only matches a submitted sheet; an approved sheet is final (DB trigger).
2. **Entries freeze with the sheet, and the DB is the belt.** One entry is one day against ONE
   required, same-org cost object; minutes are positive integers. Create/update/delete are refused
   once the sheet leaves `:draft`, in Ash (`TimesheetEntryGuard`) AND by the `tsw_parent_draft`
   trigger, which also enforces the capture window. A submitted sheet's evidence cannot move after
   payroll consumed it.
3. **The total is declared; the split is derived.** Actual pay is not minutes × one rate
   (deductions, salaried staff, overtime), so `:draft` accepts the payroll total and the two
   accounts and NEVER a share, a minute or a cent. `AllocationMath` then splits by approved
   minutes, and the shares are append-only evidence of the driver the draft froze.
4. **Drift is re-derived, not trusted.** `:post` re-runs the driver and compares minutes PER cost
   object (equal totals can hide different splits) and the share sum against the header. A stale
   draft refuses `labour_drift`; it never posts against hours that moved.
5. **A drifted draft can be withdrawn; a posted one cannot.** `:discard` writes `:discarded` and
   keeps the shares as evidence; the partial unique index frees the {period, source account} slot
   for a re-draft. The DB trigger allows exactly `draft → posted` and `draft → discarded`.
6. **An unwired mount fails honest.** `labour: [timesheet:, timesheet_entry:]` is required; without
   it the actions refuse `:timesheets_not_wired` rather than inventing a headcount ratio. The web
   host mounts Finance without Work timesheets and is refused, by design.
7. **ONE entry, N pairs, same discipline as the cost allocator.** Per cost object: Dr target /
   Cr source, both tagged on the header's axis; the entry lands on `period_end` and rides the
   posted-born factory, so R1/R6 hold and R10 refuses a closed period.

**AC:** approved hours drive the split and unapproved hours move nothing (red path: the driver
returns zero for a draft/submitted sheet); hours approved after drafting refuse the post
(`labour_drift`), the draft is discarded and the re-draft posts; the host proof allocates
Kubeworkz September labour across the three programmes as ONE entry.

---

## Phase 11 — Grants + restricted funds (R11) · opus · 2–3 sessions

`Grant`, `GrantMilestone`/`GrantClaim`, the `fund` dimension end-to-end, `Budget` reuse for the
grant budget, `GrantOpportunity` (the tracker). Recognition by `:cost_incurred` (Phase 6).
Compliance reporting as a read. **R11 + sabotage 410.** **The grant personnel report is a masking
watch-list surface** — full green/red/sabotage trio (design §4).

**AC:** R11 green + red + sabotage; fund postings reconcile to recognized grant revenue and to
claimed allowable costs; the personnel report's red leg refutes both plaintext and `vt_` tokens
in DOM/CSV/API.

---

## Phase 12 — The close run, executed end to end · default · 2 sessions

`CloseRun` + the doc's ten phases as Work tasks anchored to it, with the twelve role assignments.
Each phase also carries Docs evidence UUIDs and a separate reviewer sign-off; completion requires
task, evidence, an independent reviewer and the phase sign-off to agree. The deliverable is an
**executable walkthrough** (`samenerp/test/close_walkthrough_test.exs`) that
drives one real month through the checklist: cut-off → AP/AR → inventory & WIP → accruals →
grants → variance → reconciliations → statements → forecast roll-in → reporting, with the close
dashboard read at the end. Soft-close must block new documents and admit adjustments (Phase 3).

**AC:** the walkthrough passes on the host; a document posted after soft-close is refused; the
close dashboard reports the period's completeness honestly (an open task, missing evidence, or a
reviewer who is also the signer shows as open, never as done).

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

## Phase 16 — The Kubeworkz host proof + workstream gate · mixed · 2–3 sessions — **DONE (2026-11-06)**

1. **Mount Hr in samenerp** (design §6) — payroll postings become possible in-app.
2. **Replay the whole JE playbook** as one executable host test
   (`samenerp/test/kubeworkz_books_walkthrough_test.exs`): JE-001 → JE-081 across a real fiscal
   period on the mounted host, checking the balances the doc asserts at each stage.
3. **The extended spine re-gate:** R6–R11 re-flipped from the sabotage harness, byte-exact.
4. **Root gate:** `./ci.sh` ends **`ROOT CI: ALL PASSED`**; the workstream-wide adversarial gate
   written up in `docs/gate-ws-acct.md`; claim-evidence + roadmap updated.

**AC:** the playbook walkthrough green on the host; R6–R11 sabotage-certified; root CI ALL PASSED;
the coverage ledger (phase 0) has no workbook left without a verdict.

> **DONE (2026-11-06)** — `docs/gate-ws-acct.md` records **`==> ROOT CI: ALL PASSED`** /
> **`EXIT=0`** / **1:59:54**, with the full default tier set; `samenerp` **134 tests passed**,
> including the 42-entry JE walkthrough and the HR mount. R6–R11 targeted: **10 named flips
> across 6 patches**, byte-exact restores. The separate full 411-patch sweep passed **411/411**
> with **649 named-test confirmations** and byte-exact restores (2026-11-08). The Phase 16 delta
> was uncommitted at gate time.

---

## Sabotage allocation

| Patch | Phase | Flips |
|---|---|---|
| 403 | 1 | R6 — per-cost-object balance |
| 404 | 3 | R10 — the period guard |
| 405 | 4 | R7 — WIP ↔ lot |
| 406 | 6 | R9 — recognition exactly-once |
| 407 | 7 | R8 — variance ↔ standard card, and the per-type disposition |
| 408 | 8 | the exactly-once depreciation read, and a disposal that stops nothing |
| 409 | 5 | the accrual's linked reversal mirrored on the same side |
| 410 | 11 | R11 — grant ↔ fund |
| 411 | 9 | the ADR-040 Gate on the obsolescence write-down |
| 412 | 10 | the declared allocation basis (drivers) |

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
- **The labour driver EXISTS (Unit 10.2); consumers still have to adopt it.** Phase 7's labour
  rate/efficiency legs and Phase 11's grant cost-incurred recognition may now read approved
  timesheet minutes instead of a ratio, but until each is rewired to the driver its figures stay
  labelled (ADR-054 Ratification 5). The driver itself is no longer the blocker.
- **The doc's figures are placeholders** — the *structure* ships; the numbers get reviewed by the
  operator before they are called Kubeworkz's policy (design §7).
- **The doc's §E1–E5 appendix is not accounting** — the operator confirmed its exclusion
  (ADR-054 Ratification 6); it stays out of scope in the ledger.
