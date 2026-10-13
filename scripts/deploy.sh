#!/usr/bin/env bash
# scripts/deploy.sh — production deploy, OPERATOR side (the half that does not need a GitHub runner).
#
# WHY THIS EXISTS
#   .github/workflows/deploy.yml is the routine path — push → CI → deploy — but a workflow can only
#   run once GitHub hands it a runner. When the hosted pool is saturated, BOTH the CI job and the
#   deploy job sit `queued` with no runner assigned, and the release is blocked on infrastructure
#   that has nothing to do with the release (observed 2026-10-13: CI queued 17+ min with 0 running).
#   This script is the same deploy WITHOUT that dependency. It is not a second deploy
#   implementation: all of the real work — sync to the release commit, build, swap, health/migration/
#   smoke/secrets gates, automatic rollback — stays in scripts/deploy-prod.sh, which runs on the
#   server. This script only performs the ssh the workflow would perform, plus the gate check.
#
#   ssh ubuntu@65.109.232.89 "TARGET_SHA=<sha> bash -s" < scripts/deploy-prod.sh
#
# THE GATE (fail-honest: the deploy REFUSES to run without one of these two)
#   default       CI must have ALREADY passed for that exact SHA. Read from the GitHub API, which
#                 is always reachable and needs no runner — but it does need CI to have finished,
#                 so it cannot unblock a run stuck in the queue.
#   --local-gate  run the SAME gate CI runs (`bash ./ci.sh`) here, on that exact commit, and deploy
#                 only if it exits 0. This is the path that does not wait for a runner. It is a
#                 substitution of EXECUTOR, not of the gate: same script, same commit. It requires a
#                 clean tree at exactly the target commit, because gating anything else would prove
#                 nothing about what gets deployed.
#
#   There is deliberately no "deploy anyway" bypass: an unvalidated release is the exact thing the
#   gate exists to prevent. If you believe the gate is wrong, fix the gate.
#
# NOT VERIFIED BY THIS SCRIPT: deploy-prod.sh's own server-side gates (health, migrations, smoke,
#   secrets) and its rollback. Those still run and still decide — this script adds no trust in them.
#
# Usage:
#   scripts/deploy.sh [--sha <sha>] [--local-gate] [--host <user@host>] [--key <path>]
#                     [--pin-host-key] [--dry-run]
#
#   --sha <sha>       deploy this commit (default: origin/main after a fetch)
#   --local-gate      validate by running ./ci.sh here instead of reading CI's verdict
#   --host <target>   ssh target (default: $DEPLOY_HOST or ubuntu@65.109.232.89)
#   --key <path>      ssh identity file (default: none — use your agent/default keys)
#   --pin-host-key    append the host's pinned ed25519 key to known_hosts if it is missing
#   --dry-run         do the resolve + gate, print the exact command, then STOP (never connects)
#
# Exit: 0 deployed (or --dry-run reached the ssh step), non-zero otherwise.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY_HOST_DEFAULT="${DEPLOY_HOST:-ubuntu@65.109.232.89}"
# The same pinned host key the workflow trusts (single trust anchor, in two places on purpose: a
# deploy must not depend on the workflow file being readable to know who it is talking to).
PINNED_HOST_KEY='65.109.232.89 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDCica1GLo+FC+WEsWXNn5IFKLeZ63y3HJHAOFP+XkgO'

TARGET_SHA=""
LOCAL_GATE=0
HOST="$DEPLOY_HOST_DEFAULT"
KEY=""
PIN_HOST_KEY=0
DRY_RUN=0
START="$(date +%s)"

log() { printf '[deploy-operator %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() {
  log "FAIL: $*"
  exit 1
}

usage() {
  sed -n '/^# Usage:/,/^# Exit:/p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --sha)
      [[ $# -ge 2 ]] || die "--sha needs a value"
      TARGET_SHA="$2"
      shift 2
      ;;
    --local-gate)
      LOCAL_GATE=1
      shift
      ;;
    --host)
      [[ $# -ge 2 ]] || die "--host needs a value"
      HOST="$2"
      shift 2
      ;;
    --key)
      [[ $# -ge 2 ]] || die "--key needs a value"
      KEY="$2"
      shift 2
      ;;
    --pin-host-key)
      PIN_HOST_KEY=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "unknown argument: $1 (try --help)" ;;
  esac
done

[ -f "$REPO_ROOT/scripts/deploy-prod.sh" ] || die "not a samen checkout: $REPO_ROOT (no scripts/deploy-prod.sh)"

# ── 1. resolve the target commit ──────────────────────────────────────────────
cd "$REPO_ROOT"
git rev-parse --git-dir >/dev/null 2>&1 || die "$REPO_ROOT is not a git checkout"

if [ -z "$TARGET_SHA" ]; then
  log "no --sha given: fetching origin and deploying origin/main"
  git fetch --quiet origin || die "git fetch failed (network / remote)"
  TARGET_SHA="$(git rev-parse origin/main)" || die "could not resolve origin/main"
fi
git cat-file -e "$TARGET_SHA^{commit}" 2>/dev/null \
  || die "TARGET_SHA=$TARGET_SHA is not a commit in this checkout (fetch it first)"
SHA="$(git rev-parse "$TARGET_SHA^{commit}")"
SHORT="$(git rev-parse --short "$SHA")"
log "target: $SHORT ($(git log -1 --format=%s "$SHA"))"

# ── 2. the gate ───────────────────────────────────────────────────────────────
SLUG="$(git remote get-url origin 2>/dev/null |
  sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')"
[[ "$SLUG" == */* ]] || SLUG="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || true)"

if [ "$LOCAL_GATE" -eq 1 ]; then
  # Substituting the EXECUTOR, not the gate: require that what we are about to gate is what we are
  # about to deploy. A dirty tree or a different HEAD would validate something else entirely.
  DIRTY="$(git status --porcelain --untracked-files=no)"
  [ -z "$DIRTY" ] || die "--local-gate needs a clean tree — commit or stash first:
$DIRTY"
  HEAD_SHA="$(git rev-parse HEAD)"
  [ "$HEAD_SHA" = "$SHA" ] \
    || die "--local-gate gates the CHECKED-OUT commit, but HEAD is $(git rev-parse --short "$HEAD_SHA") and the target is $SHORT. Check out the target (git checkout $SHORT) or pass --sha $HEAD_SHA."

  log "gate: running the SAME gate CI runs (bash ./ci.sh) on $SHORT locally — this takes minutes"
  if bash "$REPO_ROOT/ci.sh"; then
    log "gate: local ./ci.sh PASSED on $SHORT ✔ (no GitHub runner involved)"
  else
    die "local ./ci.sh FAILED on $SHORT — refusing to deploy an unvalidated commit"
  fi
else
  [ -n "$SLUG" ] || die "cannot determine the GitHub repo (no origin remote, gh unavailable) — use --local-gate"
  command -v gh >/dev/null 2>&1 || die "gh is not installed, so CI's verdict cannot be read — use --local-gate"

  log "gate: asking GitHub for CI's verdict on $SHORT (no runner needed for this call)"
  VERDICT="$(gh api "repos/$SLUG/actions/workflows/ci.yml/runs?head_sha=$SHA&per_page=30" \
    --jq '[.workflow_runs[]] | sort_by(.created_at) | reverse | .[0] | "\(.conclusion // .status)|\(.id)|\(.created_at)"' 2>/dev/null)"
  [ -n "$VERDICT" ] || die "could not read CI runs for $SHORT from $SLUG (gh auth? network?) — use --local-gate"

  STATE="${VERDICT%%|*}"
  RUN_ID="$(printf '%s' "$VERDICT" | cut -d'|' -f2)"
  case "$STATE" in
    success)
      log "gate: CI run $RUN_ID concluded SUCCESS for $SHORT ✔"
      ;;
    null | "")
      log "gate: CI has produced no run for $SHORT yet (queued/not started)"
      die "CI has NOT validated $SHORT — a queued run means no runner was assigned. Re-run with --local-gate to run the same gate here instead of waiting for GitHub's pool."
      ;;
    queued | in_progress | requested | waiting | pending)
      log "gate: CI run $RUN_ID is still '$STATE' for $SHORT — it is waiting on a runner"
      die "CI has NOT validated $SHORT yet. Re-run with --local-gate to run the same gate here instead of waiting for GitHub's pool."
      ;;
    *)
      log "gate: CI run $RUN_ID concluded '$STATE' for $SHORT"
      die "CI did NOT pass for $SHORT. Fix the failure (or re-run CI), then deploy — an unvalidated release is what the gate is for."
      ;;
  esac
fi

# ── 3. transport: the same ssh the workflow performs ─────────────────────────
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15)
[ -n "$KEY" ] && SSH_OPTS+=(-i "$KEY")
if [ "$PIN_HOST_KEY" -eq 1 ]; then
  mkdir -p "$HOME/.ssh"
  if ! grep -qF "${PINNED_HOST_KEY%% *}" "$HOME/.ssh/known_hosts" 2>/dev/null; then
    printf '%s\n' "$PINNED_HOST_KEY" >> "$HOME/.ssh/known_hosts"
    log "pinned $HOST's ed25519 host key into ~/.ssh/known_hosts"
  else
    log "host key for $HOST already present in ~/.ssh/known_hosts"
  fi
fi

log "deploying $SHORT to $HOST via scripts/deploy-prod.sh (server-side build/gates/rollback)"
if [ "$DRY_RUN" -eq 1 ]; then
  log "--dry-run: stopping before ssh. Would run:"
  printf '  ssh %s %s "TARGET_SHA=%s bash -s" < scripts/deploy-prod.sh\n' \
    "${SSH_OPTS[*]}" "$HOST" "$SHA"
  log "gate satisfied for $SHORT; nothing was deployed"
  exit 0
fi

ssh "${SSH_OPTS[@]}" "$HOST" "TARGET_SHA=$SHA bash -s" < "$REPO_ROOT/scripts/deploy-prod.sh"
RC=$?
if [ "$RC" -ne 0 ]; then
  die "server-side deploy FAILED for $SHORT (exit $RC) — see the deploy log above; deploy-prod.sh rolls back on its own gates"
fi
log "DEPLOY OK — $SHORT in $(( $(date +%s) - START ))s (operator path, no GitHub runner used)"
