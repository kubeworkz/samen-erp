#!/usr/bin/env bash
# T107 — interrupt-proof harness for the gen_app-probe registry guard.
#
# Proves the fix for the recurring Phase-2 failure (T27, T28, T23): killing a gen_app
# probe mid-run (which mutates samen_core/priv/abbrev_registry.json to reserve the
# scratch app's abbrevs) used to leave the registry corrupted, requiring a manual
# `git checkout` to recover. scripts/gen_probe_guard.sh (sourced by both root ci.sh and
# this harness — same code, not a reimplementation) now snapshots the registry to a
# `mktemp`'d file before each probe and restores + SHA-256-verifies it in a trap covering
# SIGINT/SIGTERM/ERR/EXIT.
#
# Because this environment has no working process-group job control (`set -m` fails: "can't
# change option: -m"), the harness locates the REAL target process directly — it walks the
# process tree from the launcher's PID down to the `beam.smp` (BEAM VM) descendant the
# `mix run` chain execs into, and signals THAT PID specifically. This is deliberately
# surgical: it never touches any other process on the machine, only the one descendant
# chain this harness itself launched.
#
# WRAPPED (positive) case: launches `run_gen_probe` (from gen_probe_guard.sh — the exact
# code root ci.sh runs) in a background `bash -c`, polls the registry's SHA-256 until it
# diverges from pristine (the mutation window is open), sends the requested signal
# directly to the beam.smp descendant, and asserts the registry is restored byte-exact
# with zero residue from ITS OWN run. Residue is computed as "paths that appeared during
# this case": anything already present (a concurrent probe's scratch dir) is never swept or
# faulted, so the harness cannot delete another probe's app — the exact hazard the guard's
# own per-run scratch ownership removes.
#
# UNWRAPPED (negative control) case: launches the SAME probe with the raw pre-T107
# invocation shape (`mix run priv/gen_post_probe.exs`, no snapshot, no trap,
# SAMEN_T107_DISABLE_INNER_TRAP=1 to also disable the probe's own inner SIGTERM
# defense-in-depth) — i.e. exactly what ci.sh did before this task. Killing it mid-
# mutation MUST leave the registry corrupted. This is the anti-tautology proof: it shows
# the positive assertions above are not vacuous — they depend on gen_probe_guard.sh
# actually being wired in, and reproduce the real T27/T28/T23 failure when it isn't.
#
# Usage: scripts/interrupt_probe_test.sh
# Exit:  0 if all positive assertions pass AND the negative control shows real corruption;
#        non-zero + a FAIL line otherwise. Never leaves the repo dirty (registry is always
#        restored from an out-of-band backup before the script exits).

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY="$REPO_ROOT/samen_core/priv/abbrev_registry.json"
PROBE_REL="priv/gen_post_probe.exs"
MUTATION_TIMEOUT_S=30

# Portable SHA-256, same rule as gen_probe_guard.sh: Git Bash ships sha256sum but not the
# Perl-based shasum, and a missing hasher must FAIL the harness rather than leave every SHA
# empty (an empty-vs-empty comparison would report a vacuous "restored byte-exact").
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    echo "FATAL: no SHA-256 hasher (sha256sum/shasum) available — the T107 proof cannot run" >&2
    exit 1
  fi
}

# Every shape of gen-probe scratch dir a run can leave: the guard's per-run dir
# (`_gen_probe_scratch.*`, created by run_gen_probe and handed down as
# SAMEN_GEN_PROBE_SCRATCH) and the probes' own standalone `mktemp -d` dirs (what the raw
# pre-T107 negative control creates). The harness NEVER sweeps these by glob: it records
# the set present BEFORE each case and only faults/removes paths that appeared after, so a
# probe running concurrently elsewhere in the repo can never be deleted from here.
scratch_dirs_now() {
  ls -d "$REPO_ROOT"/_gen_*_scratch* 2>/dev/null || true
}

snapshot_files_now() {
  ls "${TMPDIR:-/tmp}"/samen_ci_registry_snapshot.* 2>/dev/null || true
}

# record_pre <list-file>: snapshot the current scratch/snapshot paths.
record_pre() {
  { scratch_dirs_now; snapshot_files_now; } | sort -u >"$1"
}

# new_since <pre-list-file>: paths present now but not in <pre-list-file>.
new_since() {
  local pre="$1" p
  { scratch_dirs_now; snapshot_files_now; } | sort -u | while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    grep -Fxq "$p" "$pre" || printf '%s\n' "$p"
  done
}

# cleanup_own_residue <newline-separated paths>: remove only paths THIS harness observed
# appear during its own case (never a pre-existing or concurrent run's dir).
cleanup_own_residue() {
  local p
  while IFS= read -r p; do
    [[ -z "$p" ]] && continue
    rm -rf "$p" 2>/dev/null || true
  done <<<"${1:-}"
}

OUTER_BACKUP="$(mktemp "${TMPDIR:-/tmp}/t107_harness_outer_backup.XXXXXX")"
cp "$REGISTRY" "$OUTER_BACKUP"
PRISTINE_SHA="$(sha256 "$REGISTRY")"
[[ -n "$PRISTINE_SHA" ]] || { echo "FATAL: empty pristine SHA" >&2; exit 1; }

pass_count=0
fail_count=0

note() { echo "== $* =="; }
ok() { echo "PASS: $*"; pass_count=$((pass_count + 1)); }
bad() { echo "FAIL: $*"; fail_count=$((fail_count + 1)); }

restore_outer_backup() {
  cp "$OUTER_BACKUP" "$REGISTRY"
}

# find_beam_descendant <root-pid>: walks the process tree from <root-pid> down (following
# the first child at each level — this launcher's chain is strictly linear: bash -c ->
# [subshell ->] mix -> elixir -> erl -> beam.smp) looking for the beam.smp VM process.
# Prints its PID and returns 0, or returns 1 if not found within 6 hops.
#
# NOTE: this proof requires POSIX process-tree visibility and POSIX signal delivery into
# the BEAM (`ps -o`, `pgrep`, a `beam.smp` argv). Git Bash for Windows has none of the
# three (no pgrep, `ps` without -o, and the VM is a native `erl.exe` that `kill` cannot
# signal), so this harness is a Linux-runner proof; on Windows it fails closed at "could
# not locate" rather than pretending to have interrupted anything.
find_beam_descendant() {
  local pid="$1"
  local hop
  for hop in 1 2 3 4 5 6; do
    local cmd
    cmd="$(ps -o command= -p "$pid" 2>/dev/null)"
    if [[ "$cmd" == *beam.smp* ]]; then
      echo "$pid"
      return 0
    fi
    local kids
    kids="$(pgrep -P "$pid" 2>/dev/null)"
    if [[ -z "$kids" ]]; then
      return 1
    fi
    pid="$(echo "$kids" | head -1)"
  done
  return 1
}

# wait_for_mutation <launcher-pid>: polls the registry's SHA-256 until it diverges from
# pristine (up to MUTATION_TIMEOUT_S), or fails if the launcher exits first.
wait_for_mutation() {
  local launcher_pid="$1"
  local waited_ms=0
  while :; do
    if ! kill -0 "$launcher_pid" 2>/dev/null; then
      return 1
    fi
    local cur_sha
    cur_sha="$(sha256 "$REGISTRY")"
    if [[ "$cur_sha" != "$PRISTINE_SHA" ]]; then
      echo "  (mutation window open after ~${waited_ms}ms — registry sha now $cur_sha)"
      return 0
    fi
    sleep 0.05
    waited_ms=$((waited_ms + 50))
    if [[ "$waited_ms" -gt $((MUTATION_TIMEOUT_S * 1000)) ]]; then
      return 1
    fi
  done
}

LAST_FINAL_SHA=""
LAST_RESIDUE=""
LAST_PRE_LIST=""

# run_wrapped_and_kill <signal>: the POSITIVE case — via scripts/gen_probe_guard.sh's
# run_gen_probe, exactly as root ci.sh invokes it.
run_wrapped_and_kill() {
  local signal="$1"
  restore_outer_backup
  LAST_PRE_LIST="$(mktemp "${TMPDIR:-/tmp}/t107_pre_scratch.XXXXXX")"
  record_pre "$LAST_PRE_LIST"

  bash -c "REPO_ROOT='$REPO_ROOT'; source '$REPO_ROOT/scripts/gen_probe_guard.sh'; run_gen_probe '$PROBE_REL' 'T107 interrupt harness (wrapped)'" &
  local launcher_pid=$!

  if ! wait_for_mutation "$launcher_pid"; then
    bad "$signal (wrapped): registry never mutated within ${MUTATION_TIMEOUT_S}s, or the launcher exited early"
    wait "$launcher_pid" 2>/dev/null
    return 1
  fi

  local beam_pid
  beam_pid="$(find_beam_descendant "$launcher_pid")"
  if [[ -z "$beam_pid" ]]; then
    bad "$signal (wrapped): could not locate the beam.smp descendant to signal"
    # Do not orphan a mutating BEAM: hand the signal to the launcher (the guard traps it and
    # restores the registry), give it a moment, then SIGKILL as a last resort.
    kill -s "$signal" "$launcher_pid" 2>/dev/null || true
    sleep 1
    kill -SIGKILL "$launcher_pid" 2>/dev/null || true
    wait "$launcher_pid" 2>/dev/null
    return 1
  fi

  echo "  (signaling beam.smp pid=$beam_pid with $signal)"
  kill -s "$signal" "$beam_pid"
  wait "$launcher_pid" 2>/dev/null
  echo "  (launcher exited)"

  LAST_FINAL_SHA="$(sha256 "$REGISTRY")"
  LAST_RESIDUE="$(new_since "$LAST_PRE_LIST")"
}

# run_unwrapped_and_kill <signal>: the NEGATIVE CONTROL — the raw pre-T107 invocation
# shape (no snapshot, no outer trap, inner SIGTERM defense-in-depth also disabled via
# SAMEN_T107_DISABLE_INNER_TRAP=1) — proves killing mid-mutation WITHOUT the T107 guard
# really does corrupt the registry (anti-tautology for the positive results above).
run_unwrapped_and_kill() {
  local signal="$1"
  restore_outer_backup
  LAST_PRE_LIST="$(mktemp "${TMPDIR:-/tmp}/t107_pre_scratch.XXXXXX")"
  record_pre "$LAST_PRE_LIST"

  bash -c "cd '$REPO_ROOT/samen_core' && SAMEN_T107_DISABLE_INNER_TRAP=1 mix run '$PROBE_REL'" &
  local launcher_pid=$!

  if ! wait_for_mutation "$launcher_pid"; then
    bad "$signal (unwrapped negative control): registry never mutated within ${MUTATION_TIMEOUT_S}s, or the launcher exited early"
    wait "$launcher_pid" 2>/dev/null
    return 1
  fi

  local beam_pid
  beam_pid="$(find_beam_descendant "$launcher_pid")"
  if [[ -z "$beam_pid" ]]; then
    bad "$signal (unwrapped negative control): could not locate the beam.smp descendant to signal"
    kill -s "$signal" "$launcher_pid" 2>/dev/null || true
    sleep 1
    kill -SIGKILL "$launcher_pid" 2>/dev/null || true
    wait "$launcher_pid" 2>/dev/null
    return 1
  fi

  echo "  (signaling beam.smp pid=$beam_pid with $signal)"
  kill -s "$signal" "$beam_pid"
  wait "$launcher_pid" 2>/dev/null
  echo "  (launcher exited)"

  LAST_FINAL_SHA="$(sha256 "$REGISTRY")"
  LAST_RESIDUE="$(new_since "$LAST_PRE_LIST")"
}

# --- 1/2. Positive proof: SIGINT then SIGTERM, T107 guard ENABLED ----------------------
for sig in SIGINT SIGTERM; do
  note "Positive test: kill mid-mutation with $sig (T107 guard ENABLED — run_gen_probe)"
  run_wrapped_and_kill "$sig"
  if [[ "$LAST_FINAL_SHA" == "$PRISTINE_SHA" ]]; then
    ok "$sig (wrapped): registry restored SHA-256 byte-exact ($LAST_FINAL_SHA)"
  else
    bad "$sig (wrapped): registry NOT byte-exact (pristine=$PRISTINE_SHA final=$LAST_FINAL_SHA)"
  fi
  if [[ -z "$LAST_RESIDUE" ]]; then
    ok "$sig (wrapped): zero scratch/snapshot residue"
  else
    bad "$sig (wrapped): residue left behind: $LAST_RESIDUE"
  fi
  if git -C "$REPO_ROOT" diff --stat -- samen_core/priv/abbrev_registry.json | grep -q .; then
    bad "$sig (wrapped): git diff shows a residual change to abbrev_registry.json"
  else
    ok "$sig (wrapped): git diff confirms no residual change to abbrev_registry.json"
  fi
  cleanup_own_residue "$LAST_RESIDUE"
  rm -f "$LAST_PRE_LIST"
done

# --- 3/4. Anti-tautology negative control: SIGINT then SIGTERM, guard DISABLED ---------
for sig in SIGINT SIGTERM; do
  note "Negative control: kill mid-mutation with $sig (T107 guard ABSENT — raw pre-T107 invocation)"
  run_unwrapped_and_kill "$sig"
  if [[ "$LAST_FINAL_SHA" != "$PRISTINE_SHA" ]]; then
    ok "$sig (unwrapped): registry IS corrupted without the guard (pristine=$PRISTINE_SHA final=$LAST_FINAL_SHA) — proves the positive results above are not a tautology"
  else
    bad "$sig (unwrapped): registry was unexpectedly still byte-exact without the guard — the positive proof above would be vacuous"
  fi
  cleanup_own_residue "$LAST_RESIDUE"
  rm -f "$LAST_PRE_LIST"
done

# Always leave the repo clean, regardless of how the negative control landed. Only paths
# this harness itself observed appearing are removed (see cleanup_own_residue).
restore_outer_backup
cleanup_own_residue "$LAST_RESIDUE"
rm -f "$OUTER_BACKUP" "$LAST_PRE_LIST"
final_check_sha="$(sha256 "$REGISTRY")"
if [[ "$final_check_sha" == "$PRISTINE_SHA" ]]; then
  echo "== harness teardown: registry confirmed byte-exact, residue swept =="
else
  echo "== harness teardown FATAL: could not restore registry after the negative control — MANUAL RECHECK REQUIRED ==" >&2
  exit 2
fi

echo ""
echo "== T107 interrupt-proof harness: $pass_count passed, $fail_count failed =="
if [[ "$fail_count" -gt 0 ]]; then
  exit 1
fi
exit 0
