#!/usr/bin/env bash
# scripts/sabotage_anchor_preflight.sh — fail-closed "every patch is anchored to a test that
# still exists" preflight.
#
# WHY THIS EXISTS. A patch flips a guarantee and declares, in `# TEST_FILES:`/`# MUST_FAIL:`
# headers, the tests that must go red. Nothing checked that those anchors still EXIST. When a
# test is renamed, moves file, or the header mis-states its path, the patch keeps applying
# cleanly (the guard it flips is unchanged) but the declared suite never reds — so the harness
# reports the one thing it is told to report, `suite PASSED under sabotage — the guarantee did
# not flip (vacuous gate)`, arbitrarily deep into the replay and blaming the guarantee instead
# of the anchor. Two real instances: `224-d3-pii-declared-erasability-guard-bypassed.patch`
# (~1h30m in: its REFUSED red-path had moved to the completeness gate's live-guard probe), and
# `300-t183b-ci-eval-dropped-from-closed-surface-set.patch`, whose `# TEST_FILES:` carried an
# app-DOUBLED path and whose `# MUST_FAIL:` named a check in prose rather than a test.
#
# The check is static and READ-ONLY:
#   (a) every `# TEST_FILES:` path must exist under the patch's `# APP:`;
#   (b) every `# MUST_FAIL:` string must occur in a test/property/describe NAME in those files
#       — the harness matches MUST_FAIL against ExUnit's failed-test headers, and ExUnit
#       prefixes a nested test's reported name with its `describe` string, so describe names
#       are part of the haystack.
# Two name-shape traps are handled explicitly, because getting them wrong would make this
# guard itself unreliable:
#   * SOURCE text escapes quotes (`test "… `alias :\"Elixir…\"`"`), while the RUNTIME name the
#     harness greps does not — so extracted names are unescaped before comparison.
#   * An INTERPOLATED name (`test "converges — #{name}"`) has no static value at all. A
#     MUST_FAIL that matches no literal name but coexists with interpolation in its anchored
#     files is reported as an UNVERIFIABLE note, never a failure (the dynamic harness stays the
#     authority); blocking a gate on a name that is only knowable at runtime would be a false
#     red of its own.
#
# Output contract: NOTHING is printed when every patch is anchored.
#
# Exit: 0 every patch anchored · 1 a stale/missing anchor (or no patches found)
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SABOTAGE_DIR="$REPO_ROOT/scripts/sabotages"

shopt -s nullglob
patches=("$SABOTAGE_DIR"/*.patch)
if [[ ${#patches[@]} -eq 0 ]]; then
  echo "SABOTAGE ANCHOR PREFLIGHT: FAILED — no patches found in $SABOTAGE_DIR"
  exit 1
fi

# Declared test/property/describe names in a file, as RUNTIME name text (unescaped).
#
# Extraction is deliberately mechanical: on a declaration line, drop everything through the
# OPENING quote, then drop the LAST quote and whatever follows it (` do`, `, ctx do`, a ` <>`
# continuation, …). Building this from the first-to-last QUOTE CHARACTER is what makes it
# robust to the two shapes that broke the naive forms:
#   * an escaped quote inside the name — `test "… skips host B's \"xyz\" …"` — where a
#     `"[^"]*"` match (and a strict trailing anchor) either truncates the name or drops the
#     line entirely (`38-t123`, `93-t82`, `298-uxd05`);
#   * a name CONTINUED with `<>` onto the next line (`37-t42`), where requiring ` do`/`,` after
#     the closing quote silently skipped the test — the line ends with `<>`, not ` do`.
# A fragment from a `<>`-continued name still contains the prefix a MUST_FAIL anchors on, so
# substring matching stays sound; only a MUST_FAIL spanning the concatenation itself would be
# unverifiable, which is the safe direction (a note, never a false red).
harvest_names() {
  sed -nE '/^[[:space:]]*(test|property|describe)[[:space:]]*"/ { s/^[^"]*"//; s/"[^"]*$//; p }' "$1" 2>/dev/null \
    | sed 's/\\"/"/g; s/\\\\/\\/g'
}

problems=()
notes=()

for patch in "${patches[@]}"; do
  name="$(basename "$patch")"

  app="$(sed -n 's/^# APP: *//p' "$patch" | head -1)"
  [[ -n "$app" ]] || { problems+=("$name: no '# APP:' header"); continue; }

  # TEST_FILES is space-separated; MUST_FAIL may repeat.
  test_files="$(sed -n 's/^# TEST_FILES: *//p' "$patch" | head -1)"
  [[ -n "$test_files" ]] || { problems+=("$name: no '# TEST_FILES:' header"); continue; }

  # shellcheck disable=SC2086
  set -- $test_files
  files=("$@")

  missing=()
  for rel in "${files[@]}"; do
    [[ -f "$REPO_ROOT/$app/$rel" ]] || missing+=("$rel")
  done
  if [[ ${#missing[@]} -gt 0 ]]; then
    problems+=("$name: '# TEST_FILES:' path(s) do not exist under $app/: ${missing[*]}")
    continue
  fi

  names_file="$(mktemp "${TMPDIR:-/tmp}/sabotage_names.XXXXXX")"
  for rel in "${files[@]}"; do
    harvest_names "$REPO_ROOT/$app/$rel" >> "$names_file"
  done

  interpolated=0
  grep -q '#{' "$names_file" && interpolated=1

  while IFS= read -r must; do
    [[ -n "$must" ]] || continue
    grep -qF -- "$must" "$names_file" && continue

    if (( interpolated )); then
      notes+=("$name: '# MUST_FAIL:' not verifiable statically (the anchored file(s) declare interpolated test names): $must")
      continue
    fi

    # Not in the anchored files: say WHERE it lives now, if anywhere — a MOVED test is the
    # common cause and the fix is a re-pointed TEST_FILES, not a deleted patch.
    elsewhere="$(grep -rlF -- "$must" "$REPO_ROOT/$app/test" 2>/dev/null | head -3 \
      | sed "s|^$REPO_ROOT/$app/||" | tr '\n' ' ')"
    if [[ -n "$elsewhere" ]]; then
      problems+=("$name: '# MUST_FAIL:' name is not in the anchored file(s): $must")
      notes+=("    '$must' now appears in: ${elsewhere% }")
    else
      problems+=("$name: '# MUST_FAIL:' name matches NO test anywhere in $app/ — renamed, removed, or written in prose: $must")
    fi
  done < <(sed -n 's/^# MUST_FAIL: *//p' "$patch")

  rm -f "$names_file"
done

# Silent on success, including when some MUST_FAIL is merely unverifiable statically (an
# interpolated test name is a permanent, expected condition — printing it every gate run
# would train readers to ignore this preflight). The dynamic harness remains the authority
# for those.
[[ ${#problems[@]} -eq 0 ]] && exit 0

echo ""
echo "SABOTAGE ANCHOR PREFLIGHT: ${#problems[@]} anchor problem(s) across ${#patches[@]} patches:"
printf '  %s\n' "${problems[@]}"
if [[ ${#notes[@]} -gt 0 ]]; then
  echo ""
  echo "  Context / moves:"
  printf '%s\n' "${notes[@]}"
fi
echo ""
echo "SABOTAGE ANCHOR PREFLIGHT: FAILED — a patch anchored to a nonexistent or moved test still"
echo "APPLIES, so the harness cannot tell it apart from a vacuous gate: it reports 'suite PASSED"
echo "under sabotage — the guarantee did not flip' arbitrarily deep into the replay, blaming"
echo "the guarantee instead of the anchor. Re-point '# TEST_FILES:'/'# MUST_FAIL:' at the tests"
echo "that prove the guarantee today (keep the flipped lines and the defect identical), then"
echo "re-verify with 'bash scripts/sabotage.sh --range <N>-<N>' — the flip(s) AND a byte-exact"
echo "restore must be reported."
exit 1
