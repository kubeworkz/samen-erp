#!/usr/bin/env bash
# ci.sh — run all spike test suites + samen_core + demo gate in sequence.
# Exits non-zero on the first failure.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- TIER SELECTION (opt-in, fail-closed) ---------------------------------------------
# This gate is one sequence of INDEPENDENT tiers. Running every one of them is the contract,
# and it is the default: SAMEN_CI_TIERS unset ⇒ `all`, byte-identical to the pre-tier gate
# (CI is untouched). But a change confined to ONE app does not need every other app's gate,
# and the full sequence costs ~90 minutes on a Windows checkout — the difference between a
# deploy gate an operator actually runs and one they wait out.
#
# So a subset of tiers may be selected: SAMEN_CI_TIERS=core,demo ./ci.sh. Selection is a
# subset of EXECUTION, never of the contract: a non-`all` run announces its scope up front,
# every skipped tier says so in place, the final verdict is labelled TIER SUBSET, and the
# preflights below (cheap, read-only, fail-fast) ALWAYS run — they are what makes a partial
# run safe to start at all.
#
# WHO MAY PICK A SUBSET is deliberately not decided here. scripts/ci_tiers.sh derives a tier
# set from a diff and returns `all` (i.e. refuses to narrow) for any path it cannot vouch
# for; scripts/deploy.sh is the caller that relies on it. CI always runs `all`.
# NOTE the `-` (not `:-`): an UNSET variable means `all` (CI and every existing caller), but an
# explicitly EMPTY one is a typo and must be rejected — `:-` would silently turn `SAMEN_CI_TIERS=`
# into a full run, and a knob that cannot express "you made a mistake" is not fail-closed.
CI_TIERS="${SAMEN_CI_TIERS-all}"

# tier_on <tier> — true when <tier> was selected ('all' selects every tier).
tier_on() {
  case ",$CI_TIERS," in
    *",all,"*) return 0 ;;
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

# skip_tier <tier> <what> — report a skip and return 0 (so `if skip_tier …` reads plainly).
skip_tier() {
  if tier_on "$1"; then return 1; fi
  echo "==> SKIPPING $2 (tier '$1' not selected — SAMEN_CI_TIERS=$CI_TIERS)"
  return 0
}

# The vocabulary is CLOSED and validated: an unknown or empty selection is a typo, and a typo that
# silently ran (almost) nothing while printing ALL PASSED is the exact failure this gate exists to
# prevent. Refuse instead — a subset you cannot name is a subset you cannot reason about.
KNOWN_TIERS="spikes core ai verifiers stripe postmark ses resend anthropic gen harness web demo driftwood pawchart samenerp"
if [[ -z "$CI_TIERS" ]]; then
  echo "==> TIER ERROR: SAMEN_CI_TIERS is empty. Use 'all' or a comma-separated subset of:"
  echo "    $KNOWN_TIERS"
  exit 1
fi
for tier in ${CI_TIERS//,/ }; do
  if [[ "$tier" == "all" ]]; then continue; fi
  if [[ " $KNOWN_TIERS " != *" $tier "* ]]; then
    echo "==> TIER ERROR: '$tier' is not a known tier — refusing to run a subset that cannot be reasoned about."
    echo "    Known tiers: $KNOWN_TIERS (or 'all')."
    exit 1
  fi
done

if [[ "$CI_TIERS" != "all" ]]; then
  echo "==> TIER SCOPE: SAMEN_CI_TIERS=$CI_TIERS — this run executes a SUBSET of the gate."
  echo "    Unlisted tiers are SKIPPED, not passed, and the verdict line records it. Only"
  echo "    scripts/ci_tiers.sh's diff-derived set (or an operator quoting it) should do this."
fi

# --- SABOTAGE PREFLIGHTS (fail closed, seconds–minutes) --------------------------------
# Four read-only guards run before the gate is spent. Each answers a question knowable in
# seconds that was, historically, only discovered ~an hour into the sabotage replay (or the
# app gates) — and every class cost at least one full gate:
#   * residue — an applied sabotage in this checkout poisons every baseline (12-e5 reached main);
#   * EOLs    — `eol=lf` declared but CRLF on disk → `git apply` rewrites it → no byte-exact
#               revert (died 47 patches in on 133-t84b, misreported by the SHA gate);
#   * apply   — a patch whose anchor moved no longer applies (165-t85 / 243-a2 / 255-a4);
#   * anchors — a patch anchored to a renamed/moved or prose-named test still APPLIES but
#               cannot flip (224-d3 / 300-t183b) → a phantom "vacuous gate" deep in the replay.
# The guards and their exact repairs live in scripts/sabotage_preflight.sh — the single source
# of truth, which scripts/sabotage.sh ALSO runs before its own replay (so a direct harness run
# fails fast too, and skips its copy with --no-preflight because this gate already ran it).
# Read-only: they revert nothing, repair nothing, and print nothing when the tree is clean.
echo "==> Preflights: residue · EOLs · patch applicability · test anchors"
if ! bash "$REPO_ROOT/scripts/sabotage_preflight.sh"; then
  echo ""
  echo "==> ROOT CI: FAILED — a sabotage preflight failed (see above). Repair the listed"
  echo "    path/patch/anchor and re-run; do not spend the gate on it."
  exit 1
fi

run_spike() {
  local spike_dir="$1"
  local spike_name
  spike_name="$(basename "$spike_dir")"
  echo "==> Running tests for spike: $spike_name"
  (
    cd "$spike_dir"
    mix deps.get --quiet
    mix test
  )
  echo "==> spike $spike_name: PASSED"
}

if ! skip_tier spikes "the spike suites (spikes/*)"; then
# --- spike list ---
run_spike "$REPO_ROOT/spikes/s00_smoke"
run_spike "$REPO_ROOT/spikes/s02_transformer"
# Gate-1 F6: s03/s04 re-enabled — both suites pass (s03 15 tests, s04 6 tests)
# against local Postgres. Their mechanisms are also ported into samen_core, but
# the spike suites are green so we run them rather than drop coverage.
run_spike "$REPO_ROOT/spikes/s03_fragments"
run_spike "$REPO_ROOT/spikes/s04_catalog_tx"
run_spike "$REPO_ROOT/spikes/s05_vault"
run_spike "$REPO_ROOT/spikes/s07_pii_reads"

echo ""
echo "==> All spikes passed."
fi

if ! skip_tier core "the samen_core kernel suite (samen_core/**). Its doc tests read README.md and docs/ too."; then
# --- samen_core kernel tests ---
echo ""
echo "==> Running samen_core tests"
(
  cd "$REPO_ROOT/samen_core"
  mix deps.get --quiet
  mix test --warnings-as-errors
)
echo "==> samen_core: PASSED"
fi

# --- L4 multi-node Oban proof (T90) — permanent OPT-IN tier (SAMEN_MULTINODE=1) --------
# Boots TWO real BEAM peer nodes against ONE Postgres and proves the Oban substrate is
# safe under multiple nodes: (1) exactly-once fetch across nodes (SKIP LOCKED — 120
# distinct jobs, no double-grab), (2) `unique` insert-time dedup with a refutable no-unique
# control, (3) reveal auto-revoke FAILOVER (kill the enqueuing node; the survivor runs the
# scheduled revoke exactly once — no double side effect). This is a genuine distributed
# test (local nodes satisfy spec §L4), not a simulation. OPT-IN because it needs epmd + a
# dedicated non-sandbox DB + real distribution (~10s): the default green-only path skips it;
# phase gates and the final sweep run it explicitly. Every node spawns+joins inside the
# test's own lifecycle — nothing is backgrounded and polled.
echo ""
if [[ "${SAMEN_MULTINODE:-0}" == "1" ]]; then
  echo "==> Running multi-node Oban proof (SAMEN_MULTINODE=1 — two BEAM nodes, one Postgres)"
  (
    cd "$REPO_ROOT/samen_core"
    epmd -daemon 2>/dev/null || true
    SAMEN_MULTINODE=1 mix test test/multinode/oban_multinode_test.exs
  )
  echo "==> multi-node Oban proof: PASSED"
else
  echo "==> Skipping multi-node Oban proof (opt-in: SAMEN_MULTINODE=1 ./ci.sh boots the 2-node cluster)"
fi

if ! skip_tier ai "the AI runtime eval + mask-leak red-team tier (ADR-043 D8)"; then
# --- AI runtime eval + mask-leak red-team tier (ADR-043 §10 / D8, T72) -----------------
# The PERMANENT D8 CI tier — a keyless, deterministic runtime eval of the AI plane, wired
# as a first-class ROOT-gate step (like the samen_core suite / the demo verifier gate) so a
# mask leak or an eval regression FAILS THE ROOT GATE. Two standing gates run here:
#   (1) the mask-leak RED-TEAM (RP-AI-7, ADR-043 §10.2) — full-DB vault CANARY seeding
#       (real Factory vault writes, two orgs) fired through EVERY AI egress surface (the six
#       T68 verbs, the T69 MCP tools, the T70 support operator, the T71 CRM + analytics
#       surfaces, the T67 embeddings plane) asserting ZERO canary plaintext + ZERO vt_ token
#       reaches ANY egress class EG1–EG6 (provider recording, vector store, captured logs,
#       telemetry events, rendered errors, MCP responses, persisted drafts) — plus cross-org
#       isolation and the §3.2a multi-turn expired-grant re-mask (RP-AI-10);
#   (2) the grounding-context EVAL (ADR-043 §10.1) — the committed ≥20-case corpus asserted
#       at the AUTHORITATIVE ≥90% context-assembly bar (an assembly-not-fidelity bar, §10).
# Keyless (Provider.Fake / Embedder.Deterministic) + deterministic — no flake, because a
# flaky permanent gate is a real red; SAMEN_AI_LIVE=1 is the sole live lane, never in CI.
# Sabotage-refutable at the TIER level (scripts/sabotages/53-*): a value-layer mask leak
# flips the NAMED EG1 red-team test in this exact `mix test test/ai_eval/` run, proving the
# TIER fails, not merely a unit test. samen_core's own `mix test` above also loads these
# files (test/ai_eval/); this step re-runs them as the named, legible D8 tier so a leak is
# attributable to the AI plane. NOT wired into the generated-app ci_sh.eex template (that
# cross-cutting generator change is decomposed out — backlog T134).
echo ""
echo "==> Running AI runtime eval + mask-leak red-team tier (ADR-043 D8 / §10 — T72)"
(
  cd "$REPO_ROOT/samen_core"
  mix test --warnings-as-errors test/ai_eval/
)
echo "==> AI eval tier: PASSED"
fi

if ! skip_tier verifiers "the whole-tree verifiers (agent_coverage · tool_actor_identity · tool_surface · replay_schema · analytics_producer · db_boot)"; then
# --- agent-coverage verifier (ADR-047 A7 / §9#6) --------------------------------------
# The agent loop A1-A6 built is made SELF-DEFENDING here. `mix samen.verify.agent_coverage`
# runs from samen_core but scans the WHOLE umbrella tree (the anti-bypass probe technique),
# so it discovers driftwood's shipped agent (non-vacuity floor) and locks in the F-4
# obligation by static AST: NO `tool_schema/0`-exporting module may call
# `Samen.AI.Agent.start/run` — a tool that cannot name the loop-entry primitives cannot
# reopen the raw-spawn recursion escape (ADR-047 §10a row 19; the A6 verifier's R-A6-3),
# regardless of which spawn primitive a future edit reaches for. It also asserts the
# opted-in tools declare both callbacks + carry tests, the agent-run resource carries its
# :shred retention arm (§7.4), every agent ships an AgentCase proof, and the TREE-WIDE
# leverage guard (no vertical re-implements agent behaviour outside its definition/router).
# Fail-closed (:erlang.halt(1)); sabotage-refutable at scripts/sabotages/268-*. NOT wired
# into the ci_sh.eex generated-app template — the non-vacuity floor is host-specific (a
# generated app authors no agent until it adopts one), the same T134 decomposition
# `ai_prompt_masking` took; recorded as ADR-047 §10a row 22.
echo ""
echo "==> Running agent-coverage verifier (ADR-047 A7 / §9#6 — F-4 raw-spawn AST lock + coverage floor)"
(
  cd "$REPO_ROOT/samen_core"
  mix samen.verify.agent_coverage
)
echo "==> agent coverage verifier: PASSED"

# --- tool-actor-identity verifier (T185, ADR-043 §6.2/§7 — OSS-SCAN findings/009 #2) ---
# The structural half of the "ctx[:actor]-only" tool identity rule (informal convention at
# agent/tools.ex ~:18; ADR-043 §6.2: the chokepoint never elevates, substitutes, or
# synthesizes an actor). `mix samen.verify.tool_actor_identity` refuses ANY tool schema
# declaring an actor/org/tenant identity parameter, FOUNDRY-WIDE across BOTH shared
# tool-schema surfaces — the `Samen.Automation.Action` agent-tool registry (core + host
# `extra:`, so a generated app cannot slip an actor param past this gate either) and the
# `Samen.AI.Mcp` tool catalogue — not scoped inside any one feature's own work. Fail-closed
# (:erlang.halt(1)); sabotage-refutable at scripts/sabotages/286-*.
echo ""
echo "==> Running tool-actor-identity verifier (T185, ADR-043 §6.2/§7 — ctx[:actor]-only tool identity)"
(
  cd "$REPO_ROOT/samen_core"
  mix samen.verify.tool_actor_identity
)
echo "==> tool-actor-identity verifier: PASSED"

# --- tool-surface verifier (T183b, UXD-11/UXD-12 — ADR-043 §7/§9 + ADR-047 §5.1a) -----
# T183 shipped `Samen.AI.ToolSurface` (the one surface-scoped tool registry: :mcp /
# :operator / :tenant / :ci_eval) with no verifier tier asserting its invariants, so they
# could rot silently (UXD-12). `mix samen.verify.tool_surface` closes that gap: every
# opted-in tool (`Action.tool_kinds/0`) lands on at least one surface (a malformed
# declaration fails CLOSED to unreachable-everywhere, which this gate now catches loudly
# instead of silently), the `:mcp` registry agrees with its own source
# (`Samen.AI.Mcp.tool_names/0`), `surfaces/0` stays exactly the closed four, and every tool
# on `:ci_eval` is `effect: :read` — the structural half of UXD-11's "a write tool can
# never open a real E3 approval from a CI eval run" guarantee. Fail-closed
# (:erlang.halt(1)); sabotage-refutable at scripts/sabotages/300-*.
echo ""
echo "==> Running tool-surface verifier (T183b, UXD-11/UXD-12 — Samen.AI.ToolSurface invariants)"
(
  cd "$REPO_ROOT/samen_core"
  mix samen.verify.tool_surface
)
echo "==> tool-surface verifier: PASSED"

# --- replay-schema verifier (ADR-052 §3 R6 / Lane B P1) --------------------------------
# Masked session replay is the one feature whose STORAGE is the whole risk: the value a frame
# would record is exactly the value the vault exists to keep out of Postgres. ADR-052 answers
# that with an ALLOWLIST — a frame may contain only the closed capture vocabulary
# (Samen.Replay.Values) under a declared per-kind key policy (Samen.Replay.FrameSchema) — and
# `mix samen.verify.replay_schema` is the check that the allowlist is still an allowlist. Its
# load-bearing half is BEHAVIOURAL: it drives the real `validate/1` with tampered frames (a
# plaintext string, a bare `vt_` token, an unknown kind, a key outside a closed set, an
# oversized payload), every keep-listed key with a PII-shaped value, and probes
# `Values.sanitize/2` for fail-honesty — so a refusal that stopped firing flips the gate even
# when the declarations still look right (that is exactly what sabotage 350 does). The
# declaration half additionally refuses a frame kind with no key policy, an empty closed key
# set, a carrier-shaped kind/key/keep-list entry, and a `max_payload_bytes` above its hard
# ceiling. Module-introspecting (not tree-scoped), so it is NOT in Samen.Verifier.Registry's
# `samen.verify.fleet` walk. Fail-closed (:erlang.halt(1)); P2 (capture) is what starts passing
# real frames through `validate/1`, this gate is the contract it must satisfy.
echo ""
echo "==> Running replay-schema verifier (ADR-052 §3 R6 — masked-replay allowlist + live refusals)"
(
  cd "$REPO_ROOT/samen_core"
  mix samen.verify.replay_schema
)
echo "==> replay-schema verifier: PASSED"

# --- analytics-producer verifier (ADR-021 / mount-ledger Amendment 3) ------------------
# The SILENT-EMPTY-FUNNEL gate, run TREE-SCOPED over the whole checkout: any app whose
# shipped `lib/` mounts the own-org analytics reader (`samen_tenant_analytics_routes/2`)
# must also configure its product-event producer — the `Samen.Analytics` emitter
# (`product_event_resource`) AND a `:product_event_rollup` spec in `config :samen_core,
# :rollups`. Without both, the `/analytics` page is empty for EVERY org forever under copy
# that reads as "no data yet" (samenerp shipped exactly that: readers mounted, producer
# unwired). Static (source + config only — no DB, no boot), fail-closed on an empty walk,
# sabotage-refutable. Each host's own gate runs the same verifier on itself.
echo ""
echo "==> Running analytics-producer verifier (ADR-021 — silent-empty-funnel gate, tree-scoped)"
(
  cd "$REPO_ROOT/samen_core"
  mix samen.verify.analytics_producer --root "$REPO_ROOT"
)
echo "==> analytics-producer verifier: PASSED"

# --- db-boot verifier (the tolerant-boot gate — `Samen.TestDb`) ---------------------------
# The harness half of every gate's database story, run TREE-SCOPED over the whole checkout:
# the emitted templates + their goldens (`test_helper`, `ci_bootstrap`, `anti_tautology_probe`),
# the verticals' own `priv/` probes and bootstraps, and every host's `test/test_helper.exs` /
# `test/support/` harness must reach the database through ONE shared tolerant boot — never a
# hand-rolled `:ok = Ecto.Adapters.Postgres.storage_up(...)`. That line MatchErrors on the
# benign `{:error, :already_up}` race that follows another BEAM's exit (drop refused while the
# previous pool closes), killing a harness at its own boot line before it asserts anything —
# observed 2026-10-20 when the PawChart and SamenERP anti-tautology probes died exactly there
# under this gate. The defect is INVISIBLE in a green run, which is why nothing else in CI
# would notice it coming back. Static (source only — no DB, no boot), fail-closed on an
# unwalkable or empty tree, sabotage-refutable at scripts/sabotages/367-*.
echo ""
echo "==> Running db-boot verifier (tolerant boot — emitted harnesses + priv probes route through Samen.TestDb)"
(
  cd "$REPO_ROOT/samen_core"
  mix samen.verify.db_boot --root "$REPO_ROOT"
)
echo "==> db-boot verifier: PASSED"
fi

if ! skip_tier stripe "the samen_stripe adapter package gate"; then
# --- samen_stripe adapter package gate (ADR-038 §8.1, T18/B1) ---
# The first-party-but-separate Stripe billing adapter (skeleton): path-deps on
# samen_core ONLY (never samen_web), owns its own vendor HTTP client dep (req),
# and runs its own standalone suite. Wired here (root gate) rather than
# ci-fast.sh, matching the demo/driftwood/pawchart precedent — ci-fast.sh stays
# framework-only (spikes/samen_core/samen_web). samen_core itself never
# references this package (INV-4; proved by samen_core's own
# billing_vendor_free_test.exs above, which already ran).
echo ""
echo "==> Running samen_stripe tests (ADR-038 B1 skeleton — standalone, samen_core path-dep only)"
(
  cd "$REPO_ROOT/samen_stripe"
  mix deps.get --quiet
  mix test --warnings-as-errors
)
echo "==> samen_stripe: PASSED"
fi

if ! skip_tier postmark "the samen_postmark adapter package gate"; then
# --- samen_postmark adapter package gate (ADR-038 §4/§8.1, T27/C1) ---
# The first-party-but-separate, INBOUND-CAPABLE reference delivery adapter:
# path-deps on samen_core ONLY (never samen_web), owns its own vendor HTTP
# client dep (req), runs its own standalone suite INCLUDING the shared
# cross-family Samen.AdapterConformanceCase kit (samen_core, ADR-038 §4.5;
# UXD-07/A6 switched this adapter onto it — samen_ses/samen_resend still cite
# Samen.Delivery.ProviderConformanceCase, which is UNCHANGED).
# samen_core itself never references this package (INV-4; proved by
# samen_core's own delivery_vendor_free_test.exs above, which already ran).
echo ""
echo "==> Running samen_postmark tests (ADR-038 C1 reference adapter — standalone, samen_core path-dep only)"
(
  cd "$REPO_ROOT/samen_postmark"
  mix deps.get --quiet
  mix test --warnings-as-errors
)
echo "==> samen_postmark: PASSED"
fi

if ! skip_tier ses "the samen_ses adapter package gate"; then
# --- samen_ses adapter package gate (ADR-038 §4/§8.1, T94/C1) ---
# The first-party-but-separate SECOND reference delivery adapter (M1 ruling):
# path-deps on samen_core ONLY (never samen_web), owns its own vendor HTTP
# client dep (req) + AWS SigV4 signing dep (aws_signature, ADR-038 §8.2), runs
# its own standalone suite INCLUDING the shared
# Samen.Delivery.ProviderConformanceCase harness (samen_core, ADR-038 §4.5) —
# UNCHANGED, same harness samen_postmark/samen_resend (T27/T95) run. NOT
# inbound-capable (ADR-038 §4.5 adapter split). samen_core itself never
# references this package (INV-4; proved by samen_core's own
# delivery_vendor_free_test.exs above, which already ran, plus the scoped
# SamenSes/aws/amazonses grep the T94 gate runs — ADR-038 §8.3).
echo ""
echo "==> Running samen_ses tests (ADR-038 C1 second reference adapter — standalone, samen_core path-dep only)"
(
  cd "$REPO_ROOT/samen_ses"
  mix deps.get --quiet
  mix test --warnings-as-errors
)
echo "==> samen_ses: PASSED"
fi

if ! skip_tier resend "the samen_resend adapter package gate (see: samenerp path-deps it)"; then
# --- samen_resend adapter package gate (ADR-038 §4/§8.1, T95/C1) ---
# The first-party-but-separate THIRD reference delivery adapter (M1 ruling):
# path-deps on samen_core ONLY (never samen_web), owns its own vendor HTTP
# client dep (req) — no extra signing dep needed, HMAC-SHA256 for the
# Svix-style webhook scheme is served natively by Erlang/OTP's :crypto — and
# runs its own standalone suite INCLUDING the shared
# Samen.Delivery.ProviderConformanceCase harness (samen_core, ADR-038 §4.5) —
# UNCHANGED, same harness samen_postmark/samen_ses (T27/T94) run. NOT
# inbound-capable (ADR-038 §4.5 adapter split). samen_core itself never
# references this package (INV-4; proved by samen_core's own
# delivery_vendor_free_test.exs above, which already ran, plus the scoped
# Resend-module/`:resend`-dep-atom grep the T95 gate runs — ADR-038 §8.3).
echo ""
echo "==> Running samen_resend tests (ADR-038 C1 third reference adapter — standalone, samen_core path-dep only)"
(
  cd "$REPO_ROOT/samen_resend"
  mix deps.get --quiet
  mix test --warnings-as-errors
)
echo "==> samen_resend: PASSED"
fi

if ! skip_tier anthropic "the samen_anthropic AI-provider adapter package gate"; then
# --- samen_anthropic AI-provider adapter package gate (ADR-043 §5.1, T64/D1) ---
# The first-party-but-separate reference AI-provider adapter: path-deps on samen_core
# ONLY (never samen_web — the samen_stripe/samen_postmark §8.1 layout precedent), owns
# its own vendor HTTP client dep (req, used ONLY on the SAMEN_AI_LIVE=1 live lane), and
# runs its own standalone suite. KEYLESS/fail-honest (ADR-043 §4; ADR-014/024/026):
# unconfigured complete/2 -> {:error, :not_configured} (never a fake ok); the request-
# shaping/response-parsing pipeline is proven through an injected fixture transport so
# `mix test` makes ZERO live LLM calls. samen_core itself never references this package
# (INV-4; proved by samen_core's own Samen.AI.VendorFreeTest, which already ran above).
echo ""
echo "==> Running samen_anthropic tests (ADR-043 D1 reference AI adapter — standalone, samen_core path-dep only)"
(
  cd "$REPO_ROOT/samen_anthropic"
  mix deps.get --quiet
  mix test --warnings-as-errors
)
echo "==> samen_anthropic: PASSED"
fi

# --- T107: interrupt-safe wrapper for the registry-mutating gen_app probes ------------
# See scripts/gen_probe_guard.sh for the full rationale (recurring Phase-2 failure,
# SIGINT non-trappability inside the BEAM, etc.) — sourced here so this exact code is
# also what scripts/interrupt_probe_test.sh (the T107 interrupt-proof harness) exercises.
source "$REPO_ROOT/scripts/gen_probe_guard.sh"

if ! skip_tier gen "the generator probes (gen_app flagship · post-app · deploy · gen_agent)"; then
# --- gen_app tier: the flagship generative proof (WS-D D6, AC-X-1) ---
# The PERMANENT gen_app test tier (design.md §4). In ONE automated run it generates a
# fresh app with the FULL running product (--web --api --seeds --observability), runs
# its entire ci.sh (verifier gate + generated tests + all red-paths), seeds it via the
# emitted `mix <app>.seed`, boots it and HTTP-probes /healthz + the framework LiveViews
# + the bounded deny-by-default JSON:API, and drives TWO sabotages (API allowlist,
# observability db_statement) that each flip the gate and revert byte-exact — proving the
# generated gate is non-vacuous. Kept as a SEPARATE step (not folded into `mix test`)
# because it deps.get/compiles a scratch app and runs its ci.sh five times (~100s); it
# needs local Postgres. Zero scratch residue; the committed abbrev registry is restored
# byte-exact on every exit path.
run_gen_probe "priv/gen_app_flagship_probe.exs" \
  "gen_app flagship probe (WS-D D6 / AC-X-1 — generate → ci.sh → seed → boot → 2 sabotages)"

# --- gen_app tier: the POST-APP generator proof (WS-D D7a, AC-G4-7 / AC-G26-1/3) ---
# The permanent proof for `mix samen.gen.scope` + `mix samen.gen.resource`: it generates a
# fresh app, adds a SECOND scope + Tier-0 resource via the post-app generators, re-baselines
# schema.dict.json, runs the app's FULL ci.sh (the whole verifier gate STILL green with the
# new resource + the four emitted G26 red-path files green), runs the emitted per-resource
# anti-tautology probe, then SABOTAGES a red-path mechanism (removes the resource's RoleAtLeast
# admin gate) and proves the RBAC red path FLIPS + reverts byte-exact. Correct-by-construction,
# ZERO hand-edits. Separate step (deps.get/compiles a scratch app + runs its ci.sh; ~80s; needs
# local Postgres). Zero scratch residue; the committed abbrev registry is restored byte-exact.
run_gen_probe "priv/gen_post_probe.exs" \
  "gen_app post-app generator probe (WS-D D7a — gen.scope + gen.resource → ci.sh + 4 G26 files + sabotage)"

# --- gen_app tier: the DEPLOY proof (WS-D D10, AC-G16-1/2/3 — ADR-024 fail-honest) ---
# The permanent proof for `mix samen.gen.app --deploy`: it generates a fresh --web --api
# --deploy app, runs its FULL ci.sh (the deploy artifacts do NOT break the gate — AC-G16-1),
# asserts the six deploy artifacts exist + fly.toml parses, then drives the load-bearing
# fail-closed RED PATH: the emitted config/runtime.exs RAISES (naming the secret) on EACH
# missing required secret (DATABASE_URL/SECRET_KEY_BASE/PHX_HOST/SAMEN_KMS_*) while staying
# silent when all are set + in :dev — and a sabotage that makes the KMS read permissive
# FLIPS the raise + reverts byte-exact (non-vacuity). Finally it asserts the runbook names
# the four operator TODOs with no turnkey "fly deploy" claim (AC-G16-3). NO live Fly/Neon/KMS
# call anywhere (ADR-024 — no live deploy execution). Separate step (deps.get/compiles a
# scratch app + runs its ci.sh; ~75s; needs local Postgres). Zero scratch residue; the
# committed abbrev registry is restored byte-exact.
run_gen_probe "priv/gen_app_deploy_probe.exs" \
  "gen_app deploy probe (WS-D D10 / AC-G16-1/2/3 — --deploy → ci.sh + fail-closed runtime + sabotage)"

# --- gen_agent tier: the AGENT scaffolder proof (ADR-047 A7) ---------------------------
# The permanent proof for `mix samen.gen.agent`: it scaffolds a first-party agent (a valid
# opted-in tool) + its AgentCase proof into a scratch scope, runs the emitted test (MUST
# pass — correct-by-construction), SABOTAGES the definition's tools with a non-opted-in
# kind (the four-way-intersection resolution assertion MUST flip), and reverts to green.
# SCHEMA: NONE — gen.agent reserves no abbrev + writes no migration, so the committed
# registry is untouched and run_gen_probe's SHA-256 byte-exact restore (T107) is satisfied
# trivially; the probe additionally leaves zero file residue. Wrapped by run_gen_probe like
# the three gen_app probes so the interrupt-safe registry backstop covers it uniformly.
run_gen_probe "priv/gen_agent_probe.exs" \
  "gen_agent probe (ADR-047 A7 — samen.gen.agent scaffold → emitted AgentCase proof + sabotage)"
fi

if ! skip_tier harness "the sabotage-harness regressions (selection + intra-app selection)"; then
# --- gen-probe SCRATCH OWNERSHIP regression --------------------------------------------
# `run_gen_probe` (scripts/gen_probe_guard.sh) creates each run's scratch dir and sweeps
# exactly that path. It used to glob `_gen_*_scratch*`, so one probe could delete a
# CONCURRENT probe's app mid-run — observed three times on the post probe, and it reads as a
# failure of whatever that probe was testing rather than of the guard. This pins the new
# contract: the dir is handed to the probe as SAMEN_GEN_PROBE_SCRATCH, exactly that dir is
# removed, and a planted sibling (the old glob's shape) survives byte-intact. Its negative
# control (raw `mix run`, no guard) must fail closed, so the assertions cannot pass by
# accident. No DB, applies no patch; a few seconds.
echo ""
echo "==> Running gen-probe scratch ownership regression (the guard sweeps only its own run's dir)"
bash "$REPO_ROOT/scripts/gen_probe_scratch_isolation_test.sh"
echo "==> gen-probe scratch isolation regression: PASSED"

# --- Sabotage-harness SELECTION regression (ADR-047 A4 fold (a)) ----------------------
# `scripts/sabotage.sh --changed [<ref>]` is the VERIFIER PRIMITIVE ("replay the sabotages
# relevant to my diff"). It used to derive its touched set from `git diff --name-only`,
# which lists only TRACKED paths — so any batch that ADDED files silently under-selected
# (A3's own new patches 247/248/249 were missed, because their touched files were brand
# new). A selector that reports a confident green over a hole is worse than no selector,
# so the union with `git ls-files --others --exclude-standard` is pinned by a permanent,
# UNCONDITIONAL gate step (unlike the opt-in replay below, this one is ~1s, needs no DB,
# and applies no patch — it only runs `--list`). Ships with its own negative control.
echo ""
echo "==> Running sabotage-harness selection regression (ADR-047 A4 fold (a) — --changed must see untracked files)"
bash "$REPO_ROOT/scripts/sabotage_selection_test.sh"
echo "==> sabotage selection regression: PASSED"

# --- Sabotage-harness INTRA-APP parallelism regression ---------------------------------
# `scripts/sabotage_parallel.sh` certifies the whole sweep in parallel, and it cuts the largest
# APP into slices — which is only possible because every DB-backed app's `config/test.exs` reads
# its test DB name from `SAMEN_TEST_DB` (unset ⇒ the canonical name, unchanged) and the harness
# sets it per slice via `--test-db`. That seam is now a cross-app contract, and dropping the
# `System.get_env` read in ANY of the six configs would not fail a single suite here — it would
# just silently put two slices back on one database during a certification nobody reruns. So it
# is pinned unconditionally, next to the selection regression and for the same reason. Needs no
# DB and applies no patch (every assertion is `--list`); it costs a couple of minutes on Windows
# (two calls list the whole selection) and seconds on the Linux runners.
echo ""
echo "==> Running sabotage-harness intra-app parallelism regression (per-slice test DB + slice plan/guards)"
bash "$REPO_ROOT/scripts/sabotage_intra_test.sh"
echo "==> sabotage intra-app regression: PASSED"

# --- Deploy-gate NARROWING regressions (scripts/ci_tiers.sh + scripts/deploy.sh) --------
# The root gate can now be invoked with a SUBSET of its tiers (SAMEN_CI_TIERS, derived from a
# diff by scripts/ci_tiers.sh and relied on by scripts/deploy.sh --local-gate). That is only
# acceptable if the narrowing itself is pinned, so its two halves are asserted here — in the
# `harness` tier, which is part of EVERY narrowed set's baseline: you cannot narrow the gate
# without re-certifying the thing that does the narrowing.
#   * ci_tiers_test.sh — the diff→tiers mapping and its fail-closed rules, driven against real
#     throwaway git repos (a too-narrow answer must not be producible silently);
#   * deploy_test.sh  — the caller: the exact tier set the gate is invoked with, that an
#     unvouchable baseline runs the FULL gate, and that a failing gate still fails the deploy.
# Both need no DB and apply no patch; ~50s total on Windows, seconds on the Linux runners.
echo ""
echo "==> Running deploy-gate narrowing regressions (diff→tiers mapping + deploy.sh's decision)"
bash "$REPO_ROOT/scripts/ci_tiers_test.sh"
echo "==> ci_tiers mapping regression: PASSED"
bash "$REPO_ROOT/scripts/deploy_test.sh"
echo "==> deploy.sh narrowing regression: PASSED"
fi

# --- WS-E sabotage harness (E2i.1) — permanent OPT-IN step (SAMEN_SABOTAGE=1) ---
# Replays every shipped gate sabotage as a committed patch (scripts/sabotages/*.patch):
# apply → targeted `mix test` MUST fail with the NAMED tests among the failures (the
# flip) → revert → SHA-256 byte-exact restore, zero residue. Opt-in (unlike the
# unconditional gen_app probes above) because it deliberately breaks the tree 5x and
# re-runs DB-backed suites (~3-4 min): the default CI path stays green-only; phase
# gates and E7.2 run it explicitly instead of re-deriving sabotages by hand.
echo ""
if [[ "${SAMEN_SABOTAGE:-0}" == "1" ]]; then
  echo "==> Running sabotage harness (SAMEN_SABOTAGE=1 — every gate sabotage must flip + restore byte-exact)"
  # --no-preflight: the top-of-gate preflights above already certified this exact tree;
  # the guards are idempotent, so re-running them here would only cost ~3 minutes.
  bash "$REPO_ROOT/scripts/sabotage.sh" --no-preflight
  echo "==> sabotage harness: PASSED"
else
  echo "==> Skipping sabotage harness (opt-in: SAMEN_SABOTAGE=1 ./ci.sh replays all gate sabotages)"
fi

# --- Independent app/framework gates — RUN CONCURRENTLY (10-core box) -----------------
# The four vertical/framework gates below are independent (own apps, own test DBs —
# samen_web_test / demo_test / driftwood_test / pawchart_test — own _build) so they run
# in PARALLEL to cut wall-clock. HAZARD GUARD: everything above this point (spikes,
# samen_core, the 3 registry-mutating gen probes, and the opt-in sabotage harness — which
# patches samen_core/samen_web/demo/pawchart source) is SEQUENTIAL and has already fully
# completed; nothing below touches the shared abbrev_registry.json or patches source, so
# concurrency here is race-free.
#
# CORRECTNESS CONTRACT (do NOT weaken): a backgrounded command that fails does NOT trip
# `set -e`. Each gate's stdout+stderr is captured to its own log; each background PID's exit
# code is collected explicitly with `wait <pid>`; if ANY gate failed we dump its log, print
# which one, and `exit 1` — never reaching the ALL PASSED line. Each gate's own
# `==> ... : PASSED` marker(s) print ONLY after that gate's exit code is confirmed 0.

# NOTE: which apps launch is decided by the tier selection below (registry built after the
# gate functions), so the CONCURRENTLY banner is printed there, listing the actual set.

GATE_LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/samen_ci_gates.XXXXXX")"

# --- samen_web framework UI library gate (ADR-009) ---
gate_samen_web() {
  export HEX_HOME="$GATE_LOG_DIR/hex-samen_web"
  cd "$REPO_ROOT/samen_web"
  bash ci.sh
}

# --- demo dogfood gate: warnings-as-errors test suite + the 5-verifier CI gate ---
gate_demo() {
  export HEX_HOME="$GATE_LOG_DIR/hex-demo"
  cd "$REPO_ROOT/demo"
  mix deps.get --quiet
  mix test --warnings-as-errors
  MIX_ENV=test bash ci.sh
}

# --- Driftwood reference-vertical gate (Phase 5, T5.2) ---
gate_driftwood() {
  export HEX_HOME="$GATE_LOG_DIR/hex-driftwood"
  cd "$REPO_ROOT/driftwood"
  mix deps.get --quiet
  MIX_ENV=test bash ci.sh
}

# --- PawChart second-vertical thin slice gate (Phase 6, T6.2) ---
gate_pawchart() {
  export HEX_HOME="$GATE_LOG_DIR/hex-pawchart"
  cd "$REPO_ROOT/pawchart"
  mix deps.get --quiet
  MIX_ENV=test bash ci.sh
}

# --- SamenERP host-proof gate (WS-ERP E8): the E1–E7 scopes mounted AS-IS on
# one host namespace at ≈0 authored LOC, gated by the FULL verifier suite.
gate_samenerp() {
  export HEX_HOME="$GATE_LOG_DIR/hex-samenerp"
  cd "$REPO_ROOT/samenerp"
  mix deps.get --quiet
  MIX_ENV=test bash ci.sh
}

# Gate registry: name | function | PASSED marker line(s) to emit on success — built from the
# SELECTED app tiers. `all` selects every app (identical to the pre-tier gate); a subset selects
# only those, so a change confined to one app does not also pay for the other four. An empty
# registry short-circuits to a reported skip rather than an empty launch loop.
gate_names=()
gate_fns=()
gate_markers=()
add_gate() { gate_names+=("$1"); gate_fns+=("$2"); gate_markers+=("$3"); }
if tier_on web; then add_gate samen_web gate_samen_web "==> samen_web gate: PASSED"; fi
if tier_on demo; then add_gate demo gate_demo $'==> demo tests: PASSED\n==> demo CI gate: PASSED'; fi
if tier_on driftwood; then add_gate driftwood gate_driftwood "==> Driftwood CI gate: PASSED"; fi
if tier_on pawchart; then add_gate pawchart gate_pawchart "==> PawChart CI gate: PASSED"; fi
if tier_on samenerp; then add_gate samenerp gate_samenerp "==> samenerp CI gate: ALL PASSED"; fi

if (( ${#gate_names[@]} == 0 )); then
  echo ""
  echo "==> SKIPPING every app gate (no app tier selected — SAMEN_CI_TIERS=$CI_TIERS)"
else
echo ""
echo "==> Running app gates CONCURRENTLY: ${gate_names[*]}"

# Launch them in the background, each redirected to its own per-app log.
gate_pids=()
gate_logs=()
for i in "${!gate_names[@]}"; do
  log="$GATE_LOG_DIR/${gate_names[$i]}.log"
  gate_logs+=("$log")
  "${gate_fns[$i]}" >"$log" 2>&1 &
  gate_pids+=("$!")
done

# Collect each background job's exit code EXPLICITLY (set -e will not catch a bg failure).
gate_failed=0
for i in "${!gate_names[@]}"; do
  if wait "${gate_pids[$i]}"; then
    printf '%s\n' "${gate_markers[$i]}"
  else
    code=$?
    gate_failed=1
    echo ""
    echo "==> ${gate_names[$i]} gate: FAILED (exit $code)"
    echo "==> ----- begin ${gate_names[$i]} log (${gate_logs[$i]}) -----"
    cat "${gate_logs[$i]}"
    echo "==> ----- end ${gate_names[$i]} log -----"
  fi
done

if [[ "$gate_failed" != 0 ]]; then
  echo ""
  echo "==> ROOT CI: FAILED — one or more app gates failed (logs in $GATE_LOG_DIR). NOT all passed."
  exit 1
fi

# Every launched gate confirmed exit 0 — logs no longer needed.
rm -rf "$GATE_LOG_DIR"
fi

echo ""
if [[ "$CI_TIERS" == "all" ]]; then
  echo "==> ROOT CI: ALL PASSED"
else
  echo "==> ROOT CI: ALL PASSED (TIER SUBSET: $CI_TIERS — this is NOT the full gate)"
fi
