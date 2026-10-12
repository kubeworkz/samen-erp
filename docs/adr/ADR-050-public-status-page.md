# ADR-050 — The public status page on the fleet substrate: a token-blind projection, opt-in per app, rate-limited, with no second notion of "up"

- **Status:** **ACCEPTED (2026-09-20)** — implemented in the same change that authors this ADR.
  Amends nothing. ADR-044's registry, probe modes, report wire and dead-man staleness are
  consumed **unchanged**; ADR-038 §6.1's single rate-limit seam is reused, not forked.
- **Date:** 2026-09-20
- **Provenance (this fork):** ported from upstream `ckluis/samen`'s ADR-050 after the two trees
  diverged at ADR-048 (the two git histories share no common ancestor, so this was a
  content-level port, not a merge). The port was re-verified against THIS tree rather than
  assumed: the four owning tests pass here (`samen_core/test/fleet_public_status_test.exs`,
  `samen_web/test/samen/web/fleet_public_status_test.exs`), and the durable twins are this
  fork's sabotage patches **325–328** (upstream numbered them 360–363); **329** was added in this
  fork alongside the cockpit opt-in action (§4.3) and has no upstream twin. One adaptation was
  required and is recorded in §4.4 below: this fork's suite-wide `RateLimit.FloodGuard` fails a
  test that floods an UNPINNED wall-clock-aligned window, so the limiter tests pin the window
  through `Samen.WebTest.RateLimitFlood.pin!/1` while keeping their authored limits.
- **Build status:** **BUILT and ADOPTED** (`samenerp` serves `GET /status` — §6.1).
  `Samen.Fleet.PublicStatus` (samen_core),
  `Samen.Web.Fleet.PublicStatus` + `Samen.Web.FleetStatusController` +
  `Samen.Web.Router.samen_fleet_status_route/1` (samen_web), one `flt_app` column
  (`publish_status`), one admin-gated verb (`Samen.Fleet.Registry.set_publish_status/4`),
  the cockpit's own opt-in ACTION over that verb (§4.3 — added 2026-10-11, and verified
  live against `samenerp.kubeworkz.io`, §6.1), owning tests across the two apps, sabotage
  patches **325–328** plus **329** (the cockpit action's gate). §7 names exactly what
  is deferred.
- **Task:** close the last open G11 line (`saas-gap-roadmap.md`) — a public status page —
  **without** giving the product a second, disagreeable notion of health. At the fork point the
  fleet substrate computed per-app status correctly and nothing published it: all route tables in
  `Samen.Web.Router.__routes__/2` and all `samen_*_routes` macros were authenticated or
  tenant-scoped, and `status_page|public_status|StatusPage` returned zero hits across
  `samen_web` + `samen_core`.
- **Deciders:** no operator decision is opened by this ADR. The three judgement calls (§4.2's
  lossy enum mapping, §4.3's opt-in mechanism, §7's deferral) are ruled here and are all
  reversible in the narrowing direction.

---

## 1. Context

`Samen.Fleet.Registry.build_row/3` (ADR-044 §4.6, §8.2) already derives, per registered app, a
bounded status from the app's own `stale_after_s` and the **cockpit's** `received_at` — never the
producer's `generated_at_us`. That is the dead-man semantics ADR-044 shipped, and it is the
single hardest thing about a status page to get right.

A public status page therefore has exactly one legitimate job: **project** that row onto a plane
with no identity on it. The failure mode worth designing against is not "the page is wrong" — it
is "the page is *separately* right", i.e. a second uptime computation that drifts from the
cockpit's and eventually contradicts it in front of customers.

## 2. Decision

1. **The public page computes nothing.** `Samen.Fleet.PublicStatus.read/2` calls
   `Registry.read_rows/2` and projects. There is no probing, no staleness arithmetic, no
   scheduler and no second threshold anywhere in the public path.
2. **The projection is a closed two-field struct**, `%PublicStatus.Entry{slug:, status:}`, with
   `@enforce_keys` on both. Widening the public plane requires editing that struct — a visible,
   reviewable act rather than a passing `Map.put/3` in a template.
3. **Publication is opt-in per app and defaults to off** (§4.3).
4. **The surface is unauthenticated and rate-limited** through the one shared seam (§4.4).
5. **It fails closed** (§4.5).
6. **It is framework-first**: a vertical adopts it with one router line and zero authored LOC
   (§6). No vertical re-implements any of it.

## 3. Why a narrowing, not a scrubber

The cockpit row carries `app_id`, `display_name`, `mode`, `transport`, `received_at`,
`stale_after_s` and the producer's `report` payload. A scrubbing design would render from that
row and remove the dangerous fields; every future template edit would then be a chance to
re-add one.

Instead the narrowing happens **one layer below the renderer**, in samen_core. The web module
never holds a row — it holds `Entry` structs — so no change to the HTML can widen the plane.
The `report` payload in particular never crosses: it is schema-validated at ingest but it is
still the only field on the row this cockpit did not author, so keeping it out by construction
is what makes the page token-blind rather than token-scrubbed.

## 4. Mechanism

### 4.1 Storage

One additive column, `flt_app.publish_status` (`:boolean`, `allow_nil?: false`,
`default: false`), declared in `Samen.Fleet.Scope.Blueprint.define_app/5`. Nullable in Postgres
with `DEFAULT false` (the expand-safe shape), so pre-existing rows read `false`: the migration
publishes nothing. Not a `pii_` column, not vault-routed — INV-2 untouched, and the C7
`NoPiiColumns` verifier still runs on the resource.

### 4.2 Two vocabularies, mapped lossily on purpose

| internal (`build_row/3`) | public | rationale |
|---|---|---|
| `:active` | `:operational` | reporting inside its window |
| `:stale` | `:degraded` | dead-man overdue (ADR-044 §4.6) |
| `:unreachable` | `:down` | has never reported |
| `:revoked` (suspended) | `:maintenance` | a credential revocation or suspension is an operator/security **act**; the public plane states an effect, never an act |
| `:deregistered` | *excluded* | the app is gone; it is not "down", and a gone app is not a public incident |
| anything else | `:down` | fail closed — an unrecognised internal state is never an all-clear |

`overall` is the worst published status, or `:unknown` when nothing is published — so an empty
page never renders "operational" for a fleet it is publishing nothing about.

The public vocabulary is deliberately **smaller** than the internal one. That is the point: the
mapping is not a rename, it is a loss of operator-meaningful distinctions.

### 4.3 Opt-in is a DB flag, flipped only by an operator

`Samen.Fleet.Registry.set_publish_status/4` is the only verb. It is gated by the resource's
existing update policy (`Samen.Policy.FleetAdminOnly`), so a `HeartbeatActor` — the reporting
app itself — is refused. That is ADR-044 §4.5's "never an app-initiated verb" lesson applied to
visibility: an app must not be able to publish itself, and the refusal is a policy, not an `if`.

Rejected alternative: a cockpit-side allowlist of published slugs passed to the router macro. It
needs no migration, but it makes publication a **deploy**, and it puts the list in code where a
copy-paste can publish a slug nobody audited. Per-row state with a `false` default is auditable
and reversible in one call.

**The operator ACTION over the verb (added 2026-10-11).** The verb is the mechanism; the
affordance that calls it is `Samen.Web.Operator.FleetDetailLive`'s `phx-click="publish_status"`
control on `/operator/fleet/:app_id` — so a host that mounts the cockpit gets the opt-in exactly
where the app's row already is, at 0 authored host LOC — one `handle_event/3` clause on the
detail LiveView, with no route of its own and no new mount for a host to make.

Its UI gate is deliberately **stricter** than the kernel's, and both halves are named: the
mutation is admitted by `Samen.Policy.FleetAdminOnly` (a `HeartbeatActor` — the app itself — is
refused), while the UI additionally requires `roles[:fleet] == :operator_admin` **and** a role in
**that product** (`@in_product_scope?`). Publication is an act on one product, so a fleet admin
with no role in it is not offered the control. A narrower UI posture than the kernel is the safe
direction: the UI can withhold an affordance it is not sure about, but it can never widen what
the kernel admits.

One property this action owes is honesty about **its own consequence**. What it says publishing
would produce comes from `Samen.Fleet.PublicStatus.preview/1` (the projection's own `status` →
`Entry` mapping, `:excluded` for a `:deregistered` row) and the wording from
`Samen.Web.Fleet.PublicStatus.label/1` (the page's own display strings). `preview/1` and `read/2`
share the ONE renderer, so the cockpit cannot promise a state the page does not report — §1's "no
second notion of up" applied to the surface that flips the switch — and
`samen_core/test/fleet_public_status_test.exs` asserts row-by-row that the two agree. Without that
sharing, the plausible failure is a cockpit that tells an operator "publishing lists `acme-api` as
*Down*" for an app the page reports as operational (a real defect this suite caught while the
change was being written, in an earlier revision that pattern-matched the wrong shape).

### 4.4 Public and rate-limited

Mounted in a host's PUBLIC router scope (no auth pipeline, no `on_mount`, no session, no CSRF) —
the posture `samen_module_routes :kb` and `:csat` already use. The request's identity is not
consulted because there is none; the substrate read runs as the internal
`Samen.Aggregate.Actor` resolved server-side, so **a request parameter can never widen what is
published** (`index/2` ignores params entirely).

The flood guard is the only gate the surface has, so it goes through
`Samen.Web.RateLimit` (ADR-038 §6.1 — never a parallel implementation) as a new
`:public_status_ip` surface, default **120/min per remote IP**, keyed on the IP alone (§6.2's
non-PII key discipline; never persisted). Over the window is a bare **429 with an empty body**:
a differentiated 429 would be an oracle for whether this cockpit publishes anything at all.

The path is `/status`, deliberately **not** under `/fleet`. Everything under `/fleet*` is
authority-gated and cross-checked by `mix samen.verify.fleet_wire` against
`Samen.Fleet.RouteTable.declared/0`; a public path does not belong in that surface, and keeping
it out leaves RP-J-12's "no un-gated `/fleet*` path" enumeration exact rather than carve-out-ridden.

**Fork adaptation (recorded, not silently absorbed):** this fork's suite-wide
`Samen.Web.RateLimit.FloodGuard` (armed by `samen_web`'s test helper) *fails* a test that
consults one limiter bucket more times than its limit on an unpinned, wall-clock-ALIGNED window
— the straddle-the-window hazard. The three limiter tests here are about the LIMIT and the
per-IP KEY, never about where the window falls, so they pin the window with
`Samen.WebTest.RateLimitFlood.pin!/1` while keeping their authored limits verbatim. Pinning is
test-infra only: the shipped `:fix_window` posture, the seam and the backend are untouched.

### 4.5 Fail closed

No namespace, an unreadable namespace, or any raise during resolution is `{:error, :unavailable}`
in the projection and a **503** that says "unavailable" on the page. Never an empty 200: a
reader — human or monitor — takes an empty status page as an all-clear, which is precisely the
fabricated-completeness ADR-014/024/026 refuse. Sabotage 328 is a 200 carrying the unavailable
text, and the named red is the status code.

### 4.6 Masking the one string that crosses

ADR-044 §5.2 already makes `slug` cockpit-side/operator-typed only. This ADR does not take that
on trust. A slug outside the bounded operator shape `[a-z0-9][a-z0-9-]{0,62}` renders `••••`.
`_` is outside the shape, so every `vt_*` vault token is masked on that count alone, and the
`vt_` prefix is refused explicitly as well; so are legal names, e-mail addresses, capitals and
anything with whitespace or punctuation. Both strings that reach the HTML (the bounded slug and
the mount's operator-authored title) are `Plug.HTML.html_escape/1`-escaped.

## 5. Not published, and why

`app_id`/`org_id` (cross-surface correlatable), `display_name` (the likeliest place a tenant's
legal name appears), `base_url` (internal topology), `mode`/`transport`/`received_at`
(operational detail about how often a tenant's infrastructure answers), and the producer
`report` payload. None of these reach the web layer at all.

## 6. Adoption (≈0 LOC)

```elixir
scope "/", MyAppWeb do
  pipe_through :browser
  samen_fleet_status_route(namespace: MyApp.Fleet)
end
```

Mounting it on a live cockpit exposes an **empty** page, never the fleet, until an operator
publishes an app. No vertical contains any part of this feature.

### 6.1 Adopted in this fork: `samenerp` serves `GET /status` (2026-10-11)

`samenerp` mounts it — `samen_fleet_status_route(namespace: Samenerp.Fleet, labels: %{title: "Samen
ERP status"})` in the same public scope as the `:kb` / `:csat` portals. Adoption was NOT one router
line here, and the reason is worth recording: the page projects
`Samen.Fleet.Registry.build_row/3`'s rows, so a route over a namespace that does not exist fails
closed to a **permanent 503** (§4.5 — an empty 200 would read as all-clear). This host held no
fleet registry, so the substrate came with it: `Samenerp.Fleet` (five resources, migration
`20261011120000_mount_fleet_scope`, abbrevs `efa`/`efc`/`efe`/`efr`/`efd` reserved through the
sanctioned allocator) — additive tables, with `efa_publish_status` defaulting to `false`.

That makes samenerp the first product holding a fleet scope, which the 2026-10-08 ruling had
recorded as not being the case. The reversal is **narrow and deliberate**: the host mounts the
read-only public page, and NO `samen_fleet_ingest_routes` mount — that ingest, and therefore the
`POST /fleet/enroll` + `POST /fleet/heartbeat` endpoints, stay unshipped, so RP-J-4b's route
enumeration and ADR-044 §9.3's tiers are untouched. Recorded in `docs/samenerp-mount-ledger.md`
(2026-10-11 amendment) and in ADR-044's adoption-status note. Host-level proof lives in
`samenerp/test/fleet_status_page_test.exs`, which dispatches through the real endpoint.

**Amended the same day (T166b): the cockpit is mounted, so §4.3's action has a UI on this host.**
The paragraph above originally read "no `/fleet*` route at all", which made §4.3's operator action
unreachable on the only host that held a registry to flip — the opt-in existed and could only be
exercised from a console. `samenerp` now mounts
`samen_operator_routes(Samenerp.Operator, …, fleet_cockpit: true, fleet_namespace: Samenerp.Fleet)`
(the T146 `on_mount` gate inherited by construction, RP-J-12) with the three runtime wirings that
make a cockpit read anything: `:fleet_authority` → `Samenerp.FleetAuthz` (delegating to the
operator plane's own resolver — one identity, one authorization decision), `:fleet_products`
(`[:samenerp]`, the atomized per-product tier-2 scope §5.4's publish action checks, so the grant is
provisioned config and not something a registered row confers on itself), and `:fleet, mode:
:manual` (without which `Samen.Fleet.read/2` returns the zero-config `:embedded` self-row and
ignores the namespace). Proof: `samenerp/test/fleet_cockpit_mount_test.exs`, whose ARMED
(`auth_required?: true`) legs publish a probe row through the MOUNTED cockpit under a real
operator-org `:owner` and observe it on this page — with a real `:member` and a principal holding no
operator membership both refused, and the owner's identical call as positive control; adversarial
twin `scripts/sabotages/330-samenerp-fleet-cockpit-mount-dropped.patch`. The console round trip
recorded below stays as the historical record of how the flag was flipped while no cockpit existed
— and it is still the fallback for a host that mounts the registry without a cockpit.

**Who flips the flag on THIS host (2026-10-11), and the live round trip.** As of the T166b
amendment above the opt-in is a click on `/operator/fleet/:app_id`, gated by
`roles[:fleet] == :operator_admin` AND a role in the product (§4.3). The round trip below was
verified when no cockpit existed here, so it went through the release console in the app container
(the same `bin/samenerp eval` the entrypoint's migrate/seed step uses), under an admitted
`Samen.Fleet.AdminActor` — the same verb the UI action calls:

1. registering a probe app and publishing it made `GET /status` render a **real component row** —
   `ops-status-probe` · *Down*, overall "Some published components are down." (the probe has never
   reported, so `build_row/3` → `:unreachable` → §4.2's `:down`, never an all-clear);
2. the app's OWN `HeartbeatActor` was **refused** the same flip — the "never app-initiated" policy,
   checked in production rather than assumed;
3. unpublishing took the row straight back off the page, and the probe row was then deregistered so
   the registry does not keep an app that will never report. The live page is back to publishing
   nothing.

The probe slug was exactly that — a probe — and it was retired rather than left published: the
public plane carries real components, and a fabricated one left standing is the
fabricated-completeness ADR-014/024/026 refuse. Publishing this host's REAL products is an operator
decision this change does not make for anyone.

## 7. Deferred, named (first increment)

**Uptime percentages and an incident TIMELINE are NOT in this increment**, and the page says
nothing about history — it renders current status and a line stating that it reports no history.

Both need decisions this change does not make: a retention window over `flt_report` (which
ADR-046's retention story governs), a bounded rule for what constitutes one "incident" rather
than N adjacent stale reports, and a masking rule for incident *timing* (exact timestamps are
themselves operational detail about a tenant, §5). Rendering "uptime: 100%" computed from
whatever reports happen to be in the table would be exactly the fabricated completeness this
repo refuses, so it is absent rather than approximate. A follow-on backlog row should carry it.

## 8. Proof obligations, discharged

| # | Obligation | Where |
|---|---|---|
| 1 | Opt-in defaults off; registering publishes nothing | `samen_core/test/fleet_public_status_test.exs` + sabotage **325** |
| 2 | A `vt_`-shaped or out-of-shape slug renders `••••`, never plaintext | both test files + sabotage **326** |
| 3 | No `app_id`/`display_name`/`base_url`/payload value/internal enum in the bytes, with an upstream positive control proving each value exists to leak | both test files |
| 4 | Publication is operator-only; the app's own heartbeat actor is refused, with the admin call as positive control | `samen_core/test/fleet_public_status_test.exs` |
| 5 | Rate-limited per IP; over-limit is an empty 429, with a raised-limit positive control | `samen_web/test/samen/web/fleet_public_status_test.exs` + sabotage **327** |
| 6 | Fails closed to a 503 that says so | both test files + sabotage **328** |
| 7 | The mount is genuinely public and carries its namespace — proven by dispatching through a real compiled router | `samen_web/test/support/public_status_router.ex` |
| 8 | Staleness is ADR-044's, not a second one | the `:degraded` test drives `stale_after_s` alone; no threshold exists in the public path |
| 9 | The cockpit's opt-in ACTION is operator-only, reversible, and promises only what the page reports | `samen_web/test/samen/web/fleet_publish_status_test.exs` (admin publish/unpublish reaching `read/2`, the readonly + no-product-role + no-principal refusals, each with the admin call as its positive control) + `preview/1`↔`read/2` agreement in `samen_core/test/fleet_public_status_test.exs` + sabotage **329** |
| 10 | The action is REACHABLE in production — a real host mounts the cockpit with the authority seam it needs, and the ARMED posture publishes through it | `samenerp/test/fleet_cockpit_mount_test.exs` (routes off the compiled route table with the operator `on_mount` on all four, the router's own `live_session` mount, the endpoint renders, and armed green/red with the owner call as positive control) + sabotage **330** |

## 9. Consequences

* G11's last open line closes with no new dependency, no cloud credential and no new probe.
* One more `flt_app` column for any future cockpit host to migrate (two test mounts migrated here).
* `Registry.build_row/3` gains one key (`publish_status`) so the projection can filter without
  re-reading the app rows or re-deriving staleness.
* `Samen.Fleet.PublicStatus.preview/1` and `Samen.Web.Fleet.PublicStatus.label/1` are now PUBLIC
  (2026-10-11): the cockpit's opt-in action states its consequence in the page's own mapping and
  wording, so the internal→public mapping has exactly one implementation and the display strings
  exactly one home. A future status added to §4.2's table must be handled in `public_status/1`
  (it renders `:down` by the fail-closed clause) — and that single edit then flows to both
  surfaces.
* The public/internal vocabulary split is now a thing to maintain: a new internal status must be
  mapped in `public_status/1` or it renders `:down` by the fail-closed clause.
* The opt-in now has a UI wherever a host mounts the cockpit (§6.1's amendment): on `samenerp` that
  means the action is a click whose two gates (`roles[:fleet] == :operator_admin` + a role in the
  product) are the operator plane's OWN roster, read through `Samenerp.FleetAuthz` — so arming the
  host for production closes the console, the cockpit and this page's writes with one config value.
