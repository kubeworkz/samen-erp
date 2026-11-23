#!/usr/bin/env bash
# scripts/sabotage_lock.sh — the replay-tree lock and its stale-holder recovery.
#
# WHY THIS IS A SOURCED LIBRARY. The lock's one failure mode that is NOT a patch
# failure is a HOST-LEVEL interruption — SIGKILL, a closed terminal, a machine
# going to sleep — which bypasses the harness's EXIT trap and leaves
# $SABOTAGE_ROOT/lock behind while its holder PID is dead. The next run used to
# refuse to start, and `scripts/sabotage_parallel.sh` reported the slice that hit
# it as a host-level death: a whole sweep read as FAILED with 415 of 416 patches
# certified and the missing one never replayed (observed 2026-11-23 on the
# samen_postmark slice, whose lock named a dead serial PID).
#
# The replay tree already RECOVERS from that class of interruption (residue in the
# throwaway worktree is reported and reset before the replay). The lock now recovers
# the same way: a holder PID that is no longer alive is reclaimed and the run
# continues. A holder that IS alive still fails closed — two runs sharing one
# worktree corrupt each other silently.
#
# Sourced by scripts/sabotage.sh (the real harness) and by
# scripts/sabotage_lock_test.sh (the DB-free regression), so the test exercises the
# exact code the harness runs rather than a reimplementation.
#
# Contract: the caller sets SABOTAGE_ROOT and LOCK, provides `fail <message...>`,
# and removes $LOCK on exit while LOCK_HELD=1.

# lock_holder_pid — the PID published by the run that created the lock, or empty.
lock_holder_pid() {
  sed -n 's/^pid:[[:space:]]*//p' "$LOCK/holder" 2>/dev/null | head -n 1 | tr -d '[:space:]'
}

# lock_pid_alive <pid> — `kill -0` is the POSIX liveness probe: success for a
# process this user may signal (alive), failure with ESRCH once it is gone. Anything
# that is not a positive integer is not a live holder. A RECYCLED pid reads as ALIVE
# on purpose: this probe may only ever err toward "held", because a false "dead" puts
# two runs on one worktree while a false "alive" costs one manual removal (the
# fail-closed message still names the recovery command).
lock_pid_alive() {
  [[ "${1:-}" =~ ^[1-9][0-9]*$ ]] || return 1
  kill -0 "$1" 2>/dev/null
}

# lock_write_holder <script-path> — publish this run's identity inside the lock it
# just created. The script is passed in because the writer lives one frame below the
# caller (a BASH_SOURCE lookup here would name this library, not the harness).
lock_write_holder() {
  {
    printf 'pid:     %s\n' "$$"
    printf 'host:    %s\n' "$(hostname 2>/dev/null || echo unknown)"
    printf 'started: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown)"
    printf 'script:  %s\n' "${1:-unknown}"
  } > "$LOCK/holder" 2>/dev/null || true
}

# lock_report_in_use — the holder identity, for the fail-closed path.
lock_report_in_use() {
  echo ""
  echo "!! the isolated replay tree is in use by another run:"
  sed 's/^/!!   /' "$LOCK/holder" 2>/dev/null || echo "!!   (no holder information)"
  echo "!!   tree: $SHADOW"
}

# acquire_lock — claim $LOCK, reclaiming a lock whose holder is gone.
#
# The claim is `mkdir` (atomic). mkdir and the holder write are two syscalls, so an
# EMPTY holder gets a short grace period before it is presumed dead: that is exactly
# the shape a run killed between the two syscalls leaves, but also the shape a
# just-started run has for a few milliseconds.
acquire_lock() {
  mkdir -p "$SABOTAGE_ROOT" || fail "cannot create the replay root $SABOTAGE_ROOT"

  if mkdir "$LOCK" 2>/dev/null; then
    LOCK_HELD=1
    lock_write_holder "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
    return 0
  fi

  local holder_pid grace i
  holder_pid="$(lock_holder_pid)"

  grace="${SAMEN_SABOTAGE_LOCK_GRACE:-5}"
  if [[ -z "$holder_pid" ]]; then
    i=0
    while (( i < grace )); do
      sleep 1
      i=$((i + 1))
      holder_pid="$(lock_holder_pid)"
      [[ -n "$holder_pid" ]] && break
    done
  fi

  if [[ -n "$holder_pid" ]] && lock_pid_alive "$holder_pid"; then
    lock_report_in_use
    fail "another sabotage run holds the replay tree at $SABOTAGE_ROOT (holder pid $holder_pid is still running). If that is wrong, remove $LOCK and re-run."
  fi

  # ── self-heal: the holder is gone (or never published a pid) ─────────────────
  # Renaming is the atomic step: only one reclaimer can move this lock aside. The
  # moved holder is re-checked because a LIVE run may have claimed the lock between
  # the probe above and this rename; such a run must win.
  local aside="$LOCK.stale.$$" moved_pid
  rm -rf "$aside"
  if mv "$LOCK" "$aside" 2>/dev/null; then
    moved_pid="$(sed -n 's/^pid:[[:space:]]*//p' "$aside/holder" 2>/dev/null | head -n 1 | tr -d '[:space:]')"
    if [[ -n "$moved_pid" && "$moved_pid" != "$holder_pid" ]] && lock_pid_alive "$moved_pid"; then
      if [[ ! -e "$LOCK" ]]; then mv "$aside" "$LOCK" 2>/dev/null || rm -rf "$aside"; else rm -rf "$aside"; fi
      lock_report_in_use
      fail "the replay tree was claimed by a live run while its stale lock was being reclaimed at $SABOTAGE_ROOT — nothing was replayed; re-run once that run finishes."
    fi
    echo "    lock: reclaimed the replay-tree lock at $SABOTAGE_ROOT — recorded holder pid ${holder_pid:-<none>} is no longer running (host-level interruption, not a patch failure)"
    rm -rf "$aside"
  fi

  if mkdir "$LOCK" 2>/dev/null; then
    LOCK_HELD=1
    lock_write_holder "${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"
    return 0
  fi

  lock_report_in_use
  fail "another sabotage run holds the replay tree at $SABOTAGE_ROOT. If no run is active, remove $LOCK and re-run."
}
