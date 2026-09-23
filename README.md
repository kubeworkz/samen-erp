# Samen ERP

**An Elixir · Ash · Phoenix SaaS foundry.** Samen is a substrate for one builder — or a
small studio — to launch *many* SaaS products fast without re-solving the hard parts each
time: PII vaulting and masking, a two-plane architecture (a tenant product plane plus an
operator control plane with masked impersonation), a machine-readable catalog for grounding
LLMs and tooling, and generators that emit a *running* product.

It is a kernel (`samen_core`), a web framework layer (`samen_web`), a set of generators, and
several vertical apps that exist to prove the substrate rather than to be shipped.

> **Authorship.** Samen is an AI-authored codebase: every commit was written by Claude
> (Anthropic's AI) under human direction and is marked `Co-Authored-By: Claude`. It is
> reviewed and adversarially gated by a human operator, but the code is Claude's.

## The honest hero claim

> **PII is masked by default. Reveal is grant-gated, second-party-approved, logged in a
> hash-chained log the tenant can read, and time-boxed. Cross-tenant views are
> aggregate-only and token-blind.**

Unpacked:

- **Masked by default, on both planes.** Every 🔒 field writes a `vt_*` token through one
  vault chokepoint; plaintext is nowhere at rest. Every surface renders `••••` unless a
  scoped reveal grant is present — *including* operator support and impersonation sessions.
- **Reveal is second-party.** An operator can request a reveal, but a *distinct* party must
  approve it — enforced both in policy and by a DB `CHECK (granted_by <> requestor_id)`.
  Self-approval is refused. Grants carry `expires_at` and cannot be renewed in place; an
  Oban auto-revoke job is enqueued in the same transaction as the approval.
- **Every reveal is logged where the tenant can see it.** The audit record lands in a
  hash-chained, append-only, tenant-readable log the operator cannot edit (a DB trigger
  refuses `UPDATE`/`DELETE` on the chain).
- **Cross-tenant views never touch PII.** Aggregates (MRR, queues, cohorts) run on a
  separate token-blind actor over resources that have no `pii_*` columns at all. The reveal
  path structurally refuses that actor before any grant or vault check — the two paths are
  mutually exclusive by construction.

This is deliberately *not* the stronger-sounding "run support without ever seeing PII" — that
claim was retired as false-by-construction. Support **can** see PII, but only through a
grant that a second party approved and the tenant can audit.

## The claim set (each backed by a test, verifier, or probe in CI)

| Claim | Where it is proven |
|---|---|
| **PII vaulted + masked by default** on every plane | `samen_core/test/{vault,masked_render,reveal_grants,impersonation_masking}_test.exs`; the `no_plaintext_pii` / `pii_reads` verifier tiers in every app's `ci.sh` |
| **Crypto-shred erasure** — deleting a subject's key material makes their vaulted PII unrecoverable across every tier (erasure = key destruction, not row scrubbing) | `samen_core/test/{erasure,shred_key_material,post_shred_oracle}_test.exs`; driftwood's crypto-shred game-day + the destruction oracle in its `ci.sh` |
| **Two planes** — every app runs a tenant plane and an operator plane, both masked by default, mounted from the framework | `samen_web`'s two-plane render/masking suite; the `/operator/*` routes HTTP-probed on every generated app |
| **The proof is generative** — `mix samen.gen.app` emits a running product that passes its full 19-step verifier gate, seeds vault-aware, boots, and serves every mounted route, with zero hand-edits | `samen_core/priv/gen_app_flagship_probe.exs` + `priv/gen_post_probe.exs`, permanent steps of the root `ci.sh` (need local Postgres) |
| **Self-serve identity spine** — registration (Org+User+Membership atomic, credential PII vaulted), email verification, password reset, sessions (remember-me / listing / revocation / deterministic org-cap eviction), team invites, OIDC that **honors TOTP step-up**, TOTP 2FA + vaulted recovery codes, an onboarding wizard, and login-family auth events → notifications/audit — **emitted by the generator with zero hand-edits** | `samen_web/test/samen/web/auth/*_test.exs` (`confirm`/`session`/`invitation`/`oidc`/`oidc_totp_stepup`/`totp`/`onboarding`/`auth_events`/`login_events`); `samen_core/test/auth/*`; the flagship probe's HTTP-probed `/signup /login /onboarding /settings/security/2fa` |
| **Rich declared types** — Money, Percent, Score, Duration, Priority, URL, Email, Phone, Address (+ `pii_address`/`pii_dob` vault classes); the vault write path re-runs each type's `cast_input` so vaulted values are validated + normalized on input | `samen_core/test/type/*_test.exs`; `samen_core/test/vault/vault_cast_validation_test.exs` |
| **Stripe billing as a fail-honest, vendor-free adapter** — hosted checkout, subscription lifecycle sync (fetch-on-event, idempotent, out-of-order-safe), invoice + tax mirroring, hosted-only payment methods (no PAN column can even compile), dunning, metered usage, a signature-fail-closed webhook ingress with DLQ, and a billing settings page with an honest `:not_configured` empty state. The `samen_core` kernel names **zero** Stripe strings; the adapter lives in a sibling `samen_stripe/` package | `samen_core/test/billing_*_test.exs`; `samen_stripe/test/*` (standalone); `scripts/sabotages/{25-b9,29-b3}-*.patch`; **kernel stays vendor-free** — with the four adapter packages deleted, `samen_core` + `samen_web` still pass |
| **ESP email delivery behind one behaviour, three vendors** — a shared, non-vacuous conformance harness satisfied by **Postmark, SES, and Resend** (Basic-Auth / SNS-RSA / Svix-HMAC); a single send chokepoint; PII-safe rendering that resolves through the vault plane with a fail-closed, non-skippable no-leak gate; deliverability (bounce/complaint → suppression) and masked notification digests | `samen_core/lib/samen/delivery/provider_conformance_case.ex`; `samen_core/test/delivery_*` + `test/delivery/*`; `samen_{postmark,ses,resend}/test/conformance_test.exs`; `scripts/sabotages/30-c3-*.patch` |
| **Auth-surface rate-limiting + bounded `login_failed`** — sign-in / 2FA / registration / reset limited via one shared seam; keys are HMAC-bidx / credential / IP, **never plaintext email**; the brute-force audit signal is a bounded edge row, not O(N) | `samen_web/test/samen/web/auth/rate_limit_test.exs` |
| **Automation engine** — event/schedule-triggered workflows with conditions keyed **only on non-PII attributes**, an 8-action library (email-via-C1, webhook, reminder, escalate, …), reminder/escalation primitives, and a token-blind operator health view + kill-switch. Authorable end-to-end in a tenant-plane builder LiveView | `samen_core/test/automation/*`; `samen_web/test/samen/web/automation/*` (ADR-039) |
| **Lifecycle substrate** — a generalized approve/reject engine (requester≠approver DB CHECK; reveal grants are a client), blueprint-wide **soft-delete/archival** on `ash_archival` with composition-cascade + microsecond `archived_at`, and **audit-on-write** where impersonation-context writes are the mandatory first client (an impersonated write with no audit row is impossible) plus a `versioned` opt-in on `ash_paper_trail` with token-only vaulted diffs | `samen_core/test/{approvals,lifecycle,audit}/*`; sabotages 32–34 (ADR-040) |
| **Canonical work objects** — a canonical Work Task/Project/Subtask (the CRM `Activity` table was **destructively migrated** into it and removed), Calendar (recurrence + masked ICS), Docs, polymorphic Tags, Location, Vendor, and Sales Lead — all archival + vault-aware from birth | `samen_core/lib/samen/scopes/work/*`; `samen_core/test/scopes/*` (ADR-041) |
| **LiveView client with progressive enhancement** — a real LiveSocket bundle in the shared root layout (inherited by every host + gen.app) makes `phx-click` writes browser-real, proven in headless Chromium; the auth arc still completes **JS-off** (Class-A floor), and the socket carries no `vt_`/plaintext to a no-grant operator | `T113` headless-browser regression; sabotage 32 (ADR-042) |
| **ERP base system** — the seven-component core as reusable scopes: the double-entry GL (R1: an unbalanced entry is refused by construction), AP/AR documents posting via source anchors, the append-only stock ledger + derived rollup (R3: negative stock fail-closed), Procurement's one-transaction chokepoint (R5: a GoodsReceipt receive posts stock AND GL together, the three-way match enforced), the SalesOrder bridge (Lead → SO → stock + REAL Billing invoice), Manufacturing (R4: BOM cycle refusal, consume/produce/log agree exactly-once), and HR (the first scope with a non-empty PII map — INV-1 masking, reveal-gated fields) — every ledger guarded by its reconciliation red-path suite + committed sabotage | `samen_core/test/{finance,inventory,hr}*_test.exs` + `e8_reports_test.exs` (Budget/BudgetLine + budget-vs-actual + the TB/WIP/headcount Rollup specs + the k-anon operator aggregate); `samen_web/lib/samen/web/erp/` (the six-surface closed allowlist + ONE generic read-only LiveView mounted by one router line); the `samenerp/` host mounts ALL scopes at ≈0 authored LOC and passes the full 19-step verifier gate; sabotages **302–308** (docs/ws-erp/ — ADR-049) |
| **Bank reconciliation (E9)** — import bank statement lines with SHA-256 dedup, amount-strict matching (±0.01¢) against posted GL entries, auto-categorization rules (pattern → GL account), period-based reconciliation with balanced assertion; guards against double-match and match to voided entries | `samen_core/lib/samen/scopes/banking/*`; `samen_core/test/banking_scope_test.exs` (15 tests) |
| **Multi-currency (E10)** — exchange rate storage per currency pair with timestamps, per-org base currency (default USD), `FxConvert` for batch conversion, `FxConversionGuard` refuses posting in non-base currency without a stored rate; fail-closed | `samen_core/lib/samen/scopes/finance/{exchange_rate,org_fx_settings,fx_convert,fx_conversion_guard}.ex`; `samen_core/test/multi_currency_test.exs` (10 tests) |
| **Financial statements (E11)** — Trial Balance (all accounts + balances, R1 invariant check), Balance Sheet (assets = liabilities + equity at point in time), Profit & Loss (revenue − expenses for a period, feeds into equity); pure SQL reads over existing GL data | `samen_core/lib/samen/scopes/finance/{trial_balance,balance_sheet,profit_loss}.ex`; `samen_core/test/financial_statements_test.exs` (8 tests) |
| **Credit notes + tax rates (E12)** — CreditNote/VendorCredit with draft → open → applied → void state machine, TaxRate config per org (percentage as string), TaxCalculator for per-line tax computation, CreditNoteGuard enforcing valid transitions | `samen_core/lib/samen/scopes/finance/{credit_note_blueprint,credit_note_guard,tax_calculator}.ex`; `samen_core/test/credit_notes_tax_test.exs` (16 tests) |
| **Warehouse transfers (E13)** — TransferOrder coordinating transfer_out + transfer_in in one transaction (same cross-row-cascade discipline as GoodsReceipt), TransferGuard validates positive qty, source ≠ destination, stock check, same-item constraint | `samen_core/lib/samen/scopes/inventory/{transfer_order,transfer_guard}.ex`; `samen_core/test/warehouse_transfers_test.exs` (14 tests) |
| **Landed costs (E14)** — additional costs (freight, duties, insurance) allocated to inventory items on import; value-proportional or quantity-proportional allocation; balance guard ensures allocations sum exactly to landed cost; increases effective unit cost | `samen_core/lib/samen/scopes/inventory/{landed_cost,landed_cost_allocator}.ex`; `samen_core/test/landed_costs_test.exs` (9 tests) |
| **Timesheets (E15)** — time tracking entries with project/task association, duration calculation, approval workflow | `samen_core/lib/samen/scopes/work/timesheet_entry.ex`; `samen_core/test/timesheets_test.exs` |
| **Helpdesk (E16)** — ticket management with SLAs, escalation, CSAT surveys, canned responses | `samen_core/lib/samen/scopes/support/`; `samen_core/test/helpdesk_test.exs` |
| **POS (E17)** — point-of-sale terminals, orders, payments, receipt generation | `samen_core/lib/samen/scopes/pos/`; `samen_core/test/pos_test.exs` |
| **eCommerce (E18)** — storefronts, product catalogs, shopping carts, checkout flow | `samen_core/lib/samen/scopes/ecommerce/`; `samen_core/test/ecommerce_test.exs` |
| **Quality Control (E19)** — inspection points, quality checks, non-conformance tracking | `samen_core/lib/samen/scopes/quality/`; `samen_core/test/quality_test.exs` |
| **Survey/eLearning (E20)** — surveys with questions/answers, courses with lessons/quizzes, enrollment/progress tracking | `samen_core/lib/samen/scopes/{survey,elearning}/`; `samen_core/test/{survey,elearning}_test.exs` |
| **Payroll/Leave (E21)** — payslips, leave types/balances/requests, salary structures | `samen_core/lib/samen/scopes/hr/`; `samen_core/test/payroll_leave_test.exs` |
| **Livechat/Social (E22)** — live chat sessions/channels, social media conversations | `samen_core/lib/samen/scopes/{livechat,social}/`; `samen_core/test/livechat_social_test.exs` |
| **Fleet/Dataclean (E23)** — vehicle management, maintenance, fuel tracking; data deduplication rules/merges | `samen_core/lib/samen/scopes/{fleet,dataclean}/`; `samen_core/test/fleet_dataclean_test.exs` |
| **Consolidation (E24)** — multi-entity rollups, intercompany transactions, company group mappings | `samen_core/lib/samen/scopes/consolidation/`; `samen_core/test/consolidation_test.exs` |
| **Forum/Blog (E25)** — community forums with posts/comments, blog with articles/comments | `samen_core/lib/samen/scopes/community/`; `samen_core/test/forum_blog_test.exs` |
| **E-Signatures (E26)** — document signing templates, signature requests, recipient management, audit trail | `samen_core/lib/samen/scopes/esign/`; `samen_core/test/esign_test.exs` |
| **Appointments (E27)** — meeting types, available slots, booking lifecycle, participant RSVP | `samen_core/lib/samen/scopes/appointments/`; `samen_core/test/appointments_test.exs` |
| **Marketing Automation (E28)** — campaign workflows, triggers, actions (email/SMS/wait/condition), lead nurturing | `samen_core/lib/samen/scopes/marketing_automation/`; `samen_core/test/marketing_automation_test.exs` |
| **SMS Marketing (E29)** — SMS campaigns, templates with variables, message delivery tracking, subscriber consent | `samen_core/lib/samen/scopes/sms_marketing/`; `samen_core/test/sms_marketing_test.exs` |
| **Social Marketing UI (E30)** — connected social accounts, post scheduling, campaign management, engagement metrics | `samen_core/lib/samen/scopes/social_marketing/`; `samen_core/test/social_marketing_ui_test.exs` |
| **Expenses (E31)** — expense categories/policies, individual expenses with receipts, expense sheets with multi-level approval | `samen_core/lib/samen/scopes/expenses/`; `samen_core/test/expenses_test.exs` |
| **Document Management (E32)** — folder hierarchy, document lifecycle (draft→review→approved), version control, access permissions | `samen_core/lib/samen/scopes/documents/`; `samen_core/test/documents_test.exs` |
| **Email Marketing (E33)** — email campaigns with A/B testing, templates, subscriber engagement, delivery logs | `samen_core/lib/samen/scopes/email_marketing/`; `samen_core/test/email_marketing_test.exs` |
| **Planning/Scheduling (E34)** — resources (employees/equipment), shifts with recurrence, time slot availability, schedule templates | `samen_core/lib/samen/scopes/planning/`; `samen_core/test/planning_test.exs` |
| **Approvals (E35)** — approval rules with thresholds, request lifecycle, multi-step chains (sequential/parallel) | `samen_core/lib/samen/scopes/approvals/`; `samen_core/test/approvals_test.exs` |
| **IoT (E36)** — device registry, communication channels, sensor data points with quality levels | `samen_core/lib/samen/scopes/iot/`; `samen_core/test/iot_test.exs` |
| **CMS-light (E37)** — content pages with SEO, page templates, visual themes | `samen_core/lib/samen/scopes/cms/`; `samen_core/test/cms_test.exs` |
| **Custom Fields (E38)** — dynamic key-value fields on any resource (string/integer/float/boolean/date/JSON types) | `samen_core/lib/samen/scopes/custom_fields/`; `samen_core/test/custom_fields_test.exs` |
| **HuggingFace AI Integration** — BYOK (Bring Your Own Key) architecture with AES-256-GCM encryption, SSE streaming, token validation, usage analytics, and background key validation sweeps | `samen_core/lib/samen/scopes/ai/`; `samen_core/test/ai_test.exs` (59 tests) + `ai_streaming_integration_test.exs` (50 tests) |
| **HuggingFace Key Management UI** — Phoenix LiveView for connecting, validating, revoking API keys with usage dashboard | `samen_web/lib/samen/web/settings/huggingface_live.ex` |
| **HuggingFace Key Validation Worker** — Oban background worker for daily key validation sweeps with revocation detection | `samen_core/lib/samen/scopes/ai/verify_credentials_worker.ex` |
| **Production Deployment** — Dockerfile, docker-compose, runtime.exs, deployment guide for Fly.io/AWS/Kubernetes | `samenerp/Dockerfile`, `samenerp/docker-compose.yml`, `samenerp/config/runtime.exs` |
| **API Rate Limiting** — Plan-based rate limits (Free/Pro/Enterprise), per-user/org/IP limits, AI-specific limits | `samen_web/lib/samen/web/rate_limit.ex`, `samen_web/lib/samen/web/plans/` |
| **Monitoring & Alerting** — Sentry + OpenTelemetry integration, error tracking, distributed tracing | `samenerp/lib/samenerp/monitoring.ex` |
| **Backup & Recovery** — Automated backups, point-in-time recovery, retention policy | `samenerp/lib/samenerp/backup.ex` |
| **API Documentation** — OpenAPI 3.0 spec, complete API reference | `samenerp/lib/samenerp/api_docs.ex` |
| **Customer Support** — Ticketing system, priority levels, assignment workflow | `samenerp/lib/samenerp/support.ex` |
| **Security Hardening** — CSP headers, HSTS, XSS protection, security middleware | `samenerp/lib/samenerp/security.ex` |
| **SSO/SAML** — Enterprise SAML 2.0 integration, JIT provisioning, attribute mapping | `samenerp/lib/samenerp/sso.ex` |
| **Customer Audit Log** — Compliance audit trail, CSV/JSON export, retention policy | `samenerp/lib/samenerp/audit_log.ex` |
| **Data Residency** — Regional data storage (US, EU, APAC), compliance certifications | `samenerp/lib/samenerp/data_residency.ex` |
| **White-Label Support** — Custom branding, domains, logos, email templates | `samenerp/lib/samenerp/white_label.ex` |

Full mapping: [docs/claim-evidence.md](docs/claim-evidence.md) (Phase-1 identity spine + rich
types are section J; Phase-2 billing + ESP + rate-limiting are section K; Phase-3 automation +
lifecycle substrate + work objects + the LiveView client are **section L**). **47 modules**
covered (E9–E38), plus HuggingFace AI integration, enterprise SaaS features, and
production deployment infrastructure. **Honest scope:**
the identity spine, its auth-surface rate-limiting, and the Stripe/ESP adapters are complete and
verified — **but everything runs on the keyless lane.** Billing/ESP dispatch is proven against
hermetic fakes + injected-transport cassettes; **no host wires a live provider** (every generated
app boots with billing/ESP unconfigured and honestly says so), production persistence is
fake-backed with the Ash-backed mirrors' host-wiring **deferred to T108**, and the live lanes
(`STRIPE_TEST_KEY`, `SAMEN_POSTMARK_SMOKE`, `SAMEN_ESP_LIVE`) are documented-but-not-CI. AI is a
later phase.

## Architecture

Two apps are the substrate; three are proof; one command spins up new ones.

- **`samen_core` — the kernel (web-dependency-free).** The PII vault and crypto-shred
  erasure, field masking and per-plane PII resolution, policies/RBAC and org-scoping, the
  machine-readable catalog (schema dictionary for LLM/tooling grounding), the hash-chained
  audit log, the `samen.verify.*` verifier tiers, the generators
  (`mix samen.gen.app` / `gen.scope` / `gen.resource`), and the **HuggingFace AI integration**
  (BYOK architecture with AES-256-GCM encryption, SSE streaming, token validation, usage
  analytics, and background key validation sweeps).
- **`samen_web` — the UI kit and product surfaces.** Router mount macros for the tenant and
  operator planes, masked rendering, the **self-serve identity spine** (signup / login /
  email verification / password reset / sessions / team invites / OIDC with TOTP step-up /
  TOTP 2FA enrollment / onboarding wizard), **SSO/SAML integration**, and the mountable
  product surfaces: CRM, Billing, Support desk, Marketing, Files, CSV import/export,
  Search (⌘K command palette), Settings, notifications inbox, and cross-plane chat.
- **Enterprise SaaS infrastructure** (`samenerp/lib/samenerp/`). Production-ready modules:
  - **Deployment** — Dockerfile, docker-compose, runtime.exs, deployment guide
  - **Rate Limiting** — Plan-based limits (Free/Pro/Enterprise)
  - **Monitoring** — Sentry + OpenTelemetry integration
  - **Backup** — Automated backups with retention
  - **API Docs** — OpenAPI 3.0 specification
  - **Support** — Ticketing system with priorities
  - **Security** — CSP headers, HSTS, XSS protection
  - **SSO** — SAML 2.0 enterprise integration
  - **Audit Log** — Compliance audit trail
  - **Data Residency** — Regional storage (US, EU, APAC)
  - **White-Label** — Custom branding and domains
- **Verticals as proof, not product.**
  - `driftwood` — a freight vertical; the deepest reference, with the crypto-shred game-day.
  - `pawchart` — a veterinary vertical demonstrating the mount leverage: its four Ash
    scope-mount files (`billing.ex`/`crm.ex`/`support.ex`/`marketing.ex`) sum to ~188
    authored lines mounting framework surfaces AS-IS on top of the shared substrate — but
    pawchart as a whole is a real, hand-built product (~3,900 authored lines across
    `pawchart/lib`, including its own clinic experience and router; luminary X5 corrected an
    overclaim here that quoted the mount-file total as if it were pawchart's total size).
  - `demo` — the API-only dogfood host; the canonical Identity policy-matrix and red-path
    reference.
- **`mix samen.gen.app`** — emits a new vertical (web UI, JSON:API, seeds, observability,
  tests, and a full verifier gate) that passes its own gate on the first run. Framework
  capability lands in `samen_core` / `samen_web`; a vertical adopts it with a router/macro
  call at roughly zero authored LOC.

The full design story lives at [ckluis.github.io/samen](https://ckluis.github.io/samen/) (open it in
a browser; source is [index.html](index.html)) and in the 49 ADRs under [docs/adr/](docs/adr/) (indexed in
[docs/adr/README.md](docs/adr/README.md); the count grows with every load-bearing decision —
`ls docs/adr/*.md | wc -l` for the live total).

## The verification story

This is the point of the repo, not a footnote: **every guarantee ships with a green proof, a
red-path proof, and a sabotage that proves the test can actually fail.** A test that cannot
fail is treated as a bug.

- **Committed sabotage harness.** `scripts/sabotage.sh` replays **every committed sabotage
  patch** (`scripts/sabotages/*.patch` — 308 today, and growing every phase: count it live
  rather than trusting this number). Every patch runs inside a **throwaway git worktree**
  (`.sabotage/tree`), so the main checkout is never written — a hard kill (SIGKILL) cannot
  leave sabotage behind. For each: SHA-256 the touched files → apply the patch in the
  shadow tree → the *named* tests **must** fail (not "something broke") → revert → verify
  a byte-exact restore, then assert every touched path in the main checkout is
  sha-256-identical. A residue guard (`scripts/sabotage_residue.sh`) runs at the top of
  every CI gate and detects any patch that reached the working tree by any route. Run it
  with:

  ```
  SAMEN_SABOTAGE=1 ./ci.sh
  ```

  It is opt-in because it deliberately breaks the tree hundreds of times and re-runs
  DB-backed suites; the default CI path stays green-only. Later gates add a new `.patch`
  rather than re-deriving sabotages by hand.
- **Destruction oracle for crypto-shred.** `mix samen.verify.no_plaintext_pii` runs as a
  separate OS process across every tier (domain rows, vault, audit events, rollups, Oban
  args, the KMS store) and attests that a shredded subject is unrecoverable — the erasure
  game-day regenerates and re-verifies this on every driftwood `ci.sh` run.
- **Generative proof in the root gate.** `./ci.sh` doesn't just test the substrate — it
  *generates* a fresh app, runs the app's entire gate, seeds it, boots it, HTTP-probes its
  routes, and drives sabotages against the generated gate to prove it is non-vacuous.
- **AC-mapped gate reports.** Every workstream's adversarial gate is written up in `docs/`
  (`gate-ws-*.md`, `gate-*.md`): each acceptance criterion mapped to a named covering test,
  suite counts reproduced, sabotages re-flipped. The newest is the full F1–F7 burn-down gate
  [docs/gate-burndown.md](docs/gate-burndown.md) (see also [docs/gate-ws-e.md](docs/gate-ws-e.md)).

Suite totals grow with every phase — the table below is reproduced against the current tree
(`./ci-fast.sh` for `samen_core`/`samen_web`; the F1–F7 burn-down gate for the rest, not
re-run this pass), `--warnings-as-errors` clean; treat exact counts as directional and rerun
`mix test` for the live number:

| Suite | Passing |
|---|---|
| `samen_core` | 2715 |
| `samen_web` | 1711 |
| `demo` | 465 |
| `driftwood` | 123 |
| `pawchart` | 49 |
| sabotage harness | 308/308 sabotages flipped their named tests; worktree-isolated replay, byte-exact restores |
| E9–E38 (ERP modules) | 588 tests across 30 ERP modules |
| HuggingFace AI Integration | 109 tests (59 unit + 50 streaming integration) |
| Enterprise SaaS Features | 47 modules (Deployment, Rate Limiting, Monitoring, Backup, Docs, Support, Security, SSO, Audit, Data Residency, White-Label) |

## Getting started

Prerequisites: Elixir 1.20 / OTP 29, and a local PostgreSQL that trusts `$USER` on
localhost. All commands start from the repo root.

### AI Integration (HuggingFace BYOK)

Samen supports Bring Your Own Key (BYOK) integration with HuggingFace for AI features:

1. **Connect your HuggingFace API key** at `/settings/huggingface`
2. **Your key is encrypted** with AES-256-GCM and never exposed to the frontend
3. **Use AI features** — text generation, embeddings, and more through the HuggingFace API
4. **Usage is tracked** — view API calls, token consumption, and costs in the dashboard
5. **Keys are validated daily** — background worker detects revoked/expired keys

For details, see [docs/ai-integration.md](docs/ai-integration.md).

### Enterprise SaaS Deployment

Deploy Samen as an enterprise SaaS service. Production deploys are **CI-gated and automated**: every push to `main` runs the full `ci.sh` gate (`.github/workflows/ci.yml`); on success `deploy.yml` SSHes to the prod host and runs `scripts/deploy-prod.sh`, which syncs the tree to the release commit, rebuilds the image, applies migrations, gates on health + smoke + a live ESP check, and rolls back automatically if any gate fails.

The manual fallback (operator-run):

```bash operator-todo
cd samenerp
cp .env.example .env  # Configure environment
docker-compose up -d   # Start services
docker-compose exec app bin/samenerp eval "Samenerp.Release.migrate()"  # Run migrations
```

**Features:**
- ✅ Docker + Docker Compose
- ✅ Fly.io / AWS ECS / Kubernetes
- ✅ Plan-based rate limiting
- ✅ Sentry + OpenTelemetry monitoring
- ✅ Automated backups
- ✅ OpenAPI 3.0 documentation
- ✅ SSO/SAML for enterprise
- ✅ Customer audit log
- ✅ Data residency (US, EU, APAC)
- ✅ White-label branding

For details, see [docs/deployment-guide.md](docs/deployment-guide.md).

Generate a new vertical app and run its gate:

```bash
cd samen_core
mix samen.gen.app --module Harbor --prefix hb --abbrev hrb
cd ../harbor
MIX_ENV=test bash ci.sh
```

That is a running product — a Billing scope mounted as-is, one authored resource with a
vaulted PII field, a token-blind aggregate, notifications, feature flags, an operator
workspace, and a deny-by-default `/api/v1` JSON:API — passing its own 19-step verifier gate
on the first run, with zero hand-edits. Boot it:

```bash
MIX_ENV=dev mix ecto.create && MIX_ENV=dev mix ecto.migrate
MIX_ENV=dev mix harbor.seed
mix phx.server
```

Then open `http://localhost:4050` (the landing page links every mounted surface; `/healthz`
is the liveness probe).

To run the whole foundry gate (spikes + kernel + both generative probes + framework + all
three verticals — takes minutes, must end `ROOT CI: ALL PASSED`):

```bash
bash ci.sh
```

The full zero-to-first-feature walkthrough — adding a second scope and resource with
`mix samen.gen.scope` / `mix samen.gen.resource`, then bending the API contract to watch the
gate flip — is [docs/guides/getting-started.md](docs/guides/getting-started.md). Every fenced
command in this README and that tutorial is verified against the CI probes' executed set by
`samen_core/test/doc_commands_test.exs`: an aspirational command fails the build.

## Repo map

| Path | What it is |
|---|---|
| `samen_core/` | The kernel: vault + crypto-shred, masking, policies/RBAC, catalog, audit, `samen.verify.*` verifier tiers, generators, and the **HuggingFace AI integration** (BYOK with AES-256-GCM, SSE streaming, token validation, usage analytics) |
| `samen_web/` | The framework web layer: tenant + operator plane mount macros, the UI kit, masked rendering, and the mountable product surfaces (CRM/Billing/Support/Marketing/Files/CSV/Search/Settings/chat) |
| `demo/` | The API-only dogfood host — canonical Identity policy-matrix / red-path references |
| `driftwood/` | Reference vertical: freight — the deepest gate, including the crypto-shred game-day |
| `pawchart/` | Reference vertical: veterinary — thin scope mounts (~188 lines) plus a real, hand-authored clinic UI on top |
| `samenerp/` | The WS-ERP host proof: Finance + Inventory scopes mounted AS-IS (one domain module + one router line) — CoA/journal/AP/stock/PO/work-order surfaces, Budget/BudgetLine, TB/WIP/headcount rollups, the E1–E8 walkthrough, and the full 19-step verifier gate. **Enterprise SaaS modules:** deployment, rate limiting, monitoring, backup, API docs, support, security, SSO, audit log, data residency, white-label |
| `spikes/` | The mechanism spikes (s00–s07) that de-risked the kernel; still run by root `ci.sh` |
| `docs/` | ADRs (`docs/adr/`), guides (`docs/guides/`), the gate reports (`docs/gate-*.md`), the roadmap (`docs/saas-gap-roadmap.md`), and an archived long-form design variant (`docs/archive/samen-foundry.html`) |
| `scripts/` | `sabotage.sh` + every committed sabotage patch (308 today, growing every phase) |
| `ci.sh` | The root gate: everything above, in sequence, fail-fast |

## Docs

- [Positioning Strategy](docs/positioning-strategy.md) — how Samen competes against enterprise ERP
- [Competitive Analysis](docs/competitive-analysis.md) — detailed comparison with NetSuite, Odoo, ERPNext
- [Docs index](docs/README.md) — the front door to everything under `docs/`, grouped
- [Getting started — zero to first feature](docs/guides/getting-started.md)
- [Cookbook](docs/guides/cookbook.md) — task recipes
- [Gate-failure index](docs/guides/gate-failures.md) — what each gate step means when it goes red
- [Generators](docs/guides/generators.md) · [Scope authoring](docs/guides/scope-authoring.md)
- [LLM grounding](docs/guides/llm-grounding.md) — the machine-readable schema dictionary
- [Claim-evidence parity](docs/claim-evidence.md) — every claim mapped to its proof
- [Compliance & GDPR/SOC 2 story](docs/compliance-story.md) — the honest control-posture split (day-one-from-Samen vs operator responsibility); **not** a certification
- [Outward-claim sweep](docs/claim-sweep.md) — the claim→evidence audit of the landing page, README, and compliance docs
- [ADRs](docs/adr/) — every load-bearing decision
- [**The full design story**](https://ckluis.github.io/samen/) — the interactive landing page, hosted on GitHub Pages (also available as [index.html](index.html))

## Status & caveats

Read this before assuming anything about production-readiness.

- **This is an internal foundry, built by one builder working with AI agents.** It is not a
  hosted product, not a package on Hex, and carries **no stability or support promises**. It
  is published so the architecture and the verification discipline are legible.
- **Some infrastructure is locally simulated.** Real Neon PITR drills, real AWS KMS /
  DynamoDB / S3 Object-Lock, ClickHouse ClickPipes, live Stripe keys, and Fly deploys are
  **operator TODOs**, tracked honestly as carries in the gate reports — not claimed as done.
  The local sims (a file-backed KMS, a local PITR harness) exercise the same load-bearing
  invariants, and the numbers they produce (RTO/RPO targets, detection latency) are labeled
  as sims/proxies where they appear.
- **Fail-honest by design.** An unconfigured or unimplemented adapter never returns success
  for work it did not do — it returns `{:error, :not_configured | :not_implemented}`.
  Generated deploy artifacts (ADR-024) are fail-closed: a missing secret raises and names
  itself; there is no turnkey "just run `fly deploy`".
- **The product surfaces vary in depth.** The security/governance kernel is as deep as the
  gates claim; some product surfaces are honestly-labeled first cuts. The
  [gap roadmap](docs/saas-gap-roadmap.md) ranks what is shipped versus what remains.

## License

See [LICENSE](LICENSE).
