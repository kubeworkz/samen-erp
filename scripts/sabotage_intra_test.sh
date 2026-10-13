#!/usr/bin/env bash
# scripts/sabotage_intra_test.sh — regression harness for INTRA-APP sabotage parallelism: one test
# database per slice, and the guards that keep a wider run honest.
#
# THE BUG THIS PINS. Two patches with the same APP: header could never be replayed at the same
# time, and the reason was never the patches — it was the DATABASE. Every DB-backed app's
# `test_helper.exs` (and `mix samen_web.test_setup` via the `mix test` alias) does `storage_down` →
# `storage_up` → migrate against the app's ONE canonical test DB, so a second concurrent suite of
# the same app drops the schema out from under the first. That is why the parallel driver was
# app-partitioned and why the sweep could never finish faster than its LARGEST app (samen_core,
# 173 of 334 patches — 89% of the work sits in two apps).
#
# THE FIX. Each slice runs against its own database: `scripts/sabotage.sh --test-db <name>` exports
# SAMEN_TEST_DB for the patch's `mix test`, and every DB-backed app's config/test.exs reads the
# name from it (unset ⇒ the canonical name, unchanged). scripts/sabotage_parallel.sh cuts the
# largest apps into `--range` chunks, hands each chunk its own tree + DB, and only does so when a
# list-scheduling estimate says the split beats the app-only partition.
#
# WHAT THIS SCRIPT PROVES (every driver assertion runs `--list` or `--adapt-selftest`, so NO patch
# is applied, no replay tree is built and no suite is ever run):
#
#   1. THE DATABASE SEAM IS LIVE — and refutable. For every DB-backed app the harness runs, the
#      test repo's configured database is its canonical name when SAMEN_TEST_DB is unset and the
#      override when it is set. A config that quietly ignored the variable would print the canonical
#      name in both cases and fail here, which is the whole point: a seam that cannot be observed
#      cannot be trusted (the isolation is worthless if the name never reaches the repo).
#   2. THE FLAG IS VALIDATED — `sabotage.sh --test-db` accepts a bare Postgres identifier and
#      REFUSES anything else (exit 2), and the driver refuses `--test-db` outright, because it owns
#      the name per slice and accepting a caller value would put every slice back on one database.
#   3. THE APP-ONLY PARTITION IS UNCHANGED — `--intra 1` yields exactly one slice per app, whose id
#      is the app name, exactly as the pre-intra-app driver did.
#   4. THE INTRA-APP SPLIT IS REAL AND COMPLETE — with a wide pool the largest app is cut into
#      several slices, every slice is at most one job's fair share, the slices sum to the harness's
#      OWN selected count (coverage asserted, never assumed), each app's chunk ranges are disjoint
#      and ascending, every slice has its own database name, and the estimated makespan drops below
#      the app-partition floor.
#   5. THE CONNECTION BUDGET LOWERS AN UNPINNED WIDTH — a `psql` reporting a small max_connections
#      must lower an unpinned width AND say so, rather than let the run discover it as `too many
#      clients` two hours in (pinned to a stub `psql`, so the assertion is about the driver).
#   6. NEGATIVE CONTROL — a patch that cannot be chunked (a filename with no numeric NNN- prefix,
#      which no `--range` can select) or whose `# APP:` header is duplicated (which resolves to a
#      second, bare listing line and matches no `--app` filter) makes the driver FAIL instead of
#      silently dropping it.
#   7. NEGATIVE CONTROL — the fixed-resource audit. Two probes that share a test file which creates
#      a FIXED-NAME scratch database, placed in two different slices of one app, MUST make the
#      driver refuse to launch; `--allow-shared-scratch` then proceeds and says so. Without this
#      pair, "the audit found nothing" would be indistinguishable from "the audit does nothing".
#   8. THE CALLER'S RANGE IS FOLDED, NOT FORWARDED — a slice is launched with its OWN chunk
#      `--range`, and sabotage.sh's last `--range` wins, so forwarding the caller's too would make
#      EVERY slice replay the first patch of the caller's range while still reporting the count it
#      was assigned (one patch each, all counts matching, no coverage hole to catch it). The plan
#      prints each slice's exact arguments, and one chunk is re-listed to prove it selects exactly
#      its assigned patches.
#   9. THE SEED CANNOT HIDE A PATCH, AND A RUNNING SIBLING IS NEVER COPIED — warm-starting a new
#      slice means copying a sibling's build cache, which is only safe because compiler staleness
#      is DIGEST-based: reuse survives new mtimes, an mtime-only touch recompiles nothing, and a
#      one-line content change recompiles exactly that module. Pinned on a dependency-free scratch
#      project (seconds), so an Elixir that went mtime-only fails here instead of silently
#      masking a flip in a certification. The seed PLAN is pinned too: offered from an idle
#      sibling, never from one whose per-slice lock is held, and disabled by --no-seed.
#  10. THE COLD-COMPILE BUDGET IS REPORTED, AND ITS WIDTH IS ALLOWED TO MOVE — a wide COLD start is
#      the one load that kills a sweep on a small box, so the plan must say how many slices pay the
#      one-time compile, what width the run STARTS at, and the ceiling it may climb to. Those are
#      three DISTINCT statements on purpose: "at most N" while the width is free to rise to M is a
#      number nobody can act on. A slice the seed plan is about to warm is not counted cold.
#  11. THE COLD WIDTH ADAPTS AT RUNTIME, AND THE CONTROLLER IS REFUTABLE — the width starts at the
#      configured cap and rises ONE step per round of clean epochs, on evidence it actually has: a
#      probe that still spawns its children, no fork signature in any slice log, a cold compile that
#      FINISHED at the width about to be multiplied, and a cold slice still waiting to be admitted.
#      ANY pressure lowers it once and freezes it for the rest of the run — a box having a bad
#      minute must not be allowed to ratchet the width to the floor. All of that is decided by
#      `--adapt-selftest`, which drives the real controller through scripted scenarios, and the gate
#      is proven REFUTABLE: a mutated copy of the driver whose width can no longer rise must turn it
#      red, so "the gate passed" can never mean "the gate cannot fail".
#  12. THE SCRATCH ROOT IS GIT-IGNORED — the harness replicates the checkout's untracked files
#      into every replay tree, so an un-ignored in-repo root is copied (build caches, nesting
#      deeper each run) instead of replaying patches; an in-repo root git does not ignore is
#      refused up front.
#  13. ZERO RESIDUE — every probe is removed on every exit path.
#
# Usage: scripts/sabotage_intra_test.sh
# Exit:  0 if every assertion passes; non-zero + FAIL lines otherwise.
# Cost:  ~4 minutes here, dominated by the two driver calls that list the WHOLE selection (each
#        re-runs the header lint + per-patch metadata read over all 334 patches on Windows). Every
#        other driver call is filtered to a handful of patches and takes seconds. The width-controller
#        gate is three more driver calls and compiles nothing.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SABOTAGE="$REPO_ROOT/scripts/sabotage.sh"
DRIVER="$REPO_ROOT/scripts/sabotage_parallel.sh"
SABOTAGE_DIR="$REPO_ROOT/scripts/sabotages"

# Probe artifacts (created for the negative controls only, removed on every exit path). The numbers
# 900/901 are far above every shipped patch, so a `--range 900-901` selection is exactly the probes.
PROBE_A="$SABOTAGE_DIR/900-sabotage-intra-probe-a.patch"
PROBE_B="$SABOTAGE_DIR/901-sabotage-intra-probe-b.patch"
PROBE_UNCHUNKABLE="$SABOTAGE_DIR/unchunkable-sabotage-intra-probe.patch"
PROBE_DUP_APP="$SABOTAGE_DIR/902-sabotage-intra-dup-app-probe.patch"
# The adaptive-width refutability twin's path. It MUST live inside the repo: the driver derives its
# scratch root from its own location and refuses an un-ignored in-repo root, so a copy under $WORK
# would fail the controller gate for the WRONG reason and the negative control would prove nothing.
ADAPT_PROBE="$REPO_ROOT/scripts/.sabotage-adapt-probe.sh"
PROBE_TEST_REL="samen_core/test/__probe/__sabotage_intra_probe_test.exs"
PROBE_TEST="$REPO_ROOT/$PROBE_TEST_REL"
PROBE_SRC_REL="samen_core/lib/samen/__sabotage_intra_probe.ex"
PROBE_SRC="$REPO_ROOT/$PROBE_SRC_REL"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/samen_sab_intra.XXXXXX")"

# The DB-backed apps the harness replays into (the two adapter packages have no test database at
# all, so there is nothing for them to isolate).
DB_APPS="samen_core samen_web demo driftwood pawchart samenerp"

pass_count=0
fail_count=0
ok()  { echo "PASS: $*"; pass_count=$((pass_count + 1)); }
bad() { echo "FAIL: $*"; fail_count=$((fail_count + 1)); }

cleanup() {
  rm -f "$PROBE_A" "$PROBE_B" "$PROBE_UNCHUNKABLE" "$PROBE_DUP_APP" "$PROBE_SRC" "$ADAPT_PROBE"
  rm -rf "$REPO_ROOT/samen_core/test/__probe"
  rm -rf "$WORK"
}
trap cleanup EXIT INT TERM

# db_of <app> [<override>] — the test repo's configured database, read by EVALUATING the app's
# config/test.exs the same way Mix does (Config.Reader), not by grepping it. `unset` is the
# negative control's other half: with no override the canonical name must come back.
db_of() { # db_of <app> [<override>]
  local app="$1" override="${2:-}"
  (
    cd "$REPO_ROOT/$app" || exit 1
    if [[ -n "$override" ]]; then
      SAMEN_TEST_DB="$override" INTRA_APP="$app" elixir -e '
        r = Config.Reader.read!("config/test.exs", env: :test)
        app = String.to_atom(System.get_env("INTRA_APP"))
        {_m, cfg} = Enum.find(Keyword.fetch!(r, app), fn {_m, v} -> is_list(v) and Keyword.has_key?(v, :database) end)
        IO.puts(Keyword.fetch!(cfg, :database))
      ' 2>&1 | tail -1
    else
      unset SAMEN_TEST_DB
      INTRA_APP="$app" elixir -e '
        r = Config.Reader.read!("config/test.exs", env: :test)
        app = String.to_atom(System.get_env("INTRA_APP"))
        {_m, cfg} = Enum.find(Keyword.fetch!(r, app), fn {_m, v} -> is_list(v) and Keyword.has_key?(v, :database) end)
        IO.puts(Keyword.fetch!(cfg, :database))
      ' 2>&1 | tail -1
    fi
  )
}

echo "== 1. the per-slice database seam (SAMEN_TEST_DB ⇒ the test repo's database) =="
for app in $DB_APPS; do
  canonical="$(db_of "$app")"
  override="$(db_of "$app" "sab_intra_probe_db")"
  if [[ "$canonical" == "sab_intra_probe_db" ]]; then
    bad "$app: the canonical lookup itself returned the override name ($canonical) — the probe is broken"
  elif [[ "$override" != "sab_intra_probe_db" ]]; then
    bad "$app: SAMEN_TEST_DB is IGNORED — config/test.exs still reports '$override'. Two slices of this app would share one database."
  elif [[ -z "$canonical" || "$canonical" == saber_* ]]; then
    bad "$app: could not read the canonical test database name (got '$canonical')"
  else
    ok "$app: unset ⇒ $canonical, SAMEN_TEST_DB=sab_intra_probe_db ⇒ $override"
  fi
done

echo ""
echo "== 2. --test-db is validated, and the driver owns it =="
out="$(bash "$SABOTAGE" --test-db 'not a db name' --list 2>&1)"; status=$?
if [[ $status -eq 2 ]]; then
  ok "sabotage.sh refuses a non-identifier --test-db name (exit 2)"
else
  echo "$out" | tail -3
  bad "sabotage.sh accepted '--test-db \"not a db name\"' (exit $status, expected 2)"
fi

out="$(bash "$DRIVER" --test-db someone_elses_db --list 2>&1)"; status=$?
if [[ $status -eq 2 ]]; then
  ok "the parallel driver refuses --test-db (it owns one database per slice)"
else
  bad "the parallel driver accepted --test-db (exit $status, expected 2) — every slice would share one database"
fi

out="$(bash "$SABOTAGE" --test-db sab_intra_probe_db --range 331-334 --list 2>&1)"; status=$?
if [[ $status -eq 0 ]] && grep -q 'SABOTAGE SELECTION:' <<<"$out"; then
  ok "sabotage.sh accepts an identifier --test-db name (exit 0, dry-run)"
else
  echo "$out" | tail -3
  bad "sabotage.sh rejected a valid --test-db name (exit $status)"
fi

echo ""
echo "== 3. --intra 1 reproduces the app-only partition (one slice per app) =="
out="$(bash "$DRIVER" --range 331-334 --intra 1 --list 2>&1)"; status=$?
if [[ $status -ne 0 ]]; then
  echo "$out" | tail -5
  bad "--intra 1 --list exited $status (expected 0)"
else
  ok "--intra 1 --list exited 0"
  sliced="$(grep -cE '^    [A-Za-z0-9_]+-[0-9]+ +range=' <<<"$out" || true)"
  if [[ "$sliced" == "0" ]]; then
    ok "--intra 1 produced NO intra-app slices (the app-only partition, unchanged)"
  else
    echo "$out" | grep -E '^    [A-Za-z0-9_]+-[0-9]+ +range=' | head -3
    bad "--intra 1 still cut $sliced app(s) into intra-app slices"
  fi
  if grep -qE '^  COVERAGE: sum of slices = [0-9]+ = [0-9]+ selected patch\(es\) ✓ every patch is assigned to exactly one slice$' <<<"$out"; then
    ok "coverage proof present and balanced for the app-only partition"
  else
    bad "no balanced COVERAGE proof for --intra 1"
  fi
fi

echo ""
echo "== 4. the intra-app split (wide pool: cut the largest app, keep coverage) =="
split_out="$(bash "$DRIVER" --jobs 8 --list 2>&1)"; status=$?
if [[ $status -ne 0 ]]; then
  echo "$split_out" | tail -5
  bad "--jobs 8 --list exited $status (expected 0)"
else
  ok "--jobs 8 --list exited 0"

  n_slices="$(sed -n 's/^  SLICE PLAN: \([0-9]*\) slice(s).*/\1/p' <<<"$split_out" | tail -1)"
  floor="$(sed -n 's/.*the app-partition floor is \([0-9]*\).*/\1/p' <<<"$split_out" | tail -1)"
  largest="$(sed -n 's/.*largest slice \([0-9]*\) patch(es).*/\1/p' <<<"$split_out" | tail -1)"
  est="$(sed -n 's/^  ESTIMATE: pool makespan ≈ \([0-9]*\) patch(es).*/\1/p' <<<"$split_out" | tail -1)"
  n_apps="$(grep -cE '^  [A-Za-z0-9_]+ +[0-9]+ patch\(es\)$' <<<"$split_out" || true)"
  core_slices="$(grep -cE '^    samen_core(-[0-9]+)? +range=' <<<"$split_out" || true)"

  [[ -n "$n_slices" && -n "$floor" && -n "$largest" && -n "$est" ]] \
    || bad "could not read the slice plan / estimate lines from the --jobs 8 output"
  if [[ -n "$n_slices" ]] && (( n_slices > n_apps )); then
    ok "the plan has $n_slices slice(s) over $n_apps app(s) — apps really are cut up"
  else
    bad "no intra-app split happened: $n_slices slice(s) over $n_apps app(s)"
  fi
  if [[ -n "$core_slices" ]] && (( core_slices > 1 )); then
    ok "samen_core (the 173-patch floor) is cut into $core_slices slices"
  else
    bad "samen_core was not cut into more than one slice ($core_slices) — the floor is intact"
  fi
  if [[ -n "$largest" && -n "$floor" ]] && (( largest < floor )); then
    ok "the largest slice ($largest) is below the app-partition floor ($floor)"
  else
    bad "largest slice $largest did not drop below the app-partition floor $floor"
  fi
  if [[ -n "$est" && -n "$floor" ]] && (( est < floor )); then
    ok "the estimated pool makespan ($est) beats the app-partition floor ($floor)"
  else
    bad "estimated makespan $est did not beat the floor $floor"
  fi
  if grep -qE '^  COVERAGE: sum of slices = [0-9]+ = [0-9]+ selected patch\(es\) ✓ every patch is assigned to exactly one slice$' <<<"$split_out"; then
    ok "coverage proof balanced: every selected patch is in exactly one slice"
  else
    bad "no balanced COVERAGE proof for the split plan"
  fi
  if grep -qE '^  TEST-RESOURCE AUDIT: 0 fixed-resource test file\(s\) run in more than one slice$' <<<"$split_out"; then
    ok "the shipped patch set has no fixed-resource test file running in two slices"
  else
    grep -E 'FIXED-RESOURCE|TEST-RESOURCE AUDIT' <<<"$split_out" | head -5
    bad "the audit reported (or failed to report) hazards on the real patch set"
  fi

  # Every slice gets its own database, named <app>_test_sab<N>.
  db_total="$(grep -cE 'db=[A-Za-z0-9_]+_test_sab[0-9]+' <<<"$split_out" || true)"
  db_unique="$(grep -oE 'db=[A-Za-z0-9_]+_test_sab[0-9]+' <<<"$split_out" | sort -u | wc -l | tr -d ' ')"
  if [[ -n "$n_slices" && "$db_total" == "$n_slices" && "$db_unique" == "$n_slices" ]]; then
    ok "every one of the $n_slices slices has its own database name ($db_unique unique)"
  else
    bad "per-slice databases are not one-per-slice ($db_total lines, $db_unique unique, $n_slices slices)"
  fi

  # Chunk ranges within one app must be disjoint and ascending: overlapping ranges would replay a
  # patch twice (or a gap would drop one, which the coverage proof would catch instead).
  while IFS= read -r app; do
    lo_hi="$(grep -E "^    ${app}(-[0-9]+)? +range=" <<<"$split_out" | sed -E 's/.*range=([0-9]+-[0-9]+) .*/\1/' | awk -F- '{print $1}')"
    bad_ranges=0
    prev_hi="-1"
    while IFS= read -r r; do
      [[ -n "$r" ]] || continue
      lo="${r%-*}"; hi="${r#*-}"
      if (( lo <= prev_hi )); then bad_ranges=$((bad_ranges + 1)); fi
      prev_hi="$hi"
    done <<<"$(grep -E "^    ${app}(-[0-9]+)? +range=" <<<"$split_out" | sed -E 's/.*range=([0-9]+-[0-9]+) .*/\1/')"
    if (( bad_ranges > 0 )); then
      bad "$app has overlapping or descending chunk ranges"
    fi
  done < <(grep -E '^  [A-Za-z0-9_]+ +[0-9]+ patch\(es\)$' <<<"$split_out" | awk '{print $1}')
  ok "chunk ranges are disjoint and ascending within every app"
fi

echo ""
echo "== 5. the connection budget lowers an unpinned width (stub psql) =="
mkdir -p "$WORK/bin"
{
  echo '#!/usr/bin/env bash'
  echo '# stub for scripts/sabotage_intra_test.sh: a tiny max_connections'
  echo 'echo 25'
} > "$WORK/bin/psql"
chmod +x "$WORK/bin/psql"
budget_out="$(PATH="$WORK/bin:$PATH" bash "$DRIVER" --range 331-334 --list 2>&1)"; status=$?
if [[ $status -eq 0 ]] && grep -q 'max_connections=25' <<<"$budget_out" && grep -qE 'width lowered to --jobs [0-9]+' <<<"$budget_out"; then
  ok "an unpinned width is lowered to fit max_connections=25, with the arithmetic printed"
elif grep -q 'max_connections=25' <<<"$budget_out"; then
  echo "$budget_out" | grep -A3 'max_connections' | head -6
  bad "the budget was reported but the width was not lowered"
else
  echo "$budget_out" | tail -5
  bad "the connection budget was not consulted (exit $status, no max_connections note)"
fi

echo ""
echo "== 6. NEGATIVE CONTROL: an unchunkable or duplicated-header patch must FAIL the driver =="
printf '# probe source (scratch; never applied)\n' > "$PROBE_SRC"
# (a) a filename with no numeric NNN- prefix: no --range can ever select it.
cat > "$PROBE_UNCHUNKABLE" <<EOF
# SABOTAGE: scripts/sabotage_intra_test.sh scratch probe — NEVER applied (every assertion runs --list).
# APP: samen_core
# TEST_FILES: test/jobs_queue_parity_test.exs
# MUST_FAIL: unchunkable probe
diff --git a/$PROBE_SRC_REL b/$PROBE_SRC_REL
--- a/$PROBE_SRC_REL
+++ b/$PROBE_SRC_REL
@@ -1,1 +1,1 @@
-# probe source (scratch; never applied)
+# probe source (scratch; sabotaged)
EOF
# (b) a duplicated '# APP:' header: resolves to a second, bare listing line that no --app matches.
cat > "$PROBE_DUP_APP" <<EOF
# SABOTAGE: scripts/sabotage_intra_test.sh scratch probe — NEVER applied.
# APP: samen_core
# APP: samen_web
# TEST_FILES: test/jobs_queue_parity_test.exs
# MUST_FAIL: duplicated app header probe
diff --git a/$PROBE_SRC_REL b/$PROBE_SRC_REL
--- a/$PROBE_SRC_REL
+++ b/$PROBE_SRC_REL
@@ -1,1 +1,1 @@
-# probe source (scratch; never applied)
+# probe source (scratch; sabotaged twice)
EOF

out="$(bash "$DRIVER" --list 2>&1)"; status=$?
if [[ $status -ne 0 ]]; then
  ok "the driver REFUSED to partition a selection containing an unchunkable / duplicated-header patch (exit $status)"
else
  echo "$out" | tail -5
  bad "the driver partitioned a set with an unchunkable and a duplicated-header patch (exit 0) — it would have dropped both"
fi
if grep -q 'unchunkable selection entry' <<<"$out" && grep -q 'unassignable selection entry' <<<"$out"; then
  ok "both classes are named: the numeric-prefix case and the duplicated-# APP: case"
else
  echo "$out" | grep -E 'unchunkable|unassignable|FAILED' | head -5
  bad "the refusal did not name both malformed classes"
fi
rm -f "$PROBE_UNCHUNKABLE" "$PROBE_DUP_APP"

echo ""
echo "== 7. NEGATIVE CONTROL: the fixed-resource audit must refuse, then acknowledge =="
mkdir -p "$(dirname "$PROBE_TEST")"
cat > "$PROBE_TEST" <<'EOF'
# Scratch probe for scripts/sabotage_intra_test.sh — NEVER run: it exists so the fixed-resource
# audit has something to find. It reaches outside the per-slice test database the way
# samen_core/test/backup_verification_test.exs does, which is the hazard the audit exists for.
defmodule SabotageIntraProbeTest do
  @scratch_db "sabotage_intra_scratch_probe"

  def setup_scratch(_ctx) do
    {_, 0} = System.cmd("createdb", [@scratch_db], stderr_to_stdout: true)
    :ok
  end
end
EOF
for n in a b; do
  patch="$PROBE_A"; [[ "$n" == "b" ]] && patch="$PROBE_B"
  cat > "$patch" <<EOF
# SABOTAGE: scripts/sabotage_intra_test.sh scratch probe — NEVER applied (every assertion runs --list).
# APP: samen_core
# TEST_FILES: test/__probe/__sabotage_intra_probe_test.exs
# MUST_FAIL: fixed-resource audit probe $n
diff --git a/$PROBE_SRC_REL b/$PROBE_SRC_REL
--- a/$PROBE_SRC_REL
+++ b/$PROBE_SRC_REL
@@ -1,1 +1,1 @@
-# probe source (scratch; never applied)
+# probe source (scratch; sabotaged $n)
EOF
done

hazard_out="$(bash "$DRIVER" --range 900-901 --intra 2 --list 2>&1)"; status=$?
if [[ $status -ne 0 ]]; then
  ok "the driver REFUSED to launch a plan whose two slices would share a fixed-name scratch DB (exit $status)"
else
  echo "$hazard_out" | tail -6
  bad "the driver launched a plan with a fixed-resource hazard (exit 0)"
fi
if grep -q 'FIXED-RESOURCE HAZARD' <<<"$hazard_out" && grep -q '__sabotage_intra_probe_test.exs' <<<"$hazard_out"; then
  ok "the refusal names the offending test file"
else
  echo "$hazard_out" | grep -E 'HAZARD|probe' | head -5
  bad "the refusal does not name the offending file"
fi
if grep -qE 'slices: samen_core,samen_core-2' <<<"$hazard_out"; then
  ok "the refusal names the two slices that would have contended for it"
else
  grep -E 'slices:' <<<"$hazard_out" | head -3
  bad "the refusal does not name the slices that would have contended"
fi
ack_out="$(bash "$DRIVER" --range 900-901 --intra 2 --allow-shared-scratch --list 2>&1)"; status=$?
if [[ $status -eq 0 ]] && grep -q 'ACKNOWLEDGED (--allow-shared-scratch)' <<<"$ack_out"; then
  ok "with --allow-shared-scratch the run proceeds AND the hazard stays visible in the output"
else
  echo "$ack_out" | tail -6
  bad "--allow-shared-scratch did not carry the run past the audit (exit $status)"
fi
# The plan that was refused is printed on the acknowledged run (the refusal exits before the plan
# table), so the non-vacuity of the hazard case is read from there: two slices, one probe each.
probe_slices="$(grep -cE '^    samen_core(-[0-9]+)? +range=9[0-9][0-9]-9[0-9][0-9] +1 patch\(es\)' <<<"$ack_out" || true)"
if [[ "$probe_slices" == "2" ]]; then
  ok "the two probes really were cut into two one-patch slices (the hazard case is non-vacuous)"
else
  echo "$ack_out" | grep -E 'range=' | head -4
  bad "the two probes were not split into separate one-patch slices (found $probe_slices) — the hazard case would be vacuous"
fi
rm -f "$PROBE_A" "$PROBE_B" "$PROBE_TEST" "$PROBE_SRC"

echo ""
echo "== 8. a caller --range is FOLDED into the chunk ranges, never forwarded over them =="
# sabotage.sh's last `--range` wins. A slice is launched with its own chunk `--range`, so
# forwarding the caller's as well would silently override the chunk: EVERY slice would replay the
# first patch of the caller's range while still reporting the count it was assigned — two
# same-app slices replaying one patch each, all counts matching, no coverage hole to catch it.
# (Seen live on 2026-10-12 before the fold: both slices replayed patch 197 in a --range 197-198
# run.) The plan prints each slice's exact arguments, so this is observable without running any.
fold_out="$(bash "$DRIVER" --range 197-198 --intra 2 --list 2>&1)"
cmds="$(printf '%s\n' "$fold_out" | sed -n 's/^        cmd: //p')"
if [[ -z "$cmds" ]]; then
  echo "$fold_out" | tail -5
  bad "the plan did not print the per-slice command lines (cannot see what a slice is handed)"
else
  ok "the plan prints each slice's exact arguments"
fi
if [[ "$(printf '%s\n' "$cmds" | wc -l | tr -d ' ')" == "2" ]] \
   && printf '%s\n' "$cmds" | grep -q -- '--range 197-197' \
   && printf '%s\n' "$cmds" | grep -q -- '--range 198-198'; then
  ok "the two probes' slices are handed their OWN chunk ranges (197-197 and 198-198)"
else
  printf '%s\n' "$cmds" | head -3
  bad "the slices were not handed distinct chunk ranges"
fi
if printf '%s\n' "$cmds" | grep -q -- '--range 197-198'; then
  bad "a slice is still handed the CALLER's --range 197-198, which overrides its chunk (last one wins)"
else
  ok "no slice is handed the caller's --range (it is folded into the chunks instead)"
fi
if grep -q 'FOLDED into each slice' <<<"$fold_out"; then
  ok "the fold is disclosed in the run's own output"
else
  bad "the report does not disclose that the caller's range was folded into the chunk ranges"
fi

# Sampled exactness: the chunk range a slice is handed really selects exactly that chunk (the
# post-run membership check catches this too, but this is the pre-flight half of the proof).
# Read the chunk range from a slice's OWN cmd line (never from the FILTERED banner's `range=`,
# which is the caller's) and pair it with the patch count the plan assigned that slice.
sample_range="$(printf '%s\n' "$cmds" | tail -1 | grep -oE -- '--range [0-9]+-[0-9]+' | awk '{print $2}')"
sample_count="$(printf '%s\n' "$fold_out" | grep -E "range=${sample_range} +[0-9]+ patch" | grep -oE '[0-9]+ patch\(es\)' | awk '{print $1}' | head -1)"
if [[ -n "$sample_range" && -n "$sample_count" ]]; then
  relisted="$(bash "$SABOTAGE" --app samen_core --range "$sample_range" --list 2>&1)"
  got="$(sed -n 's/^SABOTAGE SELECTION: \([0-9][0-9]*\) of .*/\1/p' <<<"$relisted" | tail -1)"
  if [[ "$got" == "$sample_count" ]]; then
    ok "re-listing a slice's own chunk range (--app samen_core --range $sample_range) selects exactly its $got assigned patch(es)"
  else
    echo "$relisted" | tail -3
    bad "--app samen_core --range $sample_range selected ${got:-?} patch(es), but the plan assigned $sample_count"
  fi
else
  bad "could not sample a chunk range from the plan (got '$sample_range' → '$sample_count')"
fi

echo ""
echo "== 9. the seed's safety property: cache reuse must be DIGEST-based, never mtime-based =="
# The driver warm-starts a new slice by copying a sibling slice's build cache. Two things have to
# hold for that to be both worthwhile and safe, and both are measurable on a scratch project whose
# whole compile cycle costs seconds. It MIRRORS the real layout: the app's own sources live in a
# per-slice tree (so a copy of them is a different path), while its dependencies live in ONE shared
# directory every slice points at (PATH dep here, `MIX_DEPS_PATH` in the driver), and the build
# path is copied.
#
#   (a) THE SAVING IS REAL: the copied build path lets the DEPENDENCY tree be reused (deps are the
#       bulk of a cold slice: measured on this box, samen_core's `mix compile` is 4m30 in a fresh
#       tree and 2m05 with a seeded cache, and the ~3m47 `mix deps.compile` is what disappears).
#       Asserted by byte-identity: the dep's .beam files must not be rewritten at all.
#   (b) IT CANNOT HIDE A PATCH: Elixir's manifest records a DIGEST of each source beside its mtime,
#       so within a project an mtime-only touch recompiles nothing while a content change
#       recompiles exactly the changed module — which is what recompiles a patch's source in the
#       slice. If an Elixir ever made staleness mtime-only, this fails HERE instead of quietly
#       letting a patch's suite run against the wrong module.
SEEDPROJ="$WORK/seedproj"
mkdir -p "$SEEDPROJ/app/lib" "$SEEDPROJ/seed_dep/lib"
cat > "$SEEDPROJ/app/mix.exs" <<'EOF'
defmodule SeedProbe.MixProject do
  use Mix.Project

  def project,
    do: [app: :seed_probe, version: "0.1.0", elixir: "~> 1.18", deps: [{:seed_dep, path: "../seed_dep"}]]

  def application, do: [extra_applications: []]
end
EOF
cat > "$SEEDPROJ/seed_dep/mix.exs" <<'EOF'
defmodule SeedDep.MixProject do
  use Mix.Project

  def project, do: [app: :seed_dep, version: "0.1.0", elixir: "~> 1.18", deps: []]
  def application, do: [extra_applications: []]
end
EOF
cat > "$SEEDPROJ/seed_dep/lib/seed_dep.ex" <<'EOF'
defmodule SeedDep do
  def hello, do: :dep
end
EOF
cat > "$SEEDPROJ/app/lib/seed_probe.ex" <<'EOF'
defmodule SeedProbe do
  def hello, do: SeedDep.hello()
end
EOF
cat > "$SEEDPROJ/app/lib/seed_probe_second.ex" <<'EOF'
defmodule SeedProbe.Second do
  def hello, do: SeedProbe.hello()
end
EOF
seed_dep_beams() { # a stable fingerprint of the DEPENDENCY's compiled output
  ( cd "$1/lib/seed_dep/ebin" 2>/dev/null && ls -l --time-style=+%s 2>/dev/null | awk '{print $6, $7}' | sort ) 2>/dev/null
}

seedproj_compile() { # seedproj_compile <dir> <build> → "<exit status>|<compile lines>"
  local out status
  out="$(cd "$1" && MIX_BUILD_PATH="$2" mix compile 2>&1)"
  status=$?
  printf '%s|%s' "$status" "$(printf '%s\n' "$out" | grep -c 'Compiling' || true)"
}

first="$(seedproj_compile "$SEEDPROJ/app" "$SEEDPROJ/build")"
[[ "${first%%|*}" == "0" && "${first##*|}" != "0" ]] \
  || bad "the scratch project's first compile did not compile anything ('$first') — the probe would be vacuous"
again="$(seedproj_compile "$SEEDPROJ/app" "$SEEDPROJ/build")"
if [[ "${again%%|*}" == "0" && "${again##*|}" == "0" ]]; then
  ok "a warm cache with unchanged sources recompiles nothing — the seed is actually usable"
else
  bad "the warm cache was not reused ('$again') — seeding could save nothing"
fi

touch "$SEEDPROJ/app/lib/seed_probe.ex"
touched="$(seedproj_compile "$SEEDPROJ/app" "$SEEDPROJ/build")"
if [[ "${touched%%|*}" == "0" && "${touched##*|}" == "0" ]]; then
  ok "an MTIME-ONLY touch recompiles nothing — staleness is decided by the source DIGEST, not the clock"
else
  bad "an mtime-only touch triggered a recompile ('$touched') — the cache would be useless after every checkout"
fi

printf '\n# content change\n' >> "$SEEDPROJ/app/lib/seed_probe.ex"
changed="$(seedproj_compile "$SEEDPROJ/app" "$SEEDPROJ/build")"
if [[ "${changed%%|*}" == "0" && "${changed##*|}" == "1" ]]; then
  ok "a one-line CONTENT change recompiles exactly that one module — a patched source can NEVER be served from the seed"
else
  bad "a content change produced '$changed' (status|compile-lines) instead of exactly 1 recompiled module — the seed could hide a patch"
fi

# The fresh-checkout case the driver actually seeds into: a copy of the app's sources (a different
# path, like a new slice tree) with a copy of the build cache, while the dependency stays where it
# was (like the shared deps dir).
cp -a "$SEEDPROJ/app" "$SEEDPROJ/fresh"
cp -a "$SEEDPROJ/build" "$SEEDPROJ/freshbuild"
dep_before="$(seed_dep_beams "$SEEDPROJ/freshbuild")"
fresh="$(seedproj_compile "$SEEDPROJ/fresh" "$SEEDPROJ/freshbuild")"
dep_after="$(seed_dep_beams "$SEEDPROJ/freshbuild")"
if [[ -n "$dep_before" && "$dep_before" == "$dep_after" ]]; then
  ok "a seeded cache in a fresh source copy reuses the DEPENDENCY tree byte-for-byte (the ~3m47s saving, on this box's samen_core)"
else
  bad "the seeded cache recompiled the dependency tree (before/after fingerprints differed) — the whole saving would be lost"
fi
if [[ "${fresh%%|*}" == "0" && -f "$SEEDPROJ/freshbuild/lib/seed_probe/ebin/seed_probe.app" ]]; then
  ok "...and the seeded build still ends USABLE (${fresh##*|} compile line(s)) — worst case a seed is slower, never stale"
else
  bad "a fresh source copy + seeded cache did not produce a usable build ('$fresh')"
fi

# The seed's OTHER half is the digest the manifest really stores: show it, so the property above
# is traceable to the artifact rather than to a timing coincidence.
manifest_entry="$(
  MANIFEST="$SEEDPROJ/freshbuild/lib/seed_probe/.mix/compile.elixir" elixir -e '
    path = System.get_env("MANIFEST")
    # The Elixir compiler manifest is a big tuple whose SECOND element is the modules map
    # (element 0 is the manifest version); read it by position, not by shape-matching the
    # whole tuple, so a future manifest version does not turn this into a MatchError.
    decoded = :erlang.binary_to_term(File.read!(path))
    vsn = elem(decoded, 0)
    modules = elem(decoded, 1)

    entries =
      cond do
        is_map(modules) -> Map.values(modules)
        is_list(modules) -> modules
        true -> []
      end

    entry =
      Enum.find(entries, fn v ->
        is_tuple(v) and Enum.any?(Tuple.to_list(v), &(is_binary(&1) and byte_size(&1) == 16))
      end)

    if entry == nil do
      IO.puts("no manifest entry carries a 16-byte source digest")
    else
      fields = Tuple.to_list(entry)
      digest = Enum.find(fields, &(is_binary(&1) and byte_size(&1) == 16))
      sources = Enum.find(fields, &is_list(&1)) || []
      IO.puts("manifest vsn #{vsn}: #{length(sources)} source(s), digest #{byte_size(digest)} bytes")
    end
  ' 2>&1 | tail -1
)"
if grep -qE '^manifest vsn [0-9]+: [0-9]+ source\(s\), digest 16 bytes$' <<<"$manifest_entry"; then
  ok "the compiler manifest really carries a source digest beside the mtime ($manifest_entry)"
else
  bad "could not read a digest out of the compiler manifest — the safety argument has no artifact behind it (got: '$manifest_entry')"
fi

echo ""
echo "== 9b. the manifest normaliser: a copied cache is reused across trees, and a patch still recompiles =="
# The property the driver's warm-start depends on, on a project that compiles in seconds. A cache
# is keyed to the tree that BUILT it (root + compile_env + the recorded timestamps), so a raw copy
# into another tree is distrusted and the whole app is rebuilt — that is the FIRST assertion here,
# and it is the refutable half: if it ever stops holding, the normaliser is no longer needed and
# the rest of this section would be pinning a no-op. The SECOND assertion is the fix (0 recompiles),
# the THIRD is the safety property that must survive it (a one-line content change still recompiles
# exactly that module), so a normaliser that papered over a real change fails here.
SEEDX="$WORK/seedx"
mkdir -p "$SEEDX/sliceA/tree/app/lib" "$SEEDX/sliceA/build"
cat > "$SEEDX/sliceA/tree/app/mix.exs" <<'EOF'
defmodule SeedX.MixProject do
  use Mix.Project

  def project, do: [app: :seed_x, version: "0.1.0", elixir: "~> 1.18", deps: []]
  def application, do: [extra_applications: []]
end
EOF
cat > "$SEEDX/sliceA/tree/app/lib/seed_x.ex" <<'EOF'
defmodule SeedX do
  def hello, do: :a
end
EOF
cat > "$SEEDX/sliceA/tree/app/lib/seed_x_second.ex" <<'EOF'
defmodule SeedX.Second do
  def hello, do: SeedX.hello()
end
EOF
# seedx_compile <slice> → "<status>|<compile line count>"
seedx_compile() { # seedx_compile <slice>
  local out status
  out="$(cd "$SEEDX/$1/tree/app" && MIX_BUILD_PATH="$SEEDX/$1/build" mix compile 2>&1)"
  status=$?
  printf '%s|%s' "$status" "$(printf '%s\n' "$out" | grep -c 'Compiling' || true)"
}

seed_a="$(seedx_compile sliceA)"
[[ "${seed_a%%|*}" == "0" && "${seed_a##*|}" != "0" ]] \
  || bad "the normaliser probe's first compile compiled nothing ('$seed_a') — the probe would be vacuous"

# The raw copy: sources + cache into a SECOND tree with no normalisation.
mkdir -p "$SEEDX/sliceB/tree" "$SEEDX/sliceC/tree"
cp -a "$SEEDX/sliceA/tree/app" "$SEEDX/sliceB/tree/app"
cp -a "$SEEDX/sliceA/build" "$SEEDX/sliceB/build"
raw="$(seedx_compile sliceB)"
if [[ "${raw%%|*}" == "0" && "${raw##*|}" != "0" ]]; then
  ok "an un-normalised cache in a fresh tree recompiles the app (${raw##*|} Compiling line(s)) — the copy really is keyed to the tree that built it"
else
  bad "an un-normalised seeded cache was reused ('$raw') — this section's normaliser assertions would be pinning a no-op, so the probe is stale"
fi

# The normalised copy: same sources, same cache, manifest repointed to the new slice id.
mkdir -p "$SEEDX/sliceC/tree"
cp -a "$SEEDX/sliceA/tree/app" "$SEEDX/sliceC/tree/app"
cp -a "$SEEDX/sliceA/build" "$SEEDX/sliceC/build"
norm="$(elixir "$REPO_ROOT/scripts/sabotage_seed_manifest.exs" \
  "$SEEDX/sliceC/build/lib/seed_x/.mix/compile.elixir" sliceA sliceC seed_x_test 2>&1)"; norm_status=$?
if [[ $norm_status -eq 0 ]] && grep -q 'seed-manifest: ok' <<<"$norm"; then
  ok "the normaliser accepts a cache copied from sliceA into sliceC ($(grep 'seed-manifest: ok' <<<"$norm"))"
else
  echo "$norm" | tail -3
  bad "the normaliser refused a straightforward seed (exit $norm_status)"
fi
normalised="$(seedx_compile sliceC)"
if [[ "${normalised%%|*}" == "0" && "${normalised##*|}" == "0" ]]; then
  ok "a NORMALISED cache in a fresh tree recompiles nothing — the seed now reuses the app, not just the deps"
else
  bad "a normalised seeded cache still recompiled ($normalised) — the normaliser is not doing its job"
fi

# A COMMENT-ONLY edit: it changes the file's bytes (so the digest moves) without changing what the
# module means, exactly the way a sabotage patch's touched source changes the digest. One `Compiling`
# LINE is what a single recompiled module produces.
printf '\n# seed normaliser probe\n' >> "$SEEDX/sliceC/tree/app/lib/seed_x.ex"
patched="$(seedx_compile sliceC)"
if [[ "${patched%%|*}" == "0" && "${patched##*|}" == "1" ]]; then
  ok "...and a one-line CONTENT change still recompiles exactly that module: the normaliser never hides a patch"
else
  bad "after normalisation a content change produced '$patched' (status|compile-lines) instead of exactly 1 — the seed could hide a patch"
fi

# The normaliser must REFUSE rather than half-apply: a wrong source stem, a non-manifest, and a
# manifest whose recorded root has no slice-id `tree` component.
bad_stem="$(elixir "$REPO_ROOT/scripts/sabotage_seed_manifest.exs" \
  "$SEEDX/sliceC/build/lib/seed_x/.mix/compile.elixir" sliceZ sliceC seed_x_test 2>&1)"; bad_stem_status=$?
if [[ $bad_stem_status -ne 0 ]]; then
  ok "the normaliser REFUSES a manifest whose recorded slice stem is not the candidate it came from (exit $bad_stem_status)"
else
  bad "the normaliser rewrote a manifest that was not the candidate's (exit 0) — it would repoint an unknown cache"
fi
printf 'not a manifest\n' > "$WORK/seedx/garbage.bin"
if ! elixir "$REPO_ROOT/scripts/sabotage_seed_manifest.exs" "$WORK/seedx/garbage.bin" sliceA sliceC seed_x_test >/dev/null 2>&1; then
  ok "the normaliser REFUSES a file it cannot read as a manifest"
else
  bad "the normaliser accepted a non-manifest file"
fi

# The RewriteSeam ITSELF: the DB the driver assigns its slice must land in compile_env, and a
# NON-sandbox repo beside it must be left alone (samen_core's multinode repo is exactly that case).
# Fabricated rather than compiled, so this costs nothing and pins the field rather than a timing.
cat > "$WORK/seedx/fab.exs" <<'EOF'
repo = [username: "postgres", database: "demo_test_sab1", pool: Ecto.Adapters.SQL.Sandbox]
multi = [database: "demo_multinode", pool: DBConnection.ConnectionPool]
env = %{local: [], config: %{demo: [Demo.Repo, repo, Demo.MultiNode.Repo, multi]}, lock: [], infer_signatures: [], dbg: nil}
term = {35, %{}, %{}, %{}, [], {[], ["lib"], false, false},
        "c:/x/.sabotage-parallel/demo/tree/demo", env, 111, 222, {%{}, %{}}}
File.write!(System.get_env("FAB"), :erlang.term_to_binary(term))
EOF
FAB="$WORK/seedx/fab.bin" elixir "$WORK/seedx/fab.exs" >/dev/null 2>&1 \
  && elixir "$REPO_ROOT/scripts/sabotage_seed_manifest.exs" "$WORK/seedx/fab.bin" demo demo-2 demo_test_sab2 >/dev/null 2>&1
cat > "$WORK/seedx/fabcheck.exs" <<'EOF'
d = :erlang.binary_to_term(File.read!(System.get_env("FAB")))
IO.puts(elem(d, 6))
IO.puts(elem(d, 8) > 111 and elem(d, 9) > 222)
Enum.each(Map.get(elem(d, 7), :config)[:demo], fn
  t when is_list(t) ->
    if Keyword.keyword?(t), do: IO.puts("#{inspect(Keyword.get(t, :pool))}=#{Keyword.get(t, :database)}")
  _ -> :ok
end)
EOF
fab_out="$(FAB="$WORK/seedx/fab.bin" elixir "$WORK/seedx/fabcheck.exs" 2>&1)"
if grep -qx 'c:/x/.sabotage-parallel/demo-2/tree/demo' <<<"$fab_out" \
   && grep -qx 'true' <<<"$fab_out" \
   && grep -qx 'Ecto.Adapters.SQL.Sandbox=demo_test_sab2' <<<"$fab_out" \
   && grep -qx 'DBConnection.ConnectionPool=demo_multinode' <<<"$fab_out"; then
  ok "the normaliser repoints the root, moves ONLY the sandbox repo's database, and refreshes the recorded timestamps"
else
  echo "$fab_out"
  bad "the normaliser did not rewrite exactly the sandbox Repo's database / the root / the timestamps"
fi

# A REAL manifest carries STRUCTS, and a struct is a map that is NOT an Enumerable. Measured
# 2026-10-13 on samen_core's own manifest: `Map.new/2` in the map branch raised
# Protocol.UndefinedError on the `Mix.Task.Compiler.Diagnostic` structs Mix records, the crash
# surfaced as a REFUSAL, and the seeded slice silently compiled from scratch while its sibling
# seeded fine. Nothing in the seed plan can show that — a refusal is a legal (merely slower)
# outcome, and the label still reads as a successful seed. So the traversal's totality over a real
# manifest is pinned HERE, on a fabricated one, where it costs nothing: this fails loudly if the
# struct clause is ever dropped again.
cat > "$WORK/seedx/structman.exs" <<'EOF'
repo = [username: "postgres", database: "demo_test_sab1", pool: Ecto.Adapters.SQL.Sandbox]
diag = struct(Mix.Task.Compiler.Diagnostic,
         file: "lib/demo.ex", source: "lib/demo.ex", severity: :warning,
         message: "the following conditional expression will always evaluate to dynamic(false)",
         position: 12, compiler_name: "Elixir", span: nil, details: %{typing_traces: []})
env = %{local: [], config: %{demo: [Demo.Repo, repo]}, lock: [], infer_signatures: [], dbg: nil}
term = {35, %{}, %{}, %{}, [], {[], ["lib"], false, false},
        "c:/x/.sabotage-parallel/demo/tree/demo", env, 111, 222, {[diag], %{}}}
File.write!(System.get_env("FAB"), :erlang.term_to_binary(term))
EOF
FAB="$WORK/seedx/struct.bin" elixir "$WORK/seedx/structman.exs" >/dev/null 2>&1 \
  && struct_out="$(elixir "$REPO_ROOT/scripts/sabotage_seed_manifest.exs" "$WORK/seedx/struct.bin" demo demo-2 demo_test_sab2 2>&1)"
struct_status=$?
if [[ $struct_status -eq 0 ]] && grep -qx 'seed-manifest: ok 1 1' <<<"$struct_out"; then
  ok "a manifest carrying compiler-diagnostic STRUCTS normalises (ok 1 1) rather than refusing"
else
  echo "$struct_out" | tail -3
  bad "the normaliser refused a struct-bearing manifest (exit $struct_status) — a real manifest records Mix.Task.Compiler.Diagnostic, so the seeded slice would silently compile from scratch"
fi

echo ""
echo "== 10. the seed plan names a warm source, and refuses a BUSY sibling =="
# The plumbing, without compiling anything: a scratch root carrying a fabricated sibling cache.
SCRATCH="$WORK/seedroot"
seed_cache() { # seed_cache <root> <stem> [<patches-replayed>] — fabricate a usable sibling cache
  local root="$1" stem="$2" n="${3:-}"
  mkdir -p "$root/$stem/build/samen_core/lib/samen_core/.mix" "$root/$stem/build/samen_core/lib/samen_core/ebin"
  : > "$root/$stem/build/samen_core/lib/samen_core/.mix/compile.elixir"
  [[ -n "$n" ]] && printf '%s\n' "$n" > "$root/$stem/replayed-patches"
  return 0
}
# `plan <root>` — the seed-plan lines of a run whose only candidate roots live under <root>.
plan() { SAMEN_SABOTAGE_PARALLEL_ROOT="$1" bash "$DRIVER" --range 197-198 --intra 2 --list 2>&1; }
seed_cache "$SCRATCH" samen_core
seed_out="$(plan "$SCRATCH")"
if grep -qE '^  SEED PLAN: 1 new slice\(s\) start from a sibling slice' <<<"$seed_out" \
   && grep -qE '^    samen_core-2 +<- samen_core/build/samen_core +\[pristine\]$' <<<"$seed_out"; then
  ok "a new slice is offered the sibling's cache as its warm start, labelled pristine"
else
  echo "$seed_out" | grep -E 'SEED PLAN|<-|nothing to seed' | head -4
  bad "the seed plan did not offer the sibling cache to the new slice (as pristine)"
fi
if grep -qE '^    samen_core +range=' <<<"$seed_out"; then
  ok "the slice that already has a cache is left alone (only the new one is seeded)"
else
  bad "the plan did not include the already-warm slice"
fi

# PRISTINE FIRST, and the ranking under it. `replayed-patches` is the file the driver appends to
# before each launch; its NUMBER is what the ranking reads. Three cases, each on its OWN root so the
# candidate set is exactly the two roots named (a stray root from another case would silently
# weaken the assertion). The recency lever is a manifest mtime — a stamp far in the past is what
# makes case 1 decisive, since a NEWER manifest is otherwise preferred.
RANK="$WORK/seedsrank"

# (1) pristine beats patched, even though the patched candidate's manifest is NEWER.
rm -rf "$RANK"; mkdir -p "$RANK"
seed_cache "$RANK" samen_core-9 3
seed_cache "$RANK" samen_core

touch -d '2020-01-01' "$RANK/samen_core/build/samen_core/lib/samen_core/.mix/compile.elixir"
case1="$(plan "$RANK")"
if grep -qE '^    samen_core-2 +<- samen_core/build/samen_core +\[pristine\]$' <<<"$case1"; then
  ok "a PRISTINE sibling is chosen over a patched one whose manifest is newer"
else
  echo "$case1" | grep -E '<-' | head -3
  bad "pristineness did not outrank manifest recency"
fi

# (2) no pristine sibling → the FEWEST patches wins (5 over 7), again against the newer manifest.
rm -rf "$RANK"; mkdir -p "$RANK"
seed_cache "$RANK" samen_core-7 5
seed_cache "$RANK" samen_core-8 7

touch -d '2020-01-01' "$RANK/samen_core-7/build/samen_core/lib/samen_core/.mix/compile.elixir"
case2="$(plan "$RANK")"
if grep -qE '^    samen_core-2 +<- samen_core-7/build/samen_core +\[patched\(5\)\]$' <<<"$case2"; then
  ok "with no pristine sibling the fewest-replayed source is chosen (patched(5) over patched(7))"
else
  echo "$case2" | grep -E '<-' | head -3
  bad "the ranking did not prefer the fewest-replayed source"
fi

# (3) equal counts → the NEWEST manifest wins, the rule that predates the ranking.
rm -rf "$RANK"; mkdir -p "$RANK"
seed_cache "$RANK" samen_core-7 5
seed_cache "$RANK" samen_core-8 5

touch -d '2020-01-01' "$RANK/samen_core-7/build/samen_core/lib/samen_core/.mix/compile.elixir"
case3="$(plan "$RANK")"
if grep -qE '^    samen_core-2 +<- samen_core-8/build/samen_core +\[patched\(5\)\]$' <<<"$case3"; then
  ok "at equal patch counts the newest manifest still wins"
else
  echo "$case3" | grep -E '<-' | head -3
  bad "at equal counts the ranking did not fall back to the newest manifest"
fi

mkdir -p "$SCRATCH/samen_core/lock"
busy_out="$(SAMEN_SABOTAGE_PARALLEL_ROOT="$SCRATCH" bash "$DRIVER" --range 197-198 --intra 2 --list 2>&1)"
if grep -q 'nothing to seed' <<<"$busy_out"; then
  ok "a sibling that is IN USE (its per-slice lock exists) is never copied out from under a writer"
else
  echo "$busy_out" | grep -E 'SEED PLAN|<-' | head -4
  bad "the seed plan offered a cache whose slice is running (a torn copy would be seeded)"
fi
rmdir "$SCRATCH/samen_core/lock"

noseed_out="$(SAMEN_SABOTAGE_PARALLEL_ROOT="$SCRATCH" bash "$DRIVER" --range 197-198 --intra 2 --no-seed --list 2>&1)"
if grep -q 'SEED PLAN: disabled (--no-seed)' <<<"$noseed_out"; then
  ok "--no-seed reports itself as disabled (each new slice compiles from scratch)"
else
  bad "--no-seed was not honoured/reported"
fi

# THE COLD-COMPILE BUDGET. A wide COLD start is the one load that kills a sweep on a small box
# (measured 2026-10-13: four cold slices at --jobs 4 died of MSYS fork exhaustion, the same fleet with
# two cold completed, and four cold compiles WITHOUT the driver all succeeded), so the plan has to say
# how many slices will pay the one-time compile, what width the run starts at, and the ceiling it may
# climb to. Four refutable properties, all on a fabricated root — nothing is compiled and no patch is
# applied:
#   * a fleet with no cache anywhere reports its cold count and the width policy it will honour;
#   * the START width follows SAMEN_SABOTAGE_PARALLEL_COLD_LIMIT — the pool lowering itself for that
#     phase — and the CEILING follows SAMEN_SABOTAGE_PARALLEL_COLD_MAX;
#   * ADAPT_SECS=0 reports a PINNED width, a DIFFERENT statement from a moving one: a plan line saying
#     "at most N" while the width is free to rise to M is a number nobody can act on;
#   * a slice the SEED plan is about to warm is NOT counted cold. If it were, the budget would shrink
#     the width for a phase that no longer exists, which is the regression that would quietly undo
#     the seeding's whole purpose.
COLDROOT="$WORK/coldroot"; mkdir -p "$COLDROOT"
# coldplan <root> [<VAR=VAL>...] — the plan for a fully cold fleet, with the adaptive knobs set
# EXPLICITLY so every assertion is about the driver and not about this host's default --jobs.
coldplan() { local root="$1"; shift; env "$@" SAMEN_SABOTAGE_PARALLEL_ROOT="$root" bash "$DRIVER" --range 197-198 --intra 2 --list 2>&1; }
cold_out="$(coldplan "$COLDROOT")"
if grep -qE '^  COLD-COMPILE BUDGET: 2 slice\(s\) start with NO build cache' <<<"$cold_out" \
   && grep -qE 'the width STARTS at [0-9]+ and|the adaptive width is PINNED' <<<"$cold_out"; then
  ok "a fleet with no cache anywhere reports its cold count and the width policy it will honour"
else
  echo "$cold_out" | grep -E 'COLD-COMPILE|STARTS|PINNED' | head -3
  bad "the plan did not report the cold-compile budget for a fully cold fleet"
fi
adapt_out="$(coldplan "$COLDROOT" SAMEN_SABOTAGE_PARALLEL_COLD_MAX=4)"
if grep -qE 'the width STARTS at 2 and' <<<"$adapt_out" && grep -qE 'ADAPTS up to 4' <<<"$adapt_out"; then
  ok "the width STARTS at the configured cap and may ADAPT up to SAMEN_SABOTAGE_PARALLEL_COLD_MAX"
else
  echo "$adapt_out" | grep -E 'COLD-COMPILE|STARTS|ADAPTS' | head -3
  bad "the plan did not report an adaptive width for a cold fleet with headroom above the cap"
fi
cold1_out="$(coldplan "$COLDROOT" SAMEN_SABOTAGE_PARALLEL_COLD_LIMIT=1 SAMEN_SABOTAGE_PARALLEL_COLD_MAX=4)"
if grep -qE 'the width STARTS at 1 and' <<<"$cold1_out" && grep -qE 'ADAPTS up to 4' <<<"$cold1_out"; then
  ok "the START width follows SAMEN_SABOTAGE_PARALLEL_COLD_LIMIT — the pool lowers itself for that phase"
else
  echo "$cold1_out" | grep -E 'COLD-COMPILE|STARTS|ADAPTS' | head -3
  bad "the adaptive start width ignored SAMEN_SABOTAGE_PARALLEL_COLD_LIMIT"
fi
max_out="$(coldplan "$COLDROOT" SAMEN_SABOTAGE_PARALLEL_COLD_MAX=3)"
if grep -qE 'ADAPTS up to 3' <<<"$max_out"; then
  ok "the CEILING follows SAMEN_SABOTAGE_PARALLEL_COLD_MAX"
else
  echo "$max_out" | grep -E 'COLD-COMPILE|ADAPTS' | head -3
  bad "the adaptive ceiling ignored SAMEN_SABOTAGE_PARALLEL_COLD_MAX"
fi
pin_out="$(coldplan "$COLDROOT" SAMEN_SABOTAGE_PARALLEL_COLD_MAX=4 SAMEN_SABOTAGE_PARALLEL_ADAPT_SECS=0)"
if grep -qE 'the adaptive width is PINNED' <<<"$pin_out"; then
  ok "SAMEN_SABOTAGE_PARALLEL_ADAPT_SECS=0 reports a PINNED width, not a moving one"
else
  echo "$pin_out" | grep -E 'COLD-COMPILE|STARTS|PINNED' | head -3
  bad "the plan still promised a moving width with adaptation disabled"
fi
warm_out="$(plan "$SCRATCH")"
if ! grep -q 'COLD-COMPILE' <<<"$warm_out" && grep -qE 'samen_core-2 +<- samen_core/build/samen_core' <<<"$warm_out"; then
  ok "a slice the SEED plan is about to warm is NOT counted cold (the budget cannot shrink for a gone phase)"
else
  echo "$warm_out" | grep -E 'SEED PLAN|COLD-COMPILE|<-' | head -4
  bad "the cold-compile budget counted a slice the seed plan is about to warm"
fi

echo ""
echo "== 11. the adaptive cold width: the CONTROLLER is driven, and the gate can FAIL =="
# The plan above says what the width WILL do; this decides it. The controller is proven on scripted
# scenarios rather than on a loaded box (which cannot be summoned on demand) — and that proof is only
# worth anything if it can fail, so a MUTATED copy of the driver must turn the very same gate RED.
# The copy lives INSIDE the repo on purpose: the driver derives its scratch root from its own
# location and refuses an un-ignored in-repo root, so a copy under $WORK would fail for the wrong
# reason and the negative control would prove nothing at all.
selftest_out="$(bash "$DRIVER" --adapt-selftest 2>&1)"; status=$?
selftest_passes="$(grep -c '^ADAPT-SELFTEST: PASS' <<<"$selftest_out")"
selftest_total="$(sed -n 's/^ADAPT-SELFTEST: ok \([0-9]*\)\/\([0-9]*\)$/\2/p' <<<"$selftest_out")"
# The scenario COUNT is asserted too: deleting a scenario is the cheapest way to make a gate pass.
if [[ $status -eq 0 && -n "$selftest_total" && "$selftest_total" -ge 7 \
      && "$selftest_passes" == "$selftest_total" && -z "$(grep '^ADAPT-SELFTEST: FAIL' <<<"$selftest_out")" ]]; then
  ok "the width controller passes all $selftest_total scripted scenario(s) (exit 0)"
else
  echo "$selftest_out" | grep -E 'ADAPT-SELFTEST' | tail -5
  bad "the adaptive-width controller gate failed (exit $status, $selftest_passes/$selftest_total scenarios)"
fi
sed 's/^    COLD_LIMIT=$(( COLD_LIMIT + 1 ))$/    : # refutability twin — the rise removed/' \
  "$DRIVER" > "$ADAPT_PROBE"
if ! grep -q 'refutability twin — the rise removed' "$ADAPT_PROBE"; then
  bad "the refutability twin could not be built (the rise line moved — re-anchor this sed)"
else
  twin_out="$(bash "$ADAPT_PROBE" --adapt-selftest 2>&1)"; twin_status=$?
  if [[ $twin_status -ne 0 ]] && grep -q '^ADAPT-SELFTEST: FAIL' <<<"$twin_out"; then
    ok "NEGATIVE CONTROL: a driver whose width can no longer RISE fails the controller gate (exit $twin_status)"
  else
    echo "$twin_out" | tail -4
    bad "the controller gate PASSED a driver whose width can no longer rise — the gate is a tautology"
  fi
fi
rm -f "$ADAPT_PROBE"

echo ""
echo "== 12. the scratch root must be git-ignored while it sits inside the repo =="
if git -C "$REPO_ROOT" check-ignore -q "$REPO_ROOT/.sabotage-parallel/logs" 2>/dev/null; then
  ok "the driver's default scratch root is git-ignored (.gitignore)"
else
  bad "$REPO_ROOT/.sabotage-parallel is NOT git-ignored — the harness would copy every slice's build cache into every replay tree"
fi
notignored_out="$(SAMEN_SABOTAGE_PARALLEL_ROOT="$REPO_ROOT/.sabotage-intra-not-ignored-probe" bash "$DRIVER" --range 331-334 --list 2>&1)"; status=$?
if [[ $status -ne 0 ]] && grep -q 'NOT git-ignored' <<<"$notignored_out"; then
  ok "an in-repo, un-ignored scratch root is REFUSED up front (exit $status), with the fix named"
else
  echo "$notignored_out" | tail -4
  bad "the driver accepted an un-ignored in-repo scratch root (exit $status) — that run would hang copying build caches"
fi
if [[ -e "$REPO_ROOT/.sabotage-intra-not-ignored-probe" ]]; then
  bad "the refused root was created anyway"
else
  ok "the refused root was never created on disk"
fi

echo ""
echo "== 13. residue =="
if [[ -e "$PROBE_A" || -e "$PROBE_B" || -e "$PROBE_UNCHUNKABLE" || -e "$PROBE_DUP_APP" || -e "$PROBE_TEST" || -e "$PROBE_SRC" || -e "$ADAPT_PROBE" ]]; then
  bad "scratch residue left behind"
else
  ok "zero residue (probe patches, probe test file and probe source all removed)"
fi
if [[ -n "$(git -C "$REPO_ROOT" status --porcelain -- scripts/sabotages scripts/.sabotage-adapt-probe.sh samen_core/test/__probe samen_core/lib/samen/__sabotage_intra_probe.ex 2>/dev/null)" ]]; then
  git -C "$REPO_ROOT" status --porcelain -- scripts/sabotages samen_core/test/__probe 2>/dev/null | head -3
  bad "the probe paths are not clean in git status"
else
  ok "scripts/sabotages and the probe path are clean in git status"
fi

echo ""
echo "sabotage-intra harness: $pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]] || { echo "SABOTAGE INTRA HARNESS: FAILED"; exit 1; }
echo "SABOTAGE INTRA HARNESS: ALL PASSED"
