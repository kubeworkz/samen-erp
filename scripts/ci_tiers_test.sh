#!/usr/bin/env bash
# scripts/ci_tiers_test.sh — regression test for scripts/ci_tiers.sh (the deploy-gate narrower).
#
# WHAT IT PROTECTS. ci_tiers.sh narrows a deploy gate, so its ONLY dangerous output is a set that
# is too NARROW — a too-wide answer merely costs time. This test drives the REAL selector against
# REAL throwaway git commits (not a stubbed map) and asserts both directions:
#   * every path class resolves to the set the design requires (the mapping AND the diff plumbing);
#   * every "I cannot vouch for this" path answers exactly `all` (fail-closed).
# A selector that always answered `all` fails the subset rows; one that always answered the
# baseline fails the kernel/web/core rows. Neither can pass by accident — that anti-tautology is
# the reason this test exists rather than a comment in the script.
#
# WHY AN INTEGRATION TEST. A stubbed map would prove the case table and nothing about
# `git diff --name-only`, `merge-base --is-ancestor`, ancestry or argument parsing — which are
# exactly the parts that decide which files a real deploy gate sees.
#
# COST: a handful of git spawns per scenario (~150ms each on a Windows checkout) ⇒ ~40s here,
# ~10s on Linux. It sits with the harness regressions, not in a hot path.
#
# Usage: bash scripts/ci_tiers_test.sh    (exit 0 = every assertion holds)
set -uo pipefail

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELECTOR="$SELF_DIR/ci_tiers.sh"
REPO_ROOT="$(cd "$SELF_DIR/.." && pwd)"
CI_SH="$REPO_ROOT/ci.sh"

for f in "$SELECTOR" "$CI_SH"; do
  [[ -f "$f" ]] || { echo "FATAL: missing $f"; exit 1; }
done

WORK="$(mktemp -d "${TMPDIR:-/tmp}/samen_ci_tiers.XXXXXX")"
FIXTURE="$WORK/fixture"
PASS=0
FAIL=0
SEEN_CSVS=""

cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT
trap 'exit 130' INT TERM

# --- the fixture: ONE repo, one base commit, EVERY path this test will touch -------------------
# Every path exists in the base commit so each scenario can be a one-line append + `commit -a`
# (one git spawn) instead of add+commit. `brand-new-top-dir/` is pre-created ON PURPOSE: it is a
# path the selector cannot reason about, and it must be a real tracked file for `commit -a` to see
# the change.
FIXTURE_PATHS=(
  samen_core/lib/x.ex
  samen_web/lib/x.ex
  spikes/s00/x.ex
  samen_resend/lib/x.ex samen_postmark/lib/x.ex samen_ses/lib/x.ex
  samen_stripe/lib/x.ex samen_anthropic/lib/x.ex
  pawchart/lib/x.ex pawchart/lib/y.ex
  demo/lib/x.ex demo/lib/y.ex
  driftwood/lib/x.ex
  samenerp/config/test.exs
  README.md CLAUDE.md docs/guides/x.md
  scripts/deploy.sh scripts/gen_probe_guard.sh
  .github/workflows/ci.yml .freebuff/project-id
  ci.sh ci-fast.sh .gitignore
  brand-new-top-dir/thing.txt
)

mkdir -p "$FIXTURE"
for p in "${FIXTURE_PATHS[@]}"; do
  mkdir -p "$FIXTURE/$(dirname "$p")"
  printf 'base\n' > "$FIXTURE/$p"
done

git -C "$FIXTURE" init -q
git -C "$FIXTURE" config user.email ci-tiers-test@example.invalid
git -C "$FIXTURE" config user.name ci-tiers-test
git -C "$FIXTURE" config core.autocrlf false   # keep the run quiet; CRLF advice is not our subject
git -C "$FIXTURE" config commit.gpgsign false
git -C "$FIXTURE" config tag.gpgsign false
git -C "$FIXTURE" add -A
git -C "$FIXTURE" commit -q -m "base"
BASE="$(git -C "$FIXTURE" rev-parse HEAD)"
PREV="$BASE"   # the previous scenario's commit: each scenario must be diffed ONE STEP, not from
                # the base, or the scenarios accumulate and the first kernel file poisons every
                # later row with a full-gate answer.
BASE_BRANCH="$(git -C "$FIXTURE" rev-parse --abbrev-ref HEAD)"
[[ -n "$BASE" && -n "$BASE_BRANCH" ]] || { echo "FATAL: could not build the fixture base commit"; exit 1; }

# --- harness ------------------------------------------------------------------------------------
LAST_OUT=""
LAST_RC=0

run_selector() { # run_selector <args...> — capture stdout (the tier CSV) and the exit status.
  local out="$WORK/out" err="$WORK/err"
  bash "$SELECTOR" "$@" >"$out" 2>"$err"
  LAST_RC=$?
  LAST_OUT="$(cat "$out")"
  LAST_ERR="$(cat "$err")"
  return 0
}

record() { SEEN_CSVS="$SEEN_CSVS $1"; }

check() { # check <label> <want-csv>
  record "$2"
  if [[ "$LAST_OUT" == "$2" ]]; then
    PASS=$((PASS + 1))
    printf 'PASS: %s ⇒ %s\n' "$1" "$LAST_OUT"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s ⇒ %s (want %s)\n' "$1" "${LAST_OUT:-<empty>}" "$2"
    printf '      stderr: %s\n' "$(tr '\n' '|' <"$WORK/err")"
  fi
}

check_all() { # check_all <label> — the fail-closed answer, and it must be the BARE word `all`
  if [[ "$LAST_OUT" == "all" ]]; then
    PASS=$((PASS + 1))
    printf 'PASS: %s ⇒ all (refused to narrow)\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s ⇒ %s (want bare `all`)\n' "$1" "${LAST_OUT:-<empty>}"
  fi
}

check_rc() { # check_rc <label> <want-rc>
  if [[ "$LAST_RC" == "$2" ]]; then
    PASS=$((PASS + 1))
    printf 'PASS: %s ⇒ exit %s\n' "$1" "$LAST_RC"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s ⇒ exit %s (want %s)\n' "$1" "$LAST_RC" "$2"
  fi
}

check_err() { # check_err <label> <stderr> <must-contain> [<must-not-contain>] — the refusal REASON
  local why=""
  [[ "$2" == *"$3"* ]] || why="does not mention '$3'"
  if [[ -n "${4:-}" && "$2" == *"$4"* ]]; then why="${why:+$why; }reads as '$4'"; fi
  if [[ -z "$why" ]]; then
    PASS=$((PASS + 1))
    printf 'PASS: %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: %s — %s\n' "$1" "$why"
    printf '      stderr: %s\n' "$(printf '%s' "$2" | tr '\n' '|')"
  fi
}

N=0
scenario() { # scenario <label> <want-csv> <path>...  — change tracked paths, commit, ask the selector
  local label="$1" want="$2"
  shift 2
  N=$((N + 1))
  local p
  for p in "$@"; do printf 'change %s\n' "$N" >>"$FIXTURE/$p"; done
  git -C "$FIXTURE" commit -aq -m "s$N"
  run_selector --repo "$FIXTURE" --since "$PREV" HEAD
  PREV="$(git -C "$FIXTURE" rev-parse HEAD)"
  check "$label" "$want"
}

# --- 1. the mapping: what each path class requires ----------------------------------------------
# Expectations are the selector's OWN contract — baseline (harness,verifiers) ∪ the class's tiers,
# sort -u'd, comma-joined — written out longhand so a silent change to either half fails here.
echo "== 1. the map: what each path class requires =="

scenario "samen_core ⇒ the whole gate (every consumer path-deps the kernel)" \
  "all" samen_core/lib/x.ex
scenario "samen_web ⇒ web + every host (four of five path-dep it)" \
  "demo,driftwood,harness,pawchart,samenerp,verifiers,web" samen_web/lib/x.ex
scenario "spikes ⇒ spikes only (frozen standalone mix projects)" \
  "harness,spikes,verifiers" spikes/s00/x.ex
scenario "samen_resend ⇒ resend + samenerp (the one adapter a host depends on)" \
  "harness,resend,samenerp,verifiers" samen_resend/lib/x.ex
scenario "samen_postmark ⇒ standalone adapter" \
  "harness,postmark,verifiers" samen_postmark/lib/x.ex
scenario "samen_ses ⇒ standalone adapter" \
  "harness,ses,verifiers" samen_ses/lib/x.ex
scenario "samen_stripe ⇒ standalone adapter" \
  "harness,stripe,verifiers" samen_stripe/lib/x.ex
scenario "samen_anthropic ⇒ standalone adapter" \
  "anthropic,harness,verifiers" samen_anthropic/lib/x.ex
scenario "pawchart ⇒ pawchart" \
  "harness,pawchart,verifiers" pawchart/lib/x.ex
scenario "demo ⇒ demo" \
  "demo,harness,verifiers" demo/lib/x.ex
scenario "driftwood ⇒ driftwood" \
  "driftwood,harness,verifiers" driftwood/lib/x.ex
scenario "samenerp ⇒ samenerp" \
  "harness,samenerp,verifiers" samenerp/config/test.exs
scenario "README.md ⇒ core (samen_core's suite READS it)" \
  "core,harness,verifiers" README.md
scenario "CLAUDE.md ⇒ core" \
  "core,harness,verifiers" CLAUDE.md
scenario "docs/** ⇒ core" \
  "core,harness,verifiers" docs/guides/x.md
scenario "scripts/** (not the gen probe) ⇒ baseline only" \
  "harness,verifiers" scripts/deploy.sh
scenario "gen_probe_guard.sh ⇒ gen (it drives the generator probes)" \
  "gen,harness,verifiers" scripts/gen_probe_guard.sh
scenario ".github/** ⇒ baseline only" \
  "harness,verifiers" .github/workflows/ci.yml
scenario ".freebuff/** ⇒ baseline only" \
  "harness,verifiers" .freebuff/project-id
scenario "the gate's own scripts ⇒ baseline only" \
  "harness,verifiers" ci.sh
scenario "a diff spanning two apps ⇒ the union of both" \
  "demo,harness,pawchart,verifiers" pawchart/lib/y.ex demo/lib/y.ex

# --- 2. fail-closed: anything the selector cannot vouch for is `all` ----------------------------
echo "== 2. fail-closed: anything it cannot vouch for ⇒ all =="

# A path in no table: a new top-level directory. This is the rule that keeps new subsystems safe.
scenario "an unrecognised top-level path ⇒ all" "all" brand-new-top-dir/thing.txt
# Captured now, because every later run overwrites LAST_ERR — §2b asserts this wording.
UNKNOWN_ERR="$LAST_ERR"

# No --since: nothing to diff, so nothing may be excluded.
run_selector --repo "$FIXTURE" HEAD
check_all "no --since (no baseline to diff against)"

# Empty diff: a redeploy of the same commit still runs everything.
run_selector --repo "$FIXTURE" --since "$BASE" "$BASE"
check_all "an empty diff (same commit before and after)"

# A target that does not resolve.
run_selector --repo "$FIXTURE" --since "$BASE" deadbeefdeadbeef
check_all "a target that does not resolve to a commit"

# A baseline that does not resolve.
run_selector --repo "$FIXTURE" --since nope-nope HEAD
check_all "a baseline that does not resolve to a commit"

# Not a git checkout at all. GIT_CEILING_DIRECTORIES stops the upward .git search, so this holds
# even when TMPDIR happens to sit inside someone's repository.
mkdir -p "$WORK/not-repo"
GIT_CEILING_DIRECTORIES="$WORK" run_selector --repo "$WORK/not-repo" --since "$BASE" HEAD
check_all "not a git checkout"

# A baseline that is not an ancestor of the target: rewritten/divergent history is not a diff.
# Done LAST, because it moves the fixture off its base branch.
git -C "$FIXTURE" branch -q side "$BASE"
git -C "$FIXTURE" checkout -q side
printf 'side\n' >>"$FIXTURE/README.md"
git -C "$FIXTURE" commit -aq -m side
git -C "$FIXTURE" checkout -q "$BASE_BRANCH"
run_selector --repo "$FIXTURE" --since side HEAD
check_all "a baseline that is not an ancestor of the target (rewritten history)"

# --- 2b. the two `all` reasons are DIFFERENT decisions ------------------------------------------
# The refusal log is what an operator acts on, so the two cases must not read as one. The kernel is
# excluded because every consumer path-deps it; a new top-level dir because there is no rule at
# all. Reporting the kernel as "unrecognised" invites the one edit that would break the mapping (a
# finer `samen_core/*` rule), so both directions are asserted — and neither string can be collapsed
# into the other and still pass.
echo "== 2b. a kernel diff and an unrecognised path refuse for different reasons =="

N=$((N + 1))
printf 'kernel change\n' >>"$FIXTURE/samen_core/lib/x.ex"
git -C "$FIXTURE" commit -aq -m "s$N"
run_selector --repo "$FIXTURE" --since "$PREV" HEAD
PREV="$(git -C "$FIXTURE" rev-parse HEAD)"
check "a fresh kernel diff still answers all" "$LAST_OUT" "all"
check_err "the kernel refusal names the dependency, not a missing rule" \
  "$LAST_ERR" "is the kernel" "matches no rule"
check_err "the unrecognised-path refusal does not claim the kernel reason" \
  "$UNKNOWN_ERR" "matches no rule" "is the kernel"

# --- 3. usage errors are refusals, not narrow answers -------------------------------------------
echo "== 3. usage errors refuse (exit 2) =="

run_selector --repo
check_rc "--repo without a value" 2
run_selector --nonsense
check_rc "an unknown argument" 2
run_selector --repo "$FIXTURE"
check_rc "a missing target sha" 2
run_selector --help
check_rc "--help exits 0" 0

# --- 4. cross-file invariants: the selector can only name tiers the gate knows ------------------
# This is what makes the two scripts safe to change independently: if ci.sh renames a tier, the
# selector must not keep emitting the old name into SAMEN_CI_TIERS (which ci.sh would then reject
# as a typo — or worse, silently run less than intended).
echo "== 4. every tier the selector emits is a tier ci.sh knows =="

KNOWN_TIERS="$(sed -n 's/^KNOWN_TIERS="\(.*\)"$/\1/p' "$CI_SH" | head -1)"
if [[ -z "$KNOWN_TIERS" ]]; then
  FAIL=$((FAIL + 1))
  printf 'FAIL: could not read KNOWN_TIERS out of %s — the vocabulary check is void\n' "$CI_SH"
else
  PASS=$((PASS + 1))
  printf 'PASS: read ci.sh vocabulary: %s\n' "$KNOWN_TIERS"

  unknown=""
  for csv in $(printf '%s\n' $SEEN_CSVS | tr ',' ' ' | sort -u); do
    [[ "$csv" == "all" ]] && continue
    if [[ " $KNOWN_TIERS " != *" $csv "* ]]; then unknown="$unknown $csv"; fi
  done
  if [[ -z "$unknown" ]]; then
    PASS=$((PASS + 1))
    printf 'PASS: every tier emitted above is in ci.sh KNOWN_TIERS\n'
  else
    FAIL=$((FAIL + 1))
    printf 'FAIL: selector emitted tier(s) ci.sh does not know:%s\n' "$unknown"
  fi

  # The baseline tiers are the ones every narrowed run pays for: assert they exist by name.
  for t in harness verifiers; do
    if [[ " $KNOWN_TIERS " == *" $t "* ]]; then
      PASS=$((PASS + 1))
      printf 'PASS: baseline tier %s is a real tier\n' "$t"
    else
      FAIL=$((FAIL + 1))
      printf 'FAIL: baseline tier %s is NOT a tier ci.sh knows\n' "$t"
    fi
  done
fi

# The `--repo` override must be REAL, or every fixture row above is vacuous (a selector that
# ignored --repo and diffed its own checkout would never have consulted these fixtures at all).
# Decisive construction: a SECOND repo whose SHAs exist nowhere else. Its own diff narrows to
# `spikes`; if --repo were ignored, $BASE2 would not resolve in the selector's own checkout and the
# answer would be `all` instead — so the narrowing below can only come from reading repo2.
FIXTURE2="$WORK/fixture2"
mkdir -p "$FIXTURE2/spikes/s00"
printf 'base\n' >"$FIXTURE2/spikes/s00/z.ex"
git -C "$FIXTURE2" init -q
git -C "$FIXTURE2" config user.email ci-tiers-test@example.invalid
git -C "$FIXTURE2" config user.name ci-tiers-test
git -C "$FIXTURE2" config core.autocrlf false
git -C "$FIXTURE2" add -A
git -C "$FIXTURE2" commit -q -m base
BASE2="$(git -C "$FIXTURE2" rev-parse HEAD)"
printf 'change\n' >>"$FIXTURE2/spikes/s00/z.ex"
git -C "$FIXTURE2" commit -aq -m change

run_selector --repo "$FIXTURE2" --since "$BASE2" HEAD
check "--repo is honoured (SHAs that exist only in fixture2 still narrow)" \
  "harness,spikes,verifiers"

# --- verdict ------------------------------------------------------------------------------------
echo
echo "CI-TIERS-TEST: $PASS passed, $FAIL failed"
(( FAIL == 0 )) || exit 1
echo "CI-TIERS-TEST: ALL PASSED"
