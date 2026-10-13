#!/usr/bin/env bash
# scripts/sabotage_parallel.sh — certify the sabotage harness in parallel: one isolated replay
# tree per SLICE, app-level and intra-app, each with its OWN test database, coverage asserted
# rather than assumed.
#
# ── WHY THIS EXISTS ──────────────────────────────────────────────────────────
# The full replay is serial because ONE replay tree + ONE lock + ONE per-app build cache are
# keyed to a single $SAMEN_SABOTAGE_ROOT. Nothing about the patches requires that: a patch runs
# `mix test` in its APP's directory, against that app's deps and that app's test DATABASE, so two
# patches with different APP headers never contend for anything but CPU. The root gate already
# leans on exactly this (`ci.sh` runs the samen_web/demo/driftwood/pawchart gates CONCURRENTLY —
# "own DBs, race-free"). The harness is the one place that still paid serially: measured
# 2026-10-12, 56 patches in 37 minutes (~1.5/min), i.e. ~3.5h for the 334-patch sweep.
#
# APP is therefore the first isolation boundary, and sabotage.sh ALREADY takes its replay root
# from `$SAMEN_SABOTAGE_ROOT` — so this driver hands each slice its own root (its own detached
# replay worktree, its own mix build cache, its own lock) and changes nothing about how a patch
# is applied, tested, judged or reverted.
#
# ── THE INTRA-APP SPLIT, AND THE DATABASE IT NEEDS ───────────────────────────
# App-level partitioning has a hard floor: the sweep can never finish faster than the LARGEST
# app's slice, and two apps are 89% of it (samen_core 173, samen_web 123) — so the app-only
# driver delivers "roughly the longest app's slice" (~2x), not the app count's (~8x).
#
# Going below that floor means running TWO slices OF THE SAME APP at once, and the reason that
# was impossible is the TEST DATABASE, not the patches: every DB-backed app's `test_helper.exs`
# (and `mix samen_web.test_setup`, via the `mix test` alias) does `storage_down` → `storage_up` →
# migrate against the app's ONE canonical test DB, so a second concurrent suite of the same app
# drops the schema out from under the first. Two same-app slices on one database is the thing the
# app boundary was preventing.
#
# So the split rests on a per-slice database: every DB-backed app's `config/test.exs` reads the
# name from `SAMEN_TEST_DB` (unset ⇒ the canonical name, byte-identical to before), and each slice
# here gets its own deterministic name — `<app>_test_sab<N>` — passed to the harness as
# `--test-db <name>`. Deterministic (not per-run-random) so repeat runs reuse a warm DB, and
# deliberately distinct from the canonical name so a driver run and a hand-run
# `scripts/sabotage.sh` cannot collide on one database either. They are NOT dropped at the end
# (that would throw away exactly the warmth that makes reruns cheap): the driver prints the exact
# reclaim command.
#
# The split is applied only where it PAYS. `--jobs <n>` is the pool width, the ideal slice size is
# `ceil(selected / jobs)`, and an app whose count exceeds it is chunked into
# `ceil(count / ideal)` contiguous `--range` chunks of near-equal size; the plan is adopted only
# when a list-scheduling estimate over the slice sizes says it beats the app-only partition. With
# `--jobs 1` nothing is split (there is no second slot to use) and with a saturated pool the
# estimate ties, so the default path never pays for a slice that cannot run concurrently.
# `--intra <k>` overrides: `--intra 1` reproduces the app-only partition exactly, `--intra 4`
# allows at most four slices per app.
#
# ── TWO GUARDS THE WIDER RUN NEEDS ───────────────────────────────────────────
# * CONNECTION BUDGET. Pool caps are per suite (samen_core/samen_web/demo 20, driftwood/pawchart/
#   samenerp 10), so N concurrent same-app slices can want N x that many connections. The plan's
#   peak (the `--jobs` largest slice pool caps) is compared against Postgres's `max_connections`;
#   when it does not fit, the driver says so with the arithmetic and — if `--jobs` was not pinned
#   by the caller — lowers the width to what fits. Parallelism you cannot connect is not
#   parallelism.
# * FIXED-RESOURCE AUDIT. A slice is isolated by tree, build cache, lock and database. It is NOT
#   isolated from a test file that reaches outside them — `createdb`/`psql` scratch databases,
#   pg_dump artifacts. Sharing a test FILE between slices is normal here (one suite is the named
#   test for several patches) and safe while it stays inside the slice's database; it stops being
#   safe the moment it does not. So the driver intersects (files targeted by patches in ≥2 slices
#   of one app) with (files containing a fixed-resource marker) and FAILS CLOSED, naming the file
#   and the slices, unless the caller acknowledges it with `--allow-shared-scratch`.
#
# ── COVERAGE IS ASSERTED, NOT ASSUMED ────────────────────────────────────────
# A partition that silently drops patches looks exactly like a green run, which is the
# under-selecting-verifier failure the `--changed` union was fixed for (patches 247/248/249).
# So this driver never reimplements selection: it asks the harness ITSELF for the selected set
# (`--list`), derives the slices from the harness's own `app=` records, and requires
# sum(slice counts) == the harness's selected count — before anything is applied. A patch whose
# filename has no numeric prefix cannot be chunked at all, so that is a hard failure too (it would
# otherwise fall outside every `--range`). And each slice's OWN verdict line is re-read after the
# run: the count the harness reports having replayed must equal the count this driver assigned it,
# so a wrong chunk boundary is caught by the slice's own output rather than by arithmetic alone.
#
# The malformed-header case is the reason the listing is parsed fail-closed: `meta APP` returns
# EVERY `# APP:` line, so a patch with a duplicated header resolves to two lines and matches no
# `--app` filter — it would vanish from a naive partition (the driver's own negative control seeds
# exactly that patch and expects this check to fail).
#
# ── WHAT IT DELIBERATELY DOES NOT DO ────────────────────────────────────────
# It does not alter `sabotage.sh`'s selection, judgment or revert logic, add flags to it beyond
# `--test-db` (which only sets the database the same suite already used), or touch `ci.sh`'s
# opt-in step, whose contract is "no flags ⇒ the full serial run, unchanged". It does not
# parallelize within a slice: a slice is a sequence, and two patches of one slice are still
# applied, tested and reverted strictly one after another.
#
# ── WARM-STARTING A NEW SLICE (--no-seed turns it off) ───────────────────────
# A slice with no build cache pays a full compile of its app AND its 42 deps in :test before its
# first patch can even run — the per-slice MIX_BUILD_PATH holds the dep beams too, not just the
# app's (42 `lib/<dep>` entries in a real slice root), so "cold" means deps AND app. Measured
# 2026-10-12 on this box: 3m47 `mix deps.compile` + 2m40 for the app, ~6m of samen_core — and an
# intra-app split multiplies that by the chunk count, which is the one cost the split adds back.
# A sibling slice of the SAME app at the SAME commit already holds those artifacts, so a new
# slice is seeded from one: copied before anything is launched, and only from a sibling whose
# per-slice lock is free (i.e. which nothing is writing).
#
# WHAT THE COPY NEEDS TO BE WORTH ANYTHING: a copied cache is INVALID in a new tree until its
# compiler manifest is repointed. Elixir's `.mix/compile.elixir` records four things keyed to WHERE
# it was built, and a mismatch in any of them makes it distrust the whole manifest and recompile
# everything — measured on samen_core, a sibling's cache in a fresh tree recompiled ALL 777 app
# files (~1m20–1m48) even though every source DIGEST matched byte-for-byte:
#   * elem 6, the project root (differs per slice BY DESIGN),
#   * the Repo `database:` inside `compile_env`, which config/test.exs takes from SAMEN_TEST_DB
#     — i.e. OUR per-slice test-DB seam leaking into compile-time config,
#   * elems 8/9, the timestamps the manifest was written with (older than a fresh tree's files).
# `scripts/sabotage_seed_manifest.exs` rewrites exactly those three to the seeded slice's values --
# the root and the timestamps are read out of the manifest, the DB is the one THIS driver assigns
# the slice -- and the copy then reuses the app too: measured 777 files/1m20 → 0 files/2.8s, and
# elems 6+7 alone (without the timestamps) already took 777 → 151. So a seeded slice now skips the
# deps compile AND the app compile. The rewrite is refused loudly if the manifest is not the shape
# this helper knows, and a refusal just means the slice compiles from scratch.
#
# The seed still cannot hide a patch, and that is measured rather than assumed: Elixir decides
# per-module staleness from the recorded source DIGEST, which the rewrite does not touch, so a
# patched source still differs from the manifest and still recompiles — verified end to end: after
# normalising, an unmodified tree recompiled 0 files while a ONE-LINE content change recompiled
# exactly that module and its dependents (2 files). `scripts/sabotage_intra_test.sh` pins both
# halves on a scratch project, so an Elixir that stopped comparing digests — or a normaliser that
# papered over one — fails a gate instead of quietly weakening a certification.
#
# PRISTINE SOURCES ARE NOW WORTH PICKING. Because the app is reused rather than rebuilt, the modules
# a sibling's earlier patches left compiled-from-patched-source are exactly what the seeded slice
# has to redo. So `seed_candidate` ranks siblings by HOW MANY PATCHES THEY HAVE REPLAYED (0 =
# pristine, recorded in a `replayed-patches` file at the slice root, written before each launch), and
# falls back to the newest manifest among equals. That ordering is exact at 0 and roughly monotone
# above it (patches differ in how much code they touch).
#
# Cost/benefit, measured — and reported as measured, because the headline is easy to overstate. A
# cold slice pays ~3m47 of `mix deps.compile` plus ~1m20–2m40 of app compile; the seed now removes
# essentially all of both (0 files, 2.8s, on the same box and cache). The cache is 187 MB and copies
# in 18s when nothing else runs; inside a real pooled run the same copy took 91s, competing with two
# slices compiling and testing. It does NOT map 1:1 onto makespan: the new slice's compile runs
# BESIDE its sibling's suite, so in a warm pool it largely hides under the slower slice (two
# back-to-back `--range 197-198 --intra 2` runs, seeded vs --no-seed, differed by ~5% — within this
# box's timing spread, a 5x range on the copy alone). The seed's clear win is a COLD fleet: several
# slices starting with no cache at once, each now skipping the deps AND the app compile.
# Slices that appear for the first time with no sibling cache yet still compile (nothing to seed
# from); after one run every slice root holds a cache, so later runs seed from them.
#
# ── USAGE ────────────────────────────────────────────────────────────────────
#   sabotage_parallel.sh [--jobs <n>] [--intra <k>] [--allow-shared-scratch]
#                       [<filters passed through to sabotage.sh>]
#
#     --jobs <n>          run at most <n> slices at once (default: every app at once on POSIX;
#                         2 on MINGW/MSYS, where a wider launch exhausted this box's fork
#                         capacity). The width drives the ideal slice size, so it also decides
#                         how far the intra-app split goes.
#     --intra <k>         at most <k> slices per app (default: derived from --jobs; 1 = the
#                         app-only partition, byte-for-byte the pre-intra-app behaviour).
#     --allow-shared-scratch
#                         acknowledge the fixed-resource audit's finding (a test file with
#                         `createdb`/`psql`/`pg_dump` markers would run in ≥2 slices). Without
#                         it the driver refuses to launch: an unattended sweep must not gamble
#                         two suites on one scratch database.
#     (env) SAMEN_SABOTAGE_PARALLEL_COLD_LIMIT
#                         how many slices that must COLD-compile may start at once (default 2; 0
#                         disables the cap). A wide cold start exhausts the MSYS fork path on a
#                         small box, so the pool lowers itself for that phase only; the plan
#                         prints how many slices are cold and the cap that will be honoured. This is
#                         the width the run STARTS at — it adapts from here (see the three below).
#     (env) SAMEN_SABOTAGE_PARALLEL_COLD_MAX
#                         the ceiling the adaptive width may climb to (default: --jobs). The width
#                         rises one step at a time, and only while the box shows no fork pressure.
#     (env) SAMEN_SABOTAGE_PARALLEL_ADAPT_SECS
#                         seconds per adaptation epoch (default 60; 0 PINS the width).
#     (env) SAMEN_SABOTAGE_PARALLEL_ADAPT_ROUNDS
#                         consecutive clean epochs required before the width rises (default 3).
#     (env) SAMEN_SABOTAGE_PARALLEL_PROBE_FORKS
#                         fork children per probe, default 12.
#     --adapt-selftest    drive the width CONTROLLER through scripted scenarios (clean → rise one
#                         step at a time, pressure → lower by one AND freeze, repeated pressure →
#                         no further lowering, nothing waiting → hold, quiet-but-unproven → hold,
#                         ADAPT_SECS=0 → pinned, budget off → never adapts) and exit. This is the
#                         gate for the controller itself; it compiles nothing.
#     --no-seed           do not warm-start a new slice from a sibling slice's build cache; every
#                         new slice then compiles its app from scratch (correct, just slower —
#                         the seed is digest-verified, so it can never reuse a patched source)
#     --list/--dry-run    print the partition, the coverage proof, the slice plan, the estimate
#                         and the audit, then EXIT (nothing applied, nothing compiled, no tree
#                         created). A hazard found by the audit still fails — a preview that
#                         cannot be run safely is not a green preview.
#     --no-preflight      pass through: skip the structural preflight (the driver runs it ONCE
#                         itself, rather than once per slice — it is read-only and idempotent)
#     --range/--from/--to/--touching/--touching-file/--changed
#                         narrow the SELECTION, and every slice runs filter ∩ slice, so the union
#                         over slices is exactly the filtered set — which is why the coverage proof
#                         still holds. --touching/--changed are passed through to each slice;
#                         --range/--from/--to are NOT, because a slice is launched with its own
#                         chunk `--range` and sabotage.sh's last `--range` wins — forwarding the
#                         caller's would override the chunk and every slice would replay the same
#                         patch (the chunks are cut from the already-filtered listing, so the
#                         caller's range is folded into them; see RANGE_FOLDED below).
#
#     --app is REJECTED: partitioning by app is this driver's job (use sabotage.sh for one app).
#     --test-db is REJECTED too: this driver owns it, per slice, and accepting a caller value
#     would put every slice back on one database.
#
# Reliability contract for a verdict (each is checked, and a missing one is a FAILURE, never a
# pass): a slice must exit 0, print the harness's own `SABOTAGE HARNESS: ALL PASSED` line, report
# at least one confirmed flip per assigned patch, replay exactly the number of patches the plan
# assigned it, and assert its own `main checkout: byte-exact` isolation line. A slice that was
# killed mid-flight fails even if its wrapper reported a zero status.
#
# Cleanup: each slice keeps its tree + build cache warm under $SAMEN_SABOTAGE_PARALLEL_ROOT
# (default .sabotage-parallel, which .gitignore pins), so repeat runs are warm. Reclaim with
#   rm -rf .sabotage-parallel && git -C . worktree prune
# (plus the per-slice databases the run's final line lists, if you want those gone too). The root
# MUST be git-ignored whenever it sits inside the repo: the harness replicates the checkout's
# UNTRACKED files into every replay tree, so an un-ignored root would be re-copied into each tree
# — nesting one level deeper on every run — instead of the run replaying patches. The driver
# refuses such a root up front rather than discovering it as a stalled slice.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HARNESS="$REPO_ROOT/scripts/sabotage.sh"
SABOTAGE_DIR="$REPO_ROOT/scripts/sabotages"

PARALLEL_ROOT="${SAMEN_SABOTAGE_PARALLEL_ROOT:-$REPO_ROOT/.sabotage-parallel}"
LOG_DIR="$PARALLEL_ROOT/logs"
DRIVER_LOCK="$PARALLEL_ROOT/driver.lock"

# Seconds between slice LAUNCHES. Each slice is a harness that spawns a subprocess per patch
# (`sed`/`git`/`mix`), so starting every slice on the same tick is a fork burst: on this
# MSYS/MINGW reference box, four simultaneous slices exhausted the fork capacity
# (`dofork: ... exit code 0xC0000142`, `fork: retry: Resource temporarily unavailable`) and three
# slices wedged instead of failing. A short stagger costs seconds and removes the burst.
STAGGER="${SAMEN_SABOTAGE_PARALLEL_STAGGER:-10}"
# A slice that stops writing to its log for this long is WEDGED, not slow: the harness prints a
# line per patch (and a first-run compile is quiet for minutes, not tens of minutes). It is killed
# and reported as a failure, because an unattended certification that hangs forever is worse than
# one that fails.
STALL_SECONDS="${SAMEN_SABOTAGE_PARALLEL_STALL:-1200}"
# How many slices may COLD-COMPILE at the same time. A slice whose root has no build cache pays its
# one-time compile inside its FIRST patch, and it does that on top of the startup fork load every
# slice carries (the 334-patch lint, the residue/EOL/anchor preflights, then git/sed/mix per patch).
# Measured 2026-10-13 on the reference box (7.7 GB, 12 cores), launching a FULLY COLD fleet at
# --jobs 4:
#   * four slices died inside their first patch with no harness output at all, while the driver log
#     carried the host's own wording — `bash 79870 dofork: child -1 … exit code 0xC0000142, errno 11`,
#     `child_copy: cygheap read copy failed … Win32 error 299`, and
#     `scripts/sabotage_parallel.sh: fork: retry: Resource temporarily unavailable`;
#   * the same fleet with only TWO slices cold completed (ALL PASSED);
#   * four COLD COMPILES with no driver around them all SUCCEEDED (status 0, 623–642s each against
#     257s solo, zero fork errors) — so the trigger is how many slices run that STARTUP BURST at once,
#     not the compiles' memory (free physical memory did fall to ~300 MB and every compile finished);
#   * and a probe of the exact operation a slice performs (a fresh BEAM start) succeeded even under
#     four concurrent cold compiles, so "can we fork at all" cannot predict this and is not used.
# The plain STAGGER above spreads the burst but was sized for a fleet whose slices are already warm.
# This is the same lever as the DB budget further down — the width gives, visibly, for the one phase
# that cannot be over-subscribed — and it is released per slice the moment its cache is built, so the
# pool refills. Warm slices are untouched: they still fill the pool to --jobs. 0 disables the cap.
COLD_LIMIT="${SAMEN_SABOTAGE_PARALLEL_COLD_LIMIT:-2}"

# ── ADAPTIVE COLD WIDTH ───────────────────────────────────────────────────────
# The cap above is a STARTING width, not a fixed one. On a box with fork headroom it is the slowest
# possible answer; on a box without it, it is the only safe one — and WHICH box we are on cannot be
# known up front (measured: a fresh-BEAM probe succeeds even under four concurrent cold compiles, so
# "can we fork right now" does not predict the burst ceiling). So the pool does not guess: it starts
# where it was told and moves ONE step at a time on evidence it actually has.
#
#   * an epoch runs every ADAPT_SECS while slices are compiling (called from the poll loop);
#   * an epoch is CLEAN when the fork probe spawns ADAPT_PROBE_FORKS children with no failure AND no
#     fork signature (`dofork` / `child_copy` / `fork: retry` / `Resource temporarily unavailable`)
#     has appeared in a slice log since the previous epoch;
#   * the width RISES by one only after ADAPT_ROUNDS consecutive clean epochs, only while a cold
#     slice is still waiting to be admitted, and only once the CURRENT width has finished a cold
#     compile (cold_releases moved past releases_at_width) — the width that is about to be
#     multiplied must have demonstrably worked, not merely looked quiet;
#   * ANY pressure — a failed probe fork, or a signature in a slice log — LOWERS the width by one and
#     FREEZES it for the rest of the run: the box has named its ceiling, and an unattended
#     certification must not keep probing it.
# The width it STARTS at and the one it ENDS at both go into the verdict, so a run reports the width
# it actually used rather than the one it was handed.
COLD_MAX="${SAMEN_SABOTAGE_PARALLEL_COLD_MAX:-0}"   # ceiling; 0 = follow --jobs (resolved once JOBS is known)
ADAPT_SECS="${SAMEN_SABOTAGE_PARALLEL_ADAPT_SECS:-60}"      # 0 = pin the width (no epochs)
ADAPT_ROUNDS="${SAMEN_SABOTAGE_PARALLEL_ADAPT_ROUNDS:-3}"   # clean epochs needed before a rise
ADAPT_PROBE_FORKS="${SAMEN_SABOTAGE_PARALLEL_PROBE_FORKS:-12}"
# TEST SEAM: the probe spawns `( $FORK_PROBE_CMD )` per child, and a non-zero exit marks the probe
# unhealthy — which is exactly what a real fork failure does. It exists so a gate can drive the
# LOWER-and-freeze path deterministically (a loaded box cannot be summoned on demand). Default: no-op.
FORK_PROBE_CMD="${SAMEN_SABOTAGE_PARALLEL_FORK_PROBE_CMD:-:}"

COLD_LIMIT_START="$COLD_LIMIT"
COLD_RAISES=0
COLD_DEMOTES=0
COLD_FROZEN=0
cold_releases=0        # cold slots given back = cold compiles finished this run
cold_launched=0        # cold slices admitted so far
adapt_clean_streak=0
adapt_last_epoch=-1
releases_at_width=0
adapt_stamp=""
adapt_scan=1           # scan slice logs for fork signatures (off in the self-test)
COLD_N=0               # how many slices start cold (set with the plan)

# cold_probe → true when this box can still spawn ADAPT_PROBE_FORKS children back to back.
cold_probe() {
  local i
  for (( i=0; i<ADAPT_PROBE_FORKS; i++ )); do
    ( $FORK_PROBE_CMD ) >/dev/null 2>&1 || return 1
  done
  return 0
}

# cold_adapt <now> — one epoch; may move COLD_LIMIT. Never rises past COLD_MAX, never falls below 1,
# never rises with no cold slice left to admit, and does NOTHING AT ALL once COLD_FROZEN is set. The
# frozen check is deliberately the FIRST thing after the timer, not a conjunct on the rise: freezing
# has to stop the LOWERING too. Probing on would let one bad minute ratchet the width to the floor —
# the opposite of the "one lowering, then leave it alone" contract in the header.
cold_adapt() {
  (( COLD_LIMIT > 0 && ADAPT_SECS > 0 )) || return 0
  (( COLD_FROZEN == 0 )) || return 0
  local now="$1"
  (( adapt_last_epoch < 0 )) && adapt_last_epoch=$now
  (( now - adapt_last_epoch >= ADAPT_SECS )) || return 0
  adapt_last_epoch=$now

  local pressure="" f
  cold_probe || pressure="a probe fork could not be spawned"
  if [[ -z "$pressure" ]] && (( adapt_scan == 1 )); then
    [[ -n "$adapt_stamp" ]] || { adapt_stamp="$WORK/adapt_stamp"; : > "$adapt_stamp" 2>/dev/null; }
    while IFS= read -r f; do
      if grep -qE 'dofork|child_copy|fork: retry|Resource temporarily unavailable' "$f" 2>/dev/null; then
        pressure="a fork signature appeared in $(basename "$f")"
        break
      fi
    done < <(find "$LOG_DIR" -maxdepth 1 -name '*.log' -newer "$adapt_stamp" 2>/dev/null)
    touch "$adapt_stamp" 2>/dev/null
  fi

  if [[ -n "$pressure" ]]; then
    if (( COLD_LIMIT > 1 )); then
      local from=$COLD_LIMIT
      COLD_LIMIT=$(( COLD_LIMIT - 1 ))
      COLD_DEMOTES=$(( COLD_DEMOTES + 1 ))
      echo "  COLD WIDTH: lowered $from -> $COLD_LIMIT — $pressure; the box has named its ceiling, so the width is FROZEN for the rest of this run"
    else
      echo "  COLD WIDTH: already at the floor (1) and still seeing pressure — $pressure; FROZEN for the rest of this run"
    fi
    COLD_FROZEN=1
    adapt_clean_streak=0
    releases_at_width=$cold_releases
    return 0
  fi

  adapt_clean_streak=$(( adapt_clean_streak + 1 ))
  # (COLD_FROZEN is already known false here — the early return above is the only freeze gate.)
  if (( COLD_LIMIT < COLD_MAX && adapt_clean_streak >= ADAPT_ROUNDS \
        && cold_releases > releases_at_width && COLD_N - cold_launched > 0 )); then
    local from=$COLD_LIMIT
    COLD_LIMIT=$(( COLD_LIMIT + 1 ))
    COLD_RAISES=$(( COLD_RAISES + 1 ))
    adapt_clean_streak=0
    releases_at_width=$cold_releases
    echo "  COLD WIDTH: raised $from -> $COLD_LIMIT — $ADAPT_ROUNDS clean epoch(s) at $from with no fork pressure, and $from cold compile(s) finished there; $(( COLD_N - cold_launched )) cold slice(s) still waiting"
  fi
  return 0
}

# run_adapt_selftest — drive the CONTROLLER through scripted scenarios. Separate from the gates for
# the plan because this is the part that decides the width, and a controller that cannot be shown to
# RISE on clean evidence AND to LOWER on pressure is not trustworthy — while the box cannot be made
# loaded on demand. Every scenario runs the real cold_adapt/cold_probe above. Prints one PASS/FAIL
# line per scenario and `ADAPT-SELFTEST: ok N/N`; returns non-zero if any scenario fails.
run_adapt_selftest() {
  local pass=0 total=0 failures=0 t

  reset_adapt() { # <start> <max> <secs> <rounds> <releases> <launched> <cold_n>
    COLD_LIMIT="$1"; COLD_LIMIT_START="$1"; COLD_MAX="$2"; ADAPT_SECS="$3"; ADAPT_ROUNDS="$4"
    cold_releases="$5"; cold_launched="$6"; COLD_N="$7"
    COLD_RAISES=0; COLD_DEMOTES=0; COLD_FROZEN=0
    adapt_clean_streak=0; adapt_last_epoch=0; releases_at_width=0; adapt_scan=0
  }
  # <label> <expect-width> <expect-raises> <expect-demotes> <expect-frozen>. FROZEN is asserted, not
  # just printed: it is the property that stops a bad minute becoming a permanent loss of width, and
  # a check that only compared the width let a controller that never froze pass (observed).
  check() {
    total=$(( total + 1 ))
    if [[ "$COLD_LIMIT" == "$2" && "$COLD_RAISES" == "$3" && "$COLD_DEMOTES" == "$4" && "$COLD_FROZEN" == "$5" ]]; then
      pass=$(( pass + 1 ))
      printf 'ADAPT-SELFTEST: PASS %-56s width=%s raises=%s demotes=%s frozen=%s\n' "$1" "$COLD_LIMIT" "$COLD_RAISES" "$COLD_DEMOTES" "$COLD_FROZEN"
    else
      failures=$(( failures + 1 ))
      printf 'ADAPT-SELFTEST: FAIL %-56s width=%s(want %s) raises=%s(want %s) demotes=%s(want %s) frozen=%s(want %s)\n' \
        "$1" "$COLD_LIMIT" "$2" "$COLD_RAISES" "$3" "$COLD_DEMOTES" "$4" "$COLD_FROZEN" "$5"
    fi
  }

  # 1. clean epochs rise ONE step at a time, and each rise needs its OWN fresh evidence (a cold
  #    compile finished at the width about to be multiplied) — so it stops at the ceiling.
  reset_adapt 2 4 60 2 2 2 6
  for t in 60 120; do cold_adapt "$t" >/dev/null; done      # 2 clean epochs at 2 -> rise to 3
  cold_releases=3                                            # a cold compile finished AT 3
  for t in 180 240; do cold_adapt "$t" >/dev/null; done     # 2 clean epochs at 3 -> rise to 4 (= cap)
  cold_releases=4
  for t in 300 360 420; do cold_adapt "$t" >/dev/null; done # clean, but already AT the ceiling
  check "clean epochs rise one step at a time, and stop at COLD_MAX" 4 2 0 0

  # 2. pressure LOWERS the width and freezes it — no later rise, however clean the box looks.
  reset_adapt 4 8 60 2 8 8 20
  FORK_PROBE_CMD=false; cold_adapt 60 >/dev/null; FORK_PROBE_CMD=:
  for t in 120 180 240 300 360 420; do cold_adapt "$t" >/dev/null; done
  check "a failed probe lowers the width and freezes it" 3 0 1 1

  # 3. the FREEZE is honoured: the first pressure epoch lowers by one, but a box having a bad minute
  #    must not be allowed to ratchet the width to the floor. A SECOND pressure epoch changes nothing.
  #    (Refutable: dropping the COLD_FROZEN early-return in cold_adapt turns exactly this red.)
  reset_adapt 4 8 60 1 4 4 20
  FORK_PROBE_CMD=false
  for t in 60 120 180 240; do cold_adapt "$t" >/dev/null; done
  FORK_PROBE_CMD=:
  check "once frozen, further pressure lowers nothing (one lowering, not a ratchet)" 3 0 1 1

  # 4. nothing left to admit → no rise, however clean the box is.
  reset_adapt 2 4 60 1 5 5 5
  for t in 60 120 180 240; do cold_adapt "$t" >/dev/null; done
  check "no waiting cold slice means no rise" 2 0 0 0

  # 5. ANTI-TAUTOLOGY: a clean probe alone must NEVER rise — the width has to have finished a
  #    cold compile first, or "quiet" would be mistaken for "proven".
  reset_adapt 2 4 60 1 0 1 4
  for t in 60 120 180 240; do cold_adapt "$t" >/dev/null; done
  check "a clean probe alone never rises (a cold compile must finish first)" 2 0 0 0

  # 6. ADAPT_SECS=0 pins the width: the controller must not run at all.
  reset_adapt 2 4 0 1 9 1 9
  for t in 60 120 180 240; do cold_adapt "$t" >/dev/null; done
  check "ADAPT_SECS=0 pins the width" 2 0 0 0

  # 7. a disabled budget (COLD_LIMIT=0) never adapts.
  reset_adapt 0 4 60 1 9 1 9
  for t in 60 120 180; do cold_adapt "$t" >/dev/null; done
  check "COLD_LIMIT=0 (budget disabled) never adapts" 0 0 0 0

  printf 'ADAPT-SELFTEST: ok %s/%s\n' "$pass" "$total"
  (( failures == 0 )) || { printf 'ADAPT-SELFTEST: FAILED %s scenario(s)\n' "$failures"; return 1; }
  return 0
}

# Pattern for the fixed-resource audit: a test file that reaches OUTSIDE its own database. Kept
# narrow on purpose — `storage_up`/`storage_down` on Repo.config() is the per-slice-safe path and
# the test helpers use it, so only fixed-name/external-tool forms are flagged. Comment lines are
# excluded (the markers legitimately appear in prose, e.g. backup_verification_test's docstring).
FIXED_RESOURCE_RE='System\.cmd\("(createdb|dropdb|psql|pg_dump|pg_restore)"|CREATE DATABASE|DROP DATABASE|ALTER DATABASE|storage_up|storage_down'
WORK="$(mktemp -d "${TMPDIR:-/tmp}/samen_sab_parallel.XXXXXX")"
LOCK_HELD=0
SLICE_PIDS=()
SLICE_IDS=()

cleanup() {
  # Kill any in-flight slice. Their own trees are already isolated, and every slice resets its
  # tree at the start of the next run, so a hard kill costs a recompile at worst.
  local pid
  for pid in "${SLICE_PIDS[@]:-}"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done
  [[ "$LOCK_HELD" == "1" ]] && rm -rf "$DRIVER_LOCK"
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
  echo ""
  echo "SABOTAGE HARNESS (PARALLEL): FAILED — $*"
  exit 1
}

usage() {
  sed -n '/^# ── USAGE/,/^# Reliability contract/p' "${BASH_SOURCE[0]}" \
    | sed '1d;$d;s/^# \{0,1\}//'
}

arg_err() {
  echo "sabotage_parallel.sh: $1" >&2
  echo "" >&2
  echo "Run 'sabotage_parallel.sh --list' to preview the partition, or see the header of this" >&2
  echo "script for the full flag reference." >&2
  exit 2
}

# ── the scratch root must be git-ignored when it sits inside the repo ────────
# The harness replicates the main checkout's UNTRACKED-but-not-ignored files into every replay
# tree, so an un-ignored root here does not merely waste space: the trees are inside it, the copy
# set includes every slice's mix build cache, and it nests one level deeper on every run. Observed
# 2026-10-12 (before .gitignore carried `.sabotage-parallel/`): a two-slice run sat 15 minutes in
# that copy with each tree holding a 54 MB copy of its sibling's cache, and the stall watchdog
# eventually had to kill it. Checked up front, in dry-run too: a preview of a plan that cannot be
# executed safely is not a green preview. (A root OUTSIDE the repo is fine and is not checked —
# git only ever lists paths under the checkout.)
if [[ "$PARALLEL_ROOT" == "$REPO_ROOT"/* ]]; then
  if command -v git >/dev/null 2>&1 \
     && ! git -C "$REPO_ROOT" check-ignore -q "$PARALLEL_ROOT/logs" 2>/dev/null; then
    fail "the scratch root $PARALLEL_ROOT is INSIDE the repo but NOT git-ignored. The harness copies the checkout's untracked files into every replay tree, so it would copy this build cache (thousands of files, nesting deeper every run) into every slice instead of replaying patches. Add the root to .gitignore (see the '.sabotage-parallel/' entry) or point SAMEN_SABOTAGE_PARALLEL_ROOT outside the repo."
  fi
fi

# ── argument parsing ─────────────────────────────────────────────────────────
JOBS=0
JOBS_PINNED=0
INTRA_CAP=0          # 0 = derive from --jobs (the auto rule); ≥1 = at most that many slices per app
INITRA_CAP_PINNED=0
LIST_ONLY=0
ALLOW_SHARED_SCRATCH=0
SEED_ENABLED=1
ADAPT_SELFTEST=0
PASSTHROUGH=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --jobs)
      shift; [[ $# -gt 0 ]] || arg_err "--jobs requires a number"
      [[ "$1" =~ ^[0-9]+$ ]] || arg_err "--jobs wants a number, got: $1"
      JOBS=$((10#$1)); (( JOBS > 0 )) || arg_err "--jobs must be at least 1"
      JOBS_PINNED=1
      PASSTHROUGH+=("--jobs" "$1"); shift ;;
    --intra)
      shift; [[ $# -gt 0 ]] || arg_err "--intra requires a number"
      [[ "$1" =~ ^[0-9]+$ ]] || arg_err "--intra wants a number, got: $1"
      INTRA_CAP=$((10#$1)); (( INTRA_CAP >= 1 )) || arg_err "--intra must be at least 1 (1 = the app-only partition)"
      INITRA_CAP_PINNED=1; shift ;;
    --allow-shared-scratch)
      ALLOW_SHARED_SCRATCH=1; shift ;;
    --no-seed)
      SEED_ENABLED=0; shift ;;
    --app)
      arg_err "--app is this driver's own job (it partitions by app); use scripts/sabotage.sh --app <name> for a single app" ;;
    --test-db)
      arg_err "--test-db is this driver's own job (one database per slice); passing it would put every slice back on ONE database" ;;
    --list|--dry-run)
      LIST_ONLY=1; shift ;;
    --adapt-selftest)
      ADAPT_SELFTEST=1; shift ;;
    --no-preflight|--range|--from|--to|--touching|--touching-file|--changed)
      PASSTHROUGH+=("$1")
      # Everything after --jobs is consumed by the driver, so pass arguments through verbatim
      # until the next recognised driver flag. The two-argument forms carry their value.
      case "$1" in
        --range|--from|--to|--touching-file)
          shift; [[ $# -gt 0 ]] || arg_err "$1 requires a value"
          PASSTHROUGH+=("$1"); shift ;;
        --changed)
          if [[ $# -gt 0 && "$1" != --* ]]; then PASSTHROUGH+=("$1"); shift; fi ;;
        --touching)
          while [[ $# -gt 0 && "$1" != --* ]]; do PASSTHROUGH+=("$1"); shift; done ;;
        *) shift ;;
      esac ;;
    -h|--help)
      usage; exit 0 ;;
    *) arg_err "unknown flag: $1 (this driver adds only --jobs/--intra/--allow-shared-scratch/--no-seed/--list; other flags pass through to sabotage.sh)" ;;
  esac
done

# Strip the driver-only flags from the passthrough (sabotage.sh does not know them).
HARNESS_ARGS=()
i=0
while [[ $i -lt ${#PASSTHROUGH[@]} ]]; do
  if [[ "${PASSTHROUGH[$i]}" == "--jobs" ]]; then i=$((i + 2)); continue; fi
  HARNESS_ARGS+=("${PASSTHROUGH[$i]}"); i=$((i + 1))
done

# SLICE_ARGS — what each SLICE is handed: the same passthrough MINUS the caller's
# --range/--from/--to. Those must not be forwarded, because a slice is launched with its OWN
# --range (its chunk) and sabotage.sh's last `--range` wins: forwarding the caller's would
# override the chunk, so EVERY slice would replay the first patch of the caller's range while
# still reporting the count it was assigned (a silent false pass — caught live on 2026-10-12, the
# two same-app slices both replaying patch 197). Dropping them is not a narrowing of the
# selection: the chunks are cut from the harness's ALREADY-filtered listing, so the caller's
# range is folded into every chunk range by construction (RANGE_FOLDED makes that visible in the
# report). --touching/--changed still pass through: they add paths to one touched-set filter and
# every patch in a chunk already passed it, so re-applying it cannot re-select anything.
SLICE_ARGS=()
RANGE_FOLDED=0
i=0
while [[ $i -lt ${#HARNESS_ARGS[@]} ]]; do
  case "${HARNESS_ARGS[$i]}" in
    --range)
      RANGE_FOLDED=1; i=$((i + 2)) ;;
    --from|--to)
      RANGE_FOLDED=1; i=$((i + 2)) ;;
    --touching-file)
      SLICE_ARGS+=("${HARNESS_ARGS[$i]}" "${HARNESS_ARGS[$((i + 1))]:-}"); i=$((i + 2)) ;;
    --changed)
      SLICE_ARGS+=("--changed")
      i=$((i + 1))
      if [[ $i -lt ${#HARNESS_ARGS[@]} && "${HARNESS_ARGS[$i]}" != --* ]]; then
        SLICE_ARGS+=("${HARNESS_ARGS[$i]}"); i=$((i + 1))
      fi ;;
    --touching)
      SLICE_ARGS+=("--touching")
      i=$((i + 1))
      while [[ $i -lt ${#HARNESS_ARGS[@]} && "${HARNESS_ARGS[$i]}" != --* ]]; do
        SLICE_ARGS+=("${HARNESS_ARGS[$i]}"); i=$((i + 1))
      done ;;
    *)
      SLICE_ARGS+=("${HARNESS_ARGS[$i]}"); i=$((i + 1)) ;;
  esac
done

FILTER_LABEL="$(
  local_parts=()
  j=0
  while [[ $j -lt ${#HARNESS_ARGS[@]} ]]; do
    case "${HARNESS_ARGS[$j]}" in
      --range|--from|--to|--touching-file) local_parts+=("${HARNESS_ARGS[$j]}=${HARNESS_ARGS[$((j + 1))]:-}"); j=$((j + 2)) ;;
      --changed) local_parts+=("changed=${HARNESS_ARGS[$((j + 1))]:-default}"); break ;;
      --touching) local_parts+=("touching"); break ;;
      --no-preflight) j=$((j + 1)) ;;
      *) j=$((j + 1)) ;;
    esac
  done
  if [[ ${#local_parts[@]} -eq 0 ]]; then echo ""; else
    IFS=', '; echo "${local_parts[*]}"
  fi
)"

# ── --adapt-selftest: prove the width CONTROLLER before any planning/compiling happens ──────
if [[ "$ADAPT_SELFTEST" -eq 1 ]]; then
  run_adapt_selftest
  exit $?
fi

# ── the coverage proof: ONE harness call, which already knows the selection ──
# `--list` prints every SELECTED patch with its resolved APP (`app=<name>`), so a single call
# yields the whole set, the partition, and the malformed case in one shot. Two reasons it is one
# call and not one per app/slice: each invocation re-runs the header lint over every patch (~1
# minute on Windows, where the per-patch `sed`/`git` spawns dominate), so a call per slice would
# spend longer than several patches; and the slices are then derived from the harness's OWN
# selection code rather than from a second implementation of it here.
SELECTION="$(bash "$HARNESS" ${HARNESS_ARGS[@]+"${HARNESS_ARGS[@]}"} --list 2>&1)" \
  || fail "the harness could not list the selection (see above)"
printf '%s\n' "$SELECTION" > "$WORK/selection.list"

TOTAL_N="$(printf '%s\n' "$SELECTION" | sed -n 's/^SABOTAGE SELECTION: \([0-9][0-9]*\) of \([0-9][0-9]*\) patches selected.*/\1/p' | tail -1)"
TOTAL_M="$(printf '%s\n' "$SELECTION" | sed -n 's/^SABOTAGE SELECTION: \([0-9][0-9]*\) of \([0-9][0-9]*\) patches selected.*/\2/p' | tail -1)"
[[ -n "$TOTAL_N" && -n "$TOTAL_M" ]] \
  || fail "could not read the selection counts from 'sabotage.sh ${HARNESS_ARGS[*]:-} --list'"
(( TOTAL_M > 0 )) || fail "no patches found in $SABOTAGE_DIR"
if (( TOTAL_N == 0 )); then
  fail "filters [$FILTER_LABEL] select no patches — nothing to certify (nothing to certify is not a pass)"
fi

# records: <app>\t<patch number>\t<patch name>, in filename order. The number is the NNN of
# NNN-slug.patch and is what `--range` filters on, so it is also the unit the slices are cut from.
: > "$WORK/records"
malformed=0
while IFS= read -r line; do
  case "$line" in
    ""|"SABOTAGE LINT: "*) continue ;;
    "SABOTAGE SELECTION"*) continue ;;
  esac
  if [[ "$line" =~ ^[[:space:]][[:space:]]([^[:space:]]+)[[:space:]]+app=([^[:space:]]+)$ ]]; then
    name="${BASH_REMATCH[1]}"; app="${BASH_REMATCH[2]}"
    num="${name%%-*}"
    if [[ ! "$num" =~ ^[0-9]+$ ]]; then
      echo "  !! unchunkable selection entry: $name (no numeric NNN- prefix, so no --range can select it)" >&2
      malformed=$((malformed + 1))
      continue
    fi
    printf '%s\t%s\t%s\n' "$app" "$((10#$num))" "$name" >> "$WORK/records"
  else
    echo "  !! unassignable selection entry: $line" >&2
    malformed=$((malformed + 1))
  fi
done <<< "$SELECTION"

(( malformed == 0 )) \
  || fail "$malformed selection entry/entries cannot be assigned to a slice — a patch whose '# APP:' header is duplicated resolves to two lines and matches NO --app filter, and a patch with no numeric filename prefix matches no --range. Either way this partition would silently drop it."
LISTED="$(wc -l < "$WORK/records" | tr -d ' ')"
(( LISTED == TOTAL_N )) \
  || fail "the listing shows $LISTED patch(es) but the selection count says $TOTAL_N — the partition cannot be trusted"

sort -t$'\t' -k1,1 "$WORK/records" | awk -F'\t' '{print $1}' | uniq -c \
  | awk '{printf "%s\t%s\n", $2, $1}' | sort -k1,1 > "$WORK/apps"
APP_COUNT="$(wc -l < "$WORK/apps" | tr -d ' ')"
(( APP_COUNT > 0 )) || fail "no apps discovered in $SABOTAGE_DIR"

# ── width, slice size, and the pool's connection budget ──────────────────────
# Default width. On a real POSIX runner: one slot per app (the pool only blocks when --jobs asks
# for less). On MSYS/MINGW: 2 — measured here, because four concurrent harnesses exhausted the
# host's fork capacity and wedged three slices. On a POSIX runner the intra-app split then takes
# the width further on its own (more slices than apps, all runnable at once).
if (( JOBS == 0 )); then
  case "$(uname -s 2>/dev/null || echo unknown)" in
    MINGW*|MSYS*|CYGWIN*)
      JOBS=2
      echo "  NOTE: defaulting to --jobs 2 on this $(uname -s) host — concurrent slices each spawn"
      echo "        per-patch subprocesses, and a 4-wide launch exhausted this box's fork capacity"
      echo "        (dofork 0xC0000142 -> 'fork: retry: Resource temporarily unavailable'), which"
      echo "        WEDGES slices rather than failing them. Override with --jobs N." ;;
    *)
      JOBS=$APP_COUNT ;;
  esac
fi

# The adaptive width's ceiling is only knowable once JOBS is final: default it to the pool width
# (there is never a point in more cold compiles than slots to run them in), and never let a ceiling
# below the starting width silently lower the width the caller asked for.
(( COLD_MAX > 0 )) || COLD_MAX=$JOBS
(( COLD_MAX < COLD_LIMIT )) && COLD_MAX=$COLD_LIMIT

# pool_cap <app> → the app's test repo pool_size (its WORST-CASE connection appetite), 0 when the
# app has no test database at all (the adapter packages' suites never touch Postgres).
pool_cap() {
  local cfg="$REPO_ROOT/$1/config/test.exs" v=""
  if [[ -f "$cfg" ]]; then
    v="$(sed -n 's/^[[:space:]]*pool_size:[[:space:]]*\([0-9][0-9]*\).*/\1/p' "$cfg" | head -1)"
  fi
  [[ -n "$v" ]] || v=0
  printf '%s' "$v"
}

# estimate_makespan <jobs> <size...> → list-scheduling (LPT) makespan over slice sizes: every
# free slot immediately takes the next-largest slice, which is the order the driver launches in.
# It is an ESTIMATE: it counts patches, not seconds, and ignores each slice's one-time compile and
# migrate. It is used only to answer "does splitting this app actually beat not splitting it?".
estimate_makespan() {
  local jobs="$1"; shift
  local slots=() size i best best_i
  for ((i = 0; i < jobs; i++)); do slots[i]=0; done
  for size in "$@"; do
    best=""; best_i=0
    for ((i = 0; i < jobs; i++)); do
      if [[ -z "$best" ]] || (( slots[i] < best )); then best="${slots[i]}"; best_i=$i; fi
    done
    slots[best_i]=$((slots[best_i] + size))
  done
  best=0
  for ((i = 0; i < jobs; i++)); do (( slots[i] > best )) && best="${slots[i]}"; done
  printf '%s' "$best"
}

# peek_peak <jobs> → the plan's worst-case concurrent connection count: the pool caps of the
# <jobs> largest slices (a slice holds up to its pool_size connections).
plan_peak() {
  local total=0 pool
  while IFS= read -r pool; do
    [[ -n "$pool" ]] || continue
    total=$((total + pool))
  done < <(cut -f7 "$WORK/plan" | sort -rn | head -n "$1")
  printf '%s' "$total"
}

# build_plan — cut every app into at most INTRA_CAP (auto: one job's fair share) contiguous
# chunk(s) of its OWN patches and write the slices to $WORK/plan as
#   <slice id>\t<app>\t<range lo>\t<range hi>\t<count>\t<db>\t<pool cap>
# Sets PLAN_SPLIT (any app split), PLAN_FLOOR (the largest single app = the app-only floor),
# PLAN_BEST_SLICE (largest slice) and PLAN_EST (list-scheduling makespan estimate).
build_plan() {
  local app count k base extra i pos size lo hi id db
  local nums=() sizes=()
  # Ideal slice size: one job's fair share of the whole selection. 1 job ⇒ nothing to split for.
  local rps=$(( (TOTAL_N + JOBS - 1) / JOBS ))
  (( rps >= 1 )) || rps=1

  : > "$WORK/plan"
  PLAN_SPLIT=0
  PLAN_FLOOR=0

  while IFS=$'\t' read -r app count; do
    [[ -n "$app" ]] || continue
    (( count > PLAN_FLOOR )) && PLAN_FLOOR=$count

    # k = slices for this app. Auto: enough chunks that no slice exceeds one job's fair share,
    # never more than the app has patches, never more than the pool has slots.
    k=$(( (count + rps - 1) / rps ))
    (( k > JOBS )) && k=$JOBS
    (( k > count )) && k=$count
    (( k < 1 )) && k=1
    # An explicit cap (or the auto rule's "not worth it" = 1) narrows it further.
    (( INTRA_CAP >= 1 && INTRA_CAP < k )) && k=$INTRA_CAP
    (( k > 1 )) && PLAN_SPLIT=1

    # THIS app's patch numbers, ascending. A chunk is a contiguous run of them, so its `--range
    # lo-hi` selects exactly the chunk (other apps' patches inside the interval are excluded by
    # `--app`), and the runs are disjoint and ordered by construction.
    nums=()
    while IFS= read -r n; do [[ -n "$n" ]] && nums+=("$n"); done \
      < <(awk -F'\t' -v a="$app" '$1 == a {print $2}' "$WORK/records" | sort -n)

    # Near-equal chunks: `base` of them `base+1` patches, the rest `base`.
    base=$(( count / k )); extra=$(( count % k ))
    pos=0
    for ((i = 1; i <= k; i++)); do
      size=$base
      (( i <= extra )) && size=$((base + 1))
      (( size < 1 )) && continue
      lo="${nums[$pos]}"; hi="${nums[$((pos + size - 1))]}"
      id="$app"; db="${app}_test_sab${i}"
      (( i > 1 )) && id="${app}-${i}"
      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$id" "$app" "$lo" "$hi" "$size" "$db" "$(pool_cap "$app")" >> "$WORK/plan"
      pos=$((pos + size))
    done
    (( pos == count )) \
      || fail "internal: $app chunked into $pos of $count patch(es) — the chunk arithmetic is wrong"
  done < "$WORK/apps"

  sizes=()
  while IFS=$'\t' read -r _id _app _lo _hi size _db _pool; do
    [[ -n "$size" ]] && sizes+=("$size")
  done < "$WORK/plan"
  PLAN_EST="$(estimate_makespan "$JOBS" ${sizes[@]+"${sizes[@]}"})"
  PLAN_BEST_SLICE=0
  for size in ${sizes[@]+"${sizes[@]}"}; do
    (( size > PLAN_BEST_SLICE )) && PLAN_BEST_SLICE=$size
  done
}

# plan_auto — build the plan, and (when --intra was not pinned) adopt the intra-app split only if
# it LOWERS the estimate. With a saturated pool the split changes nothing but the compile/migrate
# bill, and paying that for no makespan is exactly the "slices that cannot run concurrently" trap.
plan_auto() {
  (( INITRA_CAP_PINNED == 0 )) && INTRA_CAP=0
  : > "$WORK/plan_auto_note"
  build_plan
  (( INITRA_CAP_PINNED == 0 )) || return 0
  local unsplit=() count
  while IFS=$'\t' read -r _app count; do [[ -n "$count" ]] && unsplit+=("$count"); done < "$WORK/apps"
  local unsplit_est="$(estimate_makespan "$JOBS" ${unsplit[@]+"${unsplit[@]}"})"
  if (( PLAN_SPLIT == 1 && PLAN_EST >= unsplit_est )); then
    INTRA_CAP=1
    build_plan
    {
      echo "  NOTE: intra-app splitting is NOT applied: with --jobs $JOBS the app partition already"
      echo "        saturates the pool (estimated makespan $unsplit_est patch(es) either way), so an extra"
      echo "        slice per app would only pay a duplicate compile and migrate. Force it with --intra N,"
      echo "        or widen the pool with --jobs N."
    } > "$WORK/plan_auto_note"
  fi
  return 0
}

plan_auto

# ── the connection budget ────────────────────────────────────────────────────
# A wider pool means more suites holding connections at once. The plan's peak is the sum of the
# pool caps of the JOBS largest slices; when that cannot fit Postgres, the width is what has to
# give — silently over-subscribing the server just turns into a slice failing on `too many
# clients` in the middle of a two-hour certification.
MAX_CONN="$(psql -tAc 'SHOW max_connections' 2>/dev/null | tr -d '[:space:]' || true)"
[[ "$MAX_CONN" =~ ^[0-9]+$ ]] || MAX_CONN=""
BUDGET_NOTE=""
if [[ -n "$MAX_CONN" ]] && (( $(plan_peak "$JOBS") > MAX_CONN )); then
  if (( JOBS_PINNED == 1 )); then
    BUDGET_NOTE="  !! DB BUDGET: the plan's peak is $(plan_peak "$JOBS") connections (the $JOBS largest slices' pool
      caps) but Postgres reports max_connections=$MAX_CONN. --jobs was pinned, so it is honoured —
      expect the widest slices to contend for connections; lower --jobs or raise max_connections."
  else
    while (( JOBS > 1 )) && (( $(plan_peak "$JOBS") > MAX_CONN )); do
      JOBS=$((JOBS - 1))
      plan_auto
    done
    BUDGET_NOTE="  NOTE: width lowered to --jobs $JOBS: the wider plan's peak exceeded Postgres
        max_connections=$MAX_CONN (each slice may hold its pool_size connections at once). Peak is
        now $(plan_peak "$JOBS"). Raise max_connections (or pin --jobs) to go wider."
  fi
fi

# ── the fixed-resource audit ─────────────────────────────────────────────────
# Which TEST FILES does each slice run, and does any of them reach outside its own database?
# Sharing a file between slices is normal (a suite is the named test for several patches) and safe
# while the file stays inside the slice's DB; the hazard is a file that creates a FIXED-NAME
# resource — two concurrent slices would then fight over it, and the failure would surface deep in
# a slice as a confusing flake rather than as a planning mistake.
: > "$WORK/file_slices"
while IFS=$'\t' read -r id app lo hi _count _db _pool; do
  [[ -n "$id" ]] || continue
  while IFS=$'\t' read -r _a num name; do
    if [[ "$app" == "$_a" ]] && (( num >= lo && num <= hi )); then
      while IFS= read -r f; do
        [[ -n "$f" ]] || continue
        printf '%s\t%s\t%s\n' "$app" "$f" "$id" >> "$WORK/file_slices"
      done < <(sed -n 's/^# TEST_FILES: //p' "$SABOTAGE_DIR/$name" | tr ' ' '\n')
    fi
  done < "$WORK/records"
done < "$WORK/plan"

: > "$WORK/audit_hazards"
while IFS=$'\t' read -r app f ids; do
  [[ -n "$f" ]] || continue
  smax="$(printf '%s\n' "$ids" | tr ' ' '\n' | sort -u | wc -l | tr -d ' ')"
  (( smax > 1 )) || continue
  src="$REPO_ROOT/$app/$f"
  [[ -f "$src" ]] || continue
  hits="$(grep -nE "$FIXED_RESOURCE_RE" "$src" 2>/dev/null | grep -vE '^[0-9]+:[[:space:]]*#' | head -2 || true)"
  if [[ -n "$hits" ]]; then
    printf '%s\t%s\t%s\t%s\n' "$app" "$f" "$(printf '%s\n' "$ids" | tr ' ' '\n' | sort -u | tr '\n' ',' | sed 's/,$//')" \
      "$(printf '%s' "$hits" | head -1 | cut -c1-150)" >> "$WORK/audit_hazards"
  fi
done < <(sort -t$'\t' -k1,1 -k2,2 "$WORK/file_slices" | awk -F'\t' '{ if ($1"\t"$2 == key) { ids = ids " " $3 } else { if (key != "") print key "\t" ids; key = $1"\t"$2; ids = $3 } } END { if (key != "") print key "\t" ids }')

HAZARD_N="$(wc -l < "$WORK/audit_hazards" | tr -d ' ')"
if (( HAZARD_N > 0 )); then
  echo ""
  echo "  FIXED-RESOURCE HAZARD: $HAZARD_N test file(s) reach outside the per-slice database AND would run in more than one slice:"
  while IFS=$'\t' read -r app f ids marker; do
    [[ -n "$f" ]] || continue
    echo "    $app/$f  (slices: $ids)"
    echo "        $marker"
  done < "$WORK/audit_hazards"
  echo ""
  if (( ALLOW_SHARED_SCRATCH == 0 )); then
    fail "$HAZARD_N test file(s) create fixed-name external resources (scratch databases / pg_dump artifacts) and the current partition runs each of them in >1 slice of one app — two concurrent slices would fight over the same resource instead of the run being isolated. Re-partition so those files land in one slice (--intra 1, or a narrower --jobs), or pass --allow-shared-scratch if you have verified the resource is per-run unique."
  fi
  echo "  !! ACKNOWLEDGED (--allow-shared-scratch): the run proceeds; the hazard is attested above,"
  echo "     not resolved — a failure in those slices may be resource contention, not a dead gate."
fi

# The exact arguments each slice's harness sees, rendered once for the plan's `cmd:` line — the
# load-bearing evidence that a slice really is handed its OWN chunk range and its own database.
SLICE_ARGS_STR=""
for a in ${SLICE_ARGS[@]+"${SLICE_ARGS[@]}"}; do SLICE_ARGS_STR="${SLICE_ARGS_STR} ${a}"; done

# ── print the partition + the proof ─────────────────────────────────────────
if [[ -n "$FILTER_LABEL" ]]; then
  echo "SABOTAGE HARNESS (PARALLEL, FILTERED: $FILTER_LABEL) — $TOTAL_N of $TOTAL_M patches, by app:"
else
  echo "SABOTAGE HARNESS (PARALLEL) — $TOTAL_N of $TOTAL_M patches, by app:"
fi
while IFS=$'\t' read -r app count; do
  [[ -n "$app" ]] || continue
  printf '  %-14s %4s patch(es)\n' "$app" "$count"
  while IFS=$'\t' read -r id _app lo hi size db _pool; do
    printf '    %-14s range=%-11s %4s patch(es)  db=%s  root=%s\n' "$id" "${lo}-${hi}" "$size" "$db" "$id"
    printf '        cmd: sabotage.sh --app %s --range %s-%s --test-db %s%s --no-preflight\n' \
      "$app" "$lo" "$hi" "$db" "$SLICE_ARGS_STR"
  done < <(awk -F'\t' -v a="$app" '$2 == a' "$WORK/plan")
done < <(sort -k2,2nr -t$'\t' "$WORK/apps")
[[ -s "$WORK/plan_auto_note" ]] && cat "$WORK/plan_auto_note"
[[ -n "$BUDGET_NOTE" ]] && printf '%s\n' "$BUDGET_NOTE"
if (( RANGE_FOLDED == 1 )); then
  echo "  NOTE: the caller's --range/--from/--to narrowed the selection and is FOLDED into each slice's"
  echo "        own chunk range (the chunks are cut from the already-filtered listing). Slices are not"
  echo "        handed the caller's range again: sabotage.sh's last --range wins, so forwarding it would"
  echo "        override the chunk and every slice would replay the same first patch."
fi

SLICE_SUM="$(awk -F'\t' '{s += $5} END {print s + 0}' "$WORK/plan")"
SLICE_N="$(wc -l < "$WORK/plan" | tr -d ' ')"
(( SLICE_SUM == TOTAL_N )) \
  || fail "the slice plan sums to $SLICE_SUM, not $TOTAL_N — $((TOTAL_N - SLICE_SUM)) patch(es) unassigned"
echo "  COVERAGE: sum of slices = $SLICE_SUM = $TOTAL_N selected patch(es) ✓ every patch is assigned to exactly one slice"
echo "  SLICE PLAN: $SLICE_N slice(s) over $APP_COUNT app(s) — largest slice $PLAN_BEST_SLICE patch(es); the app-partition floor is $PLAN_FLOOR"
echo "  ESTIMATE: pool makespan ≈ $PLAN_EST patch(es) with --jobs $JOBS (list-scheduling over slice sizes; excludes per-slice compile/migrate)"
# ── the seed plan: which NEW slices start from a sibling's warm build cache ──
# A candidate is a sibling slice root of the SAME app that holds a usable cache (the compiler
# manifest + the app's ebin), is not the target itself, and is NOT IN USE — a running slice holds
# its per-slice lock dir, and copying a cache out from under a writer would seed torn artifacts.
#
# PRISTINE FIRST. A slice root carries a `replayed-patches` file holding HOW MANY patches the driver
# has launched into it (written BEFORE each launch, so a killed slice is counted too). A root at 0
# has never replayed a patch, so ALL of its artifacts were built from pristine sources; a root at N
# holds artifacts compiled from patched-then-reverted sources, and those recompile in the seeded
# slice. That is the real cost of a dirty source, and it is why this ranks candidates rather than
# just taking the newest: measured, an unpatched cache recompiles 0 files where the same cache after
# one module's patch recompiles that module and its dependents (2 files).
#
# So the ranking is (1) fewest patches replayed — exact and decisive for the 0 case, and an
# APPROXIMATE proxy above it (patches differ in how much code they touch, and only the touched
# LIBRARY sources cost a recompile: a slice whose patches touched test files only is cheaper than
# its count says); then (2) newest manifest, the rule that predates this ranking.
#
# Prints `<candidate>\t<label>`, or nothing when there is no usable candidate — the caller must not
# conflate "no candidate" with a path.
seed_candidate() { # seed_candidate <app> <skip-id>... → "<path>\t<label>" or empty
  local app="$1"; shift
  local best="" best_n=0 best_m=0 cand stem m skip id n mark
  for cand in "$PARALLEL_ROOT/$app/build/$app" "$PARALLEL_ROOT/$app"-*/build/"$app"; do
    [[ -d "$cand" ]] || continue
    [[ -f "$cand/lib/$app/.mix/compile.elixir" ]] || continue
    [[ -d "$cand/lib/$app/ebin" ]] || continue
    stem="$(basename "$(dirname "$(dirname "$cand")")")"
    skip=0
    for id in "$@"; do [[ "$id" == "$stem" ]] && skip=1; done
    (( skip == 1 )) && continue
    [[ -d "$PARALLEL_ROOT/$stem/lock" ]] && continue
    mark="$PARALLEL_ROOT/$stem/replayed-patches"
    n=0
    [[ -r "$mark" ]] && n="$(tr -dc '0-9' < "$mark" | head -c 9)"
    [[ "$n" =~ ^[0-9]+$ ]] || n=0
    m="$(stat -c %Y "$cand/lib/$app/.mix/compile.elixir" 2>/dev/null || echo 0)"
    if [[ -z "$best" ]] || (( n < best_n )) || { (( n == best_n )) && (( m > best_m )); }; then
      best="$cand"; best_n="$n"; best_m="$m"
    fi
  done
  [[ -n "$best" ]] || return 0
  printf '%s\t%s' "$best" "$( (( best_n == 0 )) && echo pristine || echo "patched($best_n)" )"
}

: > "$WORK/seeds"
unsown=0
while IFS=$'\t' read -r id app _lo _hi _count db _pool; do
  [[ -n "$id" ]] || continue
  # A slice that already has its cache is warm for free (a repeat run) — nothing to copy.
  [[ -d "$PARALLEL_ROOT/$id/build/$app" ]] && continue
  if (( SEED_ENABLED == 0 )); then unsown=$((unsown + 1)); continue; fi
  cand_line="$(seed_candidate "$app" "$id")"
  cand="${cand_line%%$'\t'*}"; why="${cand_line##*$'\t'}"
  if [[ -z "$cand" ]]; then unsown=$((unsown + 1)); continue; fi
  printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$cand" "$app" "$db" "$why" >> "$WORK/seeds"
done < <(sort -t$'\t' -k5,5nr "$WORK/plan")
SEED_N="$(wc -l < "$WORK/seeds" | tr -d ' ')"

if (( SEED_ENABLED == 0 )); then
  echo "  SEED PLAN: disabled (--no-seed) — every new slice compiles its app and deps from scratch"
elif (( SEED_N > 0 )); then
  echo "  SEED PLAN: $SEED_N new slice(s) start from a sibling slice's warm build cache (copied + normalised before launch):"
  while IFS=$'\t' read -r id cand _app _db why; do
    [[ -n "$id" ]] || continue
    printf '    %-14s <- %-42s [%s]\n' "$id" "${cand#$PARALLEL_ROOT/}" "$why"
  done < "$WORK/seeds"
  (( unsown > 0 )) && echo "    ($unsown new slice(s) have no usable sibling cache yet and will compile from scratch)"
else
  echo "  SEED PLAN: nothing to seed (no new slice, or no sibling cache exists yet)"
fi

# ── the cold-compile budget: how many slices will pay the one-time compile, and at once? ──────
# Computed from the ROOT plus the seed PLAN rather than predicted, and computed HERE (before the
# --list exit) so a dry run shows the same number the run will honour. A slice that is already warm
# on disk needs no slot; a slice the seed plan is about to warm needs none either — it will have a
# cache by the time it launches. Everything else cold-compiles, and the launch loop admits only
# COLD_LIMIT of those at a time.
: > "$WORK/cold"
while IFS=$'\t' read -r id app _lo _hi _count _db _pool; do
  [[ -n "$id" ]] || continue
  [[ -d "$PARALLEL_ROOT/$id/build/$app" ]] && continue     # already warm on disk
  cut -f1 "$WORK/seeds" 2>/dev/null | grep -qx "$id" && continue   # the seed plan will warm it
  printf '%s\n' "$id" >> "$WORK/cold"
done < "$WORK/plan"
COLD_N="$(wc -l < "$WORK/cold" | tr -d ' ')"
if (( COLD_N > 0 )); then
  # Three DISTINCT statements, because the truth differs: the cap can be off entirely, it can be a
  # MOVING starting width, or it can be a hard pinned ceiling. Saying "at most N" while the width is
  # free to rise to M would be the one thing a plan line must never be.
  if (( COLD_LIMIT == 0 )); then
    echo "  COLD-COMPILE BUDGET: $COLD_N slice(s) start with NO build cache — the cap is DISABLED
      (SAMEN_SABOTAGE_PARALLEL_COLD_LIMIT=0), so they may all start at once: only do this on a box
      that can take the whole fleet's cold start."
  elif (( ADAPT_SECS > 0 && COLD_MAX > COLD_LIMIT )); then
    echo "  COLD-COMPILE BUDGET: $COLD_N slice(s) start with NO build cache; the width STARTS at $COLD_LIMIT and
      ADAPTS up to $COLD_MAX — one step per $ADAPT_ROUNDS clean ${ADAPT_SECS}s epoch(s) WITH a cold compile
      finished at that width, and any fork signature lowers it once and freezes it. Pin the width with
      SAMEN_SABOTAGE_PARALLEL_ADAPT_SECS=0, cap it with SAMEN_SABOTAGE_PARALLEL_COLD_MAX. Each slice
      releases its slot as soon as its own cache is built, so the pool refills to --jobs $JOBS."
  else
    echo "  COLD-COMPILE BUDGET: $COLD_N slice(s) start with NO build cache; at most $COLD_LIMIT of them compile
      at once — the adaptive width is PINNED (SAMEN_SABOTAGE_PARALLEL_ADAPT_SECS=0, or COLD_MAX=$COLD_MAX
      leaves no room to rise). A wide cold start exhausts the MSYS fork path; each slice releases its
      slot as soon as its own cache is built, so the pool refills to --jobs $JOBS for the patch phase."
  fi
fi

echo "  TEST-RESOURCE AUDIT: $HAZARD_N fixed-resource test file(s) run in more than one slice"

if [[ $LIST_ONLY -eq 1 ]]; then
  echo ""
  echo "SABOTAGE PARALLEL SELECTION: $TOTAL_N of $TOTAL_M patches across $SLICE_N slice(s) (dry-run — nothing applied, no tree created)"
  echo "  per-slice databases: $(cut -f6 "$WORK/plan" | sort -u | tr '\n' ' ')"
  echo "  reclaim them with: $(cut -f6 "$WORK/plan" | sort -u | sed 's/^/dropdb --if-exists /' | tr '\n' ';' | sed 's/;$//')"
  exit 0
fi

# ── driver lock (the per-slice locks keep slices apart; this keeps DRIVERS apart) ──
mkdir -p "$PARALLEL_ROOT" || fail "cannot create $PARALLEL_ROOT"
if mkdir "$DRIVER_LOCK" 2>/dev/null; then
  LOCK_HELD=1
  {
    printf 'pid:     %s\n' "$$"
    printf 'started: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown)"
    printf 'script:  %s\n' "${BASH_SOURCE[0]}"
  } > "$DRIVER_LOCK/holder" 2>/dev/null || true
else
  echo ""
  echo "!! another parallel certification run holds the per-slice replay trees:"
  sed 's/^/!!   /' "$DRIVER_LOCK/holder" 2>/dev/null || echo "!!   (no holder information)"
  fail "a run is in progress at $PARALLEL_ROOT. If none is (a run killed mid-flight leaves the lock), remove $DRIVER_LOCK and re-run."
fi

mkdir -p "$LOG_DIR" || fail "cannot create $LOG_DIR"

# ── warm-start the new slices' build caches (before any slice is launched) ────
# Pure copying: no patch is applied, no suite runs, nothing in the MAIN checkout is touched. The
# target is removed first so a failed copy can never leave a half-seeded cache behind that mix
# might trust; a failure falls back to compiling from scratch for that slice only (correct, just
# slower) rather than failing the run — the seed is an optimisation, never a correctness input.
if [[ -s "$WORK/seeds" ]]; then
  echo "==> warm-starting $SEED_N new slice build cache(s) from sibling slices (copy + manifest normalisation; no patch is applied and no test runs)"
  : > "$WORK/seeded_ok"
  while IFS=$'\t' read -r id cand app db why; do
    [[ -n "$id" ]] || continue
    tgt="$PARALLEL_ROOT/$id/build/$app"
    man="$tgt/lib/$app/.mix/compile.elixir"
    started="$(date +%s)"
    rm -rf "$tgt"
    mkdir -p "$(dirname "$tgt")" || fail "cannot create $(dirname "$tgt")"
    if ! cp -a "$cand" "$tgt" 2>/dev/null || [[ ! -f "$man" ]]; then
      rm -rf "$tgt"
      echo "    !! $id: seeding from $cand failed — this slice compiles from scratch (correct, just slower)"
      continue
    fi
    # A copied cache is INVALID in a new tree until its manifest is repointed (root, the per-slice
    # test DB, the timestamps): see scripts/sabotage_seed_manifest.exs. Without this the slice
    # recompiles its whole app anyway and the copy buys only the deps. The rewrite is refused
    # loudly rather than half-applied, and a refusal is just a slower (never wrong) slice.
    src_rel="${cand#$PARALLEL_ROOT/}"; src_stem="${src_rel%%/*}"
    if norm_out="$(elixir "$REPO_ROOT/scripts/sabotage_seed_manifest.exs" "$man" "$src_stem" "$id" "$db" 2>&1)" \
       && grep -q 'seed-manifest: ok' <<<"$norm_out"; then
      printf '%s\t%s\t%s\n' "$id" "${cand#$PARALLEL_ROOT/}" "$why" >> "$WORK/seeded_ok"
      # The copy CARRIES the source's patched-then-reverted modules, so it is exactly as dirty as the
      # source was: inherit the count, or the next run would offer this root as "pristine" while its
      # cache still holds artifacts built from patched sources. A pristine source leaves no marker,
      # so the target stays clean by simply not getting one.
      # (test -r first: a missing `<` file is a redirection error that 2>/dev/null does NOT swallow)
      if [[ -r "$PARALLEL_ROOT/$src_stem/replayed-patches" ]]; then
        src_prev="$(tr -dc '0-9' < "$PARALLEL_ROOT/$src_stem/replayed-patches" | head -c 9)"
        [[ "$src_prev" =~ ^[0-9]+$ ]] && (( src_prev > 0 )) \
          && printf '%s\n' "$src_prev" > "$PARALLEL_ROOT/$id/replayed-patches"
      fi
      echo "    $id <- ${cand#$PARALLEL_ROOT/} [$why]  ($(( $(date +%s) - started ))s copy+normalise)"
      echo "        $(sed -n 's/^seed-manifest: ok /manifest /p' <<<"$norm_out") — reuse is digest-verified, so a patched source still recompiles"
    else
      rm -rf "$tgt"
      echo "    !! $id: the manifest normaliser REFUSED the copy from $cand — this slice compiles from scratch (correct, just slower)"
      sed 's/^/       /' <<<"${norm_out:-seed-manifest: (no output)}" | tail -2
    fi
  done < "$WORK/seeds"
fi

# ── the structural preflight, ONCE (it is read-only and idempotent) ──────────
# Every slice would otherwise repeat it (~3 minutes each) before its first patch.
skip_slice_preflight=0
for a in ${HARNESS_ARGS[@]+"${HARNESS_ARGS[@]}"}; do
  [[ "$a" == "--no-preflight" ]] && skip_slice_preflight=1
done
if [[ $skip_slice_preflight -eq 1 ]]; then
  echo "==> structural preflight: SKIPPED (--no-preflight — the caller already ran it)"
else
  echo "==> structural preflight (once, before any slice starts)"
  bash "$REPO_ROOT/scripts/sabotage_preflight.sh" \
    || fail "structural preflight failed (see above) — no patch was applied"
fi

# ── never read a previous run's evidence ────────────────────────────────────
# The aggregate judges every slice from its LOG and its STATUS FILE, so both must belong to THIS
# run: a slice this run never reached (a crash, a kill, a wedged driver) has to read as
# uncertified, not as whatever its predecessor happened to leave behind. Truncating up front makes
# that true by construction — a status file only reappears when a slice actually finishes.
while IFS=$'\t' read -r id _rest; do
  [[ -n "$id" ]] || continue
  rm -f "$LOG_DIR/$id.log" "$LOG_DIR/$id.status"
done < "$WORK/plan"

# ── launch the slices ───────────────────────────────────────────────────────
# Each slice gets its OWN replay root, so its worktree, its build cache and its lock are its own,
# plus its own --test-db, so its schema is its own. Its exit status goes to a file rather than
# through `wait -n` attribution, and a MISSING status file means the slice was killed — a failure,
# never a pass (a killed wrapper can still report 0).
#
# The pool polls instead of blocking on `wait -n` for one reason: a wedged child (see the fork
# burst above) would otherwise block the driver FOREVER, which is the one outcome an unattended
# certification must not have. Every poll reaps finished slices and kills stalled ones.
running=0
running_cold=0
launched=0
declare -A cold_slot=()   # slice id -> 1 while it occupies a cold-compile slot

# cold_gate <id> <app> — true when this slice must WAIT for a cold-compile slot. It asks the ROOT,
# not the plan: at launch time the seed copies are already applied, so a slice the seed plan warmed is
# warm here, and a seed that FAILED at application time (its copy was removed) is correctly counted as
# cold again rather than quietly let in. A slice that shares its root with nothing else and has no
# cache is the one that pays the startup burst, so it is the one that waits.
release_cold() { # release_cold <id> — give back this slice's cold slot, if it holds one
  [[ "${cold_slot[$1]:-0}" == "1" ]] || return 0
  cold_slot[$1]=0
  running_cold=$((running_cold - 1))
  cold_releases=$((cold_releases + 1))   # a cold compile finished: evidence a wider width can stand on
}
cold_gate() { # cold_gate <id> <app>
  [[ -d "$PARALLEL_ROOT/$1/build/$2" ]] && return 1   # warm: no cold slot needed
  (( COLD_LIMIT > 0 )) || return 1
  (( running_cold >= COLD_LIMIT ))
}

reap_slices() { # decrement for finished children; kill + mark the stalled ones
  local i pid id log mtime age
  for i in "${!SLICE_PIDS[@]}"; do
    pid="${SLICE_PIDS[$i]:-}"
    id="${SLICE_IDS[$i]:-}"
    [[ -n "$pid" && -n "$id" ]] || continue

    # The subshell's LAST action is writing the status file, so its presence — not `kill -0`,
    # which is also true for an unreaped zombie — is what says "this slice finished".
    if [[ -f "$LOG_DIR/$id.status" ]]; then
      wait "$pid" 2>/dev/null || true
      release_cold "$id"
      SLICE_PIDS[$i]=""; SLICE_IDS[$i]=""
      running=$((running - 1))
      continue
    fi

    log="$LOG_DIR/$id.log"
    mtime="$(stat -c %Y "$log" 2>/dev/null || echo 0)"
    age=$(( $(date +%s) - mtime ))
    if (( age > STALL_SECONDS )); then
      echo "  !! slice $id: no log growth for ${age}s (limit ${STALL_SECONDS}s) — killing it;"
      echo "     a wedged slice is a FAILURE, never a wait"
      kill "$pid" 2>/dev/null || true
      echo "stalled" > "$LOG_DIR/$id.status"
      release_cold "$id"
      SLICE_PIDS[$i]=""; SLICE_IDS[$i]=""
      running=$((running - 1))
      continue
    fi

    # A cold slice stops being a cold hog the moment its app is BUILT, not when it finishes: the
    # harness prints `restore: byte-exact` after every patch, so the FIRST one means the one-time
    # compile and that patch's suite are done and the root now holds a cache. Holding the slot until
    # the slice exits would serialise the rest of the fleet for nothing — this is what keeps the cold
    # budget from costing the whole run its width.
    if [[ "${cold_slot[$id]:-0}" == "1" ]] && grep -q 'restore: byte-exact' "$LOG_DIR/$id.log" 2>/dev/null; then
      release_cold "$id"
      echo "  cold slot released by $id — its app is built; the next cold slice may start"
    fi
  done
  # One adaptation epoch per reap. Cheap: the timer inside cold_adapt gates the actual probe, and a
  # reap only runs while the pool is full or gated — which is exactly when width matters.
  cold_adapt "$SECONDS"
}

while IFS=$'\t' read -r id app lo hi count db _pool; do
  [[ -n "$id" ]] || continue

  # Rolling pool: block until a slot frees (while still watching for wedged slices) — and, for a
  # slice that must cold-compile, until a cold slot frees too. Both are released by reap_slices, so a
  # wedged child can never leave the fleet waiting on either.
  while (( running >= JOBS )) || cold_gate "$id" "$app"; do
    sleep 5
    reap_slices
  done

  rm -f "$LOG_DIR/$id.status"
  # Mark this root BEFORE it runs: from here on its cache may hold artifacts built from patched
  # sources, so a later run must not treat it as a pristine seed source. Written here (not after the
  # fact) so a slice killed mid-flight is still marked — a torn, half-patched cache must never be
  # offered as the "clean" candidate. The marker sits beside the build dir, NOT inside it, so it is
  # not copied along with a cache.
  mkdir -p "$PARALLEL_ROOT/$id" 2>/dev/null || true
  mark="$PARALLEL_ROOT/$id/replayed-patches"
  prev=0
  [[ -r "$mark" ]] && { prev="$(tr -dc '0-9' < "$mark" | head -c 9)"; [[ "$prev" =~ ^[0-9]+$ ]] || prev=0; }
  printf '%s\n' "$(( prev + count ))" > "$mark"
  echo "==> slice: $id ($count patch(es), app $app, range ${lo}-${hi}, db $db) — tree $PARALLEL_ROOT/$id, log $LOG_DIR/$id.log"
  (
    # shellcheck disable=SC2086
    SAMEN_SABOTAGE_ROOT="$PARALLEL_ROOT/$id" bash "$HARNESS" --app "$app" --range "${lo}-${hi}" \
      --test-db "$db" ${SLICE_ARGS[@]+"${SLICE_ARGS[@]}"} --no-preflight > "$LOG_DIR/$id.log" 2>&1
    echo $? > "$LOG_DIR/$id.status"
  ) &
  SLICE_PIDS+=("$!")
  SLICE_IDS+=("$id")
  running=$((running + 1))
  launched=$((launched + 1))
  # Take a cold slot if this slice starts without a cache (checked now, before it can build one).
  if (( COLD_LIMIT > 0 )) && [[ ! -d "$PARALLEL_ROOT/$id/build/$app" ]]; then
    cold_slot[$id]=1
    running_cold=$((running_cold + 1))
    cold_launched=$((cold_launched + 1))
  fi

  # Spread the fork burst (no-op for the last slice).
  sleep "$STAGGER"
done < <(sort -t$'\t' -k5,5nr "$WORK/plan")

[[ $launched -gt 0 ]] || fail "no slice has any patch to run for [$FILTER_LABEL]"

# Drain (statuses come from the files, so no attribution is needed).
while (( running > 0 )); do
  sleep 5
  reap_slices
done
echo ""

# ── aggregate ───────────────────────────────────────────────────────────────
failed_slices=()
attempted=0
# Two different numbers, never conflated: `flips` counts CONFIRMATIONS (a patch with two MUST_FAIL
# lines confirms twice), while the verdict must count PATCHES — the harness's own line counts
# patches, and an aggregate that summed confirmations would overstate the sweep (the first version
# of this driver printed "5 of 334" for four patches, which is exactly the kind of inflated number
# a certification must never produce).
passed_confirmations=0
passed_patches=0
passed_slices=0
declare -A app_assigned=() app_passed=()
echo "SLICE VERDICTS"
while IFS=$'\t' read -r id app lo hi count db _pool; do
  [[ -n "$id" ]] || continue
  attempted=$((attempted + 1))
  app_assigned[$app]=$(( ${app_assigned[$app]:-0} + count ))
  log="$LOG_DIR/$id.log"
  reason=""
  status="$(cat "$LOG_DIR/$id.status" 2>/dev/null || echo missing)"
  # The slice's OWN failure line is the most useful thing to report: it names the real cause
  # ('another sabotage run holds the replay tree at …', a patch that did not apply, a suite that
  # passed under sabotage) where a generic "no verdict line" only says that something went wrong.
  slice_failure="$(grep -m1 '^SABOTAGE HARNESS: FAILED' "$log" 2>/dev/null | cut -c1-200)"
  flips="$(grep -c 'flip confirmed' "$log" 2>/dev/null || true)"
  restores="$(grep -c 'restore: byte-exact' "$log" 2>/dev/null || true)"
  verdict_line="$(grep -m1 '^SABOTAGE HARNESS: ALL PASSED' "$log" 2>/dev/null || true)"
  isolation="$(grep -m1 'main checkout: byte-exact' "$log" 2>/dev/null || true)"
  # The count the HARNESS reports having replayed must be the count this plan assigned the slice:
  # the post-run half of the coverage proof (a wrong chunk boundary shows up here, from the
  # harness's own output, not from this driver's arithmetic).
  replayed="$(printf '%s' "$verdict_line" | sed -n 's/^SABOTAGE HARNESS: ALL PASSED (\([0-9][0-9]*\) .*/\1/p')"
  db_line="$(grep -m1 '^SABOTAGE HARNESS: per-slice test DB — SAMEN_TEST_DB=' "$log" 2>/dev/null || true)"
  # Was this slice warm-started (its cache copied from a sibling before launch)? Reported in the
  # verdict so a reader can tell "the split got cheaper" from "the split paid a compile per slice".
  seed_src="$(awk -F'\t' -v id="$id" '$1 == id {print $2 ($3 ? " [" $3 "]" : "")}' "$WORK/seeded_ok" 2>/dev/null || true)"
  # MEMBERSHIP, not just the count: the patches this slice actually replayed must be exactly the
  # ones the plan assigned it. A count alone is not enough — a slice handed the WRONG --range can
  # select a different set of the same size (the caller's range overriding the chunk did exactly
  # that: two same-app slices both replayed patch 197, one patch each, and every count matched).
  expected_names="$(awk -F'\t' -v a="$app" -v lo="$lo" -v hi="$hi" \
    '$1 == a && $2 >= lo && $2 <= hi {print $3}' "$WORK/records" | sort)"
  # (`.patch`-suffixed matches only: the harness also prints `==> sabotage preflight: …` lines.)
  actual_names="$(grep -oE '^==> sabotage [^ ]+\.patch' "$log" 2>/dev/null | sed 's/^==> sabotage //' | sort || true)"

  # A non-numeric status is 'stalled' (the watchdog killed it) or 'missing' (its subshell died
  # mid-launch, e.g. the fork burst) — a slice that never completed is a FAILURE, never a pass,
  # even though a killed wrapper can still leave a zero status behind.
  if [[ "$status" == "0" ]]; then :
  elif [[ "$status" =~ ^[0-9]+$ ]]; then reason="exit status $status"
  else reason="the slice never completed (status: $status)"
  fi
  [[ -n "$verdict_line" ]] || reason="${reason:+$reason; }no 'SABOTAGE HARNESS: ALL PASSED' verdict line in the log"
  [[ -n "$db_line" ]] || reason="${reason:+$reason; }the log never announced its per-slice test DB (SAMEN_TEST_DB=$db)"
  [[ "$flips" -ge "$count" ]] || reason="${reason:+$reason; }$flips confirmed flip(s) for $count patch(es)"
  [[ "$replayed" == "$count" ]] || reason="${reason:+$reason; }the harness replayed ${replayed:-?} patch(es) but this slice was assigned $count (wrong chunk boundary?)"
  [[ "$actual_names" == "$expected_names" ]] \
    || reason="${reason:+$reason; }the slice replayed a different patch SET than the plan assigned (expected: $(printf '%s' "$expected_names" | tr '\n' ' '); replayed: $(printf '%s' "$actual_names" | tr '\n' ' '))"
  [[ -n "$isolation" ]] || reason="${reason:+$reason; }the slice never asserted 'main checkout: byte-exact'"

  # A slice can die of the HOST rather than of its patch: under a wide cold start the MSYS fork path
  # gives out (see COLD_LIMIT) and bash exits having written nothing to the slice's log, which reads
  # exactly like a patch whose suite failed. A slice that announced NO patch at all therefore says
  # nothing about its patches, and is named as a host-level death with where to look — the fork
  # warning is in the DRIVER's log, not necessarily in the slice's, so it is not required here.
  if [[ -z "$verdict_line" && -z "$actual_names" ]]; then
    reason="HOST-LEVEL DEATH before any patch was replayed — this says nothing about the patch(es) ${lo}-${hi}; on this box the known causes are a wide cold start exhausting the MSYS fork path (lower --jobs, or SAMEN_SABOTAGE_PARALLEL_COLD_LIMIT) and Postgres being unavailable. ${reason:-unknown}"
  fi

  if [[ -z "$reason" && -n "$slice_failure" ]]; then
    reason="$slice_failure"
  fi

  if [[ -z "$reason" ]]; then
    printf '  %-16s %4s/%-4s ALL PASSED   (%s named-test confirmation(s), %s byte-exact restore(s), db %s)%s\n' \
      "$id" "$count" "$count" "$flips" "$restores" "$db" "${seed_src:+, seeded from $seed_src}"
    passed_confirmations=$((passed_confirmations + flips))
    passed_patches=$((passed_patches + count))
    passed_slices=$((passed_slices + 1))
    app_passed[$app]=$(( ${app_passed[$app]:-0} + count ))
  else
    printf '  %-16s %4s/%-4s FAILED       %s\n' "$id" "$count" "$count" "$reason"
    failed_slices+=("$id ($reason; log: $LOG_DIR/$id.log)")
  fi
done < <(sort -t$'\t' -k5,5nr "$WORK/plan")

# Per-app coverage, recomputed from the slices' own replayed counts: app by app, what ran equals
# what the harness selected for that app.
uncovered=""
while IFS=$'\t' read -r app count; do
  [[ -n "$app" ]] || continue
  got="${app_passed[$app]:-0}"
  if (( got != count )); then
    uncovered="${uncovered}${app} (${got}/${count}); "
  fi
done < "$WORK/apps"
if [[ -n "$uncovered" ]]; then
  failed_slices+=("per-app coverage: $uncovered")
fi

if [[ ${#failed_slices[@]} -gt 0 ]]; then
  echo ""
  for f in "${failed_slices[@]}"; do echo "  !! $f"; done
  fail "${#failed_slices[@]} problem(s) across $attempted slice(s) — a slice that was killed mid-flight lands here too (it has no verdict line)"
fi

echo ""
echo "  every slice asserted the main checkout byte-exact; per-slice trees live under $PARALLEL_ROOT"
echo "  per-slice databases (kept warm for reruns): $(cut -f6 "$WORK/plan" | sort -u | tr '\n' ' ')"
echo "  reclaim them with: $(cut -f6 "$WORK/plan" | sort -u | sed 's/^/dropdb --if-exists /' | tr '\n' ';' | sed 's/;$//')"
# The width the run ACTUALLY used, when it was not the one it was handed: a certification that
# silently self-tuned and did not say so would be reporting a number nobody can reproduce.
if (( COLD_LIMIT_START != COLD_LIMIT || COLD_RAISES > 0 || COLD_DEMOTES > 0 )); then
  cold_note=""
  (( COLD_FROZEN == 1 )) && cold_note="; frozen after pressure"
  echo "  cold width: started $COLD_LIMIT_START, ended $COLD_LIMIT ($COLD_RAISES rise(s), $COLD_DEMOTES lowering(s)${cold_note})"
fi
echo ""
if [[ -n "$FILTER_LABEL" ]]; then
  echo "SABOTAGE HARNESS (PARALLEL): ALL PASSED ($passed_patches of $TOTAL_M sabotages — FILTERED: $FILTER_LABEL; $passed_slices slice(s), $passed_confirmations named-test confirmations)"
else
  echo "SABOTAGE HARNESS (PARALLEL): ALL PASSED ($passed_patches of $TOTAL_M sabotages flipped their named tests across $passed_slices slice(s); $passed_confirmations named-test confirmations, byte-exact restores)"
fi
echo "  reclaim the slices with: rm -rf \"$PARALLEL_ROOT\" && git -C \"$REPO_ROOT\" worktree prune"
