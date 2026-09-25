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
    Samenerp.Vertical,
    Samenerp.Aggregate,
    Samenerp.Primitives,
    Samenerp.Operator
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
  Samenerp.Vertical,
  Samenerp.Aggregate,
  Samenerp.Primitives,
  Samenerp.Operator
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
    (Atom.to_string(Samenerp.Erp.PurchaseOrder) <> ":approve") => {:tenant, Samen.Approvals.Gate}
  }

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
