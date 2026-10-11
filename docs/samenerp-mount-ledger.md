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
  ADR-050 amendment below. The *ingest* delta this bullet explains is untouched: samenerp does NOT
  mount `samen_fleet_ingest_routes`, `samen_operator_routes(…, fleet_cockpit: true)`, or any
  `/fleet*` route.
- **ADR-044 never required it of a vertical.** §9.3's tier (b) places the cockpit's own proof in
  `samen_web` ("one `:embedded` app plus two ingested reports"), and its dependency note is explicit
  that the ≥2-vertical proof must not require a vertical to host a cockpit. Tier (a) proves
  *reporting* from driftwood and pawchart via `samen_fleet_routes/1` — the app-side macro that
  driftwood, pawchart and this host mount, and `demo` deliberately does not.
- **A structural consequence worth knowing.** RP-J-4b compares the FULL declared table, so it can only
  be green for a router that mounts both sides; `--router DriftwoodWeb.Router` would report every
  cockpit-side route as unmounted. That is why each vertical's fleet evidence is its Plug-layer
  `test/fleet_wire_test.exs` and the single RP-J-4b run lives in `samen_web`.

**What would settle it the other way:** a product that actually hosts a cockpit (ADR-044 §3.1 — the
cockpit is a role, not a deployment). It would mount `samen_operator_routes(…, fleet_cockpit: true)`
and this ingest in the same router, and the two lists below would move together:

```bash
# cockpit-side ingest adopters
git grep -l "samen_fleet_ingest_routes(" -- '*.ex' '*.exs'

# cockpit adopters — must be the same set
git grep -l "fleet_cockpit: true" -- '*.ex' '*.exs'
```

Today the ingest list is `{router.ex (the macro), test/support/fleet_cockpit_router.ex}` and the
cockpit list is all `samen_web` internals — i.e. no shipped product appears in either. The ruling is
recorded in three places that must agree: here, the macro's `@doc`
(`samen_web/lib/samen/web/router.ex`), and ADR-044 §9.2.

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

**Narrower than the ruling above it.** The 2026-10-08 ruling is about the **cockpit side**, and every
part of it still stands: nothing here mounts `samen_fleet_ingest_routes` (`POST /fleet/enroll` +
`POST /fleet/heartbeat`), nothing mounts `samen_operator_routes(…, fleet_cockpit: true)` (the operator
drill-in UI), and this router serves **no `/fleet*` route at all** — so the three places that must
agree (`docs/guides/gate-failures.md`'s per-macro tally, the ingest macro's `@doc`, ADR-044 §9.2) are
unaffected, and the ingest stays the ledger's one unused delta.

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
cockpit*". That much was accepted deliberately for ADR-050's sake; the ingest and the cockpit UI
were not, and are still deliberately unshipped. If a future change mounts either, the ruling's
`git grep` pair at the top of this file is the check that moves with it.

## Re-running the certification

```bash
cd samenerp && MIX_ENV=test bash ci.sh     # ends: ==> samenerp CI gate: ALL PASSED
```

That gate runs every verifier plus the host suite — **70 tests as of 2026-10-11** (the ADR-050 mount
added `test/fleet_status_page_test.exs`'s 4; the earlier figure of 61 predates them), which includes
all seven `phaseN_surface_test.exs` files. The `mix.lock` in this app is a local resolution artifact and is deliberately not committed
(all seven phases shipped without it).
