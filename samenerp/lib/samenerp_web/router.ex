defmodule SamenerpWeb.Router do
  @moduledoc """
  The Samenerp host router (ADR-009 reuse proof, scaffolded by `mix samen.gen.app`).

  The ENTIRE product UI is MOUNTED from samen_web via `Samen.Web.Router` macros —
  zero Samenerp LiveView modules authored:

    * `samen_module_routes(:billing, ...)` — the authored scope's inherited pages
      (overview / invoices / plans),
    * `samen_notes_routes(:notes, ...)` — the WS-Notes block-page index + editor over
      this host's Docs mount (ADR-053 Phase 6; the macro sets the `:pages_path` label
      itself, so the Documents → Pages nav item comes with the mount),
    * `samen_notifications_routes(...)` — the framework notifications inbox
      (+ /notifications/settings) over the Primitives mount,
    * `samen_operator_routes(...)` — the ADR-010 operator workspace (accounts ·
      platform billing · revenue · flags · analytics · desk) over the operator
      namespace; the `flags_namespace` label activates the flag admin over this
      app's FeatureFlag rows,
    * `samen_session_routes()` — the ADR-013 current-org session write (the
      workspace switcher + the operator "Open account →" target),
    * `samen_auth_routes(...)` — the ADR-035 §5 IDENTITY-SPINE pre-actor surfaces
      (signup A1 · verify A2 · reset A3 · login A4 · 2fa A7 · invite A5), over
      this app's sole Identity mount (`Samenerp.Operator`),
    * `samen_onboarding_routes(...)` — the ADR-035 §5 A8 first-run wizard
      (org-naming · plan-selection honest empty state · teammate invite).

  The public JSON:API (WS-D D3) is FORWARDED to `SamenerpWeb.Api.Endpoint`
  under the versioned `/api/v1` namespace.

  Every tenant/shared mount carries the `@current_org_labels` seam, whose
  `:authn` label (`{:app_env, :samenerp, :auth_required?}`) is the
  prod-safety gate: OFF in dev/test (the query-param convenience identity stays),
  ON in prod (the actor is derived only from an authenticated session — see
  `Samen.Web.CurrentOrg`). Flipping `config :samenerp, :auth_required?`
  to `true` closes the spoofable `?org=`/`?user=` URL-param resolution path.

  ## The tenant AUTH GATE is emitted by the route macros (B-SEC)

  There is deliberately NO hand-written tenant auth plug in this router. Every
  `samen_*_routes` tenant macro emits its `live_session` carrying
  `on_mount: [{Samen.Web.TenantAuthz, :require_tenant}]` — the framework-side
  gate that (1) `:halt`s an armed, UNAUTHENTICATED tenant request before anything
  renders (an `on_mount` halt is the only thing that preempts `handle_params/3`
  on Phoenix LiveView's initial DEAD RENDER) and (2) PINS the org authority into
  the socket so a client `?org=` can only SELECT among the authenticated
  principal's authorized orgs, never name a new identity. A generated app is
  therefore secure-by-construction: you cannot mount a tenant surface here and
  forget the gate, because the gate travels with the macro. The operator plane
  keeps its own conn-level `:require_authenticated_operator` pipeline below —
  it derives its scope from the well-known operator org id, not `CurrentOrg`.
  """
  use Phoenix.Router
  import Phoenix.LiveView.Router
  import Samen.Web.Router

  # ADR-031/ADR-035/ADR-045 — the current-org data-on-the-mount labels shared by every
  # tenant/shared mount. `:authn` is the launch AUTH gate (the driftwood
  # convention): `{:app_env, :samenerp, :auth_required?}` — false in
  # dev/test (query-param convenience), true in prod (session-derived actor
  # only, ARMED BY DEFAULT — ADR-045 §2). `:identity_namespace` names this app's
  # Identity mount (`Samenerp.Operator`) so an ARMED (prod) host derives the
  # caller's REAL `Identity.Membership` role for tenant `write_scope` instead of
  # failing closed to `:member` (ADR-045 §4.4, the S12 residual).
  # `:org_directory` is the `{mod, fun, args}` seam `Samen.Web.CurrentOrg.list_orgs/1`
  # reads for the workspace switcher + the RESOLVED org display name — without it every
  # sidebar header + topbar breadcrumb fell back to the static "Workspace" string
  # (`Samenerp.Directory.orgs/0` — tenant orgs only, operator/debris excluded).
  # `:erp_path` is the WS-ERP E8 nav seam: its PRESENCE is what makes
  # `Samen.UI.module_nav/1` render the six-item ERP group on every framework sidebar (the
  # X1 dead-link guard — a host that never calls `samen_erp_routes/3` never sets it, so it
  # never emits `/erp/*` links). MUST match the `samen_erp_routes(:erp, …)` path below.
  # Module attributes (compile-time literals) so they are usable inside the framework
  # route-macro expansions; all values are session-safe.
  @current_org_labels %{
    authn: {:app_env, :samenerp, :auth_required?},
    identity_namespace: Samenerp.Operator,
    org_directory: {Samenerp.Directory, :orgs, []},
    erp_path: "/erp",
    # WS-ERP E9/E15-nav seams — same presence-is-the-guard posture as `erp_path`:
    # non-nil ONLY because the routes below are mounted, so every framework sidebar
    # renders the Banking/Work groups with links this router actually serves.
    banking_path: "/banking",
    work_path: "/work",
    # The Banking↔Finance bridge (same shape as marketing's `:crm_namespace`): the
    # banking mount resolves its GL account / journal-entry references through THIS
    # host's Finance namespace (BankAccount.account_id → Account, Match → JournalEntry).
    erp_namespace: Samenerp.Erp,
    # SIDEBAR-REACHABILITY (2026-10-10) — the seven mount phases' module groups, made
    # reachable from the app's OWN sidebar. Same presence-is-the-guard posture as
    # `erp_path`/`banking_path`/`work_path` above: `Samen.UI.Nav.nav_paths/1` resolves each
    # of these off EVERY tenant mount (they ride this shared label map), and a group renders
    # exactly when its label is non-nil — so deleting a line here removes that module's nav
    # group rather than emitting a link to a route this router does not serve. Each path MUST
    # match the mount macro below it (`samen_files_routes(:files, …)` etc.); they are TENANT
    # paths, and `nav_paths/1` only resolves them on a tenant-plane mount, so they can never
    # leak into operator chrome.
    files_path: "/files",
    # WS-Notes Phase 6 — the Pages surface (ADR-053 §8 O4). The SAME presence-is-the-guard
    # posture as every path in this map: `Samen.UI.Nav.nav_paths/1` resolves `:pages_path`
    # off EVERY tenant mount (the sidebar is inherited chrome), so the Documents → Pages item
    # appears on pages OTHER than /pages exactly because this line exists. `samen_notes_routes/3`
    # also sets the label on its OWN mount; this shared copy is what carries it everywhere else.
    # It MUST match the mount's `path:` below — `mix samen.verify.nav_links` fails a label that
    # outruns the router.
    pages_path: "/pages",
    chat_path: "/chat",
    search_path: "/search",
    analytics_path: "/analytics",
    ics_path: "/calendar.ics",
    ai_path: "/ai",
    flags_path: "/flags",
    # PP-9 (Batch 3 NAV-REACHABILITY) — the T118 workflow builder. The SAME
    # presence-is-the-guard posture as every path above: the Workspace group's Automation item
    # renders exactly because this host mounted `samen_automation_routes(:automation, …)` below,
    # and `mix samen.verify.nav_links` fails any host whose label outruns its router.
    automation_path: "/automation",
    # P17 next-step seam (2026-10-15) — the path `Samen.Web.Tenant.AnalyticsLive` builds the
    # "ask an owner to raise your role" link from when the page refuses a role. The SAME
    # presence-is-the-guard posture as every path above: this host mounts
    # `samen_settings_routes(:settings, …)` at exactly this path below, so declaring it makes the
    # link live instead of leaving the refused caller with a reason and no way to act. (The
    # settings mount sets its own copy — this rides the shared tenant labels so the analytics
    # mount carries it too, and `mix samen.verify.nav_links` fails a label that outruns the
    # router.)
    settings_path: "/settings"
  }

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_session)
    plug(:put_root_layout, html: {SamenerpWeb.Layouts, :root})
    plug(:protect_from_forgery)
    # ADR-035 §5 A4 — resurrect a remember-me token into the Plug session before
    # any LiveView mounts, so the subsequent `on_mount` hooks see it. Harmless when
    # no remember cookie is present (request proceeds unauthenticated — enforcement
    # is the `on_mount`'s job, mirroring the `CurrentOrg` plug/on_mount split).
    plug(Samen.Web.Auth.Plug, namespace: Samenerp.Operator)
  end

  # Phase 4 — the SHARED webhook ingress pipeline (ADR-038 §5.1). Deliberately NOT
  # the `:browser` pipeline: external providers cannot carry a CSRF token and this
  # route does no session/org reads — the HMAC over the EXACT raw bytes is the
  # authentication (the endpoint already wires `Samen.Web.Webhook.RawBodyReader`
  # into `Plug.Parsers`, so the signed bytes survive decoding; same body_reader
  # every `samen_webhook_routes/1` host wires). NO `protect_from_forgery`, NO
  # session plug — a forged/unsigned delivery is refused by the ingress's own
  # verify step (400 "invalid_signature"), not by a token the vendor never had.
  pipeline :webhook_ingress do
    plug(:accepts, ["json", "html"])
  end

  # T117/ADR-031 — the OPERATOR control-plane auth gate. `Samen.Web.AuthGate` is a NO-OP in
  # dev/test (`:auth_required?` false — the query-param convenience identity stays) and, in
  # prod, redirects any UNAUTHENTICATED request to `/login` before the SaaS-internal operator
  # surfaces render. The tenant/shared mounts are already gated by the `:authn` seam through
  # `Samen.Web.CurrentOrg`, but the operator mount derives its scope from the well-known
  # operator org id (NOT CurrentOrg), so it needs this conn-level gate — the driftwood
  # `plug(DriftwoodWeb.Auth)` house pattern, scoped to the operator plane.
  pipeline :require_authenticated_operator do
    plug(Samen.Web.AuthGate, otp_app: :samenerp, namespace: Samenerp.Operator)
  end

  # WS-D D3 — the versioned public API surface. `forward` sends `/api/v1/*` to the
  # AshJsonApi endpoint (key-auth → page-limit clamp → the generated JSON:API router
  # over `Samenerp.Vertical`). The declared route `/records` is reached at
  # `/api/v1/records` externally — the stable public contract (doc §external-surface
  # "explicitly versioned, URL-namespaced, e.g. /api/v1").
  forward("/api/v1", SamenerpWeb.Api.Endpoint)

  scope "/", SamenerpWeb do
    pipe_through(:browser)

    get("/", PageController, :index)
    get("/healthz", PageController, :healthz)
    get("/readyz", PageController, :readyz)

    # API Docs (README "API Documentation" card) — the generated OpenAPI 3.0
    # spec for the `/api/v1` JSON:API surface. Static JSON, no actor/org data.
    get("/api/openapi.json", PageController, :openapi)
  end

  # The inherited product UI, MOUNTED from samen_web. BARE `scope "/"` (no
  # `SamenerpWeb` alias): the mounted LiveViews are the framework's own
  # `Samen.Web.*` modules — aliasing under `SamenerpWeb` would wrongly resolve them.
  scope "/" do
    pipe_through(:browser)

    # ADR-013 §4.3 — the framework SESSION-write endpoint (`POST /session/org/:org_id`;
    # the stale GET redirects without switching — luminary S7. CSRF-protected via this
    # pipeline's `protect_from_forgery`).
    samen_session_routes()

    # ADR-035 §5 A1–A5/A7 — the IDENTITY-SPINE pre-actor auth surfaces
    # (signup → verify → reset → login → 2fa → invite), mounted over this app's
    # sole Identity mount (`Samenerp.Operator`) in ONE line. Pre-actor
    # public (no plane/org data). The generated app is the first host to serve
    # the full framework auth path with zero hand-edits (A9).
    #
    # PP-7 (post-login landing) — `tenant_landing:` names where a login with NO
    # explicit `return_to` lands (the ordinary case: a bookmark, a fresh tab, the
    # invite-accept / email-verify "log in" links). Without it the framework
    # fallback is the neutral `"/"` — this host's MARKETING page — so every
    # successful login bounced back to the homepage instead of opening the
    # tenant workspace. Wired to the tenant CRM Dashboard (the sidebar's
    # "Dashboard" target) so login lands IN the workspace.
    samen_auth_routes(
      namespace: Samenerp.Operator,
      repo: Samenerp.Repo,
      labels: %{tenant_landing: "/crm/dashboard"}
    )

    # ADR-035 §5 A8 — the FIRST-RUN onboarding wizard (`GET /onboarding`):
    # org-naming, plan-selection (the honest "no plans configured" empty state —
    # no `:plan_labels` hook wired until the host adds billing, INV-4), teammate
    # invite (T05's real Invite flow). Same Identity mount as the auth spine.
    samen_onboarding_routes(Samenerp.Operator, repo: Samenerp.Repo)

    # 1. Billing — the mounted samen_core Billing scope's inherited pages. Carries
    #    the `@current_org_labels` seam so the `:authn` prod gate governs actor
    #    resolution (query-param convenience in dev/test; session-only in prod).
    samen_module_routes(:billing, Samenerp.Billing, repo: Samenerp.Repo, labels: @current_org_labels)

    # 1a. CRM — Companies, Contacts, Pipeline, Opportunities (inherited from samen_core)
    samen_module_routes(:crm, Samenerp.Crm, repo: Samenerp.Repo, labels: @current_org_labels)

    # 1b. Marketing — Campaigns, Segments, Subscribers, Templates (inherited from samen_core)
    #
    #     `:crm_namespace` is the Marketing↔CRM namespace BRIDGE the framework reads in
    #     `Samen.Web.Marketing.Live.crm_mount/1` — it is what lets the Marketing mount
    #     derive a CRM-kind mount (same repo + plane → identical PiiResolution) for the
    #     Leads lens (`/marketing/leads`) and the read-only Lead detail page
    #     (`/marketing/leads/:id`). The label is EXPANDED AT COMPILE TIME into this
    #     live_session, so a host that omits it gets the honest-ABSENT posture by
    #     design: an always-empty leads list and an always-"Lead not found." detail
    #     page, never a crash. Wiring it is the host's job, not the framework's.
    samen_module_routes(:marketing, Samenerp.Marketing,
      repo: Samenerp.Repo,
      labels: Map.put(@current_org_labels, :crm_namespace, Samenerp.Crm)
    )

    # 1c. Support — Tickets + detail + KB (inherited from samen_core's Support
    #     scope, mounted on the Samenerp.Support domain). Phase 5 wires the
    #     `:kb_namespace` sibling-mount seam so the agent-facing KB
    #     (`/support/kb`) reads THIS host's CMS articles (`Samenerp.Cms`, the
    #     Phase-5 mount below) instead of rendering the honest "KB not set up"
    #     empty state.
    samen_module_routes(:support, Samenerp.Support,
      repo: Samenerp.Repo,
      labels: Map.put(@current_org_labels, :kb_namespace, Samenerp.Cms)
    )

    # 1d. Automation — the tenant workflow builder (ADR-039/T118), mounted on
    #     the Samenerp.Automation domain. Tenant plane ONLY (INV-2).
    samen_automation_routes(:automation, Samenerp.Automation,
      repo: Samenerp.Repo,
      labels: @current_org_labels
    )

    # 1e. Settings — Profile · API keys · HuggingFace · Security · Invitations ·
    #     Reveal approvals (WS-E E5), mounted over this app's Identity namespace
    #     (`Samenerp.Operator` — Credential + Session + TOTP columns already exist
    #     from `mount_operator_scopes`). `spine_*` opt-ins flip Security from its
    #     honest placeholders to the REAL session list/revoke + 2FA enrollment.
    samen_settings_routes(:settings, Samenerp.Operator,
      repo: Samenerp.Repo,
      labels: @current_org_labels,
      spine_totp: true,
      spine_sessions: true
    )

    # 1c. WS-ERP E8 — the six ERP tenant surfaces (CoA / journal / AP inbox /
    #    stock / purchase orders / work orders) over the `Samenerp.Erp` mount
    #    in ONE line: the surface allowlist + bounded columns live in
    #    `Samen.Web.Erp` (the registry IS the boundary), the generic
    #    read-only `Samen.Web.Erp.SurfaceLive` serves every path.
    samen_erp_routes(:erp, Samenerp.Erp, repo: Samenerp.Repo, labels: @current_org_labels)

    # 1f. WS-ERP E9 — Banking (bank accounts · statement lines · guarded match ·
    #     rules) over the `Samenerp.Banking` mount: the five bka/bkl/bki/bkm/bkr
    #     tables already exist from migration 20260918010000; this mount + the
    #     catalog-sync migration make them governed and reachable in ONE line.
    samen_module_routes(:banking, Samenerp.Banking,
      repo: Samenerp.Repo,
      labels: @current_org_labels
    )

    # 1g. Work (F1 / ADR-041) — tasks · projects · timeline · tree, over the
    #     `Samenerp.Work` mount (the same scope pawchart/driftwood/pawchart mount).
    samen_module_routes(:work, Samenerp.Work,
      repo: Samenerp.Repo,
      labels: @current_org_labels
    )

    # 1h. Files (G8/ADR-009) — the framework upload/preview surface over this host's
    #     Primitives mount (`Samenerp.Primitives.File`, efl_file already exists).
    #     Same one-line adoption driftwood ships.
    samen_files_routes(:files, Samenerp.Primitives,
      repo: Samenerp.Repo,
      labels: @current_org_labels
    )

    # 1h-2. WS-Notes Phase 6 — the tenant PAGES surface (ADR-053 §8 O4): the block-page
    #       index (`/pages`) and the page editor (`/pages/:id`) over this host's Docs
    #       mount (`Samenerp.Docs`, migration 20261018120000). The macro sets `:pages_path`
    #       ITSELF (like `samen_ai_routes`), so mounting the surface is the whole opt-in:
    #       the Documents group's Pages item renders exactly because this line exists (X1
    #       dead-link guard — `mix samen.verify.nav_links` fails a label that outruns the
    #       router, and a host that never mounts it never emits the link).
    #
    #       `:search_index` names this host's Primitives registry (`esh_search_index`): the
    #       Docs namespace has no SearchIndex of its own, so `Samen.Web.Notes.Search` reads
    #       it from this seam and fails CLOSED to `[]` without it — never a guessed module,
    #       never an unbounded scan. Registration is host setup
    #       (`Notes.Search.register_index/2`); its guard refuses a vaulted column, so
    #       `pii_edb_text_secure` can never enter the tsvector.
    samen_notes_routes(:notes, Samenerp.Docs,
      repo: Samenerp.Repo,
      search_index: Samenerp.Primitives.SearchIndex,
      labels: @current_org_labels
    )

    # 1i. Phase 2 — ADR-012 flagship cross-plane CHAT, TENANT plane (the org's own
    #     chat console; bodies + identities in the clear on this plane). Over this
    #     host's materialized `Samenerp.Chat` scope (tables from migration
    #     20261006130000). `:pubsub` names the running PubSub server the realtime
    #     path broadcasts on; the Presence server rides the same PubSub in
    #     `Samenerp.Application`. No `:object_cards` — this host catalogs no bespoke
    #     unfurl card; every catalogued resource unfurls via the framework default
    #     cards with zero cards written.
    samen_chat_routes(:chat, Samenerp.Chat,
      repo: Samenerp.Repo,
      labels: Map.merge(@current_org_labels, %{pubsub: Samenerp.PubSub})
    )

    # 1j. Phase 3 — Search & Discovery, three one-liners and zero authored
    #     LiveViews:
    #
    #     * `samen_search_routes` — the ⌘K search page (WS-E E4 / ADR-027) over
    #       this host's Primitives registry (`esh_search_index` — rows the
    #       engine reads per-scope; the tsvector is built at QUERY TIME from
    #       the registered non-PII columns, so results are org-scoped +
    #       PiiResolution-projected by the kernel, never by this router).
    #       This is also what makes the framework sidebar's search box (whose
    #       action defaults to `/search`) resolve instead of dead-linking.
    #     * `samen_csv_routes` — the CSV import LiveView + masked export
    #       download (WS-E E3 / ADR-028) over the CRM domain, the same
    #       driftwood/pawchart adoption: resolve_resource/2 is DENY-BY-DEFAULT
    #       onto Samenerp.Crm's registered resources only (`/csv/export/company`
    #       serves; anything else 404s — no module minting).
    #     * `samen_tenant_analytics_routes` — the P17 own-org activation funnel
    #       (ADR-045 §3) over the raw `paf_product_event_rollup` (migration
    #       20261006140000; samenerp had NO rollup tables before Phase 3 —
    #       the mounted /operator/analytics and /operator/revenue read those
    #       tables by name, so that migration closes those latent holes too).
    #       Floored (k-anonymity) + role-gated by the framework reads; an empty
    #       table renders the honest empty state, never fabricated counts.
    samen_search_routes(:search, Samenerp.Primitives,
      repo: Samenerp.Repo,
      labels: @current_org_labels
    )

    samen_csv_routes(:csv, Samenerp.Crm,
      repo: Samenerp.Repo,
      labels: @current_org_labels
    )

    samen_tenant_analytics_routes(Samenerp.Primitives,
      repo: Samenerp.Repo,
      labels: @current_org_labels
    )

    # 1k. Phase 4 — the TENANT feature-flag admin (WS-B B6 / ADR-020): ONE line
    #     over this host's Primitives mount (`eff_feature_flag` rows already
    #     exist from mount_primitives_scope). Writes are kernel-enforced
    #     (OrgScope + RoleAtLeast :admin + the NonPiiTargeting write refusal);
    #     the framework sidebar/settings nav's "Feature flags" item (default href
    #     `/flags`) resolves instead of dead-linking.
    samen_flags_routes(:flags, Samenerp.Primitives,
      repo: Samenerp.Repo,
      labels: @current_org_labels
    )

    # 1l. Phase 5 — the two PUBLIC portal kinds (the KB + CSAT module groups),
    #     mounted in this router's one public scope (the `samen_auth_routes`
    #     posture: pre-actor, no session-derived org). Both are kernel-safe by
    #     construction, so neither needs a tenant auth gate:
    #
    #     * `:kb` — the UNAUTHENTICATED self-serve help center
    #       (`GET /portal/:org` → `Samen.Web.Support.PortalKbLive`) over the
    #       `Samenerp.Cms` mount. It reads ONLY `Post.read_public`
    #       (visibility: :public AND status: :published — the action's own
    #       baked-in filter is the whole authorization surface), and `:org`
    #       comes from the URL path because an anonymous visitor has no session
    #       to derive it from.
    #     * `:csat` — the UNAUTHENTICATED tokenized CSAT survey response
    #       (`GET /support/csat/:token` → `Samen.Web.Support.CsatRespondLive`)
    #       over the `Samenerp.Support` mount (the zct/zca tables already exist
    #       from the 20260922020000 support-scope mount — no migration needed).
    #       The single-use 256-bit token in the path IS the entire authorization
    #       surface (org/ticket derive FROM the token match, never a client
    #       `?org=`), and the write fires only from the score-form submit.
    samen_module_routes(:kb, Samenerp.Cms,
      repo: Samenerp.Repo,
      path: "/portal",
      labels: @current_org_labels
    )

    samen_module_routes(:csat, Samenerp.Support,
      repo: Samenerp.Repo,
      labels: @current_org_labels
    )

    # 1l-bis. ADR-050 (G11) — the PUBLIC fleet STATUS PAGE (`GET /status`), the one
    #     fleet-substrate surface with no authority gate on it, in the SAME public
    #     scope as the two portal kinds above (no auth pipeline, no `on_mount`, no
    #     session, no CSRF). It projects `Samen.Fleet.PublicStatus.read/2` — the
    #     token-blind narrowing of the status the registry already computed (ADR-044
    #     §4.6 dead-man staleness) — over this host's `Samenerp.Fleet` mount, which
    #     migration 20261011120000 added for exactly this purpose. It re-probes
    #     nothing and publishes NOTHING until an operator opts an app in with
    #     `Samen.Fleet.Registry.set_publish_status/4` (`efa_publish_status` defaults
    #     to false), so the landed state is an empty page, never the registry.
    #
    #     The path is deliberately NOT under /fleet: the `/fleet*` family is
    #     authority-gated and cross-checked by `mix samen.verify.fleet_wire` against
    #     `Samen.Fleet.RouteTable.declared/0`. This router mounts that family's
    #     REPORTING half (`GET /fleet/health` + `POST /fleet/directive`, below) and, as of
    #     2026-10-11, the operator-side COCKPIT (`fleet_cockpit: true` on the operator mount
    #     further down) — while the cockpit-side INGEST (`samen_fleet_ingest_routes`:
    #     POST /fleet/enroll + POST /fleet/heartbeat) stays unshipped, the one-directional
    #     shape ADR-044 §3.1/§9.2 design for and the only delta the mount ledger still rules
    #     on. The public page must not sit behind that authority gate. Rate-limited
    #     per remote IP through the shared `Samen.Web.RateLimit` seam
    #     (`:public_status_ip`, 120/min); over the window is a bare empty-bodied 429.
    samen_fleet_status_route(
      namespace: Samenerp.Fleet,
      labels: %{title: "Samen ERP status"}
    )

    # 1m. Phase 6 — the Calendar & Scheduling group: the framework `.ics`
    #     (RFC-5545) export surface over this host's materialized
    #     `Samenerp.Calendar` mount (`evt_event`, migration 20261007090000).
    #     ONE line, zero authored controllers: `Samen.Web.Ics.ExportController`
    #     serves `GET /calendar.ics` org-scoped and keyset-bounded, resolving
    #     every row through `Samen.Api.PiiResolution` on the acting plane — so
    #     the downloaded feed and the pixel show the SAME attendee value
    #     (INV-1). A plain controller route, hence `:browser` (it reads the
    #     session for the org) rather than a `live_session`.
    samen_ics_routes(:ics, Samenerp.Calendar,
      repo: Samenerp.Repo,
      labels: @current_org_labels
    )

    # 1n. Phase 7 — the framework AI plane (ADR-043 §5.3 / ADR-047 A6), the LAST
    #     unmounted module group. ONE macro call mounts all NINE tenant AI surfaces
    #     over this host's materialized `Samenerp.Crm` mount + the AI domain tables
    #     from migration 20261007120000:
    #
    #       * `/ai` — the verbs; `/ai/search` — semantic search; `/ai/crm` — the CRM
    #         ask surface; `/ai/analytics` — the aggregate ask-box; `/ai/support` —
    #         the support-reply draft (persisted via the `ai_support_reply` approval
    #         kind registered in config);
    #       * `/ai/agents` + `/ai/agents/:id` — the ADR-047 A5 agent runs (list, run
    #         detail with the bounded turn log + the 🔒 vaulted transcript resolved on
    #         the caller's plane, cancel, and the approve/reject decision card for a
    #         run parked `:awaiting_approval`);
    #       * `/ai/assistant` (+ `:assistant_id` / `:id`) — the OpenClaw-lite
    #         assistant threads over the vault-routed conversation transcript.
    #
    #     `Samen.Web.TenantAuthz`'s `:require_tenant` rides INSIDE the macro, so the
    #     new routes carry the same tenant gate every other framework surface has.
    #     Every surface is fail-honest by construction: with no provider configured
    #     (this host wires none — secrets live in runtime config, never the repo) each
    #     renders `Samen.AI.configuration_hint/0` and the SIMULATED badge rather than a
    #     fabricated answer. The `ai_*` labels are the GROUNDING seams the kit reads
    #     (the `flags_namespace`/`:kb_namespace` pattern): the CRM surface grounds on
    #     this host's Company resource, the analytics ask-box on its token-blind
    #     aggregate projection.
    samen_ai_routes(:ai, Samenerp.Crm,
      repo: Samenerp.Repo,
      labels:
        Map.merge(@current_org_labels, %{
          ai_crm_resource: Samenerp.Crm.Company,
          ai_aggregate_resource: Samenerp.Aggregate.RecordCountBySegment
        })
    )

    # 2. Notifications (WS-A A4/A5) — the framework inbox (+ /notifications/settings),
    #    mounted over the Primitives mount in ONE line. Realtime rides
    #    `Samenerp.PubSub` (id-only envelopes).
    samen_notifications_routes(:notifications, Samenerp.Primitives,
      repo: Samenerp.Repo,
      labels: Map.put(@current_org_labels, :pubsub, Samenerp.PubSub)
    )

    # 3. Metrics egress (WS-F5 F5.1) — the framework `GET /metrics` Prometheus
    #    scrape endpoint over `Samen.Metrics.definitions/0`. OFF by default: the
    #    route self-gates to 404 until `metrics_egress?` is set (see
    #    config/runtime.exs → SAMEN_METRICS_ENABLED). Name matches the reporter
    #    Samen.Observability starts (`:samenerp_prometheus`).
    samen_metrics_route(name: :samenerp_prometheus)

    # ADR-044 §9.2 (J5 zero-config honesty) — the framework fleet reporting-side
    # routes (`GET /fleet/health`, `POST /fleet/directive`). Zero-config by
    # default (`:embedded` mode: one honest self-row, no credential, no
    # network) — this is what makes the J5 zero-config probe pass without the
    # generated app knowing what a fleet is.
    samen_fleet_routes(otp_app: :samenerp)
  end

  # Phase 4 — the SHARED webhook ingress (ADR-038 §5.1 / B9): `POST
  # /webhooks/:provider`, vendor-generic — the provider module + config resolve
  # from HOST config at runtime (`config :samen_web, Samen.Web.Webhook,
  # providers: %{...}, repo: Samenerp.Repo}`), so this router stays vendor-free.
  # samenerp ships NO provider config (secrets live in runtime config, never in
  # the repo), so every delivery currently answers the honest fail-closed 404
  # `unknown_provider` — nothing verified, nothing persisted. Mounting on its
  # OWN CSRF-exempt pipeline (vendors cannot carry tokens; the signature is the
  # gate) — the one scope here outside `:browser`.
  scope "/" do
    pipe_through(:webhook_ingress)

    samen_webhook_routes()
  end

  # ADR-010 — the OPERATOR / SaaS-company workspace, mounted in ONE line over the
  # operator namespace (accounts ARE tenant orgs). The operator seat reads the
  # operator org's OWN book of business on the TENANT plane (clear); drilling into
  # a tenant is the existing masked impersonation path.
  scope "/" do
    pipe_through([:browser, :require_authenticated_operator])

    samen_operator_routes(Samenerp.Operator,
      repo: Samenerp.Repo,
      # ADR-050 §4.3 / ADR-044 §9.2 — the WS-J fleet COCKPIT, mounted here as of
      # 2026-10-11 so the public status page's opt-in has a UI on this host instead of
      # being an operator act against the verb from a console. TWO options and no new
      # route table: `fleet_cockpit: true` engages the four `/operator/fleet*` LiveViews
      # (list · directives · register · the tier-2 detail page whose publish control
      # flips `efa_publish_status`), and `:fleet_namespace` names the registry they read
      # — compile-REQUIRED alongside the opt (`__require_fleet_namespace__!/1`), because a
      # cockpit that renders as mounted and reads nothing is worse than none.
      #
      # What this does NOT add: `samen_fleet_ingest_routes/1` (POST /fleet/enroll +
      # /fleet/heartbeat) stays unshipped, and `mix samen.verify.fleet_wire` allows that
      # one-sided shape BY DESIGN — the pair rule is one-directional, and a mode-A `:pull`
      # cockpit needs no ingest. This host is already an app on the reporting side
      # (`samen_fleet_routes(otp_app: :samenerp)` in the public scope below), so the fleet
      # it manages and the fleet it reports to are the same substrate, nothing more.
      #
      # The authority seam is wired (`config :samenerp, :fleet_authority` →
      # `Samenerp.FleetAuthz`, which delegates to the operator plane's OWN resolver), and so
      # is the mode (`config :samenerp, :fleet, mode: :manual` — what makes
      # `Samen.Fleet.read/2` read the registry rather than the zero-config self-row).
      # `:fleet_resolution` is deliberately LEFT UNWIRED (the driftwood posture): tenant
      # names therefore stay masked and the detail page says why, fail-closed, until a host
      # resolver is provisioned.
      fleet_cockpit: true,
      fleet_namespace: Samenerp.Fleet,
      # The operator's PORTFOLIO page (`/operator/aggregate`) — the token-blind cross-tenant
      # dashboard the sidebar's Portfolio item opens. `include_aggregate: true` declares the
      # route AND puts the nav item in the sidebar (the two are the same label, so a host can
      # never advertise a page it did not mount). SamenERP's projection is its OWN book of
      # business, so the loader is host-supplied and takes the mount (the framework's optional
      # leading-arity form) — see `Samenerp.OperatorAggregate`.
      include_aggregate: true,
      labels: %{
        aggregate_loader: {Samenerp.OperatorAggregate, :load, []},
        operator_workspace: "Samenerp Ops",
        # ADR-013 §5.2 — WHERE the two act-as crossings LAND: the operator sidebar's
        # "Act as a tenant →" switcher and an account row's "Open account →" both set the
        # session current org, then redirect here (`Samen.Web.Operator.act_as_landing/1`).
        # This is the SAME landing the tenant sign-in uses (`samen_auth_routes`'s own
        # `tenant_landing:` above), so an operator who crosses down arrives exactly where a
        # tenant of that org arrives. It MUST be a path THIS router serves: the framework's
        # neutral default is `"/"`, and every host that names nothing used to fall through to
        # `/broker` — driftwood's console, unrouted here — so the crossing 404'd AFTER the
        # org had already switched. `auth_login_redirect_test.exs` pins the sibling label;
        # `operator_act_as_landing_test.exs` pins THIS one against the compiled route table.
        tenant_landing: "/crm/dashboard",
        # T146 — the operator-ROLE authority seam. `Samen.Web.Operator.Authz`'s on_mount derives
        # operator authority from the AUTHENTICATED SESSION PRINCIPAL via this MFA (fail CLOSED
        # for any non-operator), so a plain tenant-user session cannot reach `/operator/*`.
        # In prod this resolves via `Samenerp.OperatorAuthz` credential→User→Membership (owner→
        # :operator_admin); in dev/test it still grants `:operator_admin` when disarmed.
        operator_authority: {Samenerp.OperatorAuthz, :resolve_role, [:samenerp]},
        # WS-B B6 — the FlagAdminLive namespace seam: the Primitives mount whose
        # FeatureFlag rows the platform flag admin manages.
        flags_namespace: Samenerp.Primitives
      }
    )
  end
end
