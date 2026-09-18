#!/usr/bin/env bash
# scripts/sabotage.sh — WS-E E2i.1 sabotage harness (gate automation).
#
# Replays every SHIPPED gate sabotage as a committed patch and proves each still
# FLIPS its named tests — the standing anti-tautology ritual of the E1.4/E2.3
# (and every earlier) adversarial gate, converted from by-hand judgment into
# permanent infrastructure. Every patch is applied to, and reverted from, a
# THROWAWAY GIT WORKTREE — never the main checkout (see ISOLATED REPLAY TREE
# below). For each scripts/sabotages/*.patch:
#
#   1. SHA-256 every file the patch touches (the byte-exact baseline),
#   2. apply the patch (git apply),
#   3. run `mix test <TEST_FILES>` in the patch's APP — the run MUST fail,
#   4. every MUST_FAIL substring MUST appear among the failed-test headers
#      (the named tests flipped — not just "something broke"),
#   5. revert (git apply -R) and re-SHA — byte-exact restore, zero residue.
#
# ── ISOLATED REPLAY TREE (why the main checkout can never be left dirty) ──────
# The harness used to apply a real patch to the SHARED checkout and revert it from
# `trap cleanup EXIT`. That trap survives a normal exit and SIGINT/SIGTERM, but NOT
# SIGKILL (a tool/`timeout` escalation, a closed terminal, a killed gate step) — and
# that is exactly how a sabotage reached main: patch 12-e5 (apikey-store-raw) was
# left applied in the working tree, where it looked like a legitimate edit, and
# `git add -A` committed it as if it were a fix. scripts/sabotage_residue.sh reports
# that state, but only once it exists. So the mutation no longer happens in the main
# checkout at all:
#
#   * every patch is applied to, and reverted from, a detached throwaway worktree of
#     the same repository at $SHADOW ($SAMEN_SABOTAGE_ROOT/tree, default
#     .sabotage/tree) — a SEPARATE working tree, so a hard kill can only ever leave
#     THAT dirty, and the main checkout keeps the bytes it had;
#   * that worktree is RESET at the start of every run (`reset --hard <main HEAD>` +
#     `clean -fdx`), so a killed run costs nothing and needs no manual recovery;
#   * the tests run FROM the worktree, sharing the main checkout's per-app `deps/`
#     via MIX_DEPS_PATH (re-fetching ~200 packages per app would be absurd) and using
#     a per-app mix build cache under $SAMEN_SABOTAGE_ROOT/build — which is what
#     keeps repeat runs as fast as the old in-place ones;
#   * the main checkout's WORKING STATE is replicated into it before the first patch
#     (tracked modifications as one `git diff HEAD` patch, untracked-but-not-ignored
#     files copied), so a filtered `--changed` run still certifies an in-flight batch
#     whose files are not committed yet; and per patch, every touched path is pinned
#     byte-for-byte to the main checkout's copy, so `git apply` sees exactly what it
#     would have seen in place;
#   * ignored local files (dev keystores, secrets) are deliberately NOT copied into the
#     replay tree — the targeted suites use per-run tmp keystores, and a future test that
#     needed an ignored fixture would fail LOUDLY rather than silently pass;
#   * a fingerprint of every touched path in the MAIN checkout is taken before the
#     replay and re-checked after it — the invariant this buys, asserted instead of
#     assumed;
#   * concurrent runs are excluded by a lock ($SAMEN_SABOTAGE_ROOT/lock); the failure
#     message names the recovery command.
#
# COST. The FIRST run compiles each app's deps and code into the isolated cache
# (measured on the reference box: ~5 min for samen_core, ~3 min for a small adapter
# app; the 7 apps the 308 patches target pay that once). Later runs are warm — a
# sabotaged `mix test` costs what it costs in place. Reclaim the space with
# `rm -rf .sabotage && git worktree prune`; the next run pays the cold compile again.
# `--list`/`--dry-run` creates none of it.
#
# Patch metadata lives in `# KEY: value` header lines inside each .patch
# (git apply ignores everything before the first `diff --git`):
#   APP:        the app dir to run tests in (samen_core | samen_web | ...)
#   TEST_FILES: space-separated test files (relative to APP) that hold the named tests
#   MUST_FAIL:  a substring of a test name that MUST be among the failures (repeatable)
#
# ── SELECTION / FILTER MODES (additive; DEFAULT no-arg run is UNCHANGED) ──────
# With no flags this replays ALL patches, in filename order, exactly as before.
# Flags narrow the set — a FILTERED run certifies ONLY its subset; total
# coverage still requires a full (unfiltered) run, which at 212 patches exceeds
# the 600s single tool-call ceiling and so must be run BACKGROUNDED or in
# `--app`/`--range` CHUNKS (see docs/adr/ADR-045 §4.2). Filters COMPOSE as an
# intersection.
#   --app <name>            only patches whose APP: header == <name>
#   --range <lo>-<hi>       only patches whose FILENAME number (the NNN in
#   --from <lo> --to <hi>     NNN-slug.patch — stable, matches how we say
#                             "sabotage 205") is in [lo,hi] INCLUSIVE. --from/
#                             --to are an alternate spelling; a lone --from is
#                             lo..∞, a lone --to is 0..hi.
#   --touching <path>...    only patches whose touched-file set (the +++ b/…
#   --touching-file <file>    paths) INTERSECTS the given repo-relative paths
#                             (or the newline-separated paths in <file>).
#   --changed [<ref>]       derive the touched set from the UNION of `git diff
#                             --name-only <ref>` and `git ls-files --others
#                             --exclude-standard` (default ref: origin/main if it
#                             exists, else HEAD~1) — "certify the sabotages
#                             relevant to my diff". Selects patches touching any
#                             changed file. The untracked half is LOAD-BEARING:
#                             `git diff` never lists new files, so without it a
#                             batch that ADDS a module + its sabotages selects
#                             NONE of them (the A3 247/248/249 miss). The banner
#                             says `changed=<ref>+untracked` so the union is
#                             visible in the run's own output.
#   --list, --dry-run       print the SELECTED patch set (name + resolved APP,
#                             and the count) and EXIT — no patch is applied and
#                             no test runs. Fast proof of what a filter will run.
#
# ── HEADER PREFLIGHT, WIRING, AND REQUIREMENTS ────────────────────────────────
# The header preflight (scripts/sabotage_lint.sh) ALWAYS runs over ALL patches,
# even on a filtered run: a missing APP/TEST_FILES/MUST_FAIL header anywhere is
# a latent bug (the "patch 67 missing header aborts silently" class), so it is
# checked regardless of which subset was selected.
#
# A filtered run's success line is deliberately DISTINCT from the full-harness
# line so a partial run can never be mistaken for full certification, e.g.
#   SABOTAGE HARNESS: ALL PASSED (97 of 212 sabotages — FILTERED: app=samen_web)
# vs the full-run line:
#   SABOTAGE HARNESS: ALL PASSED (212 sabotages flipped their named tests; byte-exact restores)
#
# Wiring: a permanent OPT-IN root ci.sh step, gated by SAMEN_SABOTAGE=1 (the
# WS-D generative probes run unconditionally; this one deliberately breaks the
# replay tree and re-runs targeted suites, so it is opt-in — gates run it
# explicitly). ci.sh invokes it with NO flags → the full run, unchanged. Direct
# invocation runs regardless of the env var.
#
# Later gates: add the new sabotage as a .patch here (headers + git diff),
# re-run this harness, and spend gate judgment ONLY on new vacuity hunting.
#
# Needs: local Postgres (the targeted suites are DB-backed) and a `mix deps.get`
# in each patched app's directory (the replay tree shares those deps). Exits
# non-zero on the first sabotage that fails to flip, fails to name its tests, or
# leaves residue — and on an unknown flag, an empty selection, or a replay tree it
# cannot isolate.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SABOTAGE_DIR="$REPO_ROOT/scripts/sabotages"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/samen_sabotage.XXXXXX")"

# The isolated replay tree + its per-app mix build cache (see ISOLATED REPLAY TREE
# above). Both PERSIST on purpose — the worktree is reset per run, and the build
# cache is what keeps repeat runs warm — so a killed run leaves nothing worse than
# a dirty REPLAY tree, which the next run resets.
SABOTAGE_ROOT="${SAMEN_SABOTAGE_ROOT:-$REPO_ROOT/.sabotage}"
SHADOW="$SABOTAGE_ROOT/tree"
BUILD_ROOT="$SABOTAGE_ROOT/build"
LOCK="$SABOTAGE_ROOT/lock"
LOCK_HELD=0

APPLIED_PATCH=""

cleanup() {
  # Never leave a sabotaged tree behind. The tree in question is the ISOLATED
  # worktree — the main checkout is never written — and even this revert is a
  # courtesy, since every run resets the replay tree before applying anything.
  if [[ -n "$APPLIED_PATCH" && -e "$SHADOW/.git" ]]; then
    echo "!! cleanup: reverting in-flight patch $APPLIED_PATCH in the replay tree"
    (cd "$SHADOW" && git apply -R "$APPLIED_PATCH") || true
  fi
  [[ "$LOCK_HELD" == "1" ]] && rm -rf "$LOCK"
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
  echo ""
  echo "SABOTAGE HARNESS: FAILED — $*"
  exit 1
}

usage() {
  echo "Usage: sabotage.sh [--app <name>] [--range <lo>-<hi> | --from <lo> --to <hi>]"
  echo "                   [--touching <path>... | --touching-file <file> | --changed [<ref>]]"
  echo "                   [--list | --dry-run]"
  echo ""
  # Marker-delimited (not line-numbered) so editing the header cannot silently
  # desynchronize the help text from the flags it documents.
  sed -n '/^# ── SELECTION \/ FILTER MODES/,/^# ── HEADER PREFLIGHT/p' "${BASH_SOURCE[0]}" \
    | sed '1d;$d;s/^# \{0,1\}//'
}

arg_err() {
  echo "sabotage.sh: $1" >&2
  echo "" >&2
  echo "Run 'sabotage.sh --list' to preview a selection, or see the header of this" >&2
  echo "script for the full flag reference." >&2
  exit 2
}

meta() { # meta <patch> <key> -> values, one per line
  sed -n "s/^# $2: //p" "$1"
}

# touched_paths <patch> -> repo-relative paths the patch writes, one per line.
# Normalizes the plain-diff `+++ b/path<TAB>timestamp` form (6 patches ship this
# way) down to the bare path — so the SHA baseline actually hashes a real file
# (not a tab-suffixed non-path that silently skips the check) AND so --touching
# matching compares clean repo-relative paths.
touched_paths() { # touched_paths <patch>
  sed -n 's|^+++ b/||p' "$1" | sed 's/\t.*//'
}

# sha_files <root> <listfile> <outfile> — one "<digest|ABSENT>  <path>" line per path.
# sha256sum on Linux/Git-Bash for Windows; shasum elsewhere. Same digest format.
# A path that does not exist is recorded as ABSENT rather than skipped: a patch that
# CREATES a file must leave it absent again after the revert, and silently skipping a
# missing path would make that half of the residue check vacuous.
sha_files() { # sha_files <root> <listfile> <outfile>
  : > "$3"
  local f digest
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if [[ ! -e "$1/$f" ]]; then
      printf 'ABSENT  %s\n' "$f" >> "$3"
      continue
    fi
    if command -v shasum >/dev/null 2>&1; then
      digest="$(shasum -a 256 "$1/$f")"
    else
      digest="$(sha256sum "$1/$f")"
    fi
    printf '%s  %s\n' "${digest%% *}" "$f" >> "$3"
  done < "$2"
}

# ── argument parsing ─────────────────────────────────────────────────────────
FILTER_APP=""
RANGE_LO=""
RANGE_HI=""
RANGE_ACTIVE=0
TOUCH_MODE=0
TOUCH_DESC=""
TOUCH_SET="$WORK/touch_set"
: > "$TOUCH_SET"
LIST_ONLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --app)
      shift; [[ $# -gt 0 ]] || arg_err "--app requires a name"
      FILTER_APP="$1"; shift ;;
    --range)
      shift; [[ $# -gt 0 ]] || arg_err "--range requires <lo>-<hi>"
      if [[ "$1" =~ ^([0-9]+)-([0-9]+)$ ]]; then
        RANGE_LO="${BASH_REMATCH[1]}"; RANGE_HI="${BASH_REMATCH[2]}"; RANGE_ACTIVE=1
      else
        arg_err "--range wants <lo>-<hi> (e.g. --range 200-212), got: $1"
      fi
      shift ;;
    --from)
      shift; [[ $# -gt 0 ]] || arg_err "--from requires a number"
      [[ "$1" =~ ^[0-9]+$ ]] || arg_err "--from wants a number, got: $1"
      RANGE_LO="$1"; RANGE_ACTIVE=1; shift ;;
    --to)
      shift; [[ $# -gt 0 ]] || arg_err "--to requires a number"
      [[ "$1" =~ ^[0-9]+$ ]] || arg_err "--to wants a number, got: $1"
      RANGE_HI="$1"; RANGE_ACTIVE=1; shift ;;
    --touching)
      shift
      [[ $# -gt 0 && "$1" != --* ]] || arg_err "--touching requires one or more repo-relative paths"
      local_paths=0
      while [[ $# -gt 0 && "$1" != --* ]]; do
        printf '%s\n' "$1" >> "$TOUCH_SET"; local_paths=$((local_paths + 1)); shift
      done
      TOUCH_MODE=1
      TOUCH_DESC="touching=${local_paths} path(s)" ;;
    --touching-file)
      shift; [[ $# -gt 0 ]] || arg_err "--touching-file requires a file"
      [[ -f "$1" ]] || arg_err "--touching-file: no such file: $1"
      grep -v '^[[:space:]]*$' "$1" >> "$TOUCH_SET" || true
      TOUCH_MODE=1
      TOUCH_DESC="touching-file=$(basename "$1")"; shift ;;
    --changed)
      shift
      changed_ref=""
      if [[ $# -gt 0 && "$1" != --* ]]; then changed_ref="$1"; shift; fi
      if [[ -z "$changed_ref" ]]; then
        if git -C "$REPO_ROOT" rev-parse --verify -q origin/main >/dev/null; then
          changed_ref="origin/main"
        else
          changed_ref="HEAD~1"
        fi
      fi
      git -C "$REPO_ROOT" rev-parse --verify -q "$changed_ref" >/dev/null \
        || arg_err "--changed: not a valid git ref: $changed_ref"
      # The changed set is the UNION of tracked modifications AND untracked-but-not-
      # ignored files. `git diff --name-only` lists ONLY tracked paths, so a batch that
      # ADDS files (a new lib module + the sabotages that target it) silently
      # under-selected: A3's own new patches 247/248/249 were missed by `--changed`
      # because their only touched files were brand-new, and a verifier trusting
      # `--changed` alone would have certified the batch without ever replaying them.
      # An under-selecting verifier primitive is worse than no primitive, so the union
      # is taken here (and reflected in --list and in the FILTERED banner below).
      git -C "$REPO_ROOT" diff --name-only "$changed_ref" >> "$TOUCH_SET"
      git -C "$REPO_ROOT" ls-files --others --exclude-standard >> "$TOUCH_SET"
      TOUCH_MODE=1
      TOUCH_DESC="changed=${changed_ref}+untracked" ;;
    --list|--dry-run)
      LIST_ONLY=1; shift ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      arg_err "unknown flag: $1" ;;
  esac
done

# Normalize a one-sided --from/--to into a full inclusive range.
if [[ $RANGE_ACTIVE -eq 1 ]]; then
  [[ -n "$RANGE_LO" ]] || RANGE_LO=0
  [[ -n "$RANGE_HI" ]] || RANGE_HI=999999
  if (( RANGE_LO > RANGE_HI )); then
    arg_err "--range/--from/--to: lo ($RANGE_LO) is greater than hi ($RANGE_HI)"
  fi
fi

FILTER_ACTIVE=0
[[ -n "$FILTER_APP" || $RANGE_ACTIVE -eq 1 || $TOUCH_MODE -eq 1 ]] && FILTER_ACTIVE=1

# Human-readable selection label (for the effective-selection line + success line).
filter_label() {
  local parts=()
  [[ -n "$FILTER_APP" ]] && parts+=("app=$FILTER_APP")
  [[ $RANGE_ACTIVE -eq 1 ]] && parts+=("range=${RANGE_LO}-${RANGE_HI}")
  [[ $TOUCH_MODE -eq 1 ]] && parts+=("$TOUCH_DESC")
  local IFS=', '
  echo "${parts[*]}"
}

# patch_touches <patch> — 0 if the patch's touched set intersects $TOUCH_SET.
patch_touches() {
  local pf
  while IFS= read -r pf; do
    [[ -n "$pf" ]] || continue
    grep -qxF "$pf" "$TOUCH_SET" && return 0
  done < <(touched_paths "$1")
  return 1
}

# select_patch <patch> — 0 if the patch passes EVERY active filter (intersection).
select_patch() {
  local patch="$1" name num n app
  name="$(basename "$patch")"

  if [[ -n "$FILTER_APP" ]]; then
    app="$(meta "$patch" APP)"
    [[ "$app" == "$FILTER_APP" ]] || return 1
  fi

  if [[ $RANGE_ACTIVE -eq 1 ]]; then
    num="${name%%-*}"
    [[ "$num" =~ ^[0-9]+$ ]] || return 1
    n=$((10#$num))
    (( n >= RANGE_LO && n <= RANGE_HI )) || return 1
  fi

  if [[ $TOUCH_MODE -eq 1 ]]; then
    patch_touches "$patch" || return 1
  fi

  return 0
}

# ── the isolated replay tree ─────────────────────────────────────────────────
# Nothing below ever runs `git apply`, `checkout`, `clean` or a test against
# $REPO_ROOT: the main checkout is read (diff/ls-files/hash) and never written.

# acquire_lock — fail closed when another run holds the replay tree. The lock can
# only survive a hard kill (the EXIT trap releases it), so the message also names
# the recovery; two runs sharing one worktree would corrupt each other silently.
acquire_lock() {
  mkdir -p "$SABOTAGE_ROOT" || fail "cannot create the replay root $SABOTAGE_ROOT"
  if mkdir "$LOCK" 2>/dev/null; then
    LOCK_HELD=1
    {
      printf 'pid:     %s\n' "$$"
      printf 'host:    %s\n' "$(hostname 2>/dev/null || echo unknown)"
      printf 'started: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || echo unknown)"
      printf 'script:  %s\n' "${BASH_SOURCE[0]}"
    } > "$LOCK/holder" 2>/dev/null || true
    return 0
  fi
  echo ""
  echo "!! the isolated replay tree is in use by another run:"
  sed 's/^/!!   /' "$LOCK/holder" 2>/dev/null || echo "!!   (no holder information)"
  echo "!!   tree: $SHADOW"
  fail "another sabotage run holds the replay tree at $SABOTAGE_ROOT. If no run is" \
       "active (a run killed mid-flight leaves the lock behind), remove $LOCK and re-run."
}

# shadow_reset <head-sha> — bring the replay tree to a pristine detached checkout of
# the main checkout's HEAD. Re-using the existing tree when it is still a worktree of
# this repository matters for SPEED, not just hygiene: `reset --hard` rewrites only the
# files that differ, so mix's cached compilation of unchanged sources stays valid (a
# fresh checkout would restamp every source mtime and recompile everything).
shadow_reset() { # shadow_reset <head-sha>
  if [[ -e "$SHADOW/.git" ]] && git -C "$SHADOW" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    if git -C "$SHADOW" reset --hard --quiet "$1" 2>/dev/null \
       && git -C "$SHADOW" clean -fdxq 2>/dev/null; then
      return 0
    fi
    echo "    replay tree: existing tree is unusable — recreating it"
  fi
  git -C "$REPO_ROOT" worktree prune 2>/dev/null || true
  rm -rf "$SHADOW"
  git -C "$REPO_ROOT" worktree add --detach --quiet "$SHADOW" "$1" \
    || fail "could not create the isolated replay tree at $SHADOW ('git worktree add' failed)"
  return 0
}

# replicate_working_state — the harness certifies the code a verifier is ABOUT to
# commit, not merely the last commit, so the main checkout's working state is copied
# into the replay tree: tracked modifications (staged and unstaged, one `git diff HEAD`
# patch) then untracked-but-not-ignored files. That union is exactly what `--changed`
# selects from, so a filtered run over an uncommitted batch still applies those
# patches to the bytes they were written against.
replicate_working_state() {
  local f
  git -C "$REPO_ROOT" diff HEAD --binary > "$WORK/main_state.patch"
  if [[ -s "$WORK/main_state.patch" ]]; then
    (cd "$SHADOW" && git apply --binary "$WORK/main_state.patch") \
      || fail "could not replicate the main checkout's tracked changes into $SHADOW"
  fi
  git -C "$REPO_ROOT" ls-files --others --exclude-standard > "$WORK/main_untracked"
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    [[ -f "$REPO_ROOT/$f" ]] || continue
    mkdir -p "$SHADOW/$(dirname "$f")" && cp -f "$REPO_ROOT/$f" "$SHADOW/$f" \
      || fail "could not replicate untracked file $f into $SHADOW"
  done < "$WORK/main_untracked"
}

# sync_touched_into_shadow <listfile> — pin the replay tree's copy of every touched
# path to the MAIN checkout's bytes (and delete it when the main checkout does not have
# it), so `git apply` inside the replay tree sees precisely what it would have seen in
# place — including ignored/untracked paths, and including a path a probe patch expects
# to be ABSENT.
sync_touched_into_shadow() { # sync_touched_into_shadow <listfile>
  local f
  while IFS= read -r f; do
    [[ -n "$f" ]] || continue
    if [[ -e "$REPO_ROOT/$f" ]]; then
      mkdir -p "$SHADOW/$(dirname "$f")" && cp -f "$REPO_ROOT/$f" "$SHADOW/$f" \
        || fail "could not sync $f into the replay tree"
    else
      rm -f "$SHADOW/$f"
    fi
  done < "$1"
}

prepare_replay_tree() {
  acquire_lock
  local head_sha leftover_only
  head_sha="$(git -C "$REPO_ROOT" rev-parse HEAD)" || fail "cannot resolve HEAD in $REPO_ROOT"

  # What the replay tree held BEFORE this run reset it. A previous run that was hard-
  # killed mid-patch leaves that patch applied HERE — a fact worth reporting, since it is
  # exactly the residue the main checkout used to be stuck with. It is compared below
  # against what working-state replication is expected to produce, so the harness's own
  # replicated state is never misreported as residue.
  : > "$WORK/shadow_before"
  if [[ -e "$SHADOW/.git" ]] && git -C "$SHADOW" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git -C "$SHADOW" status --porcelain 2>/dev/null > "$WORK/shadow_before" || true
  fi

  shadow_reset "$head_sha"
  replicate_working_state

  git -C "$SHADOW" status --porcelain 2>/dev/null | cut -c4- | sort -u > "$WORK/shadow_after" || true
  leftover_only="$(cut -c4- "$WORK/shadow_before" | sort -u \
    | grep -vxF -f "$WORK/shadow_after" | grep -v '^$' || true)"
  if [[ -n "$leftover_only" ]]; then
    echo "    replay tree: recovered residue from an interrupted run (reset before replay;"
    echo "                 the MAIN checkout was never written by it):"
    printf '%s\n' "$leftover_only" | head -5 | sed 's/^/                   /'
  fi
}

# ── header preflight ─────────────────────────────────────────────────────────
# ALWAYS lint ALL patches, even under a filter: a missing header anywhere is a
# latent bug (patch 67 shipped this way once and silently swallowed patches
# 68-75). Cheap (milliseconds, no git apply / mix test), so filtering never
# lowers this protection.
# Invoked via `bash`, never as the bare path: no *.sh in this repo carries the
# exec bit (the tree is authored on Windows, where core.filemode is false), so a
# direct invocation dies with "Permission denied" on a POSIX runner. This is the
# same form ci.sh and sabotage_selection_test.sh already use.
bash "$REPO_ROOT/scripts/sabotage_lint.sh" || fail "header preflight failed (see above) — no patch was applied"

# ── build the selection ──────────────────────────────────────────────────────
grand_total=0
selected=()
for patch in "$SABOTAGE_DIR"/*.patch; do
  [[ -e "$patch" ]] || continue
  grand_total=$((grand_total + 1))
  if select_patch "$patch"; then
    selected+=("$patch")
  fi
done
[[ $grand_total -gt 0 ]] || fail "no patches found in $SABOTAGE_DIR"
sel_count=${#selected[@]}

# ── --list / --dry-run: prove the selection, apply/run nothing ───────────────
if [[ $LIST_ONLY -eq 1 ]]; then
  if [[ $FILTER_ACTIVE -eq 1 ]]; then
    echo "SABOTAGE SELECTION (FILTERED: $(filter_label)) — $sel_count of $grand_total patches:"
  else
    echo "SABOTAGE SELECTION (default: full harness) — $sel_count of $grand_total patches:"
  fi
  if [[ $sel_count -gt 0 ]]; then
    for patch in "${selected[@]}"; do
      printf '  %-64s app=%s\n' "$(basename "$patch")" "$(meta "$patch" APP)"
    done
  fi
  echo ""
  echo "SABOTAGE SELECTION: $sel_count of $grand_total patches selected (dry-run — nothing applied)"
  exit 0
fi

# An empty selection certifies nothing — fail loudly (never a silent green).
if [[ $sel_count -eq 0 ]]; then
  fail "selection is empty ($sel_count of $grand_total) for filter [$(filter_label)] — nothing to certify"
fi

# Announce the effective selection at the start of any FILTERED run (the default
# full run stays byte-identical: it prints no such preamble).
if [[ $FILTER_ACTIVE -eq 1 ]]; then
  echo "SABOTAGE HARNESS: FILTERED run — $sel_count of $grand_total patches selected [$(filter_label)]"
  echo "  (a filtered run certifies ONLY this subset; full coverage needs an unfiltered/background run)"
fi

# ── the invariant, recorded before anything can touch the main checkout ──────
# Every path ANY selected patch touches, fingerprinted as the main checkout holds
# it right now, and re-fingerprinted after the replay. This is the whole point of
# the isolated tree, so it is asserted rather than argued.
for patch in "${selected[@]}"; do touched_paths "$patch"; done | sort -u > "$WORK/selected_paths"
[[ -s "$WORK/selected_paths" ]] || fail "could not parse the selected patches' touched paths"
sha_files "$REPO_ROOT" "$WORK/selected_paths" "$WORK/main_before"

# ── isolate the replay: throwaway worktree + per-app build cache ─────────────
prepare_replay_tree

# ── replay the selected patches ──────────────────────────────────────────────
total=0

for patch in "${selected[@]}"; do
  name="$(basename "$patch")"
  app="$(meta "$patch" APP)"
  test_files="$(meta "$patch" TEST_FILES)"
  [[ -n "$app" && -n "$test_files" ]] || fail "$name: missing APP/TEST_FILES header"
  meta "$patch" MUST_FAIL > "$WORK/must_fail"
  [[ -s "$WORK/must_fail" ]] || fail "$name: no MUST_FAIL headers"

  echo ""
  echo "==> sabotage $name (app: $app)"

  # 0. The patch acts on the replay tree only. Pin every path it touches to the
  #    main checkout's bytes first, so the apply sees exactly what it would have
  #    seen in place, then baseline those bytes.
  touched_paths "$patch" > "$WORK/touched"
  [[ -s "$WORK/touched" ]] || fail "$name: could not parse touched files"
  sync_touched_into_shadow "$WORK/touched"
  [[ -d "$REPO_ROOT/$app/deps" ]] || fail "$name: no deps/ in $REPO_ROOT/$app — run 'mix deps.get' there first (the replay tree runs against those deps)"
  [[ -d "$BUILD_ROOT/$app" ]] || echo "    replay tree: first run for $app — compiling its deps and code into $BUILD_ROOT/$app (one-time; later runs are warm)"

  # 1. Byte-exact baseline of every file the patch touches.
  sha_files "$SHADOW" "$WORK/touched" "$WORK/sha_before"

  # 2. Apply — inside the replay tree, never in the main checkout.
  (cd "$SHADOW" && git apply "$patch") || fail "$name: patch did not apply in the replay tree"
  APPLIED_PATCH="$patch"

  # 3. The targeted suite MUST fail under sabotage.
  out="$WORK/${name%.patch}.out"
  # shellcheck disable=SC2086
  (cd "$SHADOW/$app" && MIX_DEPS_PATH="$REPO_ROOT/$app/deps" \
     MIX_BUILD_PATH="$BUILD_ROOT/$app" mix test $test_files) > "$out" 2>&1
  status=$?

  # 5a. Revert before judging, so a failed assertion never strands a dirty tree.
  (cd "$SHADOW" && git apply -R "$patch") \
    || fail "$name: revert failed — the REPLAY tree is dirty (the next run resets it; the main checkout was never touched)"
  APPLIED_PATCH=""

  if [[ $status -eq 0 ]]; then
    tail -20 "$out"
    fail "$name: suite PASSED under sabotage — the guarantee did not flip (vacuous gate)"
  fi

  # 4. The NAMED tests are among the failures (not just any breakage).
  grep -E '^[[:space:]]*[0-9]+\) test' "$out" > "$WORK/failed_tests" || {
    tail -30 "$out"
    fail "$name: suite failed but no test-failure headers found (compile error?)"
  }

  while IFS= read -r must; do
    if grep -qF "$must" "$WORK/failed_tests"; then
      echo "    flip confirmed: $must"
    else
      cat "$WORK/failed_tests"
      fail "$name: named test did not flip: $must"
    fi
  done < "$WORK/must_fail"

  # 5b. Byte-exact restore — zero residue in the replay tree.
  sha_files "$SHADOW" "$WORK/touched" "$WORK/sha_after"
  diff -q "$WORK/sha_before" "$WORK/sha_after" > /dev/null ||
    fail "$name: SHA mismatch after revert — residue left behind"
  echo "    restore: byte-exact (sha-256 verified)"

  total=$((total + 1))
done

[[ $total -gt 0 ]] || fail "no patches replayed"

# ── the invariant, checked: the main checkout is byte-for-byte as we found it ─
sha_files "$REPO_ROOT" "$WORK/selected_paths" "$WORK/main_after"
if ! diff -q "$WORK/main_before" "$WORK/main_after" > /dev/null; then
  diff "$WORK/main_before" "$WORK/main_after" | head -20
  fail "the MAIN checkout changed while the replay ran — the isolation leaked"
fi
echo ""
echo "    main checkout: byte-exact ($(wc -l < "$WORK/selected_paths" | tr -d ' ') touched paths sha-256-unchanged) — every patch acted on the replay tree only"

echo ""
if [[ $FILTER_ACTIVE -eq 1 ]]; then
  echo "SABOTAGE HARNESS: ALL PASSED ($total of $grand_total sabotages — FILTERED: $(filter_label))"
else
  echo "SABOTAGE HARNESS: ALL PASSED ($total sabotages flipped their named tests; byte-exact restores)"
fi
echo "  replay tree + build cache kept warm at $SABOTAGE_ROOT (reclaim: rm -rf \"$SABOTAGE_ROOT\" && git -C \"$REPO_ROOT\" worktree prune)"
