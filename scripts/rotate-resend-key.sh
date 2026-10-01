#!/usr/bin/env bash
# rotate-resend-key.sh — one-command Resend API key cutover for samenerp prod.
#
# Canonical copy: scripts/rotate-resend-key.sh in the repo. The live copy on the
# prod server (/home/ubuntu/rotate-resend-key.sh) was exercised for the
# 2026-10-01 rotation — see docs/runbooks/secrets-rotation.md §5 for the full
# procedure and docs/postmortem-resend-key-leak.md for the incident record.
## Usage (run ON the prod server):
#   bash rotate-resend-key.sh '<new-key-minted-in-resend-dashboard>'
#
# Steps: validate new key (send-scope 422 probe, NOT 401) -> swap the key in
# .env.production.local (backup kept) -> force-recreate the app container ->
# health gate (rollback on failure) -> remind to revoke the old key.
set -euo pipefail

NEW_KEY="${1:-}"
ENV_FILE="/home/ubuntu/samen-erp/samenerp/.env.production.local"
COMPOSE_DIR="/home/ubuntu/samen-erp/samenerp"
BACKUP="${ENV_FILE}.bak.$(date +%Y%m%d%H%M%S)"

[ -n "$NEW_KEY" ] || { echo "usage: bash rotate-resend-key.sh '<new-key>'"; exit 1; }
case "$NEW_KEY" in re_*) ;; *) echo "refusing: new key must start with re_"; exit 1;; esac

echo "== 1/5 validating new key (send-scope probe: expect 422, never 401)"
code=$(curl -sS -m 30 -o /tmp/rotate_probe.json -w '%{http_code}' \
  -H "Authorization: Bearer $NEW_KEY" -H "content-type: application/json" \
  -d '{"from":"probe@samenerp.kubeworkz.io","to":["probe@invalid.invalid"],"subject":"rotation probe","text":"probe"}' \
  https://api.resend.com/emails || echo curl_failed)
case "$code" in
  422|200|202) echo "   OK: authenticates with send scope";;
  401) echo "   FAIL: key rejected (401):"; cat /tmp/rotate_probe.json; exit 1;;
  *) echo "   UNEXPECTED status=$code:"; cat /tmp/rotate_probe.json; exit 1;;
esac
rm -f /tmp/rotate_probe.json

echo "== 2/5 swapping key in $ENV_FILE (backup: $BACKUP)"
cp -p "$ENV_FILE" "$BACKUP"
sed -i "s|^SAMEN_RESEND_API_KEY=.*|SAMEN_RESEND_API_KEY=${NEW_KEY}|" "$ENV_FILE"
chmod 600 "$ENV_FILE"

echo "== 3/5 recreating app container with the new env"
cd "$COMPOSE_DIR"
docker compose -f docker-compose.prod.yml up -d --force-recreate --no-deps app >/dev/null

echo "== 4/5 health gate (120s; rollback on failure)"
ok=""
for i in $(seq 1 24); do
  sleep 5
  if docker exec samenerp-app-1 wget -qO- -T 5 http://127.0.0.1:4050/healthz 2>/dev/null | grep -q "ok"; then
    ok=1; break
  fi
done
if [ -z "$ok" ]; then
  echo "   FAIL: healthz not green — ROLLING BACK env from backup"
  cp -p "$BACKUP" "$ENV_FILE"
  docker compose -f docker-compose.prod.yml up -d --force-recreate --no-deps app >/dev/null
  exit 1
fi
echo "   healthz OK"

echo "== 5/5 cutover complete — NOW REVOKE THE OLD KEY"
OLD_KEY=$(grep '^SAMEN_RESEND_API_KEY=' "$BACKUP" | cut -d= -f2- || true)
if [ -n "$OLD_KEY" ]; then
  echo "   old key prefix: ${OLD_KEY:0:6}... (full value stays only in $BACKUP until you delete it)"
fi
echo "   revoke at https://dashboard.resend.com/api-keys then: rm $BACKUP"
