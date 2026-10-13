import Config

# Samenerp — a Samen vertical scaffolded by `mix samen.gen.app`. Mounts the
# samen_core Billing scope AS-IS, authors the vertical resource, defines a
# token-blind aggregate projection, and (WS-D D2 / ADR-022) mounts the Primitives
# scope + the ADR-010 operator namespace behind the samen_web framework UI.
config :samenerp,
  ecto_repos: [Samenerp.Repo],
  ash_domains: [
    Samenerp.Billing,
    Samenerp.Crm,
    Samenerp.Marketing,
    Samenerp.Support,
    Samenerp.Automation,
    Samenerp.Erp,
    Samenerp.Banking,
    Samenerp.Work,
    Samenerp.Chat,
    Samenerp.Cms,
    Samenerp.Calendar,
    Samenerp.Vertical,
    Samenerp.Aggregate,
    Samenerp.Primitives,
    Samenerp.Operator,
    # Phase 7 — the framework AI plane (Samen.AI.Prompt / SupportReplyDraft /
    # Agent.{Run,Turn,Kill} / Assistant / AssistantConversation). KERNEL resources
    # with host-invariant abbrevs AND table names, materialized here by the
    # MountAiDomain migration; adding the domain is the host's only authored line
    # (ADR-043 §5.2, INV-5).
    Samen.AI.Domain,
    # WS-B / G12 (ADR-021) — the product-event ledger (`sae`) the activation funnel is
    # rebuilt from. Mounted because this app had the analytics READERS (the P17
    # `/analytics` surface + the operator plane) without a producer: see the mount note
    # in lib/samenerp/analytics.ex and migration 20261013120000.
    Samenerp.Analytics
    # NOTE (ADR-050, 2026-10-11) — `Samenerp.Fleet` (migration 20261011120000) is
    # deliberately registered in NEITHER `ash_domains` list, and that is load-bearing
    # rather than cosmetic. `mix samen.verify.aggregate_privacy` discovers its fleet
    # from `Application.get_env(:samenerp, :ash_domains)` and requires EVERY
    # `use Samen.Aggregate.Resource` to declare a fail-closed cohort spec; the fleet
    # registry has no cohort semantics at all — it is a cross-tenant/operator-owned
    # registry, which is exactly what the blueprint uses that macro FOR (its
    # nullable-`org_id` override and the C7 NoPiiColumns check), never for aggregate
    # reads. Registering the domain would therefore force a FABRICATED cohort spec
    # (a lie about k-anonymity) purely to silence a verifier.
    #
    # The framework's own mount of this same blueprint is kept out the same way
    # (`samen_core/config/test.exs`: "The fixture domain is NOT in `:ash_domains`,
    # so `vault_declared_parity` cannot discover …"), so this is the blueprint's
    # established posture, not a gap opened here. Nothing is lost: the domain runs
    # (its resources set `validate_config_inclusion?: false`), INV-2 stays
    # COMPILE-enforced on all five resources, and their columns reach the committed
    # catalog through the migration's in-tx `catalog_sync` — which the gate's
    # schema.dict drift check and `tnt_catalog` step both exercised when this landed.
  ]

# The samen_core verifiers discover domains from :samen_core :ash_domains. Register
# this app's domains so the gate scans the mounted Billing scope + the vertical
# resource + the token-blind aggregate + the Primitives mount + the operator plane.
config :samen_core, :ash_domains, [
  Samenerp.Billing,
  Samenerp.Crm,
  Samenerp.Marketing,
  Samenerp.Support,
  Samenerp.Automation,
  Samenerp.Erp,
  Samenerp.Banking,
  Samenerp.Work,
  Samenerp.Chat,
  Samenerp.Cms,
  Samenerp.Calendar,
  Samenerp.Vertical,
  Samenerp.Aggregate,
  Samenerp.Primitives,
  Samenerp.Operator,
  Samen.AI.Domain,
  Samenerp.Analytics
  # `Samenerp.Fleet` is deliberately absent here too — see the note on the app's own
  # `ash_domains` list above (the samen_core discovery list would sweep the registry
  # through the same tenant-plane verifiers).
]

# ADR-039 §3.1 — the Automation engine seams (driftwood's exact wiring): the
# kernel reads workflows through the MFA seam, never a hard-coded resource.
config :samen_core, Samen.Automation,
  workflow_module: Samenerp.Automation.Workflow,
  repo: Samenerp.Repo

# T3.6 — the SlaBreachWorker's ticket resource (the scope's documented wire).
config :samen_core, :support_sla_breach_ticket_resource, Samenerp.Support.Ticket

config :ash, disable_async?: true
config :ash, :missed_notifications, :ignore

config :samenerp, Samenerp.Repo, migration_primary_key: [name: :id, type: :binary_id]

# Reveal-grant + non_pii + verify + vault + tnt_record repos: wire this app's repo.
config :samen_core, :reveal_grant, Samen.Reveal.Grants
config :samen_core, :reveal_grant_repo, Samenerp.Repo
config :samen_core, :non_pii_repo, Samenerp.Repo
config :samen_core, :verify_repo, Samenerp.Repo
config :samen_core, :vault_repo, Samenerp.Repo
config :samen_core, :tnt_record_repo, Samenerp.Repo

# WS-B / G12 (ADR-021) — the product-analytics capture emitter. `Samen.Analytics.track/1`
# writes into SAMENERP's `sae` ledger, and every flag-variant assignment (ADR-020 §3.4
# seam) flows to `track/1` too. WITHOUT `product_event_resource`, `track/1` is INERT
# (`{:ok, :dropped}` — the documented quiet-until-mounted posture): the framework emitters
# already fire on this host (sign-in, first-run, record create, ⌘K search) and every event
# was dropped, which is why the activation funnel was GUARANTEED empty rather than merely
# empty so far.
config :samen_core, Samen.Analytics, product_event_resource: Samenerp.Analytics.ProductEvent
config :samen_core, Samen.FeatureFlags, emit: {Samen.Analytics, :track}

# WS-B / G12 (ADR-021 §B8) — the DOMAIN-SOURCED funnel/retention rollup
# (`paf_product_event_rollup` — host-invariant table name, created in Phase 3 by
# 20261006140000) REBUILT FROM THIS HOST'S `sae` LEDGER. Funnel rows are (org, stage) for
# signup → first-run → first-record; retention rows are (org, cohort_week, week_offset 0..4)
# of distinct actors active N weeks after their first event. Refreshed on the canonical
# `*/10 * * * *` RollupRefreshWorker cron — `Samen.Jobs.default_crontab/0`, installed at
# boot by `Samen.Jobs.install_defaults/1` (see application.ex), so the host schedules
# nothing itself; the refresh framework, the erasure orchestration and the
# `no_plaintext_pii` Rollup oracle tier all read this ONE registry.
#
# ERASURE STANCE (design §4.4): `sae` has NO subject column — `sae_actor_ref` is the
# per-subject HMAC pseudonym — so the load-bearing erasure is the subject's KMS key
# destruction; `subject_delete_sql` plus the oracle's INDEPENDENT residue scan key the
# pseudonym column against the RAW subject id and match ZERO rows BY CONSTRUCTION (they
# exist to catch a sabotaged `track/1` leaking a raw id into the ledger).
#
# SCOPE — only the product-event rollup is registered here. `mrr_revenue_rollup` (also
# created by 20261006140000 and read by the operator `/operator/revenue` plane) stays
# UNWIRED: it needs a subscription-MOVEMENT ledger source this app has not adopted, and
# its readers keep rendering honest zeros rather than fabricated counts. Separate
# follow-on, named rather than silently skipped.
config :samen_core, :rollups, [
  %{
    name: :product_event_rollup,
    source: :domain,
    table: "paf_product_event_rollup",
    subject_delete_sql: "DELETE FROM sae_product_event WHERE sae_actor_ref::text = $1",
    domain_table: "sae_product_event",
    domain_subject_column: "sae_actor_ref",
    bounded_columns:
      ~w(paf_id paf_org_id paf_kind paf_stage paf_cohort_week paf_week_offset paf_actor_count paf_suppressed paf_refreshed_at),
    rebuild_sql:
      {"DELETE FROM paf_product_event_rollup",
       """
       INSERT INTO paf_product_event_rollup
         (paf_org_id, paf_kind, paf_stage, paf_cohort_week, paf_week_offset,
          paf_actor_count, paf_suppressed, paf_refreshed_at)
       SELECT
         sae_org_id                                AS paf_org_id,
         'funnel'                                  AS paf_kind,
         CASE sae_event_name
           WHEN 'session.signed_in'   THEN 'signup'
           WHEN 'first_run.completed' THEN 'first_run'
           ELSE 'first_record'
         END                                       AS paf_stage,
         NULL::date                                AS paf_cohort_week,
         NULL::int                                 AS paf_week_offset,
         COUNT(DISTINCT sae_actor_ref)::int        AS paf_actor_count,
         FALSE                                     AS paf_suppressed,
         now()                                     AS paf_refreshed_at
       FROM sae_product_event
       WHERE sae_event_name IN ('session.signed_in', 'first_run.completed', 'record.created')
       GROUP BY sae_org_id, sae_event_name
       UNION ALL
       SELECT
         a.sae_org_id                              AS paf_org_id,
         'retention'                               AS paf_kind,
         NULL::text                                AS paf_stage,
         f.cohort_week                             AS paf_cohort_week,
         ((date_trunc('week', a.sae_occurred_at)::date - f.cohort_week) / 7)::int
                                                   AS paf_week_offset,
         COUNT(DISTINCT a.sae_actor_ref)::int      AS paf_actor_count,
         FALSE                                     AS paf_suppressed,
         now()                                     AS paf_refreshed_at
       FROM sae_product_event a
       JOIN (
         SELECT sae_org_id, sae_actor_ref,
                date_trunc('week', MIN(sae_occurred_at))::date AS cohort_week
         FROM sae_product_event
         WHERE sae_actor_ref IS NOT NULL
         GROUP BY sae_org_id, sae_actor_ref
       ) f
         ON f.sae_org_id = a.sae_org_id AND f.sae_actor_ref = a.sae_actor_ref
       WHERE a.sae_actor_ref IS NOT NULL
         AND ((date_trunc('week', a.sae_occurred_at)::date - f.cohort_week) / 7) BETWEEN 0 AND 4
       GROUP BY a.sae_org_id, f.cohort_week,
                ((date_trunc('week', a.sae_occurred_at)::date - f.cohort_week) / 7)
       """}
  }
]

# T35 §4.7 / T37h: reveal grants are a CLIENT of the T34 E3 approve/reject engine.
# This app's own Approval resource (Samen.Approvals.Blueprint.define_approval/5,
# lib/samenerp/approvals.ex) + the "pii_reveal" kind registered to
# Samen.Reveal.ApprovalHandler — Grants.approve/2 now routes its happy path through
# Samen.Approvals, not the pre-T35 inline fallback (the T35 non-fatal note this
# fold-in closes).
config :samen_core, Samen.Approvals,
  approval_resource: Samenerp.Approvals.Approval,
  repo: Samenerp.Repo

config :samen_core, Samen.Approvals.Registry,
  kinds: %{
    "pii_reveal" => {:operator, Samen.Reveal.ApprovalHandler},
    # WS-ERP on this host: the gated ERP actions (E2 AP bill approve, E4 PO
    # approve — the Gate re-invokes the action as the requester inside the
    # decision transaction). Unregistered kinds would refuse at write —
    # fail-honest, but these actions are governed-approve by design.
    (Atom.to_string(Samenerp.Erp.ApInvoice) <> ":approve") => {:tenant, Samen.Approvals.Gate},
    (Atom.to_string(Samenerp.Erp.PurchaseOrder) <> ":approve") => {:tenant, Samen.Approvals.Gate},
    # Phase 7 (ADR-043 §6.3 D5) — the AI support operator's human-gated send.
    # Operator plane; the requester (the AI service principal) is never the
    # decider (distinct-party by construction).
    "ai_support_reply" => {:operator, Samen.AI.SupportOperator.ReplyHandler},
    # Phase 7 (ADR-047 A4/A6) — the ONE agent-write kind. An `effect: :write`
    # agent tool never executes inside the turn: it opens this tenant-plane
    # approval and the run parks `:awaiting_approval` until a DISTINCT human (the
    # clicking principal resolved against a REAL membership row in the RUN's org)
    # approves, and the write then executes with the APPROVER's authority. An
    # UNREGISTERED kind is refused at request time — an unwired host is honest
    # ("the agent cannot propose") but its decision card can never do anything.
    "ai_agent_write" => {:tenant, Samen.AI.Agent.WriteProposal}
  }

# Phase 7 (ADR-043 §5.2 / §6.3 / §7.5; ADR-047 §4.1/§6) — point the reusable
# AI-plane resources (mounted via `Samen.AI.Domain` above) at Samenerp.Repo so
# prompts, support-reply drafts, agent runs/turns, the kill switch, and the
# OpenClaw-lite assistant + its conversation thread all PERSIST in this host.
# COMPILE-TIME (the resources read them via `Application.compile_env`, the
# `tnt_record_repo` / `samen_ai_*_repo` precedent in samen_core/config/config.exs).
config :samen_core, :samen_ai_prompt_repo, Samenerp.Repo
config :samen_core, :samen_ai_support_reply_draft_repo, Samenerp.Repo
config :samen_core, :samen_ai_agent_run_repo, Samenerp.Repo
config :samen_core, :samen_ai_agent_turn_repo, Samenerp.Repo
config :samen_core, :samen_ai_agent_kill_repo, Samenerp.Repo
config :samen_core, :samen_ai_assistant_repo, Samenerp.Repo
config :samen_core, :samen_ai_assistant_conversation_repo, Samenerp.Repo

# Phase 7 (ADR-047 A5/A6 §5.3) — the APPROVER-MEMBERSHIP seam. `Identity.Membership`
# is materialized INTO the host namespace (ADR-004), so samen_core cannot name it;
# the host does. At decision time the clicking principal is resolved against a REAL
# membership row in the RUN's org (pinned from the durable run row, never a caller
# argument). An UNWIRED host refuses `:approver_unresolvable` (fail-closed).
config :samen_core, Samen.AI.Agent, approver_membership: Samenerp.Operator.Membership

# T4.5 aggregate-privacy floors. samen_core defaults are k=5/l=2; a fresh app's
# dogfood datasets are small, so — exactly as demo/driftwood/pawchart — use a
# small-but-non-trivial floor (k=2/l=2): a count-of-one cohort still suppresses.
# Production hosts keep k=5.
config :samen_core, :k_anonymity_min_cohort, 2
config :samen_core, :l_diversity_min_distinct, 2

# The query-budget ledger repo (SCAFFOLD — accounting only, WARN-not-enforce).
config :samen_core, :query_budget_ledger_repo, Samenerp.Repo

# ADR-010: the well-known operator org id — `Samen.Web.Operator.org_id/1` resolution
# step 2 reads it from this app env. The operator workspace reads the operator org's
# OWN book of business on the TENANT plane (clear); seeds anchor rows on this id.
config :samenerp, :operator_org_id, "0f000000-0000-4000-8000-0000000000aa"

# ADR-031/ADR-045 §2 — the launch AUTH gate, ARMED BY DEFAULT IN PROD (V-F1, Option A). The
# router's tenant/shared mounts carry `authn: {:app_env, :samenerp, :auth_required?}`;
# in dev/test this is FALSE so `Samen.Web.CurrentOrg` keeps the query-param convenience identity
# (a spoofable `?org=`/`?user=`), and in prod it is TRUE so the current org/actor is derived ONLY
# from an authenticated session — a `?org=`/`?user=` can never resolve an arbitrary tenant. This
# is EXPLICIT here (`config_env() == :prod`) AND backstopped by the framework env-aware default +
# the `Samen.Web.TenantGate` boot guard (a prod host that is disarmed refuses to boot). To run a
# real launch you must ALSO wire a login path + the tenant `:identity_namespace` seam (the router
# already does) so admin writes derive the caller's REAL membership role — see the deploy runbook.
config :samenerp, auth_required?: config_env() == :prod

# T146 — the OPERATOR-ROLE authority seam (conn-level twin of the operator mount's
# `:operator_authority` label). `Samen.Web.AuthGate` reads this app env to verify an
# authenticated principal actually holds operator authority before admitting them to the
# operator control plane, and `Samen.Web.Operator.Authz` enforces the SAME by construction at
# every operator route's mount. Deny-by-default: absent a resolver, a prod-armed app admits NO
# operator. `Samenerp.OperatorAuthz` checks a REAL operator-org Membership (credential→User→
# Membership indirection so the spine `credential_id` principal resolves) and dev/test still
# pass via the second-leg dev fallback; a tenant without an operator membership is refused.
config :samenerp, :operator_authority, {Samenerp.OperatorAuthz, :resolve_role, [:samenerp]}

# J3 / ADR-044 §6.2 — the FLEET-WIDE role read, the second seam the operator plane needs now
# that this host mounts the fleet cockpit (`samen_operator_routes(..., fleet_cockpit: true)`,
# ADR-050 §6.1). `Samen.Web.Operator.Fleet.gate/2` reads it for `roles[:fleet]` (may the
# principal open the cockpit at all), and `Samen.Web.Operator.Fleet.app_role/2` for the
# per-PRODUCT scope (may they see this product's rows and flip its public-status opt-in).
# `Samenerp.FleetAuthz.fleet_roles/1` delegates to `Samenerp.OperatorAuthz` — one identity, ONE
# authorization decision for both planes, so arming this host closes them together — and fails
# CLOSED: no operator role ⇒ `%{}` ⇒ no cockpit and no product, never a cockpit nobody
# authorized.
config :samenerp, :fleet_authority, {Samenerp.FleetAuthz, :fleet_roles, []}

# The products this operator company grants product-scoped access to, as SLUG ATOMS (the
# framework atomizes a slug for the scope lookup — `Samen.Web.Operator.Fleet.app_scope/1`).
# Default: `:samenerp` — the product this host IS (it mounts the app-side `samen_fleet_routes/1`
# reporting pair), and therefore the one whose public component `/status` is titled after
# ("Samen ERP status"). Add each additional product's slug atom as the fleet grows: a product's
# scope is a PROVISIONED grant a reviewer can see, never something a registered row confers on
# itself.
config :samenerp, :fleet_products, [:samenerp]

# The fleet MODE (ADR-044 §8.1/§8.3). `:manual` is REQUIRED of a cockpit host: the cockpit
# LiveViews read through `Samen.Fleet.read/2` with the mount's `:fleet_namespace`, and only the
# `:manual`/`:heartbeat` branch reads the REGISTRY. The zero-config `:embedded` default returns a
# single self-row and IGNORES the namespace — the cockpit would render this host alone, every
# registered product would be invisible, and `/operator/fleet/:app_id` would find no row. This
# host is the portfolio HOST while also reporting as an app; `:manual` is the host side of that.
config :samenerp, :fleet, mode: :manual

# WS-A A4/A5 — the kernel notification ENGINE wired to this app's Primitives mount
# (the ADR-014 SendWorker config convention: the kernel is mount-agnostic; the host
# names its concrete modules + repo). Realtime rides the samen_web PubSub broadcaster
# over `Samenerp.PubSub` — id-only envelopes; each inbox subscriber re-reads per
# its OWN scope.
config :samen_core, Samen.Notifications.Engine,
  notification_module: Samenerp.Primitives.Notification,
  preference_module: Samenerp.Primitives.NotificationPreference,
  repo: Samenerp.Repo,
  broadcaster: Samen.Web.Notifications.PubSubBroadcaster

config :samen_web, Samen.Web.Notifications.PubSubBroadcaster, pubsub: Samenerp.PubSub

config :phoenix, :json_library, Jason

# WS-D D5 observability (ADR-022): OTel-Ecto records the SQL statement into trace
# spans by DEFAULT — on a Samen substrate that surface must be proven token-only, so
# `db_statement: :disabled` is categorical (the `no_plaintext_pii` LogTelemetry tier
# asserts it, config-level + live-handler). `Samen.Observability.child_specs/1` (wired
# in application.ex) OWNS this default and raises at build time if this key contradicts
# it. Removing this line flips the gate (the D6 flagship observability sabotage).
config :samenerp, :opentelemetry_ecto, db_statement: :disabled

# SamenerpWeb.Endpoint — LOCAL DEV/DOGFOOD constants (ADR-022: the endpoint is a
# thin EMITTED file and the builder OWNS the port/secret_key_base/salts; a real
# deployment replaces them via config/runtime.exs — the `--deploy` layer).
config :samenerp, SamenerpWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  url: [host: "localhost"],
  http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT") || "4050")],
  secret_key_base: "samenerp_local_dogfood_secret_key_base_000000000000000000000000000000000",
  live_view: [signing_salt: "samenerp_lv_salt_dogfood"],
  render_errors: [formats: [html: SamenerpWeb.ErrorHTML], layout: false],
  pubsub_server: Samenerp.PubSub,
  server: false

# Oban: the canonical queue taxonomy is DERIVED, never hand-listed here (B-OBAN).
# config.exs is evaluated before dependency modules load, so it cannot call
# `Samen.Jobs.default_queue_config/0`; application.ex installs the full taxonomy
# (and the canonical crontab) at boot via `Samen.Jobs.install_defaults/1`. That
# matters because a job enqueued to a queue with no configured producer does not
# fail — it sits in oban_jobs as `available` forever, with no error, no retry and
# an empty DLQ. Declare only your repo + plugins here; add a queue name below ONLY
# to retune its limit (your limit wins, the rest are still installed).
# `mix samen.verify.oban_queues` gates worker-queue ⊆ configured-queue parity.
config :samen_core, Oban,
  repo: Samenerp.Repo,
  plugins: [
    {Oban.Plugins.Pruner, max_age: 7 * 24 * 60 * 60}
  ]

import_config "#{config_env()}.exs"
