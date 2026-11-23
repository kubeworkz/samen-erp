#!/usr/bin/env bash
# scripts/sabotage_selection_test.sh — regression harness for sabotage.sh's SELECTION
# logic (ADR-047 batch A4, fold (a)).
#
# THE BUG THIS PINS. `--changed [<ref>]` is the verifier primitive ("replay the
# sabotages relevant to my diff"). It derived its touched set from
# `git diff --name-only <ref>`, which lists ONLY TRACKED paths — so any batch that ADDS
# files silently under-selected. A3 hit this for real: its own new patches 247, 248 and
# 249 touch `samen_core/lib/samen/ai/agent/{tool_result,tools}.ex`, which were BRAND NEW,
# so `--changed HEAD` selected 11 patches and MISSED three of that batch's four. A
# verifier who trusted `--changed` alone would have certified A3 without ever replaying
# its own tool-result sabotages. An under-selecting selector is worse than no selector,
# because it reports a confident green over a hole.
#
# THE FIX. `--changed` now unions `git diff --name-only <ref>` with
# `git ls-files --others --exclude-standard`, and the FILTERED banner/label says
# `changed=<ref>+untracked` so the union is visible in the run's own output.
#
# WHAT THIS SCRIPT PROVES (all via `--list`, so NO patch is ever applied and no test runs):
#
#   1. POSITIVE — an untracked patch whose touched file is itself UNTRACKED IS selected
#      by `--changed HEAD`. This is the exact A3 miss, reproduced and closed.
#   2. THE MECHANISM IS THE UNION, not an accident — the same probe path is asserted
#      ABSENT from `git diff --name-only HEAD` (it is untracked, so git diff cannot see
#      it) and PRESENT in `git ls-files --others --exclude-standard`. Without this the
#      positive case could pass merely because the file happened to be tracked.
#   3. NEGATIVE CONTROL (anti-tautology) — a patch touching a path that is NEITHER
#      changed NOR untracked is NOT selected. Without this, "selects everything" would
#      pass assertion 1.
#   4. THE BANNER IS HONEST — the `--list` header for a `--changed` run names the union
#      (`changed=HEAD+untracked`), so a reader can never mistake it for the tracked-only
#      selector that shipped before.
#   5. FILTERS STILL COMPOSE AS AN INTERSECTION — `--changed HEAD --range` narrows to the
#      intersection and does not resurrect the probe patch.
#   6. `--touching` MATCHES A DIRECTORY ON A PATH-SEGMENT BOUNDARY — a patch deep
#      under the directory is selected, while a patch under a SIBLING whose name
#      extends the directory's name (`..._dir_extra`) is NOT. The trap matters: a
#      raw `[[ $pf == $dir* ]]` prefix would wrongly select the sibling.
#
#   7. `--exclude-app` IS THE COMPLEMENT OF `--app`, AND ONLY THAT — a `samen_core` probe is
#      dropped by `--exclude-app samen_core` but kept by `--exclude-app samen_web` (the
#      positive control: an "exclude everything" implementation would pass the first half),
#      and the banner names `except=<app>` so a narrowed run cannot be read as a full one.
#
# Usage: scripts/sabotage_selection_test.sh
# Exit:  0 if every assertion passes; non-zero + FAIL lines otherwise.
# Residue: NONE — every scratch file is created under scripts/sabotages/ + samen_core/lib/
# with a distinctive `__sabotage_selection_probe` name and removed on EVERY exit path
# (trap covering EXIT/INT/TERM). Nothing tracked is ever modified.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SABOTAGE="$REPO_ROOT/scripts/sabotage.sh"

PROBE_SRC_REL="samen_core/lib/samen/__sabotage_selection_probe.ex"
PROBE_SRC="$REPO_ROOT/$PROBE_SRC_REL"
# 999 keeps the probe out of every real --range window a gate would use.
PROBE_PATCH="$REPO_ROOT/scripts/sabotages/999-sabotage-selection-probe.patch"
ABSENT_PATCH="$REPO_ROOT/scripts/sabotages/998-sabotage-selection-absent-probe.patch"
ABSENT_REL="samen_core/lib/samen/__sabotage_selection_absent.ex"
PROBE_DIR_REL="samen_core/lib/samen/__sabotage_selection_probe_dir"
PROBE_SIBLING_REL="samen_core/lib/samen/__sabotage_selection_probe_dir_extra"
PROBE_DIR_PATCH="$REPO_ROOT/scripts/sabotages/997-sabotage-selection-dir-probe.patch"
PROBE_SIBLING_PATCH="$REPO_ROOT/scripts/sabotages/996-sabotage-selection-dir-sibling-probe.patch"

pass_count=0
fail_count=0
ok()  { echo "PASS: $*"; pass_count=$((pass_count + 1)); }
bad() { echo "FAIL: $*"; fail_count=$((fail_count + 1)); }

cleanup() {
  rm -f "$PROBE_SRC" "$PROBE_PATCH" "$ABSENT_PATCH" "$PROBE_DIR_PATCH" "$PROBE_SIBLING_PATCH"
  rm -rf "$REPO_ROOT/$PROBE_DIR_REL" "$REPO_ROOT/$PROBE_SIBLING_REL"
}
trap cleanup EXIT INT TERM

# A probe patch carrying the house header set (APP/TEST_FILES/MUST_FAIL) so the ALWAYS-ON
# header preflight (scripts/sabotage_lint.sh) stays green while these probes exist. The
# body is never applied — every assertion below runs `--list`.
write_probe_patch() { # write_probe_patch <patch-path> <touched-rel-path>
  cat > "$1" <<EOF
# SABOTAGE: scripts/sabotage_selection_test.sh scratch probe — NEVER applied (every
# assertion in that harness runs --list, which applies nothing). Present only for the
# lifetime of that script; removed on every exit path.
# APP: samen_core
# TEST_FILES: test/ai/agent_tools_test.exs
# MUST_FAIL: sabotage selection probe
diff --git a/$2 b/$2
--- a/$2
+++ b/$2
@@ -1,1 +1,1 @@
-# probe
+# probe (sabotaged)
EOF
}

echo "== sabotage.sh --changed selection: untracked files must be in the touched set =="

# The probe SOURCE file is created but NEVER `git add`ed — it is untracked, exactly like
# a brand-new module mid-batch.
printf '# probe\n' > "$PROBE_SRC"
write_probe_patch "$PROBE_PATCH" "$PROBE_SRC_REL"
# ...and a second probe patch touching a path that does not exist and was never changed.
write_probe_patch "$ABSENT_PATCH" "$ABSENT_REL"

# Directory-prefix probes: 997 sits DEEP under the directory; 996 sits under the
# sibling `..._dir_extra`, whose name extends the directory's. Both directories are
# real, so the sibling is routed through the same directory matcher rather than
# falling back to exact-path matching.
mkdir -p "$REPO_ROOT/$PROBE_DIR_REL/deep" "$REPO_ROOT/$PROBE_SIBLING_REL"
printf '# probe\n' > "$REPO_ROOT/$PROBE_DIR_REL/deep/nested.ex"
printf '# probe\n' > "$REPO_ROOT/$PROBE_SIBLING_REL/nested.ex"
write_probe_patch "$PROBE_DIR_PATCH" "$PROBE_DIR_REL/deep/nested.ex"
write_probe_patch "$PROBE_SIBLING_PATCH" "$PROBE_SIBLING_REL/nested.ex"

listing="$(cd "$REPO_ROOT" && bash "$SABOTAGE" --changed HEAD --list 2>&1)"
list_status=$?

if [[ $list_status -ne 0 ]]; then
  echo "$listing"
  bad "--changed HEAD --list exited $list_status (expected 0)"
else
  ok "--changed HEAD --list exited 0"
fi

# 2. THE MECHANISM: git diff cannot see the probe; ls-files --others can.
if (cd "$REPO_ROOT" && git diff --name-only HEAD) | grep -qxF "$PROBE_SRC_REL"; then
  bad "precondition broken: $PROBE_SRC_REL is TRACKED — assertion 1 would be vacuous"
else
  ok "precondition: git diff --name-only HEAD does NOT list the untracked probe (the old selector's blind spot)"
fi

if (cd "$REPO_ROOT" && git ls-files --others --exclude-standard) | grep -qxF "$PROBE_SRC_REL"; then
  ok "git ls-files --others --exclude-standard DOES list the untracked probe (the union's second half)"
else
  bad "git ls-files --others --exclude-standard did not list $PROBE_SRC_REL"
fi

# 1. POSITIVE: the untracked-file patch is selected.
if grep -qF "999-sabotage-selection-probe.patch" <<<"$listing"; then
  ok "--changed HEAD SELECTS a patch whose only touched file is UNTRACKED (the A3 247/248/249 miss, closed)"
else
  echo "$listing"
  bad "--changed HEAD did NOT select the untracked-file patch — the union regressed"
fi

# 3. NEGATIVE CONTROL: a patch touching a neither-changed-nor-untracked path is NOT
#    selected. Without this, a selector that returned every patch would pass above.
if grep -qF "998-sabotage-selection-absent-probe.patch" <<<"$listing"; then
  echo "$listing"
  bad "--changed HEAD selected a patch touching an UNCHANGED, UNTRACKED-ABSENT path — the filter is vacuous"
else
  ok "NEGATIVE CONTROL: a patch touching a neither-changed-nor-untracked path is NOT selected"
fi

# 4. THE BANNER IS HONEST about what the touched set actually contains.
if grep -qF "changed=HEAD+untracked" <<<"$listing"; then
  ok "the FILTERED selection banner names the union (changed=HEAD+untracked) — no silent widening"
else
  echo "$listing"
  bad "the --changed banner does not disclose the untracked half of the union"
fi

# 6. --exclude-app is the COMPLEMENT of --app, not "exclude everything".
excluded="$(cd "$REPO_ROOT" && bash "$SABOTAGE" --exclude-app samen_core --list 2>&1)"
if grep -qF "999-sabotage-selection-probe.patch" <<<"$excluded"; then
  echo "$excluded"
  bad "--exclude-app samen_core still selected a samen_core probe patch"
else
  ok "--exclude-app <app> DROPS that app's patches (the complement of --app)"
fi

kept="$(cd "$REPO_ROOT" && bash "$SABOTAGE" --exclude-app samen_web --list 2>&1)"
if grep -qF "999-sabotage-selection-probe.patch" <<<"$kept"; then
  ok "POSITIVE CONTROL: --exclude-app <other app> leaves the samen_core probe selected"
else
  echo "$kept"
  bad "--exclude-app samen_web dropped a samen_core patch — the filter excludes everything"
fi

if grep -qF "except=samen_core" <<<"$excluded"; then
  ok "the FILTERED banner names the exclusion (except=samen_core) — no silent narrowing"
else
  bad "the --exclude-app banner does not disclose the exclusion"
fi

# 5. FILTERS STILL COMPOSE AS AN INTERSECTION (the union widened the touched set, it did
#    not turn --changed into a union WITH the other filters).
narrowed="$(cd "$REPO_ROOT" && bash "$SABOTAGE" --changed HEAD --range 1-2 --list 2>&1)"
if grep -qF "999-sabotage-selection-probe.patch" <<<"$narrowed"; then
  echo "$narrowed"
  bad "--changed + --range did not intersect: the out-of-range probe survived"
else
  ok "filters still COMPOSE as an intersection (--changed HEAD --range 1-2 excludes the probe)"
fi

echo ""
echo "== sabotage.sh --touching: DIRECTORY entries match on a path-segment prefix =="

dir_listing="$(cd "$REPO_ROOT" && bash "$SABOTAGE" --touching "$PROBE_DIR_REL" --list 2>&1)"
dir_status=$?
if [[ $dir_status -eq 0 ]]; then
  ok "--touching <dir> --list exited 0"
else
  echo "$dir_listing"
  bad "--touching <dir> --list exited $dir_status (expected 0)"
fi

if grep -qF "997-sabotage-selection-dir-probe.patch" <<<"$dir_listing"; then
  ok "--touching <dir> SELECTS a patch touching a file DEEP under it (path-segment prefix)"
else
  echo "$dir_listing"
  bad "--touching <dir> did not select the patch under it"
fi

# BOUNDARY: the selected entry is "..._dir"; PROBE_SIBLING_REL is "..._dir_extra".
# A raw string prefix would match the sibling; the required "<dir>/" boundary must not.
if grep -qF "996-sabotage-selection-dir-sibling-probe.patch" <<<"$dir_listing"; then
  echo "$dir_listing"
  bad "BOUNDARY: <dir> matched a patch under <dir>_extra (raw string prefix, not a segment)"
else
  ok "BOUNDARY: <dir> does NOT match <dir>_extra/... (path-segment prefix, not raw string)"
fi

if grep -qF "touching=1 path(s)" <<<"$dir_listing"; then
  ok "the directory selection still reports the FILTERED touched-set banner"
else
  bad "the directory selection lost the FILTERED touched-set banner"
fi

# Exact entries must keep exact semantics, and a trailing slash must normalize.
exact_listing="$(cd "$REPO_ROOT" && bash "$SABOTAGE" --touching "$PROBE_DIR_REL/deep/nested.ex" --list 2>&1)"
if grep -qF "997-sabotage-selection-dir-probe.patch" <<<"$exact_listing" \
   && ! grep -qF "996-sabotage-selection-dir-sibling-probe.patch" <<<"$exact_listing"; then
  ok "exact FILE selection still selects only the patch touching that file"
else
  echo "$exact_listing"
  bad "exact FILE selection changed (directory or sibling leaked in)"
fi

slash_listing="$(cd "$REPO_ROOT" && bash "$SABOTAGE" --touching "$PROBE_SIBLING_REL/" --list 2>&1)"
if grep -qF "996-sabotage-selection-dir-sibling-probe.patch" <<<"$slash_listing" \
   && ! grep -qF "997-sabotage-selection-dir-probe.patch" <<<"$slash_listing"; then
  ok "a trailing slash is normalized and selects only that directory's patch"
else
  echo "$slash_listing"
  bad "trailing-slash directory selection is wrong"
fi

cleanup

# Residue check: the probes are gone and the tree is exactly as we found it.
if [[ -e "$PROBE_SRC" || -e "$PROBE_PATCH" || -e "$ABSENT_PATCH" \
      || -e "$PROBE_DIR_PATCH" || -e "$PROBE_SIBLING_PATCH" \
      || -e "$REPO_ROOT/$PROBE_DIR_REL" || -e "$REPO_ROOT/$PROBE_SIBLING_REL" ]]; then
  bad "scratch residue left behind"
else
  ok "zero residue (probe source, four probe patches and two probe dirs removed)"
fi

echo ""
echo "sabotage-selection harness: $pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]] || { echo "SABOTAGE SELECTION HARNESS: FAILED"; exit 1; }
echo "SABOTAGE SELECTION HARNESS: ALL PASSED"
