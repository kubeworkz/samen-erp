#!/usr/bin/env bash
# scripts/deploy-prod.sh — production deploy for samenerp (server-side half).
#
# Runs ON the server, normally piped over ssh by .github/workflows/deploy.yml:
#
#   ssh ubuntu@65.109.232.89 "TARGET_SHA=<sha> bash -s" < scripts/deploy-prod.sh
#
# Can also be run by hand the same way for an emergency deploy.
#
# Contract:
#   * ALL code changes arrive via `git push` → CI → this script. Never edit the
#     server checkout by hand — every run resets the tree to TARGET_SHA and any
#     un-pushed server-side commit is discarded (a backup branch is cut first).
#   * Server-only secrets live in samenerp/.env.production.local (untracked,
#     gitignored). The tracked samenerp/.env.production holds placeholders only.
#   * TARGET_SHA must be a commit CI has already validated (the workflow passes
#     the workflow_run head_sha; workflow_dispatch passes github.sha).
#
# Gates (any failure after the container swap ⇒ automatic rollback to the
# :previous image, exit 1):
#   1. compose config resolves (env files present, YAML valid)
#   2. docker build succeeds (pre-swap ⇒ old container keeps serving)
#   3. container reaches healthz=healthy within 120s
#   4. "Migration and seed complete" printed AND max(schema_migrations) >=
#      newest migration file (the entrypoint swallows migrate errors — this
#      catches the archived_at class of bug before a human ever sees a 500)
#   5. smoke: /healthz=200, the five tenant surfaces answer 302/200 (never
#      404/500), app log free of Sent 500 / Postgrex / missing-column / crash
#   6. secrets actually loaded in the container (RESEND key + aud role)
#
# Fast paths: already-at-TARGET and healthy ⇒ skip. Changed files all match the
# docs/CI-only skip patterns ⇒ skip (no rebuild for README/docs/tooling edits).
set -euo pipefail

REPO="${REPO:-$HOME/samen-erp}"
APP_DIR="$REPO/samenerp"
CONTAINER="samenerp-app-1"
DB_CONTAINER="samenerp-db-1"
TARGET_SHA="${TARGET_SHA:-}"
START="$(date +%s)"
PHASE="sync" # sync → built → swapped — gates only roll back once swapped
SKIP_PATTERNS='(^docs/)|(^\.github/)|(^scripts/)|(^spec/)|(^_orch)|(^demo/)|(^driftwood/)|(\.md$)|(^samen_core/test/)|(^samen_web/test/)|(^samenerp/test/)'

log() { printf '[deploy %s] %s\n' "$(date -u +%H:%M:%S)" "$*"; }
die() {
  log "FAIL: $*"
  # Only roll back once the swap happened — before that the old container is
  # untouched and still serving (a failed build is a plain abort).
  if [ "$PHASE" = "swapped" ]; then rollback; fi
  exit 1
}

rollback() {
  log "ROLLING BACK to samenerp-app:previous ..."
  if docker image inspect samenerp-app:previous >/dev/null 2>&1; then
    docker tag samenerp-app:previous samenerp-app:latest
    (cd "$APP_DIR" && docker compose -f docker-compose.prod.yml up -d --no-build) || true
    log "rollback issued — check: docker logs $CONTAINER"
  else
    log "no :previous image exists — manual intervention required"
  fi
}

# Keep the last 10 deploy logs. `|| true` matters: on the first-ever deploy the
# glob matches nothing, ls exits 2, and pipefail+set -e would abort the script
# HERE — before the exec/tee below, i.e. with no output at all (hit for real in
# run 35953123332: bare "exit code 2").
ls -1t /tmp/deploy-*.log 2>/dev/null | tail -n +11 | xargs -r rm -f || true
exec > >(tee -a "/tmp/deploy-$(date +%Y%m%d-%H%M%S).log") 2>&1

cd "$REPO"
[ -f "$APP_DIR/docker-compose.prod.yml" ] || die "not a samenerp deploy checkout: $REPO"

# ── 0. secrets present BEFORE anything touches the tree ────────────────────────
ENV_LOCAL="$APP_DIR/.env.production.local"
if [ ! -f "$ENV_LOCAL" ]; then
  die "$ENV_LOCAL is missing — server-only secrets live there (see header). Create it before deploying."
fi
grep -q '^SAMEN_RESEND_API_KEY=..' "$ENV_LOCAL" \
  || die "$ENV_LOCAL lacks SAMEN_RESEND_API_KEY — refusing to deploy (email would silently break)."

# ── 1. resolve target ─────────────────────────────────────────────────────────
log "fetching origin ..."
git fetch --quiet origin || die "git fetch failed (network / remote '$(git remote get-url origin)')"
if [ -z "$TARGET_SHA" ]; then
  TARGET_SHA="$(git rev-parse origin/main)"
  log "TARGET_SHA not given — defaulting to origin/main"
fi
git cat-file -e "$TARGET_SHA^{commit}" 2>/dev/null \
  || die "TARGET_SHA=$TARGET_SHA not found after fetch — did CI validate a commit that never reached origin/main?"
TARGET_SHORT="$(git rev-parse --short "$TARGET_SHA")"
log "target: $TARGET_SHORT ($(git log -1 --format=%s "$TARGET_SHA"))"

# ── 2. fail-honest guards on the working tree ────────────────────────────────
# Known server-dirty files (all content-safe: .env.production's secrets are
# duplicated in the untracked .env.production.local, and origin/main's Dockerfile
# already carries CACHEBUST — the reset replaces both without losing anything).
# Matched as path SUFFIXES so staged, unstaged, and untracked (??) states all hit.
UNKNOWN_DIRTY="$(git status --porcelain |
  grep -vE '[[:space:]]samenerp/\.env\.production(\.local)?$' |
  grep -vE '[[:space:]]samenerp/Dockerfile$' || true)"
[ -z "$UNKNOWN_DIRTY" ] || die "server checkout has un-pushed changes — push them first:
$UNKNOWN_DIRTY"

# ── 3. fast paths ────────────────────────────────────────────────────────────
if [ "$(git rev-parse HEAD)" = "$(git rev-parse "$TARGET_SHA")" ]; then
  HEALTH="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$CONTAINER" 2>/dev/null || echo absent)"
  if [ "$HEALTH" = "healthy" ]; then
    log "already at $TARGET_SHORT and container healthy — nothing to do. ✔"
    exit 0
  fi
  log "already at $TARGET_SHORT but container is '$HEALTH' — redeploying."
fi

CHANGED="$(git diff --name-only HEAD "$TARGET_SHA" 2>/dev/null || true)"
if [ -n "$CHANGED" ]; then
  OUTSIDE="$(printf '%s\n' "$CHANGED" | grep -vE "$SKIP_PATTERNS" || true)"
  if [ -z "$OUTSIDE" ]; then
    log "only docs/CI/tooling files changed — skipping build:"
    printf '%s\n' "$CHANGED" | sed 's/^/    /'
    exit 0
  fi
fi

# ── 4. sync: backup branch, then reset to the CI-validated commit ────────────
BACKUP="backup/pre-deploy-$(date +%Y%m%d-%H%M%S)"
git branch -f "$BACKUP" HEAD >/dev/null 2>&1 || die "could not cut backup branch"
# Keep the last 5 backup branches.
git for-each-ref --sort=creatordate --format='%(refname:short)' refs/heads/backup/pre-deploy-* |
  head -n -5 | xargs -r -n1 git branch -D >/dev/null 2>&1 || true
log "backup: $BACKUP"

log "resetting tree to $TARGET_SHORT (discards known-dirty Dockerfile/.env.production mods; secrets are in .env.production.local)"
git -c advice.detachedHead=false reset --hard --quiet "$TARGET_SHA"
[ -f "$ENV_LOCAL" ] || die "$ENV_LOCAL vanished after reset — it must be gitignored"

# Compose resolves BOTH env files + skips the legacy nginx service (profiles).
(cd "$APP_DIR" && docker compose -f docker-compose.prod.yml config -q) \
  || die "docker compose config failed — env files / compose YAML broken"

# ── 5. build (pre-swap: a failure here leaves the old container serving) ─────
PHASE="built"
log "snapshotting current image as :previous (rollback target)"
docker tag samenerp-app:latest samenerp-app:previous 2>/dev/null \
  || log "no current :latest image — rollback will be unavailable this run"

# The vestigial compose nginx (port 80 is owned by system nginx) may linger in
# 'created' state from earlier manual ups; it never starts under its profile.
docker rm -f samenerp-nginx-1 >/dev/null 2>&1 || true

log "building image (long: full mix compile on cache-miss) ..."
if ! (cd "$APP_DIR" && docker compose -f docker-compose.prod.yml build app); then
  die "docker build failed — old container still running (see build log above)"
fi

# ── 6. swap ──────────────────────────────────────────────────────────────────
PHASE="swapped"
log "starting new container ..."
(cd "$APP_DIR" && docker compose -f docker-compose.prod.yml up -d) \
  || die "compose up failed"

# ── 7. gate: health ──────────────────────────────────────────────────────────
log "waiting for container health (max 120s) ..."
for _ in $(seq 1 60); do
  H="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{end}}' "$CONTAINER" 2>/dev/null || echo absent)"
  [ "$H" = "healthy" ] && break
  sleep 2
done
[ "${H:-}" = "healthy" ] || die "container not healthy after 120s (state: ${H:-absent})"
log "container healthy ✔"

# ── 8. gate: migrations actually applied ─────────────────────────────────────
docker logs "$CONTAINER" 2>&1 | grep -q "Migration and seed complete" \
  || die "entrypoint did not reach 'Migration and seed complete' — migrate/seed failed (entrypoint swallows the error: check 'docker logs $CONTAINER')"

LATEST_FILE="$(ls "$APP_DIR/priv/repo/migrations"/*.exs | sort | tail -1)"
LATEST_VERSION="$(basename "$LATEST_FILE" .exs)"
DB_MAX="$(docker exec "$DB_CONTAINER" psql -U postgres -d samenerp -Atc 'SELECT max(version) FROM schema_migrations' 2>/dev/null || true)"
DB_MAX="${DB_MAX:-0}" # max() over zero rows prints empty, not 0
if [ "$DB_MAX" -lt "$LATEST_VERSION" ]; then
  die "migrations behind: db max=$DB_MAX < newest file=$LATEST_VERSION ($LATEST_FILE) — the new tables would 404/500"
elif [ "$DB_MAX" -gt "$LATEST_VERSION" ]; then
  log "WARN: db schema ahead of code (db=$DB_MAX > code=$LATEST_VERSION) — a rollback deploy?"
fi
log "migrations applied (db max=$DB_MAX ≥ $LATEST_VERSION) ✔"

# ── 9. gate: HTTP smoke (5 surface paths must exist, never 404/500) ─────────
smoke() { # path want_really (200|302)
  local path="$1" code
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 15 "http://127.0.0.1:8080$path")"
  case "$code" in
    200 | 302) log "smoke $path → $code ✔" ;;
    *) die "smoke $path → $code (expected 200/302)" ;;
  esac
}
smoke "/healthz"
smoke "/crm/dashboard"
smoke "/support"
smoke "/support/kb"
smoke "/settings"
smoke "/automation"

# ── 10. gate: clean app log (crash / missing-column / 500 classes) ──────────
BAD="$(docker logs "$CONTAINER" 2>&1 |
  grep -E 'Sent 500|Postgrex\.Error|column .* does not exist|\*\* \(' || true)"
[ -z "$BAD" ] || die "app log shows failures after swap:
$BAD"

# ── 11. gate: server-only secrets actually loaded ───────────────────────────
for VAR in SAMEN_RESEND_API_KEY SAMEN_AUD_EVENT_APP_ROLE; do
  VAL="$(docker exec "$CONTAINER" printenv "$VAR" 2>/dev/null || true)"
  [ -n "$VAL" ] || die "$VAR not present in container env — .env.production.local not picked up"
done
log "secrets loaded (RESEND, aud role) ✔"

# ── done ─────────────────────────────────────────────────────────────────────
log "DEPLOY OK — $TARGET_SHORT in $(( $(date +%s) - START ))s"
log "  image:  $(docker inspect -f '{{.Id}}' "$CONTAINER" | cut -c8-19)"
log "  rollback image: samenerp-app:previous ($(docker inspect -f '{{.Id}}' samenerp-app:previous 2>/dev/null | cut -c8-19 || echo none))"
log "  backup branch:  $BACKUP"
