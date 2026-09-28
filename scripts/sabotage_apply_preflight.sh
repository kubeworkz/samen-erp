#!/usr/bin/env bash
# scripts/sabotage_apply_preflight.sh — fail-closed "every patch still applies" preflight.
#
# WHY THIS EXISTS. A sabotage patch is a hunk PINNED to source that keeps moving: any later
# commit that shifts its anchor lines or edits its context stops it applying. The harness
# only discovers that when it REACHES that patch — patch N of 308 — so the run dies
# arbitrarily deep, after the entire tier stack has already been paid for, with a failure
# that names the patch but not the fix. Both occurrences of this class cost a full gate:
# `165-t85-m4-analytics-tenant-ask-input-reintroduced.patch` died ~90 minutes in (its
# trailing context line said "The six AI kit surfaces" after the kit grew to SEVEN), and
# `243-a2-agent-watchdog-never-nil-dropped.patch` had two anchors shifted by the UXD-08
# `:hooks` persistence while `255-a4-agent-tool-result-sentinel-egress.patch` lost its
# anchor to the A11 `redacted_and_sanitized/1` refactor. All three were regenerated against
# HEAD; this guard is what makes the next one cost milliseconds instead of a gate.
#
# The check is exact and READ-ONLY: `git apply --check` validates each patch's context and
# line counts against the worktree it would be applied to and writes nothing.
#
# SCOPE: run by scripts/sabotage_preflight.sh, which BOTH ci.sh (before the spikes) and
# scripts/sabotage.sh (before its replay) invoke — so a DIRECT harness invocation discovers a
# stale patch here, in seconds, instead of reaching it deep in the replay.
#
# Output contract: NOTHING is printed when every patch still applies, so callers' output is
# unchanged.
#
# Exit: 0 all patches apply · 1 one or more do not (or the tree could not be inspected)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SABOTAGE_DIR="$REPO_ROOT/scripts/sabotages"

command -v git >/dev/null 2>&1 || {
  echo "SABOTAGE APPLY PREFLIGHT: FAILED — git not found; cannot verify the patches"
  exit 1
}

shopt -s nullglob
patches=("$SABOTAGE_DIR"/*.patch)
if [[ ${#patches[@]} -eq 0 ]]; then
  echo "SABOTAGE APPLY PREFLIGHT: FAILED — no patches found in $SABOTAGE_DIR"
  exit 1
fi

stale=()
stale_why=()
for patch in "${patches[@]}"; do
  if ! why="$(cd "$REPO_ROOT" && git apply --check "$patch" 2>&1)"; then
    stale+=("${patch#"$REPO_ROOT"/}")
    stale_why+=("$(printf '%s' "$why" | head -2 | tr '\n' ' ' | sed 's/  */ /g')")
  fi
done

[[ ${#stale[@]} -eq 0 ]] && exit 0

echo ""
echo "SABOTAGE APPLY PREFLIGHT: ${#stale[@]} of ${#patches[@]} patch(es) no longer apply to this tree:"
for i in "${!stale[@]}"; do
  echo "  ${stale[$i]}"
  echo "    ${stale_why[$i]}"
done
echo ""
echo "SABOTAGE APPLY PREFLIGHT: FAILED — a patch whose anchor moved cannot flip anything, and"
echo "the harness only learns that when it REACHES it (arbitrarily deep into the 308-patch"
echo "replay, after the whole tier stack has been paid for). RE-ANCHOR the hunk: keep the"
echo "defect, the removed/added lines and every MUST_FAIL target identical, move only the"
echo "context/line numbers — then re-verify with"
echo "  bash scripts/sabotage.sh --range <N>-<N>"
echo "which must report the flip(s) AND a byte-exact restore. Remove the patch only if the"
echo "guarantee it defeated no longer exists."
exit 1
