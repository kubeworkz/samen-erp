# Samen — house conventions (read before touching anything)

Elixir/Ash SaaS foundry. Layout: `samen_core` (kernel: vault/PII, policy, catalog, engines,
verifiers, generators) · `samen_web` (framework UI library: LiveViews, Mount/Plane, kit) ·
`demo` (dogfood host, API-only) · `driftwood` (freight vertical) · `pawchart` (vet vertical) ·
`spikes/` (frozen mechanism spikes). Design records live in `docs/adr/` + per-workstream
`docs/ws-*/{design,build-plan}.md` — consult the ADR before changing anything it governs.

## Code exploration — codemunch FIRST (MANDATORY, not optional)
Before you Read/Grep/Glob to orient yourself in this tree, use codemunch — this has been missed
repeatedly (agents keep defaulting to raw Read/Grep sweeps). The rule, verbatim and enforced in
`driftwood/CLAUDE.md`: your FIRST orientation action is `codemunch:explore`/`codemunch:search`/
`codemunch:fetch`/`codemunch:refs`, NOT a multi-file Read or a large-tree Grep. WHEN it fires:
reading >1 source file to understand something, or grepping/globbing any of `samen_core/`,
`samen_web/`, `driftwood/`, `pawchart/`, `demo/`, `docs/` for a symbol/caller/structure → route it
through codemunch first. A single grep for one exact string in one known file is fine; a *sweep* is
not — that is what codemunch replaces. See `driftwood/CLAUDE.md` for the full rules + decision tree.

## Suites / CI (local Postgres + pgvector required)
- Prerequisite: a local Postgres server WITH the `pgvector` extension installed (`CREATE
  EXTENSION vector`) — the samen_core AI-embeddings migration hard-requires it (ADR-043
  §7.1/M3; `docs/adr/ADR-043-ai-plane.md`). Install via `brew install pgvector` (or build
  0.8.0 from source against your pg major when no bottle exists). Without it, `./ci.sh`
  fails the samen_core suite at setup with a clear "pgvector not installed" guard message
  (`samen_core/test/test_helper.exs`), not an opaque `CREATE EXTENSION` error.
- Root gate: `./ci.sh` — spikes → samen_core → the AI eval/red-team tier → 5 adapter-package
  gates (samen_stripe/postmark/ses/resend/anthropic) → 3 gen_app probes → an opt-in
  (`SAMEN_SABOTAGE=1`) sabotage-harness step → samen_web + demo + driftwood + pawchart run
  CONCURRENTLY last (own DBs, race-free once everything registry-mutating above has finished
  sequentially). Takes minutes; must end `ROOT CI: ALL PASSED`.
- Iteration tier: `./ci-fast.sh` — spikes → samen_core → samen_web ONLY (framework core,
  skips the gen_app probes + demo/vertical gates). Fast inner-loop feedback; NOT a
  substitute for `./ci.sh` before a milestone. Ends `CI-FAST: ALL PASSED`.
- Per app: `cd samen_core && mix test` (test_helper owns DB lifecycle); `cd samen_web &&
  mix test` (alias sets up the scratch DB); verticals/demo: `MIX_ENV=test bash ci.sh`
  (full verifier gate). CI compiles with `--warnings-as-errors` — keep zero warnings.
- Sabotage harness (opt-in): `SAMEN_SABOTAGE=1 ./ci.sh` or `./scripts/sabotage.sh` —
  replays every shipped gate sabotage (`scripts/sabotages/*.patch`): apply → the NAMED
  tests must FAIL → revert → SHA-256 byte-exact restore. Gates add new sabotages as
  patches (header lines: APP / TEST_FILES / MUST_FAIL / ENV) instead of re-deriving them.
  `ENV: KEY=value` (repeatable) is exported to that patch's `mix test` ONLY — the seam that
  makes an OPT-IN tier replayable (the multinode Oban proof runs only when `SAMEN_MULTINODE=1`;
  without the flag the replay collects 0 tests and the harness refuses that vacuous green).
  Default (no args) = the full 320-patch harness (unchanged). At 320 the full serial run
  exceeds the 600s single tool-call ceiling, so certify it **backgrounded** or in **chunks**
  via additive selection flags (they COMPOSE as an intersection; a FILTERED run certifies
  ONLY its subset — full coverage still needs a full/background run):
  `--app <name>` (per-app: samen_web/samen_core/driftwood/pawchart/demo/samen_stripe),
  `--range <lo>-<hi>` / `--from`/`--to` (by filename number, inclusive),
  `--touching <path>…` / `--changed [<ref>]` (only patches whose touched files intersect
  your diff — the verifier primitive), and `--list`/`--dry-run` to preview a selection
  (names + resolved APP + count) without applying anything. The header preflight still
  lints ALL patch headers even under a filter. For a full sweep, `scripts/sabotage_parallel.sh
  [--jobs <n>] [--intra <k>] [same filters]` runs the SAME patches in parallel — one isolated
  replay tree, build cache, lock AND test DATABASE per slice, all slices concurrent — after
  asserting coverage against the harness's own selection count (an under-covering partition
  fails before anything is applied). Slicing is per app AND, when a wider pool makes it pay,
  per intra-app chunk: every DB-backed app's `config/test.exs` takes its test DB name from
  `SAMEN_TEST_DB` (unset ⇒ the canonical name, unchanged), which `sabotage.sh --test-db` sets
  per slice. That seam is what removes the old floor — without it two slices of ONE app drop
  each other's schema, which is why the sweep used to be bounded by the largest app (samen_core,
  173 of 334 patches). The driver refuses to launch while a test file reaches outside its
  per-slice DB in >1 slice (`--allow-shared-scratch` to attest otherwise) and lowers an unpinned
  `--jobs` to fit Postgres's `max_connections`. A slice with no cache yet is warm-started by
  copying a sibling's build cache — preferring one that has never replayed a patch, and normalising
  the copy's Elixir manifest (`scripts/sabotage_seed_manifest.exs`) so the cache is actually reused
  in the new tree instead of recompiled (measured: 777 files/1m20 → 0 files) — under `--no-seed`.
  Plan/coverage/guard regression:
  `scripts/sabotage_intra_test.sh` (all via `--list`).

## Fail-honest adapter contract (ADR-014, ADR-024, ADR-026)
An unconfigured/unimplemented adapter NEVER returns `{:ok, _}` for work it did not do —
it returns `{:error, :not_configured | :not_implemented}`. Precedents: `Samen.Delivery.Smtp`,
`Samen.Files.Storage.S3`, the `--deploy` runtime raises on missing secrets. A stub that
claims success is the exact lie the gates sabotage-test for
(`samen_core/test/files_storage_test.exs`). Never "make it pass" by faking an ok.

## Per-plane masking tests (the masking watch-list discipline)
Every surface rendering a vault-routed (🔒) field ships THREE proofs — green: tenant plane
(and operator-with-grant) resolves plaintext; red: operator-without-grant renders `••••`,
NEVER plaintext, NEVER a `vt_*` token in DOM/CSV/API; sabotage twin: the mask assertion is
proven refutable (plane flip goes clear; a modeled leak IS detected). Use `Samen.MaskingCase`
(`use Samen.MaskingCase` — `resolve_on_plane/4`, `assert_plane_clear!/2`,
`assert_plane_masked!/2`, `assert_masked_dom!/2`, `assert_leak_detected!/2`). Reference
tests: `samen_web/test/samen/web/file_preview_masking_test.exs` (first consumer),
`samen_web/test/samen/web/notifications_masking_test.exs`. All reads resolve through
`Samen.Api.PiiResolution` on the actor's plane — never bypass it, never hand-mask.

## Chokepoints / guards (governed-by-construction — never weaken to make a test pass)
- Files: `Samen.Files.upload/3` is the ONLY path minting a `storage_key`;
  `Samen.Files.ChokepointGuard` structurally refuses direct creates/updates. Fresh files
  are `:quarantined` (fail-closed); promotion only via a clean scan (`Scanner.Reject` default).
- PII writes: through governed actions only — `Samen.Pii.WriteGuard` + `Samen.Vault.Change`;
  `Samen.Type.VaultField` is the last-line guard refusing raw plaintext.
- Reads: org-scoped (`Samen.Policy.OrgScope`) + keyset-bounded via the Reads helpers.
- Test infra ships in lib: `Samen.RedPath`, `Samen.Factory`, `Samen.MaskingCase` — every
  red-path pairs denial with a positive control (anti-tautology; a test that cannot fail is a bug).

## Abbrev registry — HANDS-OFF
NEVER add/edit rows in any `priv/abbrev_registry.json` by hand. Allocation goes through the
sanctioned allocator only (`mix samen.abbrev.reserve`, driven by `mix samen.gen.*`; ADR-023).
Any probe/script touching the registry must restore it SHA-256 byte-exact on every exit path
— INCLUDING an OS-level interrupt (SIGINT/SIGTERM), not just normal/error returns (T107).
Enforced by `ci.sh`'s `run_gen_probe` wrapper around the three `samen_core/priv/gen_*_probe.exs`
invocations: it snapshots the registry to a `mktemp`'d file before each probe and restores +
SHA-256-verifies it in a trap covering SIGINT/SIGTERM/ERR/EXIT, independent of whether the
probe itself gets to run its own cleanup (SIGINT is not trappable inside the BEAM at all).
Each run also OWNS its scratch dir: the wrapper creates it (`mktemp -d`), passes it down as
`SAMEN_GEN_PROBE_SCRATCH`, and removes exactly that path — never a `_gen_*_scratch*` glob,
which deletes a CONCURRENT probe's app mid-run (pinned by
`scripts/gen_probe_scratch_isolation_test.sh`, part of every gate tier).

## Framework-first, ≈0-LOC vertical mounts
Features live in samen_core/samen_web; verticals adopt via one router/macro call
(e.g. `samen_files_routes`) or a scope mount at ≈0 authored LOC. Never re-implement
framework behavior inside demo/driftwood/pawchart — that fails the leverage guard.

TENANT pages `use Samen.Web.Tenant.Live` (never `use Phoenix.LiveView`): the wrapper injects the
`render/1` that composes `<.app_shell>` around the page's `tenant_sidebar/1` + `tenant_page/1`, and
a page-owned `render/1` is a COMPILE ERROR — so a signed-in tenant surface cannot be written
outside the chrome. Proofs: `samen_web/test/samen/web/tenant_live_wrapper_test.exs`;
completeness sweep: `samen_web/test/samen/web/tenant_shell_coverage_test.exs`; sabotage 344.

## Agents / process
Serialized agents: ONE deliverable per agent call, fan-out concurrency 1. Every phase ends
with an adversarial gate: sabotages flip named tests and revert byte-exact; suites + every
ci.sh green before/after. Phase commits follow `git log --oneline -5` house style.
