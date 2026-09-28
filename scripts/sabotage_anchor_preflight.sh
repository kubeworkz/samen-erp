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
# PERFORMANCE. This is the slowest of the four structural guards, and it used to be slow for a
# reason unrelated to what it checks: it forked ~10 processes PER PATCH (`basename`, two `sed`s
# for the headers, `mktemp`, one or two `sed`s per test file, a `grep -q '#{'`, a `grep -qF` per
# MUST_FAIL, `rm`). At 308 patches that is ~3,000-4,500 forks, and on Git Bash (a full process
# per spawn) that is ~2 minutes of pure fork overhead. The header parse, the name harvest and
# the membership test now ALL run in a single `awk` process — the same semantics, one fork —
# and an external `grep -rlF` is paid ONLY for a MUST_FAIL that matched nothing (a real finding,
# and the "where did it move" context is worth a process). Measured ~117s → a few seconds.
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

problems=()
notes=()

# One awk pass reads every patch's headers and, for each patch, harvests the declared names out
# of its TEST_FILES (cached across patches — many share files) and checks every MUST_FAIL
# against them. It emits tab-separated records, and NOTHING else:
#   P  <kind> <patch> [<app> <paths>]   — a structural problem: NOAPP | NOTEST | MISSING
#   U  <patch> <app> <must> <0|1>       — a MUST_FAIL that matched no name in its own files
# The U records are resolved HERE (there are few of them, and only when something is off), so
# the filesystem-wide search still runs exactly when it used to and reports the same context.
# Composing the human messages in bash (rather than in awk) also keeps every apostrophe and
# em-dash out of the awk program.
scan="$(mktemp "${TMPDIR:-/tmp}/sabotage_anchor.XXXXXX")"
if ! awk -v ROOT="$REPO_ROOT" '
  function base(p,   s) { s = p; sub(/^.*\//, "", s); return s }

  # Declared test/property/describe names in ONE file, as RUNTIME name text (unescaped), cached
  # by path. Extraction is deliberately mechanical: on a declaration line, drop everything
  # through the OPENING quote, then drop the LAST quote and whatever follows it (` do`, `, ctx
  # do`, a ` <>` continuation, …). Building the name from the first-to-last QUOTE CHARACTER is
  # what makes it robust to the two shapes that broke naive forms:
  #   * an escaped quote inside the name — `test "… skips host B'"'"'s \"xyz\" …"` — where a
  #     `"[^"]*"` match (and a strict trailing anchor) truncates the name or drops the line
  #     entirely (38-t123, 93-t82, 298-uxd05);
  #   * a name CONTINUED with `<>` onto the next line (37-t42), where requiring ` do`/`,` after
  #     the closing quote silently skipped the test — the line ends with `<>`, not ` do`.
  # A fragment from a `<>`-continued name still contains the prefix a MUST_FAIL anchors on, so
  # substring matching stays sound; only a MUST_FAIL spanning the concatenation itself would be
  # unverifiable — the safe direction (a note, never a false red).
  # MISSING[path] is set when the file cannot be opened; getline keeps this to ONE process, and
  # each handle is closed so hundreds of cached files never exhaust the descriptor table.
  function harvest(path,   line, rc, s, block) {
    if (path in NAMES) return NAMES[path]
    block = ""
    rc = (getline line < path)
    if (rc < 0) { MISSING[path] = 1; NAMES[path] = ""; return "" }
    while (rc > 0) {
      if (line ~ /^[[:space:]]*(test|property|describe)[[:space:]]*"/) {
        s = line
        sub(/^[^"]*"/, "", s)
        sub(/"[^"]*$/, "", s)
        gsub(/\\"/, "\"", s)
        gsub(/\\\\/, "\\", s)
        block = block s "\n"
      }
      rc = (getline line < path)
    }
    close(path)
    NAMES[path] = block
    return block
  }

  # Evaluate the patch whose headers are currently accumulated (called at every file boundary and
  # once at END). Global state: cur, app, has_tf, tfstr, must[], nmust.
  function evaluate(   i, p, b, missing, block, j, m, nf, files) {
    if (cur == "") return
    name = base(cur)
    if (app == "") { print "P\tNOAPP\t" name; return }
    if (!has_tf)   { print "P\tNOTEST\t" name; return }

    nf = split(tfstr, files, /[ \t]+/)
    missing = ""; block = ""
    for (i = 1; i <= nf; i++) {
      p = ROOT "/" app "/" files[i]
      b = harvest(p)
      if (p in MISSING) missing = (missing == "" ? files[i] : missing " " files[i])
      else              block   = block b
    }
    if (missing != "") { print "P\tMISSING\t" name "\t" app "\t" missing; return }

    interp = (index(block, "#{") > 0)
    for (j = 1; j <= nmust; j++) {
      m = must[j]
      if (m == "") continue
      if (index(block, m) > 0) continue
      print "U\t" name "\t" app "\t" m "\t" (interp ? 1 : 0)
    }
  }

  FNR == 1 { evaluate(); cur = FILENAME; app = ""; has_tf = 0; tfstr = ""; nmust = 0 }
  /^# APP:/        { if (app == "")    { app = $0;   sub(/^# APP: */, "", app) } }
  /^# TEST_FILES:/ { if (!has_tf)      { tfstr = $0; sub(/^# TEST_FILES: */, "", tfstr); has_tf = 1 } }
  /^# MUST_FAIL:/  { m = $0; sub(/^# MUST_FAIL: */, "", m); must[++nmust] = m }
  END { evaluate() }
' "${patches[@]}" > "$scan"; then
  echo "SABOTAGE ANCHOR PREFLIGHT: FAILED — the anchor scan did not complete (awk exited non-zero)"
  rm -f "$scan"
  exit 1
fi

while IFS=$'\t' read -r tag a b c d; do
  case "$tag" in
    P)
      case "$a" in
        NOAPP)   problems+=("$b: no '# APP:' header") ;;
        NOTEST)  problems+=("$b: no '# TEST_FILES:' header") ;;
        MISSING) problems+=("$b: '# TEST_FILES:' path(s) do not exist under $c/: $d") ;;
      esac
      ;;
    U)
      name="$a"; app="$b"; must="$c"
      if [[ "$d" == "1" ]]; then
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
      ;;
  esac
done < "$scan"
rm -f "$scan"

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
