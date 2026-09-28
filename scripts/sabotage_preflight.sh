#!/usr/bin/env bash
# scripts/sabotage_preflight.sh — the sabotage replay's STRUCTURAL preflight, in ONE place.
#
# Every check below answers a question that is knowable in seconds, but was, historically, only
# discovered when the 308-patch replay REACHED the affected patch — arbitrarily deep, after the
# whole tier stack had already been paid for. Each class cost at least one full gate:
#
#   * residue  (scripts/sabotage_residue.sh)         — an applied sabotage in the main checkout
#                                                      poisons every baseline (the replay tree
#                                                      seeds from the main tree's dirty state);
#   * EOLs     (scripts/eol_preflight.sh)            — a path declaring `eol=lf` but sitting
#                                                      CRLF in the worktree makes `git apply`
#                                                      rewrite it, so no revert is byte-exact
#                                                      (died 47 patches in, on 133-t84b);
#   * apply    (scripts/sabotage_apply_preflight.sh) — a patch whose anchor moved no longer
#                                                      applies (165-t85 / 243-a2 / 255-a4 each
#                                                      cost a gate);
#   * anchors  (scripts/sabotage_anchor_preflight.sh)— a patch anchored to a renamed/moved or
#                                                      prose-named test still APPLIES but cannot
#                                                      flip, so the harness reports a phantom
#                                                      "vacuous gate" (224-d3 / 300-t183b).
#
# SINGLE SOURCE OF TRUTH. Both callers run THIS script, so the guard sequence and its rationale
# live in exactly one place:
#   * scripts/sabotage.sh — before the replay of any real (non-`--list`) run, so a DIRECT
#     `bash scripts/sabotage.sh` fails fast too. It skips this with `--no-preflight`.
#   * ci.sh              — at the very top, before the spikes, so the GATE fails before it is
#     spent. Because it has already run here, ci.sh's sabotage step passes `--no-preflight`:
#     the guards are read-only and idempotent, so running them a second time against the same
#     tree buys nothing and costs ~3 minutes.
#
# `--list`/`--dry-run` deliberately never reaches here — the harness short-circuits to the
# selection print first — so previewing a selection stays instant.
#
# READ-ONLY: nothing here writes to the tree. Silent on success apart from the progress lines
# (each guard prints nothing of its own when it is clean).
#
# Exit: 0 every structural guard clean · 1 otherwise (the failing guard prints its own diagnosis
# and its exact repair, and this script names it)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

run_guard() { # run_guard <label> <script-name-in-scripts/>
  local label="$1" script="$2"
  echo "==> sabotage preflight: $label"
  if ! bash "$REPO_ROOT/scripts/$script"; then
    echo ""
    echo "==> SABOTAGE PREFLIGHT: FAILED — $label (see the diagnosis above); no patch was applied."
    exit 1
  fi
}

run_guard "residue"             sabotage_residue.sh
run_guard "EOLs"                eol_preflight.sh
run_guard "patch applicability" sabotage_apply_preflight.sh
run_guard "test anchors"        sabotage_anchor_preflight.sh
echo "==> sabotage preflight: clean"
