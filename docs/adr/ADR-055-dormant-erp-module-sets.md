# ADR-055 — The dormant ERP module sets: **delete** them rather than complete them, and
retire the abbrevs they burned

- **Status:** **ACCEPTED (2026-10-27) — decision taken.** The disposition is DELETE. Two calls
  inside it are named as cheaply overrulable (§6 the E15 timesheet stub; §4 retire-vs-tombstone on
  the abbrev rows) — if the operator wants either the other way, it is a one-line change to this
  record and to the execution phase, not a re-audit.
- **Date:** 2026-10-27
- **Deciders:** the operator (asked for the ruling); evidence gathered by audit.
- **Consumes:** ADR-004 (scope packaging), ADR-006 / ADR-023 / ADR-025 (the abbrev registry and its
  permanence rule), ADR-049 (the ERP base scopes + §6 the honesty boundary, §7 the deferral list),
  ADR-054 §1 (which carried this as its hygiene item) and `docs/ws-acct/design.md` §0.2.
- **Answers:** ADR-054 §1's carried item — *"Whether the ~26 dormant sets should be deleted or
  completed is explicitly out of scope here and carried as a separate hygiene item."*

## Context

WS-ACCT's phase-0 audit went looking for reusable accounting code and found something else: a large
body of source that **reads** like shipped ERP functionality and is not. ADR-054 recorded the
finding and declined to act on it, because the answer is a product decision, not an accounting one.
It was right to decline — but leaving it open is expensive, and this ADR pays it off.

The estate contains **two contradictory claims** about the same code, and the audit's first job was
to find out which one is true.

- `README.md` claims the modules ship: a table row per module ("Warehouse transfers (E13) … 14
  tests", "Expenses (E31) … ", …), a test-count table reading **"E9–E38 (ERP modules) | 588 tests
  across 30 ERP modules"**, and prose reading **"47 modules covered (E9–E38)"**.
- ADR-054 §1 / `docs/ws-acct/design.md` §0.2 claim the opposite: **"no scope macro, no blueprint, no
  domain, no host mount, no test."**
- `samenerp`'s own landing page, served at `GET /`, advertises them to end users under
  **"🚀 Extended ERP (E9–E18)"** and **"⚡ Extended ERP (E19–E38)"** — including a
  **"Payroll & Leave — Payroll runs, leave types, time-off requests, and accruals"** card, which
  contradicts ADR-049 §6, where payroll computation is a binding refusal.

The audit resolves it: **ADR-054 is substantially right and the README is wrong.** The modules are
real files that compile and real ExUnit files that pass — but nothing can reach the code, no table
was ever created, and the tests assert nothing about the system. Findings, all measured against the
tree at this commit:

| Measurement | Result |
|---|---|
| Scope modules actually mounted anywhere (`use Samen.Scopes.X`) | **23** — Billing, Calendar, Support, Identity, Docs, Work, Marketing, Crm, Automation, Analytics, Tags, SalesOps, Primitives, Chat, Locations, Cms, Inventory, Finance, Outreach, Mailbox, Hr, Views, Banking |
| Dormant scope directories (a scope module that no host ever `use`s) | **23** — approvals, appointments, community, consolidation, custom_fields, dataclean, documents, ecommerce, elearning, email_marketing, esign, expenses, fleet, iot, livechat, marketing_automation, planning, pos, quality, sms_marketing, social, social_marketing, survey |
| Dormant module files (those 23 dirs + the E15 timesheet trio inside the live `work/` dir) | **89** files defining **89** modules |
| Distinct tables those modules declare | **87** |
| …of which any host's `priv/` migration creates | **0 of 87** — every resource points at a table that has never existed under any shipped schema |
| Rows those modules own in `priv/abbrev_registry.json` | **89** — in a registry that is permanent, collision-checked, and **never recycled** |
| External references to any of those modules (outside their own directory) | **0** for all 23 namespaces |
| E-series test files whose only mention of a project module is their own `defmodule` line | **24** files, **544** tests |

The last row is the claim-vs-reality gap. These files pass, and they exercise nothing. `wt1` in
`warehouse_transfers_test.exs` is `qty = 0; assert qty <= 0`. `financial_statements_test.exs` builds
four literal maps and asserts `Enum.reduce(...) == 0` — it never calls `TrialBalance`.
`quality_control_test.exs` ships a helper `widen/1` whose own comment says it exists to escape
constant folding "on literal fixture data… so engine-simulation branches stay representative" — a
shim whose purpose is to make a literal assertion survive `--warnings-as-errors`. So the README's
"588 tests" and "47 modules" are not an over-claim at the margin; they are a description of code
that does not exist. Three of the README's cited test paths (`quality_test.exs`, `survey_test.exs`,
`elearning_test.exs`) do not exist at all — the files present are `quality_control_test.exs` and
`survey_elearning_test.exs`.

**Why this is worth an ADR rather than a cleanup commit.** Because it is not a one-off. ADR-054's
audit was derailed for a full section by these files; every future agent that greps
`consolidation`, `expenses` or `timesheet` pays the same tax and can reach the same wrong
conclusion — that the code is reusable, or already done. The registry cost is permanent: 89
three-letter prefixes in a namespace that explicitly never returns them. And the landing page means
the fiction is user-facing, not merely internal.

**This is not a claim that the work was worthless or that its authors were careless.** It is a claim
about what the artifacts *are now*: an attributes layer written ahead of the packaging (ADR-004's
scope/blueprint/mount pattern) and the gates (a migration, a real test, a red twin, a sabotage
patch) that define a feature in this codebase. What landed was the part that is cheap to write and
cannot be trusted on its own.

## Decisions

1. **The dormant sets are DELETED, not completed.** The admission test is mechanical and
   conjunctive, so it cannot be argued case by case; a module is dormant iff all three hold:
   **(a)** no host anywhere does `use Samen.Scopes.<its scope>`, and its module name appears in no
   domain's `resources do` block; **(b)** no migration in any app's `priv/` declares one of its
   tables; **(c)** no file outside its own reaches its module name. All three hold for all 89 files.

2. **The measured scope of the deletion** is §Context's table: 89 files across 23 directories plus
   the E15 timesheet trio, 87 never-created tables, and the 509 tautological tests whose sole
   subject is a deleted module. The deletion is therefore **behaviour-preserving by construction**:
   nothing can call the code, no schema ever existed, and no passing assertion depended on it.

3. **The tautological tests go with their modules — but three are replaced, not deleted.** The
   `cms` scope is mounted and its 13-test file is nonetheless tautological; `financial_statements`
   and `warehouse_transfers` are the same pathology on live modules (35 tests between the three).
   Deleting those would remove a file without closing the hole, so the execution phase **replaces**
   them with real coverage that reaches the module, or removes the file if the module itself is
   unmounted (E11's `TrialBalance`/`BalanceSheet`/`ProfitLoss` are unreferenced and unmigrated, so
   they fall under decision 1 and their 8 tests go with them).

4. **The 89 abbrev rows are RETIRED — under a rule that keeps permanence intact.** The registry's
   rule is that an abbrev is permanent because it is projected into physical column names: *"once
   data exists under `com_name`, that prefix can never change without rewriting history."* That
   rationale is a statement about **data**, and these prefixes have none: 87 of 87 tables were never
   created, so no row was ever written under them. The rule therefore does not bind here, and the
   rows may be retired — but only under proof, and only through a sanctioned path:
   - a new `mix samen.abbrev.retire` that **refuses** unless it can show both (i) the owner module no
     longer exists in the tree and (ii) **no** migration in any app declares that module's table;
   - **never** hand-edited (`priv/abbrev_registry.json` stays HANDS-OFF, per `CLAUDE.md`);
   - every row that ever had data keeps its permanent reservation, so ADR-006/023/025's invariant is
     narrowed for these rows only, and the narrowing is *verifiable*, not discretionary.
   The alternative — leaving 89 rows pointing at modules that no longer exist — is rejected because
   it degrades what the registry means: an "owner" would no longer be an owner, and every future
   reader and allocator would have to learn to ignore dangling rows.

5. **Not completed, because there is no head start to lose.** The case for completing would be that
   ~30 ERP module sets are roadmap value. Two things defeat it. **Nothing chartered needs them**:
   WS-ACCT's ledger maps the manual's needs onto Finance, Inventory, Docs, Budget and Files, and
   ADR-054 §1 already priced "wiring any of it" as new work under the rule *"dormant code is not
   reuse."* And **the artifacts are not a foundation**: what exists is the attribute/action/policy
   layer only — no scope macro, no blueprint, no migration, no domain, no honest test, none of the
   verifier tiers, and a resource shape authored before ADR-049 fixed the packaged-scope pattern.
   Reaching "complete" would mean auditing, re-shaping, migrating, testing and mounting each set —
   which is the same work as authoring it, plus the cost of trusting code written against a design
   that has since moved. **If one is chartered later, it is authored as a packaged scope the way
   Finance, Inventory and Hr were** — which is the only path this codebase accepts as "shipped".
   Git history preserves every deleted file, so this is recoverable; it is not a shredding.

6. **E15 (timesheets) is deleted with the rest, and WS-ACCT Phase 10 authors it fresh.** This is the
   one deletion that touches a chartered plan, so it is called out. ADR-054 decision 17 / ratification
   ruling 5 authorised the labour driver, which needs timesheet *hours* — and the natural reading was
   "wire E15 into Work". That reading is overruled here: the stub has no migration, no reference and
   no test, and its summary rollup predates the Work scope's own conventions, so "wire it" means
   audit-and-fix it, which is not cheaper than authoring it inside `Work`. The labour driver is
   **unaffected as a decision** — only its starting point changes, and Phase 10 already carries the
   cost. The reason to take the uniform position rather than carve out an exception is precisely
   this ADR's subject: keeping one grep-visible-but-not-real timesheet module is what cost ADR-054 a
   section of its audit in the first place.

7. **What is explicitly preserved.** The audit's frontier is **module-level, not directory-level**,
   and two live cases sit dangerously close to the deleted ones:
   - **E13/E14 are LIVE and stay.** `TransferOrder`/`TransferGuard` and `LandedCost` are defined by
     the Inventory scope and mounted by the flagship host (`samenerp/erp.ex` lists
     `resource(Samenerp.Erp.TransferOrder)` and `resource(Samenerp.Erp.LandedCost)`), and their
     tables (`etn_transfer_order`, `eld_landed_cost`) **are** migrated in samenerp. ADR-054's Phase
     10 additionally reuses `LandedCostAllocator` as a **pattern** — so deleting "the E13/E14 files"
     by directory would break a ratified plan.
   - **E10 (FX) is live** (`ExchangeRate`, `OrgFxSettings` are defined by the Finance blueprint);
     **E11 is not** (`TrialBalance`/`BalanceSheet`/`ProfitLoss` are referenced by nothing and
     `stb_trial_balance` is unmigrated) — E11 therefore falls under decision 1 despite living inside
     the mounted Finance directory.
   The rule is applied to the **module**, never to the folder, and the execution phase computes the
   frontier with the verifier in decision 9 rather than from any hand list — **including this one**.

8. **The claims surfaces are corrected as part of the execution.** A deleted module is not the same
   as a retracted claim, and three surfaces currently assert the fiction:
   - `README.md` — the per-module rows, the **"588 tests across 30 ERP modules"** row, the
     **"47 modules covered (E9–E38)"** prose, and the three test paths that do not exist;
   - `samenerp/lib/samenerp_web/page_controller.ex` — the **"Extended ERP (E9–E18)"** and
     **"(E19–E38)"** sections on the public landing page. The **payroll card is wrong under every
     disposition** (complete, delete or leave), because ADR-049 §6 makes payroll computation a
     standing refusal — so it is corrected on its own merits and does not wait on this ADR;
   - `docs/claim-evidence.md` — the claim ledger, which (correctly) does not register the 588-test
     claim today; it gains the honest replacement rows so the next audit does not have to re-derive
     this table.

9. **A standing verifier, so the rot cannot re-accumulate, and the execution is its own gated
   change.** Nothing failed while 89 unreachable modules accumulated — that is the root cause, and a
   one-time cleanup that leaves no guard repeats itself. A verifier (a `mix samen.verify.*` task in
   the tier that already walks scopes, e.g. beside `catalog_parity`/`prefixes`) **fails the gate**
   when a module under `lib/samen/scopes/` is simultaneously **unmounted, unmigrated and
   unreferenced** — decisions 1(a)/(b)/(c) made executable, with its own green/red twin and a
   sabotage patch per house discipline. The deletion itself ships as **its own phase with its own
   adversarial gate** (full `./ci.sh` before and after), **not** folded into a WS-ACCT phase, so a
   large mechanical deletion never shares a commit with feature work.

## Consequences

- The estate becomes diagnosable again: `consolidation`, `expenses`, `timesheet`, `pos`,
  `esign` and the rest stop reading as shipped features. ADR-054 §1's "dormant code is not reuse"
  becomes mechanically true rather than a note a reader must remember.
- Deletion must be preceded by the verifier (decision 9) so the frontier is computed, not guessed —
  and the verifier then outlives the deletion as the reason it cannot recur.
- Abbrev permanence is narrowed for exactly these rows, under proof, via a new sanctioned task. The
  registry stops meaning "every row names a live owner" and starts meaning "every row names an owner
  that either exists or provably never had data" — a rule with a test rather than a convention.
- 509 tests disappear from the samen_core count and must not be replaced by count-padding: the
  README's totals move **down**, and the honest number is a smaller one. Any future "test count"
  claim in the README or the claim ledger is expected to move with them.
- `samenerp`'s landing page and the README lose ~30 advertised capabilities. That subtraction is the
  point: what remains advertised will be what a user can actually click, per the fail-honest
  posture (`CLAUDE.md`; ADR-014/024/026).
- If any of these sets is chartered later, it starts from a packaged scope, a migration, a real test,
  a red twin and a sabotage patch — i.e. from this codebase's definition of "shipped" — rather than
  from these 89 files.
