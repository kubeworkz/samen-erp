# Operator plane — routes, roles, and local sign-in

**Who can reach which `/operator/*` page, and how to get in locally** (ADR-010 operator plane ·
ADR-044 fleet cockpit · ADR-038 §5.5 DLQ). This is the reader-facing map: it names the two gates
every operator route passes, the closed role set, one row per surface with the role it needs, and
the dev/`prod` sign-in stories for the four hosts in this repo.

Stated plainly, because it is the part people get wrong: **the operator plane is not a second
deployment.** It is a set of LiveViews mounted at `/operator/*` by one router macro
(`samen_operator_routes/2`), gated by a role the *host* owns, reading the operator org's own book
of business. Every host that calls the macro inherits every page at ≈0 authored LOC.

---

## 1 · The two gates (in order)

A request to `/operator/accounts` passes **two independent gates**. Knowing which does what is
what lets you tell "not signed in" from "signed in but not an operator".

### Gate 1 — conn-level pipeline `:require_authenticated_operator` → `Samen.Web.AuthGate`

A `Plug` the host pipes its operator scope through. It is **armed only when the host is armed**
(`config :<otp_app>, auth_required?: true`, which the shipped hosts set only in `:prod`). When
armed it checks, in order:

1. **Authentication** — a session carrying either the legacy `samen_current_user` or a live
   identity-spine `samen_session_token`; else redirect to `:login_path` (default `/login`).
2. **Operator role** — the signed-session principal is passed to the host's app-env
   `:operator_authority` MFA; a non-operator return redirects to `/login`.

When **not** armed (dev/test) this plug is a no-op. It is deliberately *defense-in-depth*: it
gates the HTTP dead-render, not the websocket. See `samen_web/lib/samen/web/auth_gate.ex`.

### Gate 2 — `on_mount {Samen.Web.Operator.Authz, :require_operator}` (the real, always-on gate)

`samen_operator_routes/2` puts **every** route it declares into one `live_session` carrying this
hook. It runs in **every environment, including dev** — `auth_required?: false` never relaxes the
*role* check. It resolves operator authority from the **authenticated session principal** (never
from the mount, never from a param) via the mount label `:operator_authority` — an
`{mod, fun, args}` MFA called with the principal id appended — validates the return against
`Samen.OperatorPlane.Actor.roles/0`, and on success assigns `:samen_operator_role`.

**Fail-closed by construction.** No `:operator_authority` seam, a `nil` return, an unknown role,
or an *erroring* resolver ⇒ `{:halt, redirect}` to `:login_path` and **nothing renders**. A plain
authenticated tenant user cannot reach any `/operator/*` surface; neither can an anonymous
visitor. A host that wires nothing gets no operator access, never open access.

> **Where the role comes from — and never from.** The `on_mount` is also the only place a page
> may read `:samen_operator_role`. A page that wants to withhold a control reads *that assign*;
> a `?role=` param or a mount label is never authority. See
> `samen_web/lib/samen/web/operator/authz.ex`.

### Role set (closed)

`Samen.OperatorPlane.Actor.roles/0` — `:operator_admin`, `:operator_support`, `:operator_readonly`,
`:operator_break_glass`. These are **operator roles**, distinct from the tenant role set
(`:owner/:admin/:member/:viewer`). Capabilities:

| Role | Reads the operator CRM | Impersonates a tenant (`may_impersonate?/1`) | In the per-page write predicates¹ | Break glass |
|---|---|---|---|---|
| `:operator_admin` | ✅ | ✅ | ✅ | ❌ |
| `:operator_support` | ✅ | ✅ | ✅ (the day-to-day write role) | ❌ |
| `:operator_readonly` | ✅ | ❌ | ❌ | ❌ |
| `:operator_break_glass` | ✅ | ✅ (superset emergency role) | ❌ | ✅ (the only role `Samen.BreakGlass.authorized?/1` accepts) |

¹ **"In the write predicates" is a per-page fact, not a role property.** Read it as *"is this
role in the sets the write surfaces actually check"* — not as a blanket "may mutate anything".
`:operator_break_glass` is a **read + impersonate + emergency-reveal** role; it is deliberately
*outside* the webhook-DLQ write set (`@write_roles [:operator_admin, :operator_support]`) and
outside `Samen.Automation.Health.may_manage?/1` (also admin/support only). Granting a role is not
granting every write.

---

## 2 · Surface map — route → role

Default prefix is `/operator` (`:path` opt). `A` = `:operator_admin`, `S` = `:operator_support`
(used below). "Any" = any role in the closed set (Gate 2 passed) — the page renders for all four.

| Route | LiveView (all `Samen.Web.Operator.*`) | Read needs | Write needs |
|---|---|---|---|
| `/operator/accounts` | `AccountsLive` | any | create on the writable seat |
| `/operator/accounts/:id` | `AccountDetailLive` | any | — (read + drill-in links) |
| `/operator/billing` | `PlatformBillingLive` | any | — |
| `/operator/revenue` | `RevenueLive` | any | — |
| `/operator/flags` | `FlagAdminLive` | any | kill switch / ramp edits on the writable seat |
| `/operator/analytics` | `AnalyticsLive` | any | the "ask" box — see below |
| `/operator/desk` | `DeskLive` | any | ticket create/delete on the writable seat |
| `/operator/desk/:id` | `DeskDetailLive` | any | reply on the writable seat (NOT session-gated) |
| `/operator/webhooks` | `WebhookDlqLive` | any | **replay / resolve: A or S only** |
| `/operator/aggregate` | `AggregateLive` | any | — (only if `include_aggregate: true`) |
| `/operator/deliverability/:org_id` | `DeliverabilityLive` | any + **live impersonation session** | — |
| `/operator/automation/:org_id` | `AutomationHealthLive` | any + **session** | kill / re-arm |
| `/operator/agents/:org_id` | `AgentHealthLive` | any + **session** | kill / re-arm |
| `/operator/activity/:org_id` | `ActivityLive` | any + **session** | — |
| `/operator/replay/:org_id` | `ReplayLive` | any + **session** | — (the page's one submit IS the session open, on its deny state) |
| `/operator/{deliverability,automation,activity}/resolve` | `FleetResolveLive` | any (redirects) | — |
| `/operator/fleet` | `FleetLive` | **`roles[:fleet] != nil`** | — |
| `/operator/fleet/directives` | `FleetDirectivesLive` | `roles[:fleet]` | publish: `roles[:fleet] == A` |
| `/operator/fleet/register` | `FleetRegisterLive` | `roles[:fleet]` | register/enroll: `roles[:fleet] == A` |
| `/operator/fleet/:app_id` | `FleetDetailLive` | `roles[:fleet]` + `roles[<slug>]` for the row | publish status: `roles[:fleet] == A` |
| `/operator/impersonate` *(host-local)* | `<Host>Web.OperatorImpersonationLive` | A, S or B (`may_impersonate?`) | opens a bounded, reason-required session |

Notes that matter in practice:

- **Posture vs enforcement.** Where a page "withholds" a control it is showing *posture*; the
  kernel Ash policy (`OrgScope`, `RoleAtLeast`, `Samen.Pii.WriteGuard`) is the *enforcement*. The
  framework router only ever mounts the operator workspace on the **operator org's own tenant
  plane** (`plane: :tenant`, PII clear — the SaaS owns it); a hand-made `plane: :operator` mount
  renders **read-only UI**. See `Samen.Web.Operator.Live.writable?/1` and
  `samen_web/lib/samen/web/operator.ex`.
- **The DLQ is the exception that proves the rule.** `replay`/`resolve` are offered *only* to
  `:operator_admin`/`:operator_support`; an `:operator_readonly` session sees the queue plus an
  explicit `#dlq-readonly` note and no control at all. The handler keeps its own gate, and both
  read the same `may_write?/1` predicate, so the page can never offer a write the server would
  refuse (`samen_web/lib/samen/web/operator/webhook_dlq_live.ex`).
- **The DLQ says WHICH silence it is.** Withholding there is per-**row** (the controls render on
  `dead` envelopes only) *and* per-**role**, so an empty action column used to mean either "nothing
  has dead-lettered" or "your role may not write" — and the `#dlq-readonly` note appears in only the
  second case. `#dlq-posture` now renders on **both** postures: it names the resolved
  `:samen_operator_role` (via the same `operator_role_label/2` the chrome uses, and carrying the
  same `data-operator-role` atom), states whether writes are offered on this page at all, and reads
  the dead count — so an operator who is offered nothing knows whether that is the queue or the
  role. It is a *statement of posture*, never authority: `authorize_write/1` is unchanged, and the
  posture bar is proven load-bearing by
  `scripts/sabotages/337-s14-dlq-posture-bar-dropped.patch`.
- **The TENANT chrome offers the console to operators — and only to operators (P18).** A host's
  tenant workspace runs on the operator org's own tenant plane, so an operator who signs in lands
  on a TENANT page (`/crm/dashboard` in samenerp). The shared workspace switcher
  (`Samen.Web.CurrentOrg.switcher/1`) ends with the console entry (`← <operator workspace> →
  /operator/accounts`), and the SETTINGS sidebar — which carries no switcher at all — renders the
  same entry directly, so an operator editing their profile never loses the path back. Two facts
  decide whether it renders: the session's **seat** — the
  operator role `Samen.Web.Operator.Authz.seat_role/2` resolves from the host seam (the mount's
  `:operator_authority` label, else the app-env `config :<otp_app>, :operator_authority`, which
  is what a tenant module mount has) — assigned by `Samen.Web.TenantAuthz` and stashed on the
  mount as the `:operator_seat` label by `Samen.Web.Live.assign_mount/2`; and the workspace
  directory, because the entry must survive an EMPTY list (samenerp seeds only its own operator
  org, which `Samenerp.Directory` excludes, so this is its default state). A plain tenant session
  gets no entry — the link would only dead-end at Gate 2 — and nothing about it grants access:
  everything under `/operator` still runs both gates above. Proofs: `operator_seat_test.exs`,
  `current_org_test.exs`, sabotage 396.
- **A sign-in LANDS an operator on the console (P18).** Offering the entry is not enough when the
  operator's own workspace is the console: `Samen.Web.Auth.SessionController.finish_login/5` now
  picks the destination in this order — (1) an explicit, same-origin `return_to` always wins (a
  deep link, the invite-accept flow's "sign in to continue" included, is the user's instruction);
  (2) otherwise the **seat** decides, resolved through the SAME `Authz.seat_role/2` seam the
  chrome gates the entry on, from the session the login just minted; (3) otherwise the host's
  `:tenant_landing`. So an operator with nothing to return to arrives on
  `Samen.Web.CurrentOrg.operator_console_path/0` (`/operator/accounts` — the one place the path
  is named, used by the entry AND the landing) and a plain tenant sign-in is exactly where it
  was. The open-redirect refusal still runs FIRST: a `//`/absolute `return_to` is dropped before
  either destination is chosen, and an erroring host seam falls back to the tenant landing, never
  to the console. This grants nothing — `/operator/*` still re-derives authority per request.
  Proofs: `samen_web/test/samen/web/login_landing_test.exs` (operator green, tenant control, seat
  keyed on the signer's own principal, `return_to` wins, both open-redirect refusals, and the
  disarmed twin), the host twin `samenerp/test/auth_login_redirect_test.exs` (armed, so operator
  vs tenant is a real roster decision, plus the disarmed dev posture), sabotage 397.
  **A dev-only seat never PLACES anyone.** The seat answers two questions of very different
  weight, so `Samen.Web.Operator.Authz.seat_provenance/1` names which answer it is: `:roster` on
  an ARMED host (a real roster decision, the same one `/operator/*` re-derives) versus `:dev_only`
  on a DISARMED one, where the usual resolver grants an operator role to *everyone*
  (`Samenerp.OperatorAuthz`'s documented fallback, and the shape `dev_operator_role/2` names). The
  chrome still OFFERS the console on a `:dev_only` seat — a developer browsing their own tenant
  workspace wants the door — but the landing ignores it, so a tenant's dev sign-in is exactly
  where it always was: on its tenant dashboard (`/crm/dashboard` in samenerp). Arm the host
  (`config :<otp_app>, auth_required?: true`) to see the operator landing locally. The landing is
  a *destination*, not an entitlement: a host whose seam says "not an operator" is never sent
  there.
- **The chrome names the resolved role.** Every operator page's sidebar footer
  (`Samen.Web.Operator.Live.operator_sidebar/1`) renders the session's `:samen_operator_role` as
  a human label — the *same* assign every write predicate reads — so an operator reading the
  DLQ's `#dlq-readonly` note (or a fleet `*-readonly` note) can see which role they actually
  hold, on the page, without guessing. It falls back to the mount's static `:operator_role` copy
  only when no role was resolved (a mount that never ran the on_mount), and that fallback is
  display only — never authority.
- **A note that withholds a control IS how you ask what each role may do.** The label and the
  notes render the *same* panel (`Samen.Web.Operator.Live.operator_role_help_panel/1`): per
  capability, who holds it, whether THIS session's role does (✓ / —), and what else the capability
  needs. The notes are `<.role_help_note>` — their own sentence is the `<summary>` of a native
  `<details>` (no JS, keyboard-operable) and the panel sits behind it, **focused on the capability
  the note withheld**: `#dlq-readonly` → `dlq_write`, `#publish-readonly` → `fleet_publish`,
  `#register-not-admin` → `fleet_register`, and each drill-in's role-denied state →
  `tenant_drill_in`. Rows are DERIVED from the enforcement wherever a predicate exists
  (`Actor.may_impersonate?/1`, `Samen.Automation.Health.may_manage?/1`,
  `BreakGlass.authorized?/1`); the two with no callable predicate are restated once and PINNED in
  `samen_web/test/samen/web/operator_sidebar_role_test.exs` against the REAL DLQ page, the REAL
  register page and the REAL `Fleet.gate/2`, for every operator role — so the panel cannot drift
  from the behaviour. Notes render ONLY where the control is withheld (a positive control in each
  test proves the note is absent for a role that holds the capability).
- **The per-tenant drill-ins need a session, not just a role.** `deliverability`, `automation`,
  `agents`, `activity`, `replay` all go through `Samen.Web.Operator.Impersonation.gate_socket/3`, which
  composes **T146 role AND T84a org-scope AND a real, reason-required `Samen.Impersonation`
  session**. `:operator_readonly` therefore cannot drill in (it cannot impersonate); the deny
  state renders the open-session affordance — and, for a role that may never open one, the
  withheld-control note (`Live.drill_in_role_denied?/1`, the same `may_impersonate?/1` gate), so
  the operator is not left with a form whose every submit `open/4` refuses. `desk/:id` is
  deliberately *not* session-gated: it is the operator org's own desk on the tenant plane, not a
  tenant drill-in.
- **`replay/:org_id` is a step list, not a screen recording.** It plays back the `nav.visited` /
  product-event ledger a tenant session wrote — WHICH surface, when, and which registered events
  fired in between. The recorder stores only a bounded surface token derived from the LiveView
  module (never a URL, path param, id, keystroke or form value), so there is no vault-routed field
  on the surface and nothing to mask. The page says so in its own `#replay-scope-note`. Full
  design, the player's server-state playhead, and its failure modes:
  [`session-replay.md`](session-replay.md).
- **The analytics "ask" box** mints a `Samen.OperatorPlane.Actor` from the resolved
  `:samen_operator_role`; with no resolved role it fails closed to a non-operator actor the kernel
  refuses — never back to a synthetic tag.
- **Fleet cockpit roles are a second, fleet-wide seam.** `Samen.Web.Operator.Fleet.gate/2` reads
  `Samen.Fleet.Authz.roles_for(otp_app, principal_id)` through the host's `:fleet_authority` MFA
  and requires the reserved `:fleet` scope; tier-2 rows additionally require the product's slug
  scope. Publishing a directive, registering an app, and flipping a product's public status all
  gate on `roles[:fleet] == :operator_admin`. Fail-closed to `%{}`.
- **Break glass is its own role and its own runbook** — see
  [`docs/runbooks/break-glass.md`](../runbooks/break-glass.md). Only `:operator_break_glass` may
  reveal.

---

## 3 · Getting in locally

### 3.1 The fast path — a dev seat with no login (recommended)

All three UI hosts set `config :<app>, auth_required?: config_env() == :prod` and a
`:operator_authority` seam whose **dev fallback returns `:operator_admin` while the host is
disarmed**. So in `MIX_ENV=dev`, Gate 1 is a no-op and Gate 2's seam hands back `:operator_admin`
— **every `/operator/*` page is reachable with no login at all.**

```bash
# driftwood (default port 4010)
cd driftwood
mix deps.get && mix ecto.create && mix ecto.migrate && mix driftwood.seed
mix phx.server
# → http://localhost:4010/operator/accounts
```

```bash
# pawchart (default port 4032)
cd pawchart
mix deps.get && mix ecto.create && mix ecto.migrate && mix pawchart.seed
mix phx.server
# → http://localhost:4032/operator/accounts
```

```bash
# samenerp (default port 4050) — also seeds a REAL admin login (see 3.2)
cd samenerp
mix deps.get && mix ecto.create && mix ecto.migrate && mix samenerp.seed
mix phx.server
# → http://localhost:4050/operator/accounts
```

Each host's `PORT` env var overrides the port; the endpoint binds `127.0.0.1`.

A **generated** app is the same story: `mix samen.gen.app` emits
`config :<otp_app>, :operator_authority, {Samen.Web.Operator.Authz, :dev_operator_role, [<otp_app>]}`
(`samen_core/priv/templates/config_exs_web.eex`), a *named* dev-only grant that returns `nil` the
instant the app is armed — the exploit can never be shipped by omission.

### 3.2 A real local login — the identity spine at `/login`

Driftwood, pawchart and samenerp all mount `samen_auth_routes` (the ADR-035 identity spine), which
**owns `/login`** (plus `/signup`, `/verify`, `/reset`, `/2fa`). POST login is handled by
`Samen.Web.Auth.SessionController`.

- **samenerp is the turnkey one.** `mix samenerp.seed` creates the operator org and an admin
  credential and prints them:

  ```
  mix samenerp.seed
  # Email:    admin@samenerp.kubeworkz.io
  # Password: changeme123456
  ```

  Then browse `http://localhost:4050/login`, sign in, and open `/operator/accounts`. Pass
  `--email … --password …` to seed your own. `Samenerp.OperatorAuthz.resolve_role/2` maps the
  operator-org **Membership** role to the operator role (`:owner → :operator_admin`,
  `:admin → :operator_support`, `:member → :operator_readonly`, no membership → denied).
- **driftwood and pawchart do not ship a workable local password on purpose.** Driftwood's
  `:auth_credentials` is `%{}` — *"this PUBLIC repo commits no working password"*
  (`driftwood/lib/driftwood/auth.ex`). Use the dev seat (§3.1), sign up through `/signup`, or
  inject a credential at runtime.

### 3.3 Exercising a specific (non-admin) role locally

To see a *role-restricted* page — the DLQ read-only posture, a fleet publish refusal, a
read-only drill-in denial — you need a real role, which means arming the host and listing the
principal in its roster:

| Host | Seam to edit | Shape |
|---|---|---|
| driftwood | `config :driftwood, :operator_roster` (empty by default) | `%{"<principal_id>" => :operator_readonly}` |
| pawchart | `config :pawchart, :operator_roster` | ships `%{"op-pawchart-platform" => :operator_support}`; add your principal |
| samenerp | the operator-org `Membership` row's role | `:member → :operator_readonly`, etc. |
| generated app | replace `{Samen.Web.Operator.Authz, :dev_operator_role, [app]}` | with a real roster resolver |

Then arm the host (`config :<app>, auth_required?: true`) so the roster is the *only* authority
and the dev grant is gone. `Samen.Web.Operator.Authz.dev_operator_role/2` is the named framework
default you are replacing, not a thing to extend.

**Worked example — the DLQ read-only view:** seed a dead envelope, set
`config :driftwood, :operator_roster, %{"<you>" => :operator_readonly}`, arm the host, log in,
and open `/operator/webhooks`. You should see the envelopes, the `#dlq-readonly` explanation, and
**no** Replay/Resolve control — plus a `#dlq-posture` bar reading *Writes withheld* with your role
named and *"1 dead below still need an operator who may write"*, so the empty action column is
never mistaken for an empty queue. Flip the roster entry to `:operator_support` and reload: the
controls appear and the bar reads *Writes offered*. (That pair is asserted by
`samen_web/test/samen/web/webhook_dlq_authz_test.exs`.)

### 3.4 Arming for prod (what changes)

`config_env() == :prod` flips `auth_required?` to `true` (and `Samen.Web.TenantGate` **refuses to
boot** a prod host that is explicitly disarmed). Gate 1 then becomes live, both gates require a
principal the roster/seam calls an operator, and an unlisted principal is refused on a prod-armed
app *even if* you left the dev resolver wired. The deploy runbook
(`samen_core/priv/templates/deploy_runbook.eex`) carries this as an Operator TODO.

---

## 4 · What each host in this repo mounts

| Host | Operator mount | Cockpit | Local entry |
|---|---|---|---|
| **driftwood** | `samen_operator_routes/2` (`include_aggregate: false` — it mounts its own freight-shaped `/operator/aggregate` in a separate `live_session`) + host-local `/operator/impersonate` | ✗ | port 4010 |
| **pawchart** | `samen_operator_routes/2` (`include_aggregate: false`) + host-local `/operator/impersonate` | ✗ | port 4032 |
| **samenerp** | `samen_operator_routes/2` with **`fleet_cockpit: true, fleet_namespace: Samenerp.Fleet`** → `/operator/fleet`, `/operator/fleet/directives`, `/operator/fleet/register`, `/operator/fleet/:app_id` | ✅ (only host in this repo) | port 4050 |
| **demo** | none — its router is a bare `Plug.Router` forwarding `/api/v1` only (`demo/lib/demo_web/router.ex`); the demo host is API-only | ✗ | — |

Both fleet-cockpit seams are wired in `samenerp/config/config.exs`: `:fleet_authority →
Samenerp.FleetAuthz` and `:fleet_products, [:samenerp]`. `Samenerp.FleetAuthz` **delegates to
`Samenerp.OperatorAuthz`**, so one identity gets one authorization decision for both planes.

---

## 5 · Where the code lives

| Concern | File |
|---|---|
| The mount macro (every route below) | `samen_web/lib/samen/web/router.ex` · `samen_operator_routes/2` |
| The always-on role gate | `samen_web/lib/samen/web/operator/authz.ex` |
| The conn-level prod plug | `samen_web/lib/samen/web/auth_gate.ex` |
| The closed role set + `may_impersonate?/1` | `samen_core/lib/samen/operator_plane/actor.ex` |
| Fleet-wide role seam (`roles[:fleet]`) | `samen_core/lib/samen/fleet/authz.ex` · `samen_web/lib/samen/web/operator/fleet.ex` |
| Per-tenant drill-in gate (role + scope + session) | `samen_web/lib/samen/web/operator/impersonation.ex` |
| The operator sidebar / `writable?/1` posture | `samen_web/lib/samen/web/operator/live.ex` |
| The tenant chrome's operator SEAT (`seat_role/2`) | `samen_web/lib/samen/web/operator/authz.ex` |

Proofs worth reading alongside this doc: `samen_web/test/samen/web/webhook_dlq_authz_test.exs`,
`fleet_cockpit_authz_test.exs`, `operator_scope_gate_test.exs`,
`driftwood/test/operator_authz_test.exs`, `pawchart/test/operator_authz_test.exs`,
`samenerp/test/fleet_cockpit_mount_test.exs`.

---

## Related

- [Two-plane + masking concepts](../concepts/two-plane-masking.md) — why the operator seat is the
  tenant plane and drill-ins are masked.
- [ADR-010 operator plane](../adr/ADR-010-operator-plane.md) · [ADR-044 fleet cockpit](../adr/ADR-044-fleet-cockpit.md) · [ADR-038 §5.5 webhook DLQ](../adr/ADR-038-adapter-architecture.md)
- [Break-glass runbook](../runbooks/break-glass.md)
