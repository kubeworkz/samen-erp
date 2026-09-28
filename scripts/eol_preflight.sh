#!/usr/bin/env bash
# scripts/eol_preflight.sh — fail-closed EOL preflight for the byte-exact restore contract.
#
# WHY THIS EXISTS. `.gitattributes` pins the source tree to LF (`*.ex`/`*.exs`/`*.eex`
# `text eol=lf`) precisely so that a `git apply` round-trip is byte-stable on hosts with
# `core.autocrlf=true` — the comment there names this as "the Windows smudge lesson".
# A tracked file may still sit in the worktree as CRLF: git reports it CLEAN (autocrlf
# normalizes before comparing), so `git status` cannot show it, and nothing else notices
# until `git apply` touches it. `git apply` HONOURS the attribute and rewrites the whole
# file as LF, so the harness's `git apply -R` can never return the pre-captured CRLF bytes
# and the run dies with a misleading `SHA mismatch after revert — residue left behind`.
#
# That is exactly how the full 308-patch replay first failed: 47 patches in, on
# 133-t84b-operator-routes-on-mount-drop.patch, because `samen_web/lib/samen/web/router.ex`
# was CRLF in the worktree while `.gitattributes` mandated LF. The per-patch SHA gate was
# right; the diagnosis arrived ~25 minutes into the gate and named the wrong cause. Three
# files carried this drift, so which patch detonates first is arbitrary — the class is the
# bug, and it is detectable in milliseconds, before the gate is spent.
#
# Only paths whose OWN attribute declares `eol=lf` are flagged: a large number of tracked
# files are legitimately `w/crlf` with no `text`/`eol` rule (autocrlf round-trips those and
# `git apply` follows the worktree convention, so they restore exactly).
#
# The fix discards NOTHING: for these paths the working tree and the index are already
# byte-identical once normalized (that is why `git status` is clean). `git checkout --`
# simply rewrites the file from the index — LF — and refreshes the stat cache.
#
# Output contract: NOTHING is printed when the tree honours its own EOL rules, so callers'
# output is unchanged. On drift it prints each offending path, its on-disk EOL class, the
# exact repair command, and a FAILED line.
#
# Exit: 0 clean · 1 drift (or the tree could not be inspected)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

command -v git >/dev/null 2>&1 || {
  echo "EOL PREFLIGHT: FAILED — git not found; cannot inspect the worktree EOLs"
  exit 1
}

# `--eol -z` is machine-readable: each record is "<meta>\t<path>\0" and <meta> is four
# space-separated fields (i/<eol> w/<eol> attr/<...> [eol=<...>]). The stream is consumed
# DIRECTLY — never through `$(...)`, which strips the NUL separators and fuses every record
# into one (the bug that made this guard silently pass its own negative control) — so paths
# containing spaces stay intact and every tracked path is actually inspected.
scanned=0
drifted_paths=()
drifted_eols=()

while IFS= read -r -d '' record; do
  scanned=$((scanned + 1))
  meta="${record%%$'\t'*}"
  path="${record#*$'\t'}"
  [[ "$meta" == "$record" ]] && continue

  # shellcheck disable=SC2162
  read -r _index_eol worktree_eol _attr declared_eol <<<"$meta"

  [[ "$declared_eol" == "eol=lf" ]] || continue
  [[ "$worktree_eol" == "w/lf" ]] && continue

  drifted_paths+=("$path")
  drifted_eols+=("$worktree_eol")
done < <(cd "$REPO_ROOT" && git ls-files --eol -z)

(( scanned > 0 )) || {
  echo "EOL PREFLIGHT: FAILED — no tracked paths enumerated in $REPO_ROOT"
  exit 1
}

[[ ${#drifted_paths[@]} -eq 0 ]] && exit 0

echo ""
echo "EOL PREFLIGHT: ${#drifted_paths[@]} tracked path(s) declare eol=lf but are NOT LF on disk:"
for i in "${!drifted_paths[@]}"; do
  echo "  ${drifted_paths[$i]}  (${drifted_eols[$i]})"
  echo "    repair: git checkout -- ${drifted_paths[$i]}"
done
echo ""
echo "EOL PREFLIGHT: FAILED — a 'git apply' round-trip cannot be byte-exact on these paths."
echo "git reports them CLEAN (autocrlf normalizes before comparing), so this is invisible in"
echo "'git status' until the sabotage harness reaches a patch that touches one — then it dies"
echo "with a misleading 'SHA mismatch after revert'. The repair discards nothing: the"
echo "worktree bytes and the index blob are already identical once normalized."
echo "Run the listed command(s), confirm 'git status --short' is still empty, then re-run."
exit 1
