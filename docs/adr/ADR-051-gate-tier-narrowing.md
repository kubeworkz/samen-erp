# ADR-051 — Tiered execution of the root gate: a diff-derived subset for the local deploy path, and the baseline that makes narrowing sound

- **Status:** Accepted (2026-10-13). **BUILT** — the tier machinery in `ci.sh`, the selector
  `scripts/ci_tiers.sh`, the narrowing in `scripts/deploy.sh --local-gate`, and two permanent
  `harness`-tier regressions (`scripts/ci_tiers_test.sh`, `scripts/deploy_test.sh`).
- **Governs:** the root gate's execution contract (`ci.sh`) and the local deploy gate
  (`scripts/deploy.sh`). CI itself (`.github/workflows/ci.yml`) is **unchanged** and still runs
  `all`.

## 1. Context

The root gate is one sequence of **independent tiers** — spikes, the kernel suite, the AI eval
tier, five adapter packages, three generator probes, the sabotage-harness regressions, and five
app gates — and it costs **~89 minutes** on a Windows checkout. `scripts/deploy.sh --local-gate`
exists precisely for the operator whose release is blocked on a saturated GitHub runner: it runs
the *same* gate on the *same* commit instead of waiting for one. But it ran **every** tier, so the
escape hatch from a queue became an hour and a half of local wall-clock. The observed failure mode
is not a wrong answer — it is the operator who does not run the gate at all.

The asymmetry that shapes everything below: a too-**wide** tier set costs time, but a too-**narrow**
one ships an unvalidated release. So every rule here is written to make narrowing hard and refusal
cheap.

## 2. Decision

**2.1 `ci.sh` accepts an opt-in tier subset.** `SAMEN_CI_TIERS` unset ⇒ `all`, byte-identical to
the pre-tier gate (CI and every existing caller are untouched). An explicitly **empty** value is a
typo and is **refused** (`-`, not `:-`: a knob that cannot express "you made a mistake" is not
fail-closed); so is an unknown tier name, against a closed vocabulary. A non-`all` run announces
its scope up front, every skipped tier says so **in place**, the four sabotage preflights
(residue · EOLs · patch applicability · anchors) **always run**, and the final verdict is labelled
`ROOT CI: ALL PASSED (TIER SUBSET: …)`.

**2.2 `scripts/ci_tiers.sh` derives the set from a diff** — and answers `all` whenever it cannot
vouch for what it is looking at: an unrecognised path (every new top-level directory lands here),
no `--since`, a ref that does not resolve to a commit, a baseline that is not an ancestor of the
target (rewritten history is not a diff), or an empty diff. It never refuses to *check*; it only
refuses to *narrow*.

**2.3 The baseline is evidence, not an assumption.** A tier may be skipped **only** because the
code it covers was already validated at the baseline commit. The baseline is therefore the newest
ancestor of the target for which CI itself concluded `success`. No such ancestor — no `gh`, no
network, no successful run — means there is nothing to vouch for, and the **full gate runs**.
`--since <ref>` substitutes the operator's own attestation; `--full-gate` opts out entirely.

**2.4 Narrowing is a subset of EXECUTION, never of the contract.** Same script, same commit, same
clean-tree and HEAD-equals-target requirements; exit 0 is still required for the deploy to
proceed. A narrowed run is never dressed up as the full gate: `ci.sh` labels its verdict, and
`deploy.sh` logs which tiers were skipped and on what basis.

**2.5 The narrowing tooling is pinned where narrowing cannot avoid it.** Both regressions run in
the `harness` tier, and `harness` is in the **baseline of every narrowed set** — so you cannot
narrow the gate without re-certifying the thing that does the narrowing.

## 3. The mapping, and the evidence for each edge

| Path | Required tiers | Why (the dependency, not a guess) |
|---|---|---|
| `samen_core/**` | `all` | every app, adapter, spike and probe path-deps the kernel — there is no safe subset |
| `samen_web/**` | `web` + every host | `driftwood`/`pawchart`/`samenerp` path-depend it; `demo` does not, and is kept in rather than trusted to stay out |
| `samen_resend/**` | `resend` + `samenerp` | the only adapter any host path-deps (verified in `samenerp/mix.exs`); the other four are standalone |
| `samen_stripe` · `samen_postmark` · `samen_ses` · `samen_anthropic` | that package | standalone packages, each with its own gate |
| `spikes/**` | `spikes` | frozen standalone mix projects |
| `demo` · `driftwood` · `pawchart` · `samenerp` | that app | one host's gate |
| `README.md` · `CLAUDE.md` · `docs/**` | `core` | the kernel's own suite **reads** them (`doc_commands` / `doc_recipes` / `gen_app`) — a README fence has broken AC-G10-1/2 before |
| `scripts/gen_probe_guard.sh` | `gen` | it drives the generator probes |
| `scripts/**` (else) · `.github/**` · `.freebuff/**` · `ci.sh` · `ci-fast.sh` · `.gitignore` | baseline only | tooling is not covered by any tier; the harness regressions are the baseline |
| anything else | `all` | a path the selector cannot reason about is a path it cannot exclude |

**Baseline, added to every narrowed set:** `harness` (the ~1–2 min sabotage-harness regressions
that pin the selectors which certify everything else, plus the regressions from §2.5) and
`verifiers` (the whole-tree verifiers, which scan hosts and packages from outside them). Both are
cheap next to any app gate and are exactly the cross-cutting checks a per-app diff is most likely
to break invisibly.

## 4. Non-negotiables

1. **No new way to pass.** Narrowing cannot turn a red gate green: exit 0 is still required, no
   preflight is skippable, and there is still no "deploy anyway".
2. **No narrowed run claims the full gate.** The verdict label and the deploy log both say a
   subset ran, and which tiers were not re-run.
3. **Unvouchable ⇒ full gate**, including the case that invites a mistake: a CI run that succeeded
   on a commit which is *not* an ancestor of the target vouches for nothing and is refused.
4. **The mapping's evidence is the manifests.** Adding a path-dependency edge without adding it
   here is the way this design breaks; new paths default to `all`, which is why forgetting is
   slow rather than wrong.
5. **A knob that would do nothing is refused**, not ignored (`--since`/`--full-gate` outside
   `--local-gate`).
6. **CI is unchanged.** The workflow still runs `all`; the milestone discipline in `CLAUDE.md`
   ("`./ci.sh` before a milestone") still stands.

## 5. What this does NOT do

- It does not narrow CI. A pushed commit is still validated by the whole gate.
- It does not help a **kernel** change: `samen_core/**` ⇒ `all` by 2.1's own rule, because every
  consumer path-deps it. The savings are per-app, per-adapter, docs and tooling changes.
- It is not a claim that a narrowed pass is equivalent to a full one — only that every tier it
  skipped was validated at the baseline it names, and that the diff cannot have invalidated them.
- It does not make the derived baseline self-certifying: the baseline is only as good as CI's
  coverage of it, which is the same trust the non-local gate already extends to CI's verdict.

## 6. Proof

- `scripts/ci_tiers_test.sh` — 37 assertions driving the real selector against throwaway git
  repos: every row of §3, every refusal in §2.2 (plus a successful run on a non-ancestor), the
  usage errors, that every emitted tier is in `ci.sh`'s vocabulary (the cross-file invariant that
  lets the two scripts change independently), and that `--repo` is honoured at all (without which
  every fixture-based assertion would be vacuous).
- `scripts/deploy_test.sh` — 21 assertions driving the real `deploy.sh` with a **stubbed** gate in
  a throwaway checkout: the exact tier set the gate is invoked with, the derived and attested
  baselines, the non-ancestor refusal, `--full-gate`, that a **failing** narrowed gate still fails
  the deploy and never reaches the deploy step, that a dirty tree and a non-HEAD target are still
  refused, and that the knobs are refused outside `--local-gate`.
- `samen_core`'s doc-command gate re-run green after the README change (it binds every fenced
  command in the section this ADR's operator docs live in).

## 7. Consequences

- A narrowed local gate now costs the affected tiers **plus ~50s** of harness regressions on
  Windows (seconds on the Linux runners). That is deliberate: it is the price of §2.5.
- When `gh` is unavailable the derived baseline collapses to "nothing", and the operator gets the
  full gate — slower, never weaker. The remedy is `--since <ref>`, which is an attestation and is
  logged as one.
- The mapping in §3 must be maintained alongside `mix.exs` path deps. Sabotage coverage for the
  narrowing decision itself is carried by the two `*_test.sh` suites rather than by patch files,
  because the subject is a decision over git history rather than a line of production code.
