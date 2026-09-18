#!/usr/bin/env bash
# scripts/sabotage_residue.sh — fail-closed RESIDUE preflight for scripts/sabotages/*.patch.
#
# WHY THIS EXISTS. An applied sabotage in the working tree does not look like a bug: it
# looks like a legitimate edit whose targeted tests fail far from the cause — and a
# `git add -A` then commits the sabotage as if it were a fix. That is not hypothetical:
# patch 12-e5 (apikey-store-raw) reached main that way and failed the samen_web +
# driftwood gates on the next push, ~46 minutes into the run. The harness no longer CAUSES
# this (it replays every patch in a throwaway worktree — see the ISOLATED REPLAY TREE
# section of scripts/sabotage.sh — so its own residue cannot reach the shared checkout),
# but the state itself still arrives by other routes: a checkout left behind by a
# pre-isolation run or a hard kill (SIGKILL skips every trap, including the harness's),
# a patch someone applied by hand, or a committed sweep like 12-e5. Hard kills recurred 4+
# times on the abbrev registry, so this guard covers them exactly rather than hopefully;
# scripts/gen_probe_guard.sh covers the same hazard for that registry (see its SAFETY
# note). Its value is unchanged by the isolation and is now purely defence in depth.
#
# The detector is exact and READ-ONLY: `git apply --reverse --check <patch>` succeeds iff
# that patch is currently applied to the tree. Nothing is modified — recovery is reported,
# never performed, so this guard can never destroy a developer's real work.
#
# Output contract: NOTHING is printed when the tree is clean, so callers' output is
# unchanged. On residue it prints each offending patch, the file(s) it touches, the exact
# recovery command, and a FAILED line.
#
# Exit: 0 clean · 1 residue (or no patches found)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SABOTAGE_DIR="$REPO_ROOT/scripts/sabotages"

command -v git >/dev/null 2>&1 || {
  echo "SABOTAGE RESIDUE: FAILED — git not found; cannot certify the tree"
  exit 1
}

shopt -s nullglob
patches=("$SABOTAGE_DIR"/*.patch)
if [[ ${#patches[@]} -eq 0 ]]; then
  echo "SABOTAGE RESIDUE: FAILED — no patches found in $SABOTAGE_DIR"
  exit 1
fi

applied=()
for patch in "${patches[@]}"; do
  # Reverse-applies cleanly -> the patch's output is what the tree currently holds.
  if (cd "$REPO_ROOT" && git apply --reverse --check "$patch" 2>/dev/null); then
    applied+=("$patch")
  fi
done

[[ ${#applied[@]} -eq 0 ]] && exit 0

echo ""
echo "SABOTAGE RESIDUE: ${#applied[@]} of ${#patches[@]} patch(es) are APPLIED to the working tree:"
for patch in "${applied[@]}"; do
  rel="${patch#"$REPO_ROOT"/}"
  echo "  $rel"
  sed -n 's|^+++ b/|    touches: |p' "$patch" | sed 's/\t.*//'
  echo "    recover: git apply -R $rel"
done
echo ""
echo "SABOTAGE RESIDUE: FAILED — the tree carries applied sabotage. Do NOT run the gates"
echo "and DO NOT commit in this state: the sabotage's own targeted tests are supposed to"
echo "fail, and the patch would land as if it were a fix. Revert it with the command(s)"
echo "above, then re-run."
exit 1
