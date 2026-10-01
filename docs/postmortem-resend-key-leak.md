# Postmortem — Resend API key leaked into prod container logs

**One-line summary:** a production delivery-failure log line printed the live Resend API key
verbatim; the key was rotated and revoked within hours of discovery, the leak class was closed
structurally (provider credentials are now opaque at the type level and scrubbed from every
error path), and the whole fix shipped through CI + Deploy with prod verification at each step.

**Status:** closed. Old key revoked (proven `401`), new key live (proven authenticated
dispatch), no raw credential material in any prod log surface.

Code: `SamenResend.Secret` (`samen_resend/lib/samen_resend/secret.ex`),
`Samen.Delivery.Redact` (`samen_core/lib/samen/delivery/redact.ex`),
scrub wiring in `samen_resend/lib/samen_resend/provider.ex`,
`samen_core/lib/samen/delivery/chokepoint.ex`, `samen_core/lib/samen/delivery/auth_mailer.ex`,
auth-header fix in `samen_resend/lib/samen_resend/transport.ex`.

---

## What happened

During the 2026-09-25 → 09-29 prod outage investigation, a delivery-failure path logged an
error term that contained the provider config — including the live Resend API key
(`re_XpsL4…ThRf`, fingerprinted hereafter; the full value is deliberately not reproduced in
this document). The key sat in plain text in prod container logs, readable by anyone with
container-log access.

The exposure was found during the outage debugging (prior incident thread). By the time the
rotation work started on 2026-09-30, the offending log *line* was already gone — the app
container had been recreated several times and Docker logs do not survive recreation — but the
key itself remained live, and persisted in two places: the investigation transcript and the
server's env file (`/home/ubuntu/samen-erp/samenerp/.env.production.local`, mode 600, the
legitimate source the deploy script requires). A credential that has been logged once must be
treated as compromised regardless of log rotation, because the log line can outlive the
rotation of the medium that holds it (transcripts, backups, log shippers).

## Exposure assessment

- **Scope of the leaked key:** *send-restricted*. Probing Resend's management endpoints with
  it returned `401 restricted_api_key` — it could not mint keys, list/verify domains, or touch
  account settings. Its only power was sending email as the verified domain. That is exactly
  the least-privilege scope the dashboard offers, and it meaningfully bounded the blast radius:
  worst case is phishing mail sent as the product's domain, not account takeover.
- **Where the value existed:** (1) prod container logs — already rotated away by container
  recreation before remediation began; (2) the incident transcript — persists, but rendered
  inert by revocation; (3) the server env file — legitimate, mode 600, never left the server.
  The repo was never contaminated: the key never appears in git history.
- **Window of exposure:** from the leak (during the 09-25 → 09-29 outage window) until
  revocation on 2026-10-01 ~03:00 UTC. No evidence of abuse was observed in prod during the
  window (healthy `422` dispatch signatures throughout, no anomalous auth failures), but the
  authoritative check is Resend's own send log — see Follow-ups.
- **Residual risk after revocation:** none. The revocation probe returns
  `401 "API key is invalid"`, so the value persisting in the transcript does no harm.

## The fix — four commits

The remediation had two goals: make the *current* incident impossible to repeat (redaction),
and make the *fix itself* actually reach prod (the pipeline fought back — see the fifth
commit).

| Commit | What it does | Proof it works |
|---|---|---|
| `9e0df5e` — never let provider credentials reach a log or crash report | Introduces `%Secret{}` — an opaque wrapper (custom `Inspect` renders `#Secret<[REDACTED]>`, **no** `String.Chars` so interpolation *raises* rather than leaks) — and `Samen.Delivery.Redact`, a token-level scrubber: boundary-anchored regex over known key prefixes (`re_`, `sk_`, `pk_live_`, `AKIA`, `ghp_`, …) with an entropy floor (a digit or uppercase in the tail) so prose like "re_authenticate" survives; deep-scrubs maps/lists/tuples; unknown structs untouched. Wired into the provider's `do_deliver` (api_key wrapped, error terms scrubbed), `Chokepoint.send/2` (`{:error, reason}` scrubbed), and `AuthMailer`'s catch-all. | 4 provider redaction tests + 7 redaction unit tests; and, beautifully, prod itself: when the follow-up transport bug crashed, the crash report printed `#Secret<[REDACTED]>` — the redaction worked on its first real crash. |
| `8ffd915` — transport unwraps the Secret credential for the auth header | The transport built `Authorization: Bearer #{api_key}` by interpolation — which now *raises* on `%Secret{}`. Prod signup 500'd with `Protocol.UndefinedError` at `transport.ex:36` until this commit changed the header to `"Bearer " <> Secret.unwrap(api_key)`. A deliberate design consequence of layer 1: the only place the raw key may exist is inside the header construction. | Prod E2E after deploy: signup → `302 …?registered=1` (was 500); email dispatch shows the healthy `{:resend_error, 422, …}` fail-soft signature. |
| `033c4bd` — keep the Secret contract probes off the type checker's radar | CI compiles tests with `--warnings-as-errors`; the deliberate-raise probes (interpolating `%Secret{}`, `wrap(42)`) were statically flagged. The probe values are now routed through `Application.get_env/2` (opaque `term()` boundary), preserving the runtime contract without compile warnings. | Local: `samen_resend` `mix test --warnings-as-errors` → 53 passed. |
| `8e2f623` — backfill the PREVIOUS month's `aud_event` partition *(en-route find, not leak-related)* | Blocked the pipeline: CI failed on `033c4bd` with `23514 no partition of relation aud_event`. Root cause was a deterministic monthly time-bomb — the `INV-2` fixture writes an audit row at `now − 25h`, but both test harnesses only ensured *current + future* partitions, so in the first hours of every month the backdated row lands in the previous month, which has no partition. Added `PartitionManager.ensure_recent_partitions/2` (current + N preceding months, idempotent) wired into both harnesses, and made month stepping calendar-exact — the old `Date.add(anchor, offset * 31)` walk could silently skip a short month on a day-31 anchor. | Reproduced the exact CI failure locally at 23:44 UTC Sep 30 (inside the failure window), then the same test passed after the fix; full `samen_web` suite 1791/1791 inside the window; CI ✓ Deploy ✓ on `8e2f623`, `prod_verify.sh` ALL PASSED. |

Net effect: a provider config can no longer be logged *by construction*. Even a future leak
produces at most `#Secret<[REDACTED]>` in logs, and `Redact.scrub/1` catches any token-shaped
string that reaches an error path through some other channel.

## Rotation — proof chain

The leaked key was send-restricted, so rotation could not be done via Resend's API (401 on
management endpoints) — it required the dashboard, i.e. a human step. Everything around that
step was automated and verified:

1. **Cutover script staged** (`/home/ubuntu/rotate-resend-key.sh`): validate the new key
   against Resend (a live send probe; `401` = reject) → swap `.env.production.local`
   (timestamped backup) → `docker compose up -d --force-recreate --no-deps app` → 120s healthz
   gate with automatic rollback → print fingerprints.
2. **Handoff hygiene:** the new key was minted in the dashboard and applied by the operator in
   *their own* SSH session — the live value never entered the incident transcript (the same
   channel that still carries the old leaked value).
3. **Cutover executed** 2026-10-01 02:49 UTC (backup file timestamp `.bak.20261001024917`).
   Verified from outside the cutover session: env fingerprint changed
   `re_XpsL4…ThRf` → `re_HMmng…W5Ug` (both len 36), file still mode 600, container recreated
   and healthcheck *healthy*, public `/healthz` → 200.
4. **Post-cutover E2E:** `prod_verify.sh` ALL PASSED (healthz, signup → `registered=1`, login
   302, styled settings sidebar). Dispatch signature `{:resend_error, 422, …}` — the new key
   *authenticates* to Resend (a bad key would 401) and fails soft on the invalid probe
   recipient, as designed. Zero `[error]` lines since cutover.
5. **Revocation:** old key deleted in the dashboard. Direct API probe with the old value:
   `HTTP 401 {"message":"API key is invalid","name":"validation_error","statusCode":401}` —
   dead, proven, not assumed.
6. **Cleanup:** the env backup (which contained the old key) deleted; no backup files remain.
   Full container log history greps **0** hits for `re_[A-Za-z0-9_-]{20,}` and 0 for the old
   fingerprint — and after `9e0df5e`, that invariant is enforced by the code, not just checked.

## What worked / what didn't

**Worked:** least-privilege key scope (the leak's blast radius was one domain's outbound
mail, nothing more); the redaction proving itself on its first real crash within hours of
shipping; the validate-before-swap cutover with rollback; verifying every claim with a probe
or an E2E run rather than trusting the dashboard's word for it.

**Didn't:** the fix pipeline itself — two CI failures en route (the `--warnings-as-errors`
test-compile gate, then the partition time-bomb) meant the *transport fix* reached prod a full
cycle late, during which prod signup 500'd on email dispatch. The time-bomb is worth naming:
a test that only runs on push stayed latent for ~3 months and would have failed the first CI
run of every month's first day, forever. Scheduled runs would have caught it in a day.

## Follow-ups

- [ ] **Operator:** audit Resend's send log for the exposure window (dashboard → Logs) to
  conclusively rule out abuse of the old key. (Prod-side signals showed nothing anomalous.)
- [ ] Add a scheduled (nightly) CI run so month-boundary time-bombs surface within 24h.
- [ ] Sweep for other forward-only time assumptions (rollup windows, retention cutoffs,
  partition ensures) that fail deterministically at boundaries.
- [ ] Add a step-5 "secret canary" to `prod_verify.sh`: grep container logs for token-shaped
  strings after the signup probe, so every future prod verify re-proves this invariant.
- [ ] Add secret scanning (gitleaks or equivalent) to CI so a credential committed or printed
  in build output fails the gate before it ships.
- [ ] Encode the rotation runbook (staged script + dashboard steps + revocation probe) into
  `docs/runbooks/` so the next rotation is copy-paste.
