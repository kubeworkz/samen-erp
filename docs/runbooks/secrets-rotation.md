# Secrets rotation

Rotation procedures for the fail-closed secret set a deployed Samen app reads at boot
(`config/runtime.exs`, ADR-024/AC-G16-2): `DATABASE_URL`, `SECRET_KEY_BASE`, `PHX_HOST`,
`SAMEN_KMS_KEY_ID`, `SAMEN_KMS_REGION` — plus the per-webhook HMAC signing secret, which is
vaulted data, not an env var. Also see the generated per-app [`deploy.md`](deploy.md) for the
original secrets checklist.

**Fail-closed contract:** `config/runtime.exs` **raises** a named error on any missing or
empty secret at boot. Never unset a secret before its replacement is set and confirmed — a
gap boots nothing.

| Secret | Where set | Rotation trigger | Downtime/impact | Steps |
|---|---|---|---|---|
| `DATABASE_URL` | `fly secrets` (Neon connection string) | Credential compromise, scheduled rotation, Neon role change | Zero, if rolled per §1 | §1 |
| `SECRET_KEY_BASE` | `fly secrets` | Compromise, scheduled rotation | Invalidates existing sessions/signed cookies — forced re-login | §2 |
| `SAMEN_KMS_KEY_ID` / `SAMEN_KMS_REGION` | `fly secrets` | CMK rotation/replacement, region migration | High-risk if changing to a **different** key — requires DEK re-wrap | §3 |
| Webhook HMAC signing secret (`pii_wh_signing_secret`) | Vaulted per-webhook field, minted via governed Primitives webhook resource | Compromise, scheduled rotation, consumer offboarding | Per-webhook; old signature verification breaks for that endpoint once retired | §4 |
| Provider API keys (e.g. `SAMEN_RESEND_API_KEY`) | `.env.production.local` on the app server (docker compose `env_file`) — NOT `fly secrets` | Key leak, staff offboarding, scheduled rotation | Zero — healthz-gated container recreate (~5s) | §5 |

---

## 1. `DATABASE_URL` (Neon DB credentials)

Zero-downtime path: Neon supports multiple roles/passwords per branch, so a new credential
can be minted and validated before the old one is retired.

1. In Neon, create a new role password (or a new role) for the target branch — do NOT delete the old one yet.
2. Build the new `DATABASE_URL` (`postgres://…/<db>?sslmode=require`).
3. Set the new secret without unsetting the old: `fly secrets set DATABASE_URL=<new-url>`.
4. Fly performs a rolling restart on `secrets set` — machines pick up the new value on restart; watch `/readyz` (`:repo` check) across the rollout to confirm connectivity before proceeding.
5. Let in-flight connections on old machines drain naturally (Fly's rolling restart handles this — no manual connection draining needed for a `fly secrets set` deploy).
6. Once all machines are healthy on the new credential, revoke/delete the old Neon role password.
7. Confirm `/readyz` stays green post-revocation (proves nothing was still using the old credential).

## 2. `SECRET_KEY_BASE` (session/cookie signing)

Rotating this key **invalidates every existing session and signed cookie** — Phoenix verifies
signatures against the currently configured key, so old signatures fail verification
immediately on rotation. There is no key-versioning scheme in the base app by default; treat
rotation as a forced global re-login unless the deployed app has been extended with a
multi-key verifier (check the app's endpoint config for a `signing_salt`/key list before
assuming otherwise).

1. Generate a new value: `mix phx.gen.secret` (≥64-byte random string).
2. If the app supports staged rotation (multiple accepted signing keys), configure the new key as an additional accepted key first, deploy, then flip it to primary in a second deploy, then remove the old key in a third — this avoids a hard cutover. If it does not, skip to step 3 and accept the forced re-login.
3. Set the new secret: `fly secrets set SECRET_KEY_BASE=<new-value>`.
4. Communicate the impact ahead of the window if this is a synchronous cutover — every logged-in user is signed out and any outstanding signed URL/token (e.g. email confirmation links) becomes invalid.
5. Confirm `/readyz` and a fresh login flow work post-rotation.

## 3. KMS (`SAMEN_KMS_KEY_ID` / `SAMEN_KMS_REGION`)

This is the vault master-key context for `Samen.Kms.AwsKmsDynamo`: per-subject DEKs are
wrapped by the configured CMK, and unwrapped through it on every governed read. There are two
very different operations hiding under "KMS rotation" — treat them differently:

- **AWS-native CMK key rotation** (automatic annual rotation, or manual re-key of the *same*
  key ARN) — AWS re-wraps the key material internally; `SAMEN_KMS_KEY_ID` does not change and
  existing wrapped DEKs remain valid. This is the low-risk, routine case; no app-side action
  needed beyond confirming AWS rotation is enabled on the key.
- **Changing `SAMEN_KMS_KEY_ID` to a genuinely different key** (new CMK, region migration,
  key replacement after suspected compromise) — every existing wrapped DEK in the DynamoDB
  store was wrapped by the OLD key. Pointing the app at a new key ID without re-wrapping means
  every existing subject's DEK becomes unwrappable — a fail-closed outage on every vaulted
  field read for that subject, not a graceful fallback.

For the second case:

1. Treat this as a **careful, staged, drill-first operation** — do not attempt it live on a
   production key for the first time. Apply the same philosophy as
   [pitr-gameday.md](pitr-gameday.md): rehearse the full re-wrap procedure against a
   non-production KMS key + DynamoDB table first, and only promote to production once the
   drill is clean.
2. Plan the re-wrap: for every existing wrapped-DEK record, unwrap with the OLD key, wrap with
   the NEW key, write back — an online migration, not a config flip. Do this BEFORE changing
   `SAMEN_KMS_KEY_ID` in the running app, or run it in a mode that accepts both keys during the
   transition (unwrap-tries-old-then-new) if the adapter supports it.
3. Confirm IAM grants `kms:Decrypt` on the OLD key and `kms:Encrypt`/`kms:GenerateDataKey` on
   the NEW key to the migration runner for the duration of the re-wrap.
4. Only after every wrapped DEK is confirmed re-wrapped under the new key: `fly secrets set SAMEN_KMS_KEY_ID=<new-id> SAMEN_KMS_REGION=<region>`.
5. Watch `/readyz`'s `:kms` check and the KMS error-rate alert ([alerts.md](alerts.md) §4) closely through the rollout.
6. Keep the old CMK enabled (not scheduled for deletion) for a safety window after cutover, in case a re-wrap gap surfaces.

## 4. Webhook HMAC signing secret

Each webhook's signing secret is a **vaulted per-webhook field**
(`pii_<abbrev>_signing_secret`, e.g. `pii_wh_signing_secret`), minted through the governed
Primitives webhook resource. It is **not an environment variable** and is not touched by `fly
secrets` at all — rotation is scoped to a single webhook, not the whole app.

1. Mint a new signing secret on the target webhook via its governed action (the Primitives
   webhook resource's mint/rotate action — do not write the field directly; it goes through
   the same PII write-guard chokepoint as any other vaulted field).
2. Surface the new secret to the webhook's consumer (whoever verifies the HMAC on the
   receiving end) through your normal out-of-band credential handoff — the secret itself is
   never logged or displayed outside a governed reveal.
3. Roll the consumer to verify against the new secret. If the consumer needs a grace window,
   check whether the webhook resource supports holding both an active and a prior secret
   during rotation; if not, this is a hard cutover — coordinate timing with the consumer.
4. Once the consumer confirms verification against the new secret, retire the old secret on
   the webhook resource.
5. Confirm a live webhook delivery round-trips (signed, delivered, verified) post-rotation.

## 5. Provider API keys (`SAMEN_RESEND_API_KEY` and friends)

Email-provider API keys are **third-party credentials**: they live outside the app's own
fail-closed secret set and outside `fly secrets` — in this deployment they sit in
`.env.production.local` (mode 600) next to `docker-compose.prod.yml`, and the deploy script
refuses to run without `SAMEN_RESEND_API_KEY` set. Rotation is therefore an operator-on-the-
server procedure, automated by [`scripts/rotate-resend-key.sh`](../../scripts/rotate-resend-key.sh)
(exercised for the 2026-10-01 rotation — full incident record:
[postmortem](../postmortem-resend-key-leak.md)).

**Trigger:** confirmed or suspected leak (a key that has EVER been printed to a log, chat,
or ticket is compromised — rotation of the storage medium does not un-compromise it),
scheduled rotation, or staff offboarding. The leaked key in the 2026-10-01 incident was
send-restricted, which bounded the blast radius to one domain's outbound mail — mint
replacement keys with the same least-privilege scope, never "Full access".

### Hard rules (from the 2026-10-01 incident)

1. **The key never passes through chat, tickets, or agent transcripts.** Mint it in the
   dashboard, and apply it to the server in YOUR OWN SSH session. A transcript that carries a
   live credential is itself a leak (the pre-rotation key was still sitting in the incident
   transcript when this runbook was written — rendered harmless only by revocation).
2. **Validate before you swap.** The cutover script probes Resend with the new key and aborts
   on anything but a send-scope answer — a mistyped key changes nothing.
3. **Revoke is the actual neutralization.** Cutover alone replaces the value; the old key
   stays LIVE at Resend until deleted in the dashboard. Revoke immediately after cutover,
   then PROVE the revocation (step 6).
4. **The backup file contains the old key.** It exists (mode 600) between cutover and
   cleanup — delete it as soon as revocation is proven.

### Procedure (copy-paste)

1. **Mint** in [dashboard.resend.com/api-keys](https://dashboard.resend.com/api-keys) →
   *Create API Key*: name it (`samenerp-prod-YYYY-MM`), permission **Sending access**, scope
   to the verified sending domain. The value (`re_…`) is shown **once** — copy it now.
2. **Get the script on the server** (from a checkout of this repo):

   ```bash
   scp scripts/rotate-resend-key.sh ubuntu@<prod-host>:/home/ubuntu/rotate-resend-key.sh
   ```

3. **Cutover — in your own SSH session**, key as a quoted argument:

   ```bash
   ssh ubuntu@<prod-host>
   bash /home/ubuntu/rotate-resend-key.sh 're_PASTE_NEW_KEY'
   ```

   The script: (1) probes Resend with the new key — `422`/`200`/`202` = authenticates with
   send scope, `401` = abort with nothing changed; (2) swaps the key in
   `.env.production.local` (timestamped backup, `chmod 600`); (3) recreates only the app
   container; (4) gates on `healthz` for 120s, auto-restoring the backup and recreating again
   on failure; (5) prints the old-key fingerprint and the revoke reminder.

4. **Verify from a second channel** (not the cutover session):

   ```bash
   # fingerprint changed (prints first8...last4 + length — compare before/after)
   ssh ubuntu@<prod-host> 'k=$(grep -oP "^SAMEN_RESEND_API_KEY=\K.*" \
     /home/ubuntu/samen-erp/samenerp/.env.production.local); echo "${k:0:8}...${k: -4} (len ${#k})"'

   # full E2E from the repo: healthz, signup→registered=1, login, sidebar
   bash .prod_gate/prod_verify.sh

   # dispatch signature: want {:resend_error, 422, ...} (AUTHENTICATED + fail-soft on the
   # invalid probe recipient); a 401 here means the NEW key is wrong/revoked
   ssh ubuntu@<prod-host> 'docker logs samenerp-app-1 --since 10m 2>&1 \
     | grep -oE "resend_error, [0-9]+" | sort | uniq -c'
   ```

   Semantics worth memorizing: `401` from Resend = authentication problem (bad/revoked key);
   `422` = authentication PASSED and the payload was rejected. A healthy deployment shows
   `422` on `.example`-address probes, never `401`.

5. **Revoke the old key** in the dashboard (API Keys → delete the old entry). Until this
   step the leaked/replaced credential is still live.
6. **Prove revocation** — probe the OLD value; expect `401 "API key is invalid"`
   (`422` would mean it is still live — go re-check the dashboard):

   ```bash
   curl -s -m 20 https://api.resend.com/emails \
     -H "Authorization: Bearer re_OLD_KEY" -H 'content-type: application/json' -d '{}'
   ```

7. **Cleanup + final gate** — delete the backup (it holds the old key), then re-run
   `prod_verify.sh` and the log-hygiene grep:

   ```bash
   ssh ubuntu@<prod-host> 'rm /home/ubuntu/samen-erp/samenerp/.env.production.local.bak.*
     && docker logs samenerp-app-1 2>&1 | grep -cE "re_[A-Za-z0-9_-]{20,}"'
   # want: no backup files, grep count 0 (also enforced in-code by Samen.Delivery.Redact)
   ```

8. **Record it**: append the rotation (date, key fingerprint, trigger) to the ops log so the
   next scheduled rotation has a baseline.

### Rollback

If the healthz gate fails, the script self-rolls-back (restores the backup env file and
recreates the container) — investigate `docker logs samenerp-app-1` and re-run. If you need
to roll back MANUALLY after a successful cutover (e.g. the new key was revoked too early),
restore the backup the same way before deleting it, and remember the OLD key must still be
live at Resend for that to work.
