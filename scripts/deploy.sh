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
#   --local-gate is SPENDY: the gate is a sequence of INDEPENDENT tiers and costs ~90 minutes on a
#   Windows checkout — long enough that an operator waits it out instead of running it. So it
#   NARROWS by default: scripts/ci_tiers.sh derives the tier set from the diff and ci.sh runs only
#   those (SAMEN_CI_TIERS=<csv>), while the preflights and every cross-cutting verifier still run.
#
#   The baseline that makes narrowing SOUND is evidence, not an assumption: a tier may be skipped
#   only because the code it covers was already validated at the baseline commit. So the baseline
#   is the newest ancestor of the target for which CI itself concluded SUCCESS. If there is no such
#   ancestor — no gh, no network, no successful run, rewritten history — there is nothing to vouch
#   for and the FULL gate runs. `--since <ref>` replaces that with the operator's own attestation;
#   `--full-gate` ignores narrowing entirely.
#
#   A narrowed run is never dressed up as the full gate: ci.sh labels its verdict `TIER SUBSET`,
#   and this script logs which tiers were skipped and on what basis they could be skipped.
#
# NOT VERIFIED BY THIS SCRIPT: deploy-prod.sh's own server-side gates (health, migrations, smoke,
#   secrets) and its rollback. Those still run and still decide — this script adds no trust in them.
#
# Usage:
#   scripts/deploy.sh [--sha <sha>] [--local-gate] [--since <ref>] [--full-gate]
#                     [--host <user@host>] [--key <path>] [--pin-host-key] [--dry-run]
#
#   --sha <sha>       deploy this commit (default: origin/main after a fetch)
#   --local-gate      validate by running ./ci.sh here instead of reading CI's verdict
#   --since <ref>     with --local-gate: narrow against this baseline instead of the newest
#                     CI-validated ancestor (an attestation — you are vouching for it)
#   --full-gate       with --local-gate: run every tier; no narrowing
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
SINCE=""
FULL_GATE=0
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
    --since)
      [[ $# -ge 2 ]] || die "--since needs a value"
      SINCE="$2"
      shift 2
      ;;
    --full-gate)
      FULL_GATE=1
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

# Narrowing knobs are meaningless on the default gate (which reads CI's verdict for the EXACT
# sha, a full-gate result). Refuse rather than silently ignore them — a knob that does nothing
# while appearing to do something is how an operator talks themselves into a weaker gate.
if [ "$LOCAL_GATE" -eq 0 ]; then
  [ -z "$SINCE" ] || die "--since only applies to --local-gate (the default gate reads CI's verdict for the exact SHA — there is nothing to narrow)"
  [ "$FULL_GATE" -eq 0 ] || die "--full-gate only applies to --local-gate (the default gate is already CI's full gate)"
fi

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

# ci_validated_ancestor <sha> — the NEWEST ancestor of <sha> for which CI concluded SUCCESS, or
# nothing when there is nothing to vouch for (no gh, no network, no successful run, rewritten
# history). This is the only basis on which tiers may be skipped: a tier is skipped because CI
# validated the code it covers at this commit — never because we assume it still passes. Empty
# output is a REFUSAL to narrow, not an error, so it is returned on every path.
ci_validated_ancestor() {
  local target="$1" sha
  command -v gh >/dev/null 2>&1 || return 0
  [ -n "$SLUG" ] || return 0
  # Newest first, so the first one that turns out to be an ancestor is the newest ancestor.
  for sha in $(gh api "repos/$SLUG/actions/workflows/ci.yml/runs?status=success&per_page=50" \
    --jq '.workflow_runs[].head_sha' 2>/dev/null); do
    if git merge-base --is-ancestor "$sha" "$target" 2>/dev/null; then
      printf '%s' "$sha"
      return 0
    fi
  done
  return 0
}

if [ "$LOCAL_GATE" -eq 1 ]; then
  # Substituting the EXECUTOR, not the gate: require that what we are about to gate is what we are
  # about to deploy. A dirty tree or a different HEAD would validate something else entirely.
  DIRTY="$(git status --porcelain --untracked-files=no)"
  [ -z "$DIRTY" ] || die "--local-gate needs a clean tree — commit or stash first:
$DIRTY"
  HEAD_SHA="$(git rev-parse HEAD)"
  [ "$HEAD_SHA" = "$SHA" ] \
    || die "--local-gate gates the CHECKED-OUT commit, but HEAD is $(git rev-parse --short "$HEAD_SHA") and the target is $SHORT. Check out the target (git checkout $SHORT) or pass --sha $HEAD_SHA."

  # ── which tiers does THIS change actually need? ────────────────────────────────────────────
  # Same script, same commit: what changes is how many of its independent tiers run. The
  # baseline is derived (or attested) and the selector is allowed to refuse — see the header.
  GATE_SINCE="$SINCE"
  GATE_BASIS=""
  if [ "$FULL_GATE" -eq 1 ]; then
    GATE_BASIS=""
  elif [ -n "$GATE_SINCE" ]; then
    GATE_BASIS="--since $GATE_SINCE, as attested by the operator"
  else
    GATE_SINCE="$(ci_validated_ancestor "$SHA")"
    GATE_BASIS="the newest ancestor CI validated"
  fi

  TIERS="all"
  if [ "$FULL_GATE" -eq 0 ] && [ -n "$GATE_SINCE" ]; then
    log "gate: narrowing to $GATE_BASIS — the [ci-tiers] lines below are this decision's reasoning"
    TIERS="$(bash "$REPO_ROOT/scripts/ci_tiers.sh" --repo "$REPO_ROOT" --since "$GATE_SINCE" "$SHA")" || TIERS="all"
  fi
  [ -n "$TIERS" ] || TIERS="all"   # an empty answer is a refusal to narrow, never a subset

  if [ "$TIERS" = "all" ]; then
    GATE_ENV=""
    GATE_LABEL="the FULL gate"
    if [ "$FULL_GATE" -eq 1 ]; then
      log "gate: --full-gate — running the FULL gate (bash ./ci.sh) on $SHORT (~90 min)"
    else
      log "gate: no tier subset could be vouched for — running the FULL gate (bash ./ci.sh) on $SHORT (~90 min)"
    fi
  else
    GATE_ENV="$TIERS"
    GATE_LABEL="TIER SUBSET $TIERS"
    log "gate: running only the tiers this change needs (SAMEN_CI_TIERS=$TIERS) on $SHORT"
    log "gate: SKIPPED tiers are not re-run here; each is skipped because the baseline above already validated the code it covers."
  fi

  GATE_RC=0
  if [ -n "$GATE_ENV" ]; then
    SAMEN_CI_TIERS="$GATE_ENV" bash "$REPO_ROOT/ci.sh" || GATE_RC=$?
  else
    bash "$REPO_ROOT/ci.sh" || GATE_RC=$?
  fi
  [ "$GATE_RC" -eq 0 ] \
    || die "local ./ci.sh FAILED on $SHORT ($GATE_LABEL, exit $GATE_RC) — refusing to deploy an unvalidated commit"

  if [ "$GATE_ENV" = "" ]; then
    log "gate: local ./ci.sh PASSED on $SHORT ✔ (the full gate — no GitHub runner involved)"
  else
    log "gate: local ./ci.sh PASSED on $SHORT ✔ ($GATE_LABEL — not the full gate; no GitHub runner involved)"
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
