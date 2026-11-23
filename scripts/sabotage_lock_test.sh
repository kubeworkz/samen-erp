#!/usr/bin/env bash
# scripts/sabotage_lock_test.sh — pins the replay-tree lock's STALE-HOLDER RECOVERY.
#
# WHY. A host-level interruption (SIGKILL, a closed terminal, a machine going to
# sleep) bypasses scripts/sabotage.sh's EXIT trap and leaves $SABOTAGE_ROOT/lock
# behind while its holder PID is dead. The next run — or a scripts/sabotage_parallel.sh
# slice — used to refuse to start, and the parallel driver reported that slice as a
# host-level death: the WHOLE sweep read as FAILED with 415 of 416 patches certified
# and the remaining patch never replayed (observed 2026-11-23 on the samen_postmark
# slice, whose lock named a dead serial PID). That is a host event masquerading as a
# patch failure, which is exactly what a certification must never do.
#
# WHAT THIS PROVES — against the REAL lock code (scripts/sabotage_lock.sh, sourced):
#   1. a free lock is acquired, and the holder names the acquiring process;
#   2. a lock whose recorded PID is DEAD (a reaped child, verified dead first) is
#      reclaimed: acquisition SUCCEEDS, the reclaim is reported as a lock event (not a
#      patch failure), and the new holder is the acquiring process;
#   3. a lock whose recorded PID is ALIVE still fails closed, is NOT reclaimed, and is
#      left byte-intact — the anti-tautology control: recovery fires on liveness, not
#      on the mere existence of a lock;
#   4. an EMPTY holder (a kill between `mkdir` and the holder write) is reclaimed after
#      the grace period rather than blocking forever.
# No DB, no replay tree, no patch: the lot runs in a few seconds.
#
# Usage: scripts/sabotage_lock_test.sh
# Exit:  0 only if all four hold.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB="$REPO_ROOT/scripts/sabotage_lock.sh"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/sabotage_lock_test.XXXXXX")"
trap 'rm -rf "$SCRATCH"' EXIT

pass_count=0
fail_count=0
note() { echo "== $* =="; }
ok() { echo "PASS: $*"; pass_count=$((pass_count + 1)); }
bad() { echo "FAIL: $*"; fail_count=$((fail_count + 1)); }

# The liveness probe and the holder parser are used by the assertions below; sourcing
# defines functions only (no top-level action), so the test judges the same predicate
# the harness does.
LOCK="" ; SABOTAGE_ROOT="" ; SHADOW=""
# shellcheck source=/dev/null
source "$LIB"

# acquire_in <root> — run the REAL acquire_lock in its own shell against <root> and
# print its output plus the acquiring pid. The subshell keeps a fail-closed case from
# ending this test.
acquire_in() {
  local root="$1"
  mkdir -p "$root"
  SABOTAGE_ROOT="$root" LOCK="$root/lock" SHADOW="$root/tree" \
  SAMEN_SABOTAGE_LOCK_GRACE="${SAMEN_SABOTAGE_LOCK_GRACE:-5}" \
  bash -c '
    set -uo pipefail
    fail() { echo "SABOTAGE HARNESS: FAILED — $*"; exit 1; }
    source "$1"
    LOCK_HELD=0
    acquire_lock
    echo "ACQUIRED pid=$$"
  ' _ "$LIB" 2>&1
}

# write_holder <lockdir> <pid>
write_holder() {
  mkdir -p "$1"
  printf 'pid:     %s\nhost:    test\nstarted: 2026-01-01T00:00:00Z\nscript:  test\n' "$2" > "$1/holder"
}

holder_pid_of() { # holder_pid_of <lockdir>
  sed -n 's/^pid:[[:space:]]*//p' "$1/holder" 2>/dev/null | head -n 1 | tr -d '[:space:]'
}

# ── 1. a free lock is acquired and the holder identifies the acquirer ────────
note "free lock"
ROOT1="$SCRATCH/free"
out1="$(acquire_in "$ROOT1")"
rc1=$?
acq1="$(sed -n 's/^ACQUIRED pid=//p' <<<"$out1")"
if [[ $rc1 -eq 0 && -n "$acq1" ]] && ! grep -q 'SABOTAGE HARNESS: FAILED' <<<"$out1"; then
  ok "a free replay-tree lock is acquired"
else
  echo "$out1" | sed 's/^/    /'
  bad "acquiring a free lock did not succeed (exit $rc1)"
fi
if [[ -n "$acq1" && "$(holder_pid_of "$ROOT1/lock")" == "$acq1" ]]; then
  ok "the holder names the acquiring process (pid $acq1)"
else
  bad "the holder does not name the acquiring process (want '$acq1', got '$(holder_pid_of "$ROOT1/lock")')"
fi

# ── 2. a DEAD holder is reclaimed and the run continues ─────────────────────
note "dead holder (host-level interruption)"
sh -c 'exit 0' & dead_pid=$!
wait "$dead_pid" 2>/dev/null
if lock_pid_alive "$dead_pid"; then
  bad "fixture pid $dead_pid still reads alive — the dead-holder case would be vacuous"
else
  ok "fixture pid $dead_pid is genuinely dead by the harness's own probe"
fi
ROOT2="$SCRATCH/dead"
write_holder "$ROOT2/lock" "$dead_pid"
out2="$(acquire_in "$ROOT2")"
rc2=$?
acq2="$(sed -n 's/^ACQUIRED pid=//p' <<<"$out2")"
if [[ $rc2 -eq 0 && -n "$acq2" ]]; then
  ok "a lock whose holder pid is dead is reclaimed — acquisition succeeds instead of failing the run"
else
  echo "$out2" | sed 's/^/    /'
  bad "a stale lock with a dead holder still blocked the run (exit $rc2)"
fi
if grep -q 'lock: reclaimed the replay-tree lock' <<<"$out2" \
   && grep -q 'not a patch failure' <<<"$out2"; then
  ok "the reclaim is reported as a lock event, explicitly not a patch failure"
else
  echo "$out2" | sed 's/^/    /'
  bad "the reclaim was not reported as a lock event / not distinguished from a patch failure"
fi
if [[ -n "$acq2" && "$(holder_pid_of "$ROOT2/lock")" == "$acq2" ]]; then
  ok "the reclaimed lock carries the new holder (pid $acq2), not the dead one"
else
  bad "the reclaimed lock still names the dead holder (want '$acq2', got '$(holder_pid_of "$ROOT2/lock")')"
fi

# ── 3. a LIVE holder still fails closed and is left untouched ───────────────
note "live holder (the fail-closed control)"
sleep 60 & live_pid=$!
ROOT3="$SCRATCH/live"
write_holder "$ROOT3/lock" "$live_pid"
cp "$ROOT3/lock/holder" "$SCRATCH/live_holder.before"
out3="$(acquire_in "$ROOT3")"
rc3=$?
if [[ $rc3 -ne 0 ]] && grep -q 'in use by another run' <<<"$out3"; then
  ok "a lock whose holder pid is alive still fails closed"
else
  echo "$out3" | sed 's/^/    /'
  bad "a live holder did not fail closed (exit $rc3)"
fi
if grep -q 'reclaimed' <<<"$out3"; then
  bad "a LIVE holder's lock was reclaimed — two runs could share one worktree"
else
  ok "a live holder's lock is never reclaimed"
fi
if cmp -s "$SCRATCH/live_holder.before" "$ROOT3/lock/holder" \
   && [[ "$(holder_pid_of "$ROOT3/lock")" == "$live_pid" ]]; then
  ok "the live run's lock is byte-intact after the refused acquisition"
else
  bad "the live run's lock was modified by the refused acquisition"
fi
kill "$live_pid" 2>/dev/null || true
wait "$live_pid" 2>/dev/null || true

# ── 4. an EMPTY holder is reclaimed after the grace period ──────────────────
note "empty holder (killed between mkdir and the holder write)"
ROOT4="$SCRATCH/empty"
mkdir -p "$ROOT4/lock"
out4="$(SAMEN_SABOTAGE_LOCK_GRACE=1 acquire_in "$ROOT4")"
rc4=$?
if [[ $rc4 -eq 0 ]] && grep -q 'lock: reclaimed the replay-tree lock' <<<"$out4"; then
  ok "an empty holder is reclaimed after the grace period instead of wedging forever"
else
  echo "$out4" | sed 's/^/    /'
  bad "an empty holder was not reclaimed after the grace period (exit $rc4)"
fi

echo ""
echo "sabotage-lock harness: $pass_count passed, $fail_count failed"
[[ $fail_count -eq 0 ]] || { echo "SABOTAGE LOCK HARNESS: FAILED"; exit 1; }
echo "SABOTAGE LOCK HARNESS: ALL PASSED"
