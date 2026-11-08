# GATE — WS-ACCT "The Kubeworkz books" (workstream gate, Phase 16)

**Decision: GO**

Date: 2026-11-06 (full-sweep addendum 2026-11-08)
Scope gated: the Phase 16 host proof — the Kubeworkz HR mount, the complete JE-001 → JE-081
playbook on the real host, the R6–R11 extended-spine re-flips, and the full root gate. This is
the workstream close-out at the Phase 16 boundary. It re-runs the root gate and the Phase 16
proofs; it does not re-derive every earlier phase's AC. Those phases are covered by the root
suite and mapped workbook-by-workbook in `docs/ws-acct/kubeworkz-books.md`.

Inputs: `docs/ws-acct/design.md`, `docs/ws-acct/build-plan.md` (Phase 16),
`docs/ws-acct/kubeworkz-books.md`, ADR-054,
`docs/chip_manufacturing_accounting_setup.md` §"Journal Entry Playbook",
`samenerp/test/kubeworkz_books_walkthrough_test.exs`,
`samenerp/test/hr_mount_test.exs`, and the R6–R11 patches under `scripts/sabotages/`.

**Tree state:** HEAD is `9c7feb5f` (Phase 15). The Phase 16 delta is uncommitted: 9 tracked
files modified and 4 untracked files at the start of the gate. This report is the only file
added by the write-up. The gate made no source changes; nothing was committed or pushed.

---

## Verdict in one line

WS-ACCT Phase 16: **GO**. The full root gate ended `==> ROOT CI: ALL PASSED` with `EXIT=0`; the
`samenerp` host gate recorded **134 tests passed**, including the complete 42-entry JE playbook;
the host HR mount and its grant-personnel masking path passed; and the targeted R6–R11 re-gate
flipped **10 named assertions across 6 patches** and restored every patch byte-exact. No P0/P1
findings. No P2 carries remain: the opt-in full 411-patch harness passed **411 of 411** on
2026-11-08 (**3:02:05**, **649 named-test confirmations**, byte-exact restores); the
documentation and JE-062 decision are closed, and the code and root proof are green.

---

## Root gate — exact verdict

| Item | Result |
|---|---|
| Command | `env -u SAMEN_CI_TIERS -u SAMEN_SABOTAGE -u SAMEN_MULTINODE bash ./ci.sh` |
| Tier set | full default set; no `TIER SUBSET` banner |
| Start | `2026-11-06 19:01:27` |
| End | `2026-11-06 21:01:21` |
| Wall time | **1:59:54** |
| Final marker | **`==> ROOT CI: ALL PASSED`** |
| Exit | **`EXIT=0`** |
| Sabotage harness | **skipped** — opt-in (`SAMEN_SABOTAGE=1`), intentionally not enabled for this run |

The run was a full gate, not a narrowed one. The pre-app tiers all passed:

| Stage | Result |
|---|---|
| Sabotage preflights / residue checks | clean |
| Spikes `s00`, `s02`, `s03`, `s04`, `s05`, `s07` | passed |
| `samen_core` tests | passed |
| AI eval tier | passed |
| Verifiers: agent coverage, tool actor identity, tool surface, replay schema, analytics producer, db boot | passed |
| Adapters: `samen_stripe`, `samen_postmark`, `samen_ses`, `samen_resend`, `samen_anthropic` | all passed |
| `gen_app` flagship / post-app / deploy probes | all passed (`1422.5s` / `964.8s` / `832.2s`) |
| `gen_agent` probe + harness regressions | all passed |

### App gates (run concurrently)

| App | Verdict | Evidence |
|---|---|---|
| `samen_web` | **PASSED** | `==> samen_web gate: PASSED` |
| `demo` | **PASSED** | `Result: 52 passed, 631 excluded`; `demo CI gate: PASSED` |
| `driftwood` | **PASSED** | PITR game-day #2 both arms green; corrupt-restore red path failed closed |
| `pawchart` | **PASSED** | microchip vault anti-tautology probe flipped and recovered |
| `samenerp` | **ALL PASSED** | **134 tests passed**; `samenerp CI gate: ALL PASSED` |

All five app gates printed their pass marker before the root verdict. The root transcript records
`==> ROOT CI: ALL PASSED` / `EXIT=0` / `END 2026-11-06 21:01:21`.

---

## Host proof — the HR mount

`samenerp/test/hr_mount_test.exs` proves the host-side mount, not just the kernel seam:

- creates a `Samenerp.Hr.Employee` with employee number, hire date, employment type, vaulted
  `Samen.Type.FullName`, work email, and date of birth;
- asserts the in-transaction `EmploymentEvent` ledger row is `:hired`;
- creates a pending `LeaveRequest`;
- resolves the grant personnel report through `:personnel_namespace` on both planes:
  the tenant sees the real name (`Kube Worker`); the operator sees `••••` and never the name.

This is the mount that makes host payroll postings possible. The test is included in the
`samenerp` app gate's 134-test run.

---

## Host proof — the whole JE playbook

`samenerp/test/kubeworkz_books_walkthrough_test.exs` posts the manual's playbook through the
mounted `Samenerp.Erp.JournalEntry`, in order, in a real December 2026 fiscal period.

| Assertion | Result |
|---|---|
| Concrete entries | **42** (`JE-001` → `JE-081`; gaps are the manual's structure, not skipped work) |
| Sections | **9** — R&D, slot/order, fabrication, delivery/inventory, PDB assembly, revenue/COGS, period-end, grants, year-end close |
| Posting path | every entry is created as `:draft`, then posted; every entry is asserted balanced org-wide |
| Section balances | exact non-zero account-map match after each of the nine sections |
| Pre-close expense total | **18,394,900 cents** |
| Pre-close revenue total | **3,583,300 cents** |
| Soft close | period becomes `:soft_closed`; document window closes, but the two closing JEs are still admitted as journal-only adjustments |
| Final trial balance | **38,375,600 debit = 38,375,600 credit**; `tb.balanced` |
| Retained earnings (`3100`) | **14,811,600 debit** (the period's net loss) |
| Posted-entry count | **42** |
| Final period status | `:soft_closed` |
| Focused run | **1 passed** |
| Root host gate | **134 passed** (includes this test) |

### Documented source corrections and limitations

The replay follows the books seed's corrected forms, not the manual's contradictory rows:

1. **JE-055** uses only the manual's "Corrected Entry". The manual's original row would
   double-credit inventory and put COGS on the debit side.
2. **JE-063** credits `1520 · Accumulated Depreciation – Lab Equipment`, not `1510`. The
   manual's `1510` is the PDK licence's accumulated amortization; `Account.code` is unique per
   org, so the host cannot carry both meanings on one code.
3. **JE-004 / JE-053** use the manual's rounded monthly amounts (**1,389** and **833**). The
   exact 50,000.00 / 36 schedule belongs to the asset-register suite, not this ledger replay.
4. **JE-062 is asserted as written, including its arithmetic consequence.** After JE-041/055,
   `1400` has 800.00 remaining; the manual's 1,000.00 write-down lands `1400` at
   **−20,000 cents**. The replay does not invent a correction, silently cap the write-down, or
   make the negative balance disappear. This is a source-manual data-quality issue, not a
   production accounting policy.
5. **This is a ledger proof, not a duplicate of the specialised suites.** Accrual pairs, the
   gated reserve write-down, derived asset schedules, grant recognition schedules, and the
   close-run dashboard each have their own host tests. The walkthrough posts the manual's
   entries as written so the source's balances are checkable end to end.

---

## R6–R11 — the extended-spine re-gate

The targeted re-gate selected exactly the six committed patches that carry the Phase 16 spine.
Each patch was applied, its named assertions were required to fail, then the patch was reverted.

| Patch | Invariant | Named `MUST_FAIL` flips | Result |
|---|---|---|---|
| `403-finance-r6b-balance-check-lumps-cost-objects.patch` | **R6b** — per-cost-object balance, not just org-wide | an entry balanced org-wide but not per cost object is refused | flip confirmed |
| `404-finance-r10-period-guard-dropped.patch` | **R10** — closed/soft-closed period guard | a soft-closed period refuses a document post; with the DB trigger disabled, the closed-period post is still refused | 2 flips confirmed |
| `405-acct-r7-wip-supplier-boundary-dropped.patch` | **R7** — WIP ↔ lot ↔ supplier boundary | owned stock is not WIP; consignment stock is not supplier WIP | 2 flips confirmed |
| `406-acct-p6-recognition-exactly-once-brace-dropped.patch` | **R9** — recognition exactly once | a second run in the same period is a clean no-op; the row is append-only | flip confirmed |
| `407-acct-p7-variance-off-card-and-yield-written-off.patch` | **R8** — variance ↔ standard card and per-type disposition | a revised card does not price a period it does not govern; every variance reaches the account the manual names | 2 flips confirmed |
| `410-acct-p11-grant-recognition-ignores-incurred-cost.patch` | **R11** — grant ↔ fund | recognition never runs ahead of incurred cost and carries the fund dimension; an empty period recognises zero | 2 flips confirmed |

**Total: 10 named test flips across 6 patches.**

Commands and exact harness verdicts:

```text
bash scripts/sabotage.sh --range 403-407
→ ALL PASSED (5 of 411 — FILTERED)   exit 0

bash scripts/sabotage.sh --range 410-410
→ ALL PASSED (1 of 411 — FILTERED)   exit 0
```

Every patch printed `restore: byte-exact (sha-256 verified)`. The main checkout reported
byte-exact after each chunk; `scripts/sabotage_residue.sh` exited `0`; `git diff --check` was
clean.

**Scope of this section:** this is a targeted R6–R11 certification; the `FILTERED` banners name
that selection explicitly, and it is not by itself a full 411-patch claim. The separate
unfiltered sweep below supplies the full-sweep certification.

---

## Full 411-patch sabotage sweep — opt-in harness

The full sweep is the maintained parallel partitioner, run with no `--app` or `--range` filter:

```text
bash scripts/sabotage_parallel.sh --jobs 2
START 2026-11-07T21:29:59-05:00
END   2026-11-08T00:32:04-05:00
wall  3:02:05
EXIT=0
```

| Slice | Patches | Verdict | Named-test confirmations | Restores |
|---|---:|---|---:|---:|
| `samen_core` | 199 | **ALL PASSED** | 300 | 199 byte-exact |
| `samen_web` | 170 | **ALL PASSED** | 286 | 170 byte-exact |
| `driftwood` | 17 | **ALL PASSED** | 27 | 17 byte-exact |
| `pawchart` | 13 | **ALL PASSED** | 20 | 13 byte-exact |
| `samenerp` | 7 | **ALL PASSED** | 9 | 7 byte-exact |
| `demo` | 3 | **ALL PASSED** | 4 | 3 byte-exact |
| `samen_postmark` | 1 | **ALL PASSED** | 1 | 1 byte-exact |
| `samen_stripe` | 1 | **ALL PASSED** | 2 | 1 byte-exact |
| **Total** | **411** | **ALL PASSED** | **649** | **411 byte-exact** |

Final marker:

```text
SABOTAGE HARNESS (PARALLEL): ALL PASSED (411 of 411 sabotages flipped their named tests across 8 slice(s); 649 named-test confirmations, byte-exact restores)
```

Every slice asserted the **main checkout byte-exact**; the harness worked in isolated trees under
`.sabotage-parallel/` and did not mutate the main checkout. Driver transcript:
`.sabotage-parallel/full-411-20261107-212959.log`. An older `logs/samen_core-3.log` contains a
failure from a previous run; it is not part of this sweep, whose active logs show zero failures.

---

## Phase 16 checklist

| Build-plan item | Status | Evidence |
|---|---|---|
| Mount HR in `samenerp` | **MET** | `samenerp/test/hr_mount_test.exs`; host gate 134 passed |
| Replay the whole JE playbook on the host | **MET** | 42 entries, nine sections, final TB balanced at 38,375,600 cents; focused 1 passed; host gate 134 passed |
| R6–R11 re-flipped byte-exact | **MET (targeted)** | 6 patches, 10 named flips, all restores byte-exact |
| Full 411-patch sabotage sweep | **MET** | unfiltered `scripts/sabotage_parallel.sh --jobs 2`; **411/411** across 8 slices, **649 named-test confirmations**, byte-exact restores, `EXIT=0`, **3:02:05** |
| Root gate ends `ROOT CI: ALL PASSED` | **MET** | literal marker + `EXIT=0`; full default tier set |
| Workstream gate written up | **MET** | this file |
| Coverage ledger has no workbook without a verdict | **MET** | all 18 workbook headings carry a verdict (including `E1–E5` as `OUT OF SCOPE`); the status header now records Phase 16 and the full sweep |
| Claim-evidence + roadmap updated | **MET** | `docs/claim-evidence.md` §Q and `docs/saas-gap-roadmap.md` §"State after WS-ACCT" cite this gate and record the Phase 16 result and full 411-patch sweep |

The coverage ledger's **content** is complete for the Phase 16 AC: every workbook 1–18 has a
verdict, and `E1–E5` is explicitly out of scope. Its **status header** now records Phase 16 and
the full sweep.

---

## Findings

### WS-ACCT-GATE-P2-1 — JE-062 leaves SoC inventory at −$200.00 (P2 — CLOSED)

The walkthrough proves the source manual's arithmetic as written: after JE-041/055, `1400` has
800.00; JE-062 writes down 1,000.00, leaving **−20,000 cents**. The test asserts this, so the
negative balance is visible rather than hidden.

**Decision (2026-11-08):** retain the manual's entry as written and treat the negative balance as
a source-manual data-quality limitation, not a production accounting policy. No cap, reversal,
or offsetting correction is added, and the walkthrough keeps asserting the arithmetic so the
mismatch stays visible. A production policy for writing inventory down past zero requires a
separate, explicitly approved change. Closed by documentation decision; no code change.

### WS-ACCT-GATE-P2-2 — full 411-patch sabotage harness (P2 — CLOSED)

`SAMEN_SABOTAGE` was unset in the root gate, so that run printed:

```text
==> Skipping sabotage harness (opt-in: SAMEN_SABOTAGE=1 ./ci.sh replays all gate sabotages)
```

The opt-in harness was run separately with the maintained parallel partitioner and no filters:
`bash scripts/sabotage_parallel.sh --jobs 2`. It covered **all 411 patches across 8 slices,
exactly once**, and ended:

```text
SABOTAGE HARNESS (PARALLEL): ALL PASSED (411 of 411 sabotages flipped their named tests across 8 slice(s); 649 named-test confirmations, byte-exact restores)
EXIT=0
END 2026-11-08T00:32:04-05:00
```

Start `2026-11-07T21:29:59-05:00`; wall time **3:02:05**. The root run remains a separate gate;
this sweep certifies the sabotage patches, not a second root-gate run. Closed (2026-11-08).

### WS-ACCT-GATE-P2-3 — coverage ledger header refreshed (P2 — CLOSED)

`docs/ws-acct/kubeworkz-books.md` records Phase 16 and the full sweep in its status block; the
18 workbook sections and their verdicts are unchanged. Closed after the gate.

### WS-ACCT-GATE-P2-4 — roadmap update landed (P2 — CLOSED)

Phase 16's build-plan item 4 explicitly requires the claim-evidence and roadmap updates.
`docs/claim-evidence.md` §Q and `docs/saas-gap-roadmap.md` §"State after WS-ACCT" now cite this
gate and record the host proof, root verdict, targeted R6–R11 result, and the full 411-patch
sweep. Closed after the gate; the sweep addendum landed 2026-11-08.

**No P0/P1 findings.**

---

## Carries forward

1. **Claim-evidence update — done.** `docs/claim-evidence.md` §Q records the Phase 16 host
   proof, the 134-test host gate, the 42-entry walkthrough, the targeted R6–R11 result, and the
   full 411-patch sweep.
2. **Roadmap update — done.** `docs/saas-gap-roadmap.md` §"State after WS-ACCT" marks Phase 16
   complete and records the root-gate and full-sweep evidence.
3. **Coverage-ledger header — done.** `docs/ws-acct/kubeworkz-books.md` records Phase 16 and the
   full sweep; the 18 workbook verdicts were not rewritten.
4. **JE-062 decision — done (2026-11-08).** The manual's entry is retained as written; the
   **−20,000 cents** balance is a documented source-manual data-quality limitation, not a
   production policy.
5. **Full-sweep certification — done (2026-11-08).** The unfiltered
   `scripts/sabotage_parallel.sh --jobs 2` run passed **411 of 411** patches across 8 slices
   (**649 named-test confirmations**, byte-exact restores, `EXIT=0`, **3:02:05**). The root gate
   remains separate.

---

## Fix tasks

**Mandatory code fixes: none.** The Phase 16 code, root proof, and full 411-patch sweep are
green. No documentation items remain; the JE-062 decision is recorded (item 4), and the
full-sweep certification is closed (item 5). Nothing was committed or pushed by this gate.
