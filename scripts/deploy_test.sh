#!/usr/bin/env bash
# scripts/deploy_test.sh — regression test for scripts/deploy.sh's LOCAL GATE NARROWING.
#
# WHAT IT PROTECTS. `deploy.sh --local-gate` may now run only the tiers a diff needs, and the only
# acceptable failure mode of that decision is SKIPPING something it could not vouch for. So this
# test drives the REAL scripts/deploy.sh (not a re-implementation of its logic) inside a throwaway
# checkout whose ci.sh is a STUB, and asserts:
#   * which tier set the gate was actually invoked with (the stub records SAMEN_CI_TIERS);
#   * that a baseline it cannot vouch for runs the FULL gate, never a subset — including a CI run
#     that succeeded on a commit which is NOT an ancestor (that vouches for nothing);
#   * that a FAILING gate still fails the deploy, so narrowing is not a way past the gate;
#   * that a narrowed run is never reported as the full gate.
#
# WHY A STUB. The real gate costs ~90 minutes and needs Postgres; what is under test here is the
# DECISION, not ci.sh (which has its own suite, and whose tier machinery is exercised by
# scripts/ci_tiers_test.sh). The stub records the one thing the decision produces.
#
# Usage: bash scripts/deploy_test.sh    (exit 0 = every assertion holds)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_DEPLOY="$SELF_DIR/deploy.sh"
REAL_TIERS="$SELF_DIR/ci_tiers.sh"

for f in "$REAL_DEPLOY" "$REAL_TIERS"; do
  [[ -f "$f" ]] || { echo "FATAL: missing $f"; exit 1; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/samen_deploy_test.XXXXXX")"
FIX="$WORK/fix"
FIXBIN="$WORK/bin"
STUB_LOG="$WORK/gate.log"
OUT="$WORK/out"
PASS=0
FAIL=0

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

# --- the fake `gh` ------------------------------------------------------------------------------
# deploy.sh's baseline derivation makes exactly two gh calls. Both are answered locally, so this
# test never touches the network or a real GitHub account. FAKE_GH_SHA empty ⇒ "CI published no
# successful run", which is a refusal to narrow, not an error.
mkdir -p "$FIXBIN"
cat >"$FIXBIN/gh" <<'FAKE_GH'
#!/bin/sh
case "$*" in
  *actions/workflows*)
    [ -n "${FAKE_GH_SHA:-}" ] || exit 1
    printf '%s\n' "$FAKE_GH_SHA"
    ;;
  *"repo view"*) printf '%s\n' "acme/samen" ;;
  *) exit 1 ;;
esac
FAKE_GH
chmod +x "$FIXBIN/gh"

# Self-check the instrument before trusting it: if the exec bit is not honoured here, every
# baseline-derived case below would silently exercise the "no gh" path instead, and the test would
# be measuring the wrong thing. Fail loudly as an INFRASTRUCTURE problem instead.
if ! FAKE_GH_SHA=deadbeef PATH="$FIXBIN:$PATH" gh api repos/a/b/actions/workflows/ci.yml/runs >"$WORK/ghprobe" 2>/dev/null; then
  echo "FATAL: the fake gh on PATH is not runnable (exec bit not honoured?) — the test's instrument is broken"
  exit 1
fi
[[ "$(cat "$WORK/ghprobe")" == "deadbeef" ]] \
  || { echo "FATAL: the fake gh did not answer the probe — the test's instrument is broken"; exit 1; }

# --- the fixture checkout -----------------------------------------------------------------------
mkdir -p "$FIX/scripts" "$FIX/spikes/s00"
cp "$REAL_DEPLOY" "$FIX/scripts/deploy.sh"
cp "$REAL_TIERS" "$FIX/scripts/ci_tiers.sh"
printf '#!/usr/bin/env bash\n# never read: the local gate only checks that it exists\n' >"$FIX/scripts/deploy-prod.sh"

# The STUB gate. It records the tier set it was invoked with — the entire product of the decision
# under test — and exits with whatever the case asks for.
cat >"$FIX/ci.sh" <<'STUB_CI'
#!/usr/bin/env bash
[ -n "${STUB_LOG:-}" ] || { echo "stub ci.sh: STUB_LOG unset (run me from scripts/deploy_test.sh)" >&2; exit 99; }
printf 'CI_TIERS=%s\n' "${SAMEN_CI_TIERS-<unset>}" >>"$STUB_LOG"
[ "${STUB_EXIT:-0}" -eq 0 ] || { echo "stub ci.sh: gate FAILED (STUB_EXIT=$STUB_EXIT)" >&2; exit "$STUB_EXIT"; }
echo "==> ROOT CI: ALL PASSED"
STUB_CI

# Commit 1 — the base. Every path below is tracked from here so each case can be a one-line edit.
printf 'base\n' >"$FIX/spikes/s00/x.ex"
printf 'base\n' >"$FIX/README.md"
git -C "$FIX" init -q
git -C "$FIX" config user.email deploy-test@example.invalid
git -C "$FIX" config user.name deploy-test
git -C "$FIX" config core.autocrlf false
git -C "$FIX" config commit.gpgsign false
git -C "$FIX" add -A
git -C "$FIX" commit -q -m base
BASE="$(git -C "$FIX" rev-parse HEAD)"
BRANCH="$(git -C "$FIX" rev-parse --abbrev-ref HEAD)"

# Commit 2 — a change inside ONE host's tree: narrows to that host's tier + the baseline.
printf 'change\n' >>"$FIX/spikes/s00/x.ex"
git -C "$FIX" commit -aq -m "spikes change"
SPIKE_TIP="$(git -C "$FIX" rev-parse HEAD)"

# Commit 3 — a change the selector cannot reason about (a brand-new top-level directory): the
# honest answer is the FULL gate, and deploy.sh must obey that.
mkdir -p "$FIX/brand-new-top-dir"
printf 'x\n' >"$FIX/brand-new-top-dir/z.txt"
git -C "$FIX" add -A
git -C "$FIX" commit -q -m "unrecognised path"
TIP="$(git -C "$FIX" rev-parse HEAD)"

# --- harness ------------------------------------------------------------------------------------
LAST_RC=0
LAST_OUT=""
LAST_TIERS=""
STUB_EXIT=0
FAKE_GH_SHA=""

run_deploy() { # <args...> — the REAL deploy.sh, in the fixture, with the stub gate
  : >"$STUB_LOG"
  (
    # SAMEN_CI_TIERS unset so "<unset>" really means deploy.sh chose the full gate.
    unset SAMEN_CI_TIERS
    cd "$FIX" &&
      PATH="$FIXBIN:$PATH" FAKE_GH_SHA="$FAKE_GH_SHA" STUB_LOG="$STUB_LOG" STUB_EXIT="$STUB_EXIT" \
        bash scripts/deploy.sh "$@"
  ) >"$OUT" 2>&1
  LAST_RC=$?
  LAST_OUT="$(cat "$OUT")"
  LAST_TIERS="$(sed -n 's/^CI_TIERS=//p' "$STUB_LOG" | tail -1)"
  return 0
}

check() { # <label> <got> <want>
  if [[ "$2" == "$3" ]]; then
    PASS=$((PASS + 1))
    printf 'PASS: %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s\n      got  %s\n      want %s\n' "$1" "${2:-<empty>}" "$3"
  fi
}

check_out_has() { # <label> <substring>
  if [[ "$LAST_OUT" == *"$2"* ]]; then
    PASS=$((PASS + 1))
    printf 'PASS: %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s — output lacks %q\n' "$1" "$2"
    printf '%s\n' "$LAST_OUT" | sed 's/^/      | /'
  fi
}

check_out_lacks() { # <label> <substring>
  if [[ "$LAST_OUT" != *"$2"* ]]; then
    PASS=$((PASS + 1))
    printf 'PASS: %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s — output contains %q (it must not)\n' "$1" "$2"
    printf '%s\n' "$LAST_OUT" | sed 's/^/      | /'
  fi
}

# `--local-gate` gates the CHECKED-OUT commit, so each case must put the target in the tree first.
at() { git -C "$FIX" checkout -q "$1"; }

# --- 1. an attested baseline narrows to exactly the affected tiers -------------------------------
echo "== 1. --since <attested baseline> narrows to the diff's tiers =="

at "$SPIKE_TIP"
run_deploy --local-gate --sha "$SPIKE_TIP" --since "$BASE" --dry-run
check "--local-gate exits 0 when the (narrowed) gate passes" "$LAST_RC" 0
check "the gate was invoked with exactly the affected tiers" "$LAST_TIERS" "harness,spikes,verifiers"
check_out_has "the run is labelled TIER SUBSET, never as the full gate" "TIER SUBSET"
check_out_has "the operator is told which tiers were skipped and why it was safe" \
  "the baseline above already validated the code it covers"
check_out_has "a passing gate still reaches the deploy step" "Would run:"

# --- 2. the derived baseline: CI's newest validated ancestor ------------------------------------
echo "== 2. no --since: the baseline is the newest ancestor CI validated =="

FAKE_GH_SHA="$BASE"
at "$SPIKE_TIP"
run_deploy --local-gate --sha "$SPIKE_TIP" --dry-run
check "the derived baseline narrows exactly as the attested one did" "$LAST_TIERS" "harness,spikes,verifiers"
check_out_has "deploy.sh says which baseline it derived" "the newest ancestor CI validated"
FAKE_GH_SHA=""

# ANTI-TAUTOLOGY: a CI run that SUCCEEDED on a commit which is not an ancestor of the target
# vouches for nothing — the derivation must reject it, not adopt it.
git -C "$FIX" checkout -q --orphan unattached
printf 'unrelated\n' >"$FIX/unattached.txt"
git -C "$FIX" add -A
git -C "$FIX" commit -q -m unattached
UNA="$(git -C "$FIX" rev-parse HEAD)"
git -C "$FIX" checkout -q "$BRANCH"
rm -f "$FIX/unattached.txt"

FAKE_GH_SHA="$UNA"
at "$SPIKE_TIP"
run_deploy --local-gate --sha "$SPIKE_TIP" --dry-run
check "a successful CI run on a NON-ancestor vouches for nothing ⇒ full gate" "$LAST_TIERS" "<unset>"
FAKE_GH_SHA=""

# --- 3. refusals: every "cannot vouch" path runs the FULL gate ----------------------------------
echo "== 3. cannot vouch ⇒ the FULL gate (never a subset) =="

at "$TIP"
run_deploy --local-gate --sha "$TIP" --since "$SPIKE_TIP" --dry-run
check "an unrecognised path (new top-level dir) ⇒ full gate" "$LAST_TIERS" "<unset>"
check_out_has "and it is reported as the full gate" "the FULL gate"

at "$SPIKE_TIP"
run_deploy --local-gate --sha "$SPIKE_TIP" --dry-run
check "no CI-validated ancestor (no successful run) ⇒ full gate" "$LAST_TIERS" "<unset>"
check_out_lacks "the full gate is never labelled TIER SUBSET" "TIER SUBSET"

at "$SPIKE_TIP"
run_deploy --local-gate --sha "$SPIKE_TIP" --since "$BASE" --full-gate --dry-run
check "--full-gate overrides a narrowing baseline" "$LAST_TIERS" "<unset>"
check_out_has "--full-gate says so" "--full-gate"

# --- 4. the gate is not weakened ----------------------------------------------------------------
echo "== 4. narrowing is not a way past the gate =="

STUB_EXIT=1
at "$SPIKE_TIP"
run_deploy --local-gate --sha "$SPIKE_TIP" --since "$BASE" --dry-run
STUB_EXIT=0
[[ "$LAST_RC" -ne 0 ]] && OK=yes || OK=no
check "a FAILING narrowed gate fails the deploy" "$OK" "yes"
check_out_has "and says why it refused" "refusing to deploy an unvalidated commit"
check_out_lacks "and never reaches the deploy step" "Would run:"

at "$SPIKE_TIP"
printf 'dirty\n' >>"$FIX/spikes/s00/x.ex"
run_deploy --local-gate --sha "$SPIKE_TIP" --since "$BASE" --dry-run
[[ "$LAST_RC" -ne 0 ]] && OK=yes || OK=no
check "a dirty tree is still refused" "$OK" "yes"
git -C "$FIX" checkout -q -- spikes/s00/x.ex

at "$SPIKE_TIP"
run_deploy --local-gate --sha "$BASE" --since "$BASE" --dry-run
[[ "$LAST_RC" -ne 0 ]] && OK=yes || OK=no
check "gating a commit that is not HEAD is still refused" "$OK" "yes"

# --- 5. the knobs refuse to be silently ignored --------------------------------------------------
echo "== 5. --since/--full-gate outside --local-gate are refused, not ignored =="

at "$SPIKE_TIP"
run_deploy --sha "$SPIKE_TIP" --since "$BASE"
[[ "$LAST_RC" -ne 0 ]] && OK=yes || OK=no
check "--since without --local-gate is refused" "$OK" "yes"

run_deploy --sha "$SPIKE_TIP" --full-gate
[[ "$LAST_RC" -ne 0 ]] && OK=yes || OK=no
check "--full-gate without --local-gate is refused" "$OK" "yes"

# --- verdict ------------------------------------------------------------------------------------
echo
echo "DEPLOY-TEST: $PASS passed, $FAIL failed"
(( FAIL == 0 )) || exit 1
echo "DEPLOY-TEST: ALL PASSED"
