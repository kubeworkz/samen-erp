# Samenerp mount ledger — the seven host-adoption phases

**As of:** 2026-10-09 · **Host:** `samenerp` · **What it covers:** the seven numbered *mount phases*
that adopted the framework's remaining surface groups in this host at ≈0 authored LOC.

## Why this file exists

`samenerp` is the reuse proof (ADR-009): a host that mounts the framework's product surfaces with a
router line each and authors no LiveView. The later adoption work was sequenced as seven mount
phases, but the sequence itself was recorded only in commit subjects and in the numbered comment
blocks of `samenerp/lib/samenerp_web/router.ex` (`1i.` … `1n.`). So "are the seven phases done?" was
answerable only by reading git history. This file is that missing ledger: one row per phase, the
macro it mounted, the migration it needed, and the proof that certifies it — plus a re-derivable
check for whether any framework mount macro is still unadopted.

**Not to be confused with** `docs/ws-erp/build-plan.md` (WS-ERP phases E0–E7), which is the *module*
workstream — Finance ledger · AP/AR · Inventory · Procurement · Sales · Manufacturing · HR — exposed
through `samen_erp_routes` and mounted long before these phases. Different sequence, own plan.

A "phase" here is one previously-unmounted framework module group. Every phase follows the same
shape: one (or a few) `samen_*_routes` calls in the tenant/public scope, the host-side domain or
table materialization the group reads, and a `phaseN_surface_test.exs` that drives the REAL router —
never a hand-built mount.

## The ledger

| Phase | Framework module group | Mount macro(s) | Host namespace · migration | Surface proof | Shipped |
|---|---|---|---|---|---|
| 1 | Banking (orphan close-out) · Work · Files/Documents | `samen_module_routes(:banking, …)`<br>`samen_module_routes(:work, …)`<br>`samen_files_routes(:files, …)`<br>(+ the `/api/openapi.json` docs route) | `Samenerp.Banking` · `Samenerp.Work` · `Samenerp.Primitives`<br>`20261005120000_add_banking_scope_catalog`<br>`20261005120001_add_work_scope` | `test/phase1_surface_test.exs` (3)<br>+ `banking_surface_test.exs`, `banking_match_guard_test.exs` | `b1519f8` |
| 2 | Chat & Communication (ADR-012 cross-plane, tenant plane) | `samen_chat_routes(:chat, …)` (`pubsub: Samenerp.PubSub`) | `Samenerp.Chat`<br>`20261006130000_mount_chat_scope` | `test/phase2_surface_test.exs` (3) | `119a8dc` |
| 3 | Search & Discovery (⌘K · CSV · own-org analytics) | `samen_search_routes(:search, …)`<br>`samen_csv_routes(:csv, …)`<br>`samen_tenant_analytics_routes(…)` | `Samenerp.Primitives` · `Samenerp.Crm`<br>`20261006140000_add_cockpit_rollups` | `test/phase3_surface_test.exs` (6) | `5af1552` |
| 4 | Integrations (feature flags · webhook ingress) | `samen_flags_routes(:flags, …)`<br>`samen_webhook_routes()` (own CSRF-exempt `:webhook_ingress` pipeline) | `Samenerp.Primitives`<br>`20260722100000_webhook_event` (`whk_event` replay-store/DLQ delegate) | `test/phase4_surface_test.exs` (4) | `42b7db2` |
| 5 | Knowledge Base · CSAT (the two PUBLIC portal kinds) | `samen_module_routes(:kb, …, path: "/portal")`<br>`samen_module_routes(:csat, …)` | `Samenerp.Cms` · `Samenerp.Support`<br>`20261006150000_mount_cms_scope` | `test/phase5_surface_test.exs` (5) | `58dda56` |
| 6 | Calendar & Scheduling (framework `.ics` export) | `samen_ics_routes(:ics, …)` | `Samenerp.Calendar`<br>`20261007090000_mount_calendar_scope` | `test/phase6_surface_test.exs` (5) | `16732a7` |
| 7 | AI plane (ADR-043 §5.3 / ADR-047 A6) | `samen_ai_routes(:ai, Samenerp.Crm, …)` | `Samen.AI.Domain` + 7 repo seams<br>`20261007120000_mount_ai_domain` | `test/phase7_surface_test.exs` (4) | `9ec9171` |

30 tests across the seven files; the `samenerp` gate runs 65 in total (the seven phase files'
30, the framework flood-guard tripwire, the three SIDEBAR-REACHABILITY legs below, and the rest of
the host suite).

## Sidebar reachability — the phases' module groups in the app's own nav (2026-10-10)

A mount is not a REACHABLE surface. Every phase added a route group that the app rendered nowhere
but its own page: `/files`, `/chat`, `/search`, `/analytics`, `/calendar.ics`, `/ai` and `/flags`
were hand-typed-URL-only from the rest of the product (the PP-8/PP-9 nav-island defect class). The
framework now carries them in the INHERITED sidebar, and this host opts in with DATA — not code.

**Framework side (`samen_web`).** `Samen.UI.Nav.module_nav/1` grew one X1-gated group per phase
module (Documents · Chat · Discover · Insights · Calendar · AI, plus a Feature-flags item in the
existing Workspace group). Each renders exactly when its path label is set, so a host that never
mounted a module never emits a link to it — the same presence-is-the-guard posture as the
pre-existing `erp_path`/`banking_path`/`work_path` seams. `Samen.UI.Nav.nav_paths/1` resolves every
gated path from a `%Samen.Web.Mount{}`'s labels, and all nine `module_nav/1` call sites now splat it
(`<.module_nav {Samen.UI.nav_paths(@mount)} …>`), so the NEXT module is one label plus one group
instead of nine hand-threaded triples.

Two properties of that seam are load-bearing:

- **Tenant-plane only.** The new groups resolve ONLY for a `:tenant`-plane mount. `:chat_path` is
also what driftwood's OPERATOR-plane desk chat carries (`/operator/desk-chat`), and an
operator-plane sidebar linking a bare tenant surface is the silent plane crossing T116 bars.
ERP/Banking/Work keep their historical resolution, so no existing host's nav changes.
- **Round-trip safe.** The new label keys are whitelisted in `Samen.Web.Mount.@label_keys/0`; a key
read off a mount but not whitelisted is DROPPED by `from_session/1` on a cold BEAM, which would
silently disarm the whole group. `samen_web/test/samen/web/nav_path_roundtrip_test.exs` pins both
the round trip and the whitelist, and the source-grep guard (`label_keys_completeness_test.exs`)
covers the new `Mount.label/3` call sites.

**Host side.** Seven lines in `@current_org_labels` (`files_path` … `flags_path`), each naming the
path the mount macro below it actually serves.

**The host proof** — `test/nav_reachability_test.exs` (3 legs, driven through the REAL router):

1. the sidebar of an ORDINARY tenant page (CRM Companies, which mounts none of these modules
   itself) lists every phase module — the groups are inherited chrome, so this must hold on every
   tenant page, not only on the module's own;
2. every `href` that sidebar emits resolves to a route `SamenerpWeb.Router` declares — the leg that
   catches a label drifting from its macro (rename the chat path to `/conversations` and the nav
   points at a route this host no longer serves) — with the resolver's refutability asserted
   against a fabricated path;
3. the groups are DATA on the tenant mount: `nav_paths/1` resolves all seven from the labels and
   none without them.

**Registered in the sabotage harness** (all three verified with
`bash scripts/sabotage.sh --from 321 --to 322` / `--range 173-173`: flip confirmed, restore
byte-exact): `321-phase-module-nav-groups-removed.patch` deletes the six phase groups and flips
the component test (`samen_web`); `322-samenerp-files-nav-label-dropped.patch` drops `files_path`
from this host's label map and flips leg 1 (`samenerp`); and the pre-existing
`173-pp8-pp9-settings-automation-nav-items-removed.patch` was **re-anchored** to the new Workspace
shape (its `:if` gained the `@flags_path` leg and a Feature-flags item) — same defect, same two
PP-8/PP-9 MUST_FAIL targets. Live spot-checks before that: drifting `search_path` to
`/nosuchsearch` failed leg 2 with the route-table diagnosis, and the tree was restored byte-exact.
The same green/red/plane cases are pinned at component level in
`samen_web/test/samen/ui/components_test.exs`.

**Deliberately NOT in the sidebar.** Phase 5's `:kb`/`:csat` are PUBLIC pre-actor portals (a
visitor with no session has no sidebar to render them in); Phase 3's CSV is an ACTION on a
per-resource route (`/csv/import/:resource`), not a destination; Phase 4's webhook ingress is
vendor-facing (its operator-side DLQ already rides the operator nav). Only the flag admin joins the
nav from Phase 4.

**Other hosts opt in the same way** — one label per mounted module in their shared tenant labels
map, and only for modules they actually mount. `driftwood` labels the five groups it mounts
(`files_path`/`chat_path`/`search_path`/`ai_path`/`automation_path`) and `pawchart` the four it
mounts (`work_path`/`files_path`/`search_path`/`ics_path`); neither declares a label for a module
it does not mount, because `mix samen.verify.nav_links` would report it as the dead link it is.
`pawchart` is the sharper case: it mounts no automation surface, so it must NOT carry
`:automation_path` — the item that put a `/automation` `NoRouteError` one click away until the
framework label-gated it (that host is why `mix samen.verify.nav_links` exists). Each host's own
gate runs the verifier against its real router (`--router …`), so the labels and the mounts below
them can never drift apart.

## What each proof actually pins

Every phase proof follows the same discipline: drive the route through `SamenerpWeb.Endpoint`,
assert the status and the surface's own DOM anchor, then add the identity/masking legs the group
needs. Named, per phase:

- **Phase 1** — `/files` renders the framework upload/preview surface with its honest empty state;
  the byte-serve route refuses a fresh upload at the quarantine gate (fail-closed); `GET
  /api/openapi.json` serves the generated document. Coverage note: the `:work` module pages have no
  router-driven assertion in this host — they ride the same `samen_module_routes/3` expansion as the
  other module groups (banking has its own surface + guard tests).
- **Phase 2** — `/chat` renders empty; a seeded thread lists by subject and its vault-routed body is
  CLEAR on the tenant plane; a missing thread renders the honest not-available posture, never a crash.
- **Phase 3** — `/search` renders the palette with the honest no-match posture; a registered file
  ranks for its own org and never another's; CSV import renders and CSV export serves seeded rows as
  `text/csv` while unknown resources 404 deny-by-default; own-org analytics renders the honest empty
  state and, seeded, floored counts for the caller's org only.
- **Phase 4** — the flag admin renders empty and seeded; an unconfigured provider delivery is refused
  fail-closed (the 404 also proves the route is CSRF-exempt by design — a 403 would mean forgery
  protection leaked in); a signed delivery persists with replay dedupe and a forgery stores nothing.
  The test-local HMAC stub is the load-bearing detail: if `RawBodyReader` stopped delivering the exact
  signed bytes, the accepted-delivery proof flips.
- **Phase 5** — the public help center renders its honest empty state, shows a published PUBLIC post
  and hides an INTERNAL one; the agent KB reads this host's CMS namespace through the `kb_namespace`
  label; a garbage CSAT token renders the one generic invalid state (never an oracle) and a minted
  single-use token records once, then is honestly invalid on replay.
- **Phase 6** — `GET /calendar.ics` serves the Calendar mount with the attendee CLEAR on the tenant
  plane; a fresh org exports a well-formed but eventless VCALENDAR; the export is org-scoped; a
  recurring event exports one VEVENT carrying an RRULE; and the attendee is vaulted at rest, clear on
  the tenant plane and `••••` on the operator plane (INV-1).
- **Phase 7** — all nine AI routes render (the analytics surface asserted as its operator-gated honest
  refusal on a tenant plane, not as its ask form); an unconfigured plane is fail-honest (SIMULATED or
  an honest error, never a live claim) driven through `VerbsLive.load/3`; assistants are org-scoped;
  and the vault-routed transcript is an opaque `vt_*` token at rest, clear on the tenant plane and
  masked on the operator plane, with both anti-tautology twins.

## The completeness check (re-derivable)

The framework's public mount macros are defined in `samen_web/lib/samen/web/router.ex`. Re-run this
after any phase to see whether anything is still unadopted by this host:

```bash
# macros the framework defines
grep -oE "^  defmacro samen_[a-z_]+_routes" samen_web/lib/samen/web/router.ex \
  | awk '{print $2}' | sort -u > /tmp/fw.txt

# macros samenerp mounts
grep -oE "samen_[a-z_]+_routes\(" samenerp/lib/samenerp_web/router.ex \
  | tr -d '(' | sort -u > /tmp/erp.txt

comm -23 /tmp/fw.txt /tmp/erp.txt   # defined but not mounted here
```

These are audit recipes over the repo's own source, not documented product commands. The D9
DOC-COMMAND EXTRACTOR (`samen_core/test/doc_commands_test.exs`) deliberately binds the *builder*
guides (`README.md`, `guides/getting-started.md`, `guides/cookbook.md`, `guides/gate-failures.md`) to
reality and does not list this ledger, so a future maintainer adding the file to its `@doc_paths` is
making a decision rather than fixing an oversight: these pipelines are not in the gen_app probes'
executed set, and `DocCommands.verify/2` would flag them as aspirational.

Result at the time of writing: **20 defined, 19 used** — 26 call sites in the router. The single
delta is `samen_fleet_ingest_routes` (the ADR-044 fleet *cockpit-side* ingest), which no shipped host
mounts. That delta is **ruled below, not open** — see the next section.

**Recount (2026-10-11, ADR-050 amendment):** re-run over the shipped hosts (`samenerp` · `demo` ·
`driftwood` · `pawchart`, both the `_route(` and `_routes(` forms): **23 defined, 22 used by a shipped
host — 85 call sites.** The earlier totals were stale (this fork has added macros and mounts since),
but the *delta is unchanged and still exactly one*: `samen_fleet_ingest_routes`. `ADR-050`'s new
`samen_fleet_status_route` is now USED (by `samenerp` — the amendment below), so it never entered the
delta column.

## Ruling — the cockpit-side ingest is deliberately unshipped (2026-10-08)

`git grep -l "samen_fleet_ingest_routes(" -- '*.ex' '*.exs'` returns exactly two files: the macro
definition (`samen_web/lib/samen/web/router.ex`) and `samen_web/test/support/fleet_cockpit_router.ex`.
The second is a REAL compiled router that mounts the cockpit (`samen_operator_routes(…,
fleet_cockpit: true)`), the app-side reporting pair, and this ingest — the framework's own
certification host, not a shipped app. **No product adopts the cockpit side, and that is a decision,
not an oversight.**

It is not dead surface, and not unexercised:

- **It is certified at the gate, loudly.** `samen_web/ci.sh` runs `mix samen.verify.fleet_wire --host
  samen_web --router Samen.WebTest.FleetCockpitRouter`, whose RP-J-4b cross-check compares that
  router against `Samen.Fleet.RouteTable.declared/0` **in both directions**. Let the macro stop
  emitting `POST /fleet/enroll` + `POST /fleet/heartbeat`, or let an undeclared fleet route appear,
  and the gate fails. The HTTP behavior is separately pinned by
  `samen_web/test/samen/web/fleet_ingress_test.exs` (14 tests — the load-bearing 204-with-empty-body
  zero-read proof, forged-signature `401`, flood bounds, enroll `200`/`401`): RP-J-1/2/3/10/13.
- **A host cannot adopt it cheaply.** Its required `namespace:` is a `Samen.Fleet.Scope`-mounted Ash
  domain (`flt_app` · `flt_credential` · `flt_enrollment_token` · `flt_report` · `flt_directive`),
  which no shipped app had at the time of writing — `git grep -ln flt_credential -- demo driftwood
  pawchart samenerp` returned nothing, and the only materialization in the tree was
  `samen_core/priv/test_repo`'s fixture. Adopting the ingest is therefore a product *becoming a
  cockpit* (operator-plane routes plus a five-resource fleet scope), not a router line.
  **SUPERSEDED IN PART (2026-10-11):** `samenerp` now holds a five-resource fleet scope
  (`Samenerp.Fleet`, abbrevs `efa`/`efc`/`efe`/`efr`/`efd`, migration `20261011120000`) — see the
  ADR-050 amendment below — and, by **Amendment 2** below, mounts the cockpit UI
  (`samen_operator_routes(…, fleet_cockpit: true, fleet_namespace: Samenerp.Fleet)`, the four
  `/operator/fleet*` routes). The *ingest* delta this bullet explains is untouched: samenerp does NOT
  mount `samen_fleet_ingest_routes`.
- **ADR-044 never required it of a vertical.** §9.3's tier (b) places the cockpit's own proof in
  `samen_web` ("one `:embedded` app plus two ingested reports"), and its dependency note is explicit
  that the ≥2-vertical proof must not require a vertical to host a cockpit. Tier (a) proves
  *reporting* from driftwood and pawchart via `samen_fleet_routes/1` — the app-side macro that
  driftwood, pawchart and this host mount, and `demo` deliberately does not.
- **A structural consequence worth knowing.** RP-J-4b compares the FULL declared table, so it can only
  be green for a router that mounts both sides; `--router DriftwoodWeb.Router` would report every
  cockpit-side route as unmounted. That is why each vertical's fleet evidence is its Plug-layer
  `test/fleet_wire_test.exs` and the single RP-J-4b run lives in `samen_web`.

**What would settle it the other way — and how much of it has now happened:** a product that
actually hosts a cockpit (ADR-044 §3.1 — the cockpit is a role, not a deployment). **2026-10-11
(T166b): one happened.** `samenerp` mounts `samen_operator_routes(Samenerp.Operator, …,
fleet_cockpit: true, fleet_namespace: Samenerp.Fleet)` (Amendment 2 below), so the
`fleet_cockpit: true` list is no longer "`samen_web` internals only" — a shipped product is in it. It
does NOT mount the ingest, and that is the DESIGNED one-sided shape rather than a half-finished
adoption: rule 1 is one-directional (`ingest ⇒ cockpit`) because enroll/heartbeat ARE the cockpit's
side of the wire and a mode-A `:pull` cockpit needs neither. The two lists below therefore no longer
move together by construction, and the one this ruling is about (the ingest) is unchanged. What the
original paragraph predicted would move together:

```bash
# cockpit-side ingest adopters
git grep -l "samen_fleet_ingest_routes(" -- '*.ex' '*.exs'

# cockpit adopters — must be the same set
git grep -l "fleet_cockpit: true" -- '*.ex' '*.exs'
```

Today the ingest list is `{router.ex (the macro), test/support/fleet_cockpit_router.ex}` — no shipped
product, as ruled. The cockpit list is no longer `samen_web`-only: `samenerp/lib/samenerp_web/router.ex`
joined it on 2026-10-11 (Amendment 2). The ruling is recorded in three places that must agree — here,
the macro's `@doc` (`samen_web/lib/samen/web/router.ex`), and ADR-044 §9.2 — and the second amendment
is carried in ADR-044 §9.2's adoption note and in the ADR-050 record.

**Enforced, not merely recorded (2026-10-08).** The invariant is now a GATE — and it is rule 1 of
a small data table rather than a bespoke check: `mix samen.verify.fleet_wire`
(`samen_core/lib/mix/tasks/samen.verify.fleet_wire.ex`) implements the **co-adoption rules**
(`co_adoption_rules/0`), the set of mounts that are only sound alongside a counterpart in the
same app. Each rule is data (`:side`, `:requires`, `:why`, `:fix`), the scan is driven entirely
by the table, and every rule is one-directional (the counterpart without its side is fine).
Four ship today (an audit of every mount macro's `@doc` — the per-macro tally is in
`docs/guides/gate-failures.md`):

1. **The cockpit pair** — the cockpit-side ingest requires a cockpit (this ledger's ruling).
2. **The raw-bytes seam** (ADR-038 §5.1 / ADR-044 §4.4a) — the signature-verifying receivers
   (`samen_webhook_routes/1`, `samen_fleet_routes/1`, and `samen_fleet_ingest_routes/1`, whose
   `@doc` says it “Needs the SAME raw-body reader”) require the endpoint's `Plug.Parsers`
   `Samen.Web.Webhook.RawBodyReader`. Those `@doc`s state the obligation as MUST and nothing
   enforced it: a host that skips the one-line endpoint change compiles, boots, and refuses
   correctly-signed deliveries *as if forged* (the heartbeat pipe signs
   `Crypto.body_digest(raw_body)`). All three wire-mounting hosts (driftwood, pawchart, this one)
   wire it, so the rule is green **and** genuinely engaged on the real tree — the test asserts
   both, so a rule that stopped firing is visible instead of silently green.
3. **The org-session plug** (ADR-026/ADR-028/F2) — a files/CSV/ICS mount requires
   `plug :fetch_session` in the host's router: those byte/export controllers sit outside the
   `live_session` and resolve the org from the session (`Samen.Web.CurrentOrg.resolve/3`), so
   without it every download 503s while the LiveViews beside it mount fine. All three hosts
   mount an org-session surface and all three supply the plug.
4. **The realtime PubSub** (ADR-012 §6.3/ADR-016 §4) — a chat/notifications mount requires a
   supervised `Phoenix.PubSub` whose name MATCHES the mount's `:pubsub` label (the framework
   default being `Driftwood.PubSub`), plus chat's `Samen.Web.Chat.Presence` roster server on that
   same bus, because the chat room's connected mount subscribes and tracks presence on it. A
   mount that names no label would silently broadcast on a vertical's bus.

So the two `git grep` commands above are the human-readable form of checks the build already runs.
`samen_web/ci.sh` invoked that verifier for RP-J-4/P8 before this existed, so enforcement needed no
new gate step. Its proof: `samen_core/test/verify_fleet_wire_test.exs`'s co-adoption describe
(green real tree + a red divergence, positive control and anti-tautology twin per rule + two
fail-closed paths for the walker + a table-integrity test), with the adversarial twins registered
as `scripts/sabotages/309-fleet-ingest-cockpit-colocation-drop.patch` (rule 1),
`scripts/sabotages/310-raw-body-seam-missing.patch` (rule 2),
`scripts/sabotages/312-org-session-plug-rule-drop.patch` (rule 3),
`scripts/sabotages/313-realtime-pubsub-rule-drop.patch` (rule 4) and
`scripts/sabotages/314-fleet-ingest-dropped-from-seam-side.patch` (rule 2's ingest leg).

**The cockpit's own namespace is compile-enforced too (2026-10-08).** Rule 1 insists only that a
cockpit EXISTS; the mount itself now refuses to compile without the namespace it reads —
`samen_operator_routes(..., fleet_cockpit: true, fleet_namespace: MyApp.Fleet)`, enforced by
`Samen.Web.Router.__require_fleet_namespace__!/1` at macro expansion (the T142
`:actor_resolver` refusal shape). The two `git grep` lists below are therefore strictly stronger
than they were: every cockpit mount they find names its namespace by construction. Proof:
`samen_web/test/samen/web/router_test.exs`'s T84b describe (compile-time refusal, the
`fleet_namespace: nil` pin, and both positive controls) plus `samen_core/test/fleet_registry_test.exs`'s
nil-namespace read-path twin; adversarial twin
`scripts/sabotages/311-cockpit-namespace-requirement-drop.patch`.

**Verified (2026-10-08) — both directions, and the negative control:**

```bash
cd samen_web && MIX_ENV=test mix samen.verify.fleet_wire --host samen_web --router Samen.WebTest.FleetCockpitRouter
#   → samen.verify.fleet_wire: OK — no violations found.        (exit 0)

cd samenerp && MIX_ENV=test mix samen.verify.fleet_wire --host samenerp --router SamenerpWeb.Router
#   → FAIL, 6 violations: the four /operator/fleet* cockpit routes + POST /fleet/enroll
#     + POST /fleet/heartbeat, each "promised but not mounted".  (exit 1)
```

The second run is the point: it shows the cross-check is not vacuous, and it is the structural
consequence above — a reporting-only host *must* fail RP-J-4b for the cockpit side. (Its failure list
has exactly six entries because the three `/operator/{deliverability,automation,activity}/resolve`
routes are mounted UNCONDITIONALLY by `samen_operator_routes/2` — §5.3's deep-link targets — so this
host already has them.)

**Re-verified 2026-10-11, after Amendment 2 — the SAME command, now two violations:**

```bash
cd samenerp && MIX_ENV=test mix samen.verify.fleet_wire --host samenerp --router SamenerpWeb.Router
#   → FAIL, 2 violations: POST /fleet/enroll + POST /fleet/heartbeat,
#     each "promised but not mounted".                          (exit 1)
```

The four `/operator/fleet*` entries left that list because this host now mounts them, and what
remains is exactly the ingest delta this section rules on — legal because rule 1 is one-directional,
not because the check is lax. The three resolve routes were always mounted unconditionally, which is
the whole explanation of the old count of six.

## Base mounts (pre-date the numbered phases)

Not part of the sequence, mounted earlier by the scaffold and the WS-ERP work: `samen_module_routes`
for `:billing`, `:crm`, `:marketing`, `:support` · `samen_automation_routes` · `samen_settings_routes`
· `samen_erp_routes` · `samen_notifications_routes` · `samen_fleet_routes` · `samen_operator_routes` ·
`samen_session_routes` / `samen_auth_routes` / `samen_onboarding_routes`.

## Open items (2026-10-08)

- **`samen_fleet_ingest_routes` is unadopted — ruled, not open** (see the ruling above). The
  completeness-check delta is deliberate: a cockpit-side surface, certified in `samen_web`'s own gate,
  adopted only by a product that becomes a cockpit.
- **Two surfaces are tenant-plane only in this host.** The `.ics` export (Phase 6) and the whole AI
  group (Phase 7) have no operator-plane route; their operator legs are proven through the masking
  seam rather than a second mounted route.
- **No live AI provider.** samenerp wires none by design (INV-5 — secrets live in runtime config), so
  every AI surface is fail-honest or SIMULATED until a key is supplied, and the `SAMEN_AI_LIVE=1` lane
  never runs in CI. The Phase-7 proofs pin that honesty, not a real completion.
- **Root-CI caveat.** The sequential tiers (spikes · samen_core · AI eval tier · 5 adapters · 3
  gen_app probes · sabotage selection) are green against this host's tree, but no single `./ci.sh` run
  has ended `ROOT CI: ALL PASSED` on this box: the final concurrent app tier flaked in *other* apps —
  `samen_web` running its suite on a 2-connection pool while `config/test.exs` declares 20, and
  driftwood/pawchart `ci_bootstrap` hard-matching an un-retried contended `storage_down`/`storage_up`.

## Amendment — samenerp holds a FLEET REGISTRY for the public status page (2026-10-11, ADR-050)

**Narrower than the ruling above it, in the one respect that survived the day (see the second
amendment below).** The 2026-10-08 ruling is about the **cockpit side**, and its ingest half still
stands unchanged: nothing here mounts `samen_fleet_ingest_routes` (`POST /fleet/enroll` +
`POST /fleet/heartbeat`), so the three places that must agree (`docs/guides/gate-failures.md`'s
per-macro tally, the ingest macro's `@doc`, ADR-044 §9.2) are unaffected, and the ingest stays the
ledger's one unused delta. A mode-A `:pull` cockpit needs no ingest, so this one-sided shape is what
ADR-044 §3.1/§9.2 DESIGN for — enforced as rule 1 of `mix samen.verify.fleet_wire`'s co-adoption
table, not left to a comment.

What DID change is the substrate fact that bullet leaned on. ADR-050's public status page projects
`Samen.Fleet.Registry.build_row/3`'s already-computed rows, so the page cannot be *live* without a
fleet registry to project — a route mounted against a missing namespace fails closed to a permanent
**503** by design (§4.5 refuses an empty 200 that would read as all-clear). samenerp is the
operator-facing product here, so it became the **portfolio host**:

| Added | What |
|---|---|
| `samenerp/lib/samenerp/fleet.ex` | `Samenerp.Fleet` — the `use Samen.Fleet.Scope` mount (five resources) |
| `samenerp/priv/repo/migrations/20261011120000_mount_fleet_scope.exs` | `efa_app` · `efc_credential` · `efe_enrollment_token` · `efr_report` · `efd_directive` (all additive), cataloged in-tx |
| `config/config.exs` | `Samenerp.Fleet` registered in both `ash_domains` lists (app + the verifiers') |
| `lib/samenerp_web/router.ex` | `samen_fleet_status_route(namespace: Samenerp.Fleet)` — `GET /status`, in the SAME public scope as the `:kb`/`:csat` portals |
| abbrev registry | `efa`/`efc`/`efe`/`efr`/`efd`, reserved via `mix samen.abbrev.reserve --host samenerp` (never by hand, ADR-023) |

**Landed state:** `/status` is live and **publishes nothing** — no row exists, and
`efa_publish_status` defaults to `false`, so publication requires the admin-gated
`Samenerp.Fleet.Registry.set_publish_status/4` (the app's own heartbeat actor is refused by policy).
Host-level proof: `test/fleet_status_page_test.exs` (dispatched through the real endpoint — 200, no
auth bounce, empty page, opt-in respected, heartbeat refusal with its admin positive control).

**The opt-in, exercised against PRODUCTION (2026-10-11).** The public page's flag is flipped by an
operator, and this host ships no cockpit, so on samenerp the act is a call to the verb from the
release console in the app container (`bin/samenerp eval`, the same mechanism the entrypoint's
migrate/seed step uses) under an admitted `Samen.Fleet.AdminActor`. Round trip, observed live on
`https://samenerp.kubeworkz.io/status`: publishing a probe app rendered a real component row
(`ops-status-probe` · *Down*, overall "Some published components are down." — the probe never
reported, so `build_row/3`'s `:unreachable` maps to §4.2's `:down`); the app's own `HeartbeatActor`
was refused the same flip; unpublishing removed the row on the next read. The probe was then
DEREGISTERED, so the page omits it entirely and the landed state is again "publishes nothing" — a
probe left published would be a fabricated public component, which is what ADR-050 refuses.

The operator ACTION itself lives in the framework (`Samen.Web.Operator.FleetDetailLive`, ADR-050
§4.3). As first landed it was reachable only on a host mounting
`samen_operator_routes(…, fleet_cockpit: true)` — which this host did not — so the opt-in here was a
console call against the verb. **The second amendment below mounts the cockpit, closing that gap.**

## Amendment 2 — samenerp MOUNTS THE COCKPIT, with the authority seam it needs (2026-10-11, T166b)

**What moves.** The 2026-10-08 ruling's first clause ("no cockpit UI") is reversed by
`samen_operator_routes(Samenerp.Operator, repo: Samenerp.Repo, …, fleet_cockpit: true,
fleet_namespace: Samenerp.Fleet)` — four `/operator/fleet*` LiveViews (list · directives · register ·
the tier-2 detail page whose publish control flips `efa_publish_status`), riding the SAME operator
`live_session` and therefore the T146 `{Samen.Web.Operator.Authz, :require_operator}` `on_mount` on
every route (RP-J-12 by construction — no separate fleet auth hook exists to forget). The reason is
ADR-050 §4.3: this host holds the registry, so it is the one host where the publish action is worth
having a UI for, and leaving it console-only made the feature's own opt-in an operator script step.

**What does NOT move.** `samen_fleet_ingest_routes` stays unshipped (the ingest half above), and
RP-J-4b's enumeration is untouched — the verifier still runs against `samen_web`'s test-support
cockpit router, and this app's own `ci.sh` runs `nav_links`, not `fleet_wire`.

| Added | What |
|---|---|
| `samenerp/lib/samenerp/fleet_authz.ex` | `Samenerp.FleetAuthz.fleet_roles/1` — the `:fleet_authority` seam (ADR-044 §6.2): the reserved `:fleet` scope plus one scope per configured product, at the role this host's operator resolver reports. It DELEGATES to `Samenerp.OperatorAuthz` (the `:operator_authority` resolver) so one identity gets one authorization decision; fail CLOSED to `%{}` for a non-operator. |
| `config/config.exs` | `:fleet_authority` (the seam above), `:fleet_products, [:samenerp]` (the atomized per-product tier-2 grant the publish action checks — provisioned config, never conferred by a registered row), and `:fleet, mode: :manual` (without which `Samen.Fleet.read/2` returns the zero-config `:embedded` self-row and ignores `:fleet_namespace`) |
| `lib/samenerp_web/router.ex` | `samen_operator_routes(…, fleet_cockpit: true, fleet_namespace: Samenerp.Fleet)` — the four cockpit routes, no new route table |
| `test/fleet_cockpit_mount_test.exs` | host-level proof: the four routes off the COMPILED route table each carrying the operator `on_mount`, the mount read back out of the `live_session` the router itself compiled, every route rendered through the real endpoint, and the ARMED (`auth_required?: true`) posture driven green/red — a real operator-org `:owner` publishes through the mounted cockpit and the public page reports it; a real `:member` and a principal with no operator membership are refused, with the owner's identical call as positive control |
| `scripts/sabotages/330-…` | adversarial twin: drop `fleet_cockpit: true` and the two named legs flip, byte-exact reverted |

**Left unwired deliberately:** `:fleet_resolution` (the tenant-NAME seam, ADR-044 §16.2) — the
driftwood posture. Cohort counts render; every tenant name stays masked and the page says why.

**The seam that matters for production.** `Samenerp.FleetAuthz` is a thin delegation on purpose: the
cockpit's role read and the operator console's role gate resolve through the SAME
`Samenerp.OperatorAuthz` (credential → User → operator-org Membership), so `auth_required?: true`
closes the console and the cockpit together and the dev convenience both share disappears with the
same config value. A second roster was the alternative, and it would be a second policy that can
drift from the first with neither decision auditable against the other.

**Constraint discovered by mounting it — the fleet domain must NOT be a registered `ash_domain`.**
`Samenerp.Fleet` is deliberately absent from BOTH `ash_domains` lists, and this is load-bearing:
`mix samen.verify.aggregate_privacy` discovers its fleet from
`Application.get_env(:samenerp, :ash_domains)` and requires every `use Samen.Aggregate.Resource` to
declare a fail-closed cohort spec. The fleet registry has no cohort semantics — it is cross-tenant
operator-owned registry data, which is precisely what the blueprint uses that macro FOR (the
nullable-`org_id` override and the C7 `NoPiiColumns` check), never for aggregate reads. So
registering the domain forces a FABRICATED cohort spec to silence the verifier, and NOT registering
it is the correct posture. The framework's own mount is kept out the same way
(`samen_core/config/test.exs`), so this is established posture rather than a gap: the domain still
runs (`validate_config_inclusion?: false`), INV-2 stays compile-enforced on all five resources, and
its columns reach the committed catalog via the migration's in-tx `catalog_sync`. A future reader who
"tidies" this by adding the domain back will fail the gate at step 15 — that is the note's whole
purpose.

**The reversal, stated plainly, because a future reader should not have to infer it from a table:**
this host now holds a fleet scope, which the ruling's own bullet described as "a product *becoming a
cockpit*". That much was accepted deliberately for ADR-050's sake, and the cockpit UI followed the
same day (Amendment 2): the registry this host holds is exactly the registry the publish action must
be reachable from, so shipping the storage without the surface would have left the feature's own
opt-in as a console step. The cockpit-side INGEST stays deliberately unshipped — the one-sided shape
ADR-044 §3.1/§9.2 design for, since a mode-A `:pull` cockpit reports outward and accepts no pushes.
If a future change mounts the ingest, the ruling's `git grep` pair at the top of this file is the
check that moves with it.

## Amendment 3 — the analytics PRODUCER is mounted, so Insights → Activation can actually fill (2026-10-13, ADR-021)

Samenerp shipped the analytics READERS in Phase 3 and never the producer, and the difference was
invisible until someone looked at the page: `GET /analytics` rendered its honest empty state under copy
that reads as *"no data yet"*, while the truth was *"no data possible"* — for every org, forever. Two
links were missing, and **both** are needed:

1. **The emitter was inert.** `Samen.Analytics.track/1` persists nothing without
   `config :samen_core, Samen.Analytics, product_event_resource: …` — it answers `{:ok, :dropped}`
   ("sources are quiet until the host mounts the Analytics scope", by design). The framework emitters
   already fire on this host: the session controller emits `session.signed_in` on every sign-in, the
   first-run wizard emits `record.created` + `first_run.completed`, ⌘K emits `search.used`, and every
   flag-variant assignment rides the `Samen.FeatureFlags` emit seam. All of it was being discarded.
2. **The rollup had no source.** `paf_product_event_rollup` (created by `20261006140000`, which named
   this as the host's follow-on) is rebuilt by the domain-sourced `:product_event_rollup` spec from
   `<abbrev>_product_event`. With no ledger and no spec, the table stayed empty, so
   `Samen.Web.Tenant.AnalyticsReads` could only ever render ⊘ or the empty state.

What landed — framework-first: **no framework code changed and no new surface was authored**:

* `Samenerp.Analytics` — `use Samen.Scopes.Analytics` (the demo/driftwood/pawchart mount) with the
  FRESH abbrev `sae`, reserved through the sanctioned allocator
  (`mix samen.abbrev.reserve --host samenerp --abbrev sae --owner Samenerp.Analytics.ProductEvent`;
  the registry gained exactly one appended row — ADR-023/ADR-006, never hand-edited).
* migration `20261013120000_add_analytics_scope.exs` — the `sae_product_event` ledger plus its
  `(org, event_name, occurred_at)` read index, catalogued in the same transaction (ADR-004).
* config — `product_event_resource`, the `Samen.FeatureFlags` emit target, and the
  `:product_event_rollup` spec whose `rebuild_sql` reads `sae_product_event`. The refresh is the
  canonical `*/10 * * * *` `RollupRefreshWorker` cron `Samen.Jobs.install_defaults/1` already installs
  at boot, so this host schedules nothing itself.

**Deliberately NOT wired: `mrr_revenue_rollup`.** The operator `/operator/revenue` plane reads it, and it
stays on honest zeros: it needs a subscription-MOVEMENT ledger source this app has not adopted, and
inventing one to make a page look busier would be the fabricated-count failure the analytics posture
exists to prevent. Named here so the next reader does not treat it as an oversight.

**A floor note the tests forced.** `Samen.Aggregate.Privacy` defaults to k=5, but every shipped host
configures `:k_anonymity_min_cohort, 2` — samenerp included — so a 2-actor cohort RELEASES here and only
a count-of-one renders ⊘. The new suite reads the floor from `Privacy.k/0` rather than assuming 5, and
asserts a sub-floor cohort renders ⊘ **in its own count cell** (a bare `body =~ "⊘"` would pass on the
page's suppression-count note alone).

**Proof.** `test/analytics_activation_test.exs` (10 tests) pins each link and then the outcome: the
resource's `sae_product_event` table; the emitter config; an ANTI-TAUTOLOGY red path (with
`product_event_resource` cleared, the SAME capture is `{:ok, :dropped}` and persists nothing — the exact
defect); the registered domain-sourced spec reconciling with independently computed distinct-subject
counts; and the page rendering the captured cohort, ⊘ below the floor, a foreign org's sentinel never
leaking, and the empty state still correct for an org with no events.

**One divergence worth naming** (so nobody "fixes" it blind): this host registers NO `non_pii!`
clearances for `sae_actor_ref` / `sae_entity_ref` / `sae_props`, so the CDC projection default-denies
exactly those three columns (verified via `Samen.Cdc.Projection.classify_columns/1`). demo, driftwood and
pawchart register them to satisfy AC-G12-3's "`project/1` returns ALL columns" claim for a ledger that
IS mirrored. Nothing on this host consumes `sae` through the mirror, so the deny is the SAFE direction,
and the gate's `pii_classify` / `no_plaintext_pii` tiers are green either way. If a CDC consumer for
`sae` ever appears, clear the three columns the way `Driftwood.Analytics.NonPiiSetup` does — that is a
hardening step, not a repair.

**The gate that keeps it from regressing on ANY host (2026-10-13).** Amendment 3 fixed this host;
`mix samen.verify.analytics_producer` keeps the CLASS from shipping again. It is a static
(source + config) verifier: any app whose shipped `lib/` mounts `samen_tenant_analytics_routes/2`
must ALSO configure its product-event producer — the `Samen.Analytics` emitter
(`product_event_resource`) AND a `:product_event_rollup` spec in `config :samen_core, :rollups`,
the two links this amendment names — or the gate reports the app, the mount location and the
missing half. It runs in this host's own `ci.sh` (the bare command, over the cwd app), tree-scoped
over the whole checkout in the root gate's `verifiers` tier, and as a member of
`samen.verify.fleet` (so any checkout can be gated with one argument). The generated-app
templates emit the same step, so a host is gated from birth. Operator-only hosts are
**deliberately out of scope**: `samen_operator_routes/2` bundles `/operator/analytics` into every
generated app, so requiring a producer for it would make product analytics mandatory rather than
opt-in. Adversarial twin: `scripts/sabotages/335-analytics-producer-reader-mount-matcher-neutered.patch`.

## Amendment 4 — the PAGES surface is mounted, so the block editor has an app to live in (2026-10-20, ADR-053 §8 O4)

WS-Notes shipped P1–P5 into `samen_core`/`samen_web`, but no host ever called
`samen_notes_routes/3`, so the whole surface was reachable only from the library's own test router
and the workstream's definition of done — "a member of samenerp can create a nested page, type
blocks, split/merge/move/indent them, find a paragraph by its text, and follow a `[[page]]`
backlink, with no page reload" — had no app to happen in. This amendment mounts it here.

| File | What it is |
|---|---|
| `lib/samenerp_web/router.ex` | `samen_notes_routes(:notes, Samenerp.Docs, repo: Samenerp.Repo, search_index: Samenerp.Primitives.SearchIndex, labels: @current_org_labels)` — `GET /pages` (index) + `GET /pages/:id` (editor). The macro sets `:pages_path` on its own mount; the host's SHARED tenant label map carries `pages_path: "/pages"` too, because the sidebar is inherited chrome resolved from the CURRENT page's mount (same posture as `files_path`/`chat_path`). `mix samen.verify.nav_links` keeps the two spellings equal to the route. |
| `lib/samenerp/docs.ex` · `priv/repo/migrations/20261018120000_mount_docs_scope.exs` | Pre-existing from WS-Notes Phase 1 — the `Doc`/`DocBlock`/`DocLink` rows the surface edits (the mount is the adoption; nothing new was authored for it). |
| `test/notes_surface_mount_test.exs` | 5 host-level proofs through the REAL router: both routes declared; `/pages` renders this org's pages inside the shared shell + the New-page form; `/pages/:id` renders the page's block; Documents → Pages is inherited chrome on `/crm/companies` (which mounts notes nowhere); another org's page id is `Page not found` with neither its title nor its block text in the DOM (R1). |
| `test/nav_reachability_test.exs` | Documents → Pages added to the reachable roster, so the no-dead-link leg judges `/pages` on every tenant page. |
| `lib/samenerp/seeds.ex` | The HOST half of Pages search: `notes_mount/0` mirrors the router's mount (the router does not expose its compiled one), `ensure_notes_search_index!/1` calls `Samen.Web.Notes.Search.register_index/2` (guard-first — `pii_edb_text_secure` can never enter the tsvector), and `seed_notes_pages!/1` seeds one demo page (two plain blocks + one vaulted) and registers the index. `seed!/0,1` calls the registration OUTSIDE the `already_seeded` short-circuit, so a re-run repairs a missing row; it seeds no content. `mix samenerp.seed` runs the demo-page seed in `MIX_ENV=dev` only (`lib/mix/tasks/samenerp.seed.ex`), and the release entrypoint calls `Seeds.seed!()` from an `eval`, so no production path can reach the demo content. |
| `config/config.exs` · `samen_web/lib/samen/web/org_provisioning.ex` | The CREATION half of the same registration: `config :samenerp, :org_provisioning, [{Samenerp.Seeds, :ensure_notes_search_index!, []}]` arms the framework seam (`{mod, fun, args}`, called as `apply(mod, fun, args ++ [org_id])`), which runs on the org-creation path itself — the signup controller after the A1 transaction commits, and the operator plane's New-account write. Non-fatal by contract (the org is already committed) and loud on failure (`{:error, [{mod, fun, reason}]}` + a `Logger.error` per failure; a raise or an unexpected return is a failure too). `Samenerp.Seeds.backfill_notes_search_index!/0` is the deploy half: `seed!/0,1` sweeps the tenant directory on every boot, so orgs that predate the wiring are repaired on the next release. |
| `test/notes_org_provisioning_test.exs` | 4 proofs: the hook is wired AND resolvable from the MOUNT (`Mount.otp_app(Seeds.notes_mount()) == :samenerp`), which is how both call sites reach it; a real `POST /signup` (CSRF token off the form, the no-JS POST fallback) yields an org that already carries exactly `Doc.title` + `DocBlock.text` with no seed call anywhere in the test; that brand-new org's `/pages?q=` answers for a block its own member typed and deep-links to it; and the backfill registers a directly-created org that predates the hook. Anti-tautology: a directly-created org has NO registry rows, so the signup rows are the creation path doing the work. |
| `test/notes_search_test.exs` | 5 proofs: the two registry rows are exactly `Doc.title` + `DocBlock.text` and re-registering does not duplicate; a seeded page is found by its plain block text through the REAL router (`GET /pages?q=typed`, block hit, deep link to `/pages/:id`); `?q=vaulted` renders the honest empty state with the vaulted plaintext absent from the body — with a positive control on the same page proving the silence is the vault, not a dead query; `SearchIndexGuard` refuses `text_secure` and accepts `text`; and another org's seeded page is not searchable from this org (positive control: it IS a hit when searched from the org that owns it). |

**Deliberately NOT mounted: `demo`.** The WS-Notes build plan listed it second, on the assumption
that its existing Docs mount made this a one-liner. Demo's posture is API-only (`Demo.DocsScope`'s
moduledoc states the boundary — no web-surface router mount, the same one `samen_ics_routes`
respected), so mounting a tenant LiveView there would be a posture change disguised as a one-liner.

**Search is registered, not merely mounted.** `Samen.Web.Notes.Search` is fail-closed, so a mounted
surface with no `SearchIndex` rows answers every `?q=` with an honest empty state — "wired" and
"searchable" are two different claims. `Samenerp.Seeds.ensure_notes_search_index!/1` makes the
second one true for a seeded org (and `seed!/0,1` repairs it on a re-run), which is proven end to end
by `test/notes_search_test.exs`, and its refutability by
`scripts/sabotages/368-samenerp-notes-seed-skips-search-registration.patch` (drops the seed's
registration call → the "found by its plain block text" test flips; restore byte-exact).

**...and it is provisioned at CREATION, not only by the seeder (unit 1c, 2026-10-21).** A seeder can
only repair the orgs it knows about, so every tenant org created after a seed — self-serve signup,
operator New-account — had no registry rows and therefore a permanently empty `/pages?q=`. The
registration now also runs on the creation path via `Samen.Web.OrgProvisioning` (one config line
above; the seam reports failures instead of unwinding a committed account), with
`Samenerp.Seeds.backfill_notes_search_index!/0` repairing pre-existing orgs from `seed!/0,1` on
every boot. Refutability: sabotages 369 (the config line), 370 (the operator-plane call) and 371
(the signup call) each flip a named test in `test/notes_org_provisioning_test.exs` /
`samen_web/test/samen/web/org_provisioning_test.exs` and restore byte-exact.

**Still open on this host, named rather than implied:** `Notes.Export` (unit 2.4) is unbuilt, so
R6's export-masking row has no mechanism yet, and `mix samen.docs.materialize` (unit 1a) has no
samenerp caller (there is no legacy `body` content here — the host was mounted after blocks
existed).

## Re-running the certification

```bash
cd samenerp && MIX_ENV=test bash ci.sh     # ends: ==> samenerp CI gate: ALL PASSED
```

That gate runs every verifier plus the host suite — **88 tests as of 2026-10-13** (the ADR-050 mount
added `test/fleet_status_page_test.exs`'s 4; Amendment 2's cockpit mount added
`test/fleet_cockpit_mount_test.exs`'s 8; Amendment 3 added `test/analytics_activation_test.exs`'s 10;
the earlier figure of 61 predates all three), which includes all seven `phaseN_surface_test.exs` files.
Amendment 4 adds `test/notes_surface_mount_test.exs`'s 5; the gate re-derives the total, so it is not
restated here. The `mix.lock` in this app is a local resolution artifact and is deliberately not committed
(all seven phases shipped without it).
