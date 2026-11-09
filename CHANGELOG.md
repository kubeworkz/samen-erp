# Changelog

All notable changes to Samen are recorded here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); Samen aims to follow
[Semantic Versioning](https://semver.org/spec/v2.0.0.html) from 1.0 onward.

## [Unreleased]

### Added

- **Bank statement import and ranked match suggestions** (WS-ERP E9): CSV and OFX/QFX
  statements now import through the governed `StatementLine.:import` action. The parser accepts
  canonical columns and common bank aliases, including either a signed amount column or separate
  debit/credit columns (with withdrawal/deposit aliases), OFX 1.x SGML and OFX 2.x XML, normalizes
  dates and signed amounts to integer cents, and refuses a bad row or duplicate file before writing. The
  import service creates each line and its `StatementImport` audit batch in one transaction,
  deduplicating by file hash and by the existing line hash. The bank-account screen accepts a
  file upload or pasted statement text and shows ranked suggestions for unmatched lines; the
  suggestions use the bank's cash leg (not a balanced entry's zero net total), and "Use
  suggestion" prefills the ordinary guarded match form rather than writing a match directly.
- **Journal approval and segregation of duties** (WS-ACCT journal controls): Finance mounts a
  new admin-owned `JournalApprovalPolicy` (one per org, optional amount threshold). When it is
  enabled, a human `:post`/`:void` opens a `Samen.Approvals` request instead of posting; the
  request is bound to the entry's `prepared_by`, so a different principal cannot submit it and
  the preparer cannot approve their own work. A distinct approver's decision re-invokes the
  ordinary governed action, and the entry records `prepared_by`, `approved_by`, `approved_at`
  and `approval_id` in the same transaction. System cascades (no actor) and orgs without a
  policy retain the previous path. The approved context is re-verified against the stored
  approval row, so faking the Gate context cannot bypass the control. The Kubeworkz books
  seed opens the policy enabled at threshold 0, `Books.verify/1` checks it, and an operator's
  disable/threshold edit is reported as drift rather than silently overwritten.
- **Journal approval admin settings surface** (`/erp/journal-approval`, mounted by
  `samen_erp_routes/3`): a tenant admin can enable or disable the org's
  `JournalApprovalPolicy` and set its threshold in cents, creating the one row when the org
  has none. The page reads under the member scope and writes through the resource's OWN
  admin-only governed actions, so a non-admin member sees a read-only control and a crafted
  save is refused by the kernel; the operator plane renders no form.
- **AP invoice capture** (`/erp/ap-capture`, mounted by `samen_erp_routes/3`): paste vendor
  invoice text or upload a PDF/image, review the parsed number, dates, lines and total, then
  confirm ONE `:draft` `ApInvoice`. Capture never approves: the bill still walks the ordinary
  `:approve` Gate. A number already on a bill is refused at parse time, and a softer
  vendor/date/total duplicate is refused on confirm unless the operator explicitly confirms.
  Text and CSV uploads are free; PDFs and images use the configured OCR adapter.
- **Durable per-org hosted-OCR budget** (AP capture): PDF/image submissions are metered per
  organization in Postgres (`web_ocr_quota`), 60 documents per hour by default via the
  `:erp_invoice_ocr` `Samen.Web.RateLimit` surface. The counter is a single atomic upsert, so
  every node shares it and a restart cannot refill it; windows use the database clock. The
  budget is shown before an upload, refreshed by an id-only PubSub event on the ERP dashboard,
  and labelled with the time until reset. A prune worker drops expired windows, and
  `[:samen, :erp, :ocr_quota, :exhausted]` / `[:samen, :erp, :ocr_quota, :prune]` telemetry
  reports exhaustion and sweeps. Missing migrations fail closed for documents; pasted text
  still works.
- **AP bill payments and payment runs** (`/erp/ap-payments`): `:pay` settles an approved bill
  and posts the AP-clearing debit/cash credit in the same transaction, anchored to the bill so
  a second payment is refused by the row lock. The page runs one same-vendor batch over
  selected approved bills, flags possible duplicate bills, and hands the remittance CSV and
  ACH/EFT file directly from the render. A run that includes a bill that is no longer approved
  pays nothing.
- **AR receipt intake** (`/erp/ar-receipts`, mounted by `samen_erp_routes/3`): one customer
  payment is split across the customer's open Billing invoices. The new
  `Samen.Scopes.Finance.ArReceiptApplication` re-reads the statement, refuses cross-customer,
  over-allocated, already-settled or duplicated selections, then creates and posts one
  `PaymentReceipt` per allocation — each with its cash+AR-clearing journal entry — inside one
  transaction, so any failure rolls the whole payment back. The page reloads the same
  `ArAging` projection after posting, so the open list and the aging page reflect the cash
  immediately.
- **AR aging and customer statements** (`/erp/ar-aging`): read the host's Billing invoices and
  POSTED `PaymentReceipt` cash through `Samen.Scopes.Finance.ArAging`, bucketed current /
  1–30 / 31–60 / 61–90 / 90+ / undated, with a per-customer statement of every invoice and
  settling receipt. The page is read-only and uses the same kernel projection the API uses;
  provider `amount_paid_cents` is deliberately ignored in favor of posted cash.
- **Canonical Work scope — `Project` + the self-referential `Task`** (ADR-041 §3, F1): a new
  `Samen.Scopes.Work` blueprint ships one canonical Work item (`kind`/`title`/`body`/`status`/
  `priority`/`due_at`/`completed_at`, a generic CRM-agnostic `(subject_key, subject_id)`
  object-ref anchor, `custom`, `owner_id`, and the self-referential `parent_id` Subtask tree
  with cycle refusal), archivable with a subtree cascade. Every vertical inherits Project +
  Task at ≈0 authored LOC; no PII (the scope's catalog PII map is empty).
- **Tier-1 custom fields gain five new bounded types** (ADR-036 H6): `money`, `url`, `phone`,
  `email`, `address` join `Samen.CustomFields`'s existing `string`/`integer`/`number`/
  `boolean`/`date`/`enum` set, reusing the matching `Samen.Type.*` module's own cast/
  validation logic and bounded constraints (`currencies` allowlist for money; `schemes`/
  `max_length` for url; `max_length` for phone/email; `allowed_countries` for address). A
  non-`pii_declared` custom field of type `email`/`phone`/`address` is refused BY TYPE, not
  merely by value-shape heuristic (closing a gap the heuristic alone can't reach for a
  MAP-valued `address` field) — "a Tier-1 custom field can never be a vault bypass" now holds
  for all eleven types.
- **`mix samen.gen.resource --field-type` — the full rich-type menu** (ADR-036 H7): the
  generator's scaffolded resource's ONE scalar `pii do` vault field can now be declared as
  any of `string | money | percent | score | duration | priority | url | email | phone |
  address` (default `string`, byte-identical to pre-existing output). Every menu entry still
  materializes as a `Samen.Type.VaultField` `vt_*` token column regardless of its declared
  logical type — only the resource's `pii_attribute` declaration and the generated G26 test
  files' sample values vary per entry.
- **`Samen.Web.Csv` gains a Duration cell clause** (ADR-036 D5/H7): the canonical export form
  is ISO-8601 (e.g. `"PT5400S"`), matching the H2 contract table — `Samen.Type.Duration`'s Ash
  value is a bare integer (no wrapper struct), so the cell serializer now consults the
  column's declared Ash type before falling back to the generic value-shape dispatch every
  other cell already used.
- **E7 audit-on-write — the `versioned` blueprint opt-in** (ADR-040 §6, T119): a resource
  declares `use Samen.Resource, versioned: true` (mode `:changes_only`, the default) or
  `versioned: :snapshot` and ash_paper_trail (ADR-037 §5.4 ADOPT) generates a governed
  `<Resource>.Version` recording every create/update/destroy as an attributable, token-only
  diff. The generated version resource gets FULL samen governance (INV-3, §6.2): an
  allocator-owned abbrev injected into its `samen do abbrev end` section at build time (the
  first auto-allocated abbrev on a generated resource; registry stays HANDS-OFF), prefixed
  columns, a mirrored `org_id`, OrgScope policies, catalog registration, and the
  `no_plaintext_pii` roster. INV-1 holds by construction: a vault-routed (🔒) attribute
  versions as its `vt_*` token, NEVER plaintext, for BOTH `:changes_only` and the full-row
  `:snapshot` reconstruction (`store_action_inputs?` is `false` forever; `:full_diff` is
  refused substrate-wide). The four audit tiers stay disjoint (§7.4): a versioned +
  impersonated write produces BOTH a Version row (E7) and a separate §6.6 `impersonation_write`
  governance `aud_event` — never one row serving both (the impersonation-write audit no-ops on
  version resources).

### Removed

- **BREAKING (pre-1.0): the CMS `ContentVersion` resource is retired** (ADR-040 §6.5, T119).
  The bespoke `content_version` ledger (`define_content_version`, the `<abbrev>_content_version`
  table, the admin-gated `:create_version` action) is removed in favor of E7 audit-on-write:
  CMS `Page`/`Post`/`Block` now declare `versioned: :snapshot`, so ash_paper_trail records a
  full-row `<Resource>.Version` snapshot on EVERY tracked write (create/update/publish/
  mark_archived/archive/restore) — fixing the long-standing gap where status transitions
  promised a version but only `set_attribute`'d (nothing ever appended a `ContentVersion` row).
  Content history now reads `Demo.CmsScope.{Page,Post,Block}.Version`; demo's `:create_version`
  smoke/test call sites are rewired to assert the automatic version rows. Zero data drop: the
  ledger held only dev/fixture data (no lifecycle hook ever wrote it, no production host mounts
  the CMS scope), so a clean drop/create produces the paper_trail-backed shape — the historical
  `add_cms_scope` migration no longer creates the table, and a guarded, idempotent
  `DROP TABLE IF EXISTS` + catalog cleanup (T97 move-then-drop convention) sweeps any lingering
  dev DB. The retired `cvr` abbrev stays in the registry (never recycled — permanence). PITR
  is not needed (no data).
- **BREAKING (pre-1.0): the CRM `Activity` resource is removed** (ADR-041 §5, operator ruling
  M5). `Activity` (call/email/meeting/note) was **destructively migrated into the canonical
  Work-scope `Task`** and its table dropped on every host (`act_activity`/`fac_activity`/
  `vce_activity`/`swa_activity` → `<work>_task`). A contract-phase, idempotent, per-host
  `INSERT … ON CONFLICT DO NOTHING` + `DROP TABLE` copies **every** Activity field onto Task
  field-for-field (§5.1) with **zero data drop**: `type→kind`, `subject→title`, body/status/
  due_at/completed_at/custom/id/org_id/timestamps verbatim; the ≤3 CRM foreign keys collapse to
  the primary subject anchor by precedence (`opportunity ▸ person ▸ company`) **and** the full
  non-null ref set is preserved in `custom.crm_refs`. The CRM detail timeline + composer now
  read/write the Work `Task` through the object-ref anchor (OR-matching `custom.crm_refs`), so a
  user sees the identical event stream. Cross-org protection moves from the belongs-to
  `SameOrgFk` to the org-scoped `Samen.Web.ObjectRef.resolve` write boundary — a cross-org
  reference is now **inert** (unresolvable) rather than a `SameOrgFk` validation error.
  Driftwood's `CheckCall` ubiquitous-language alias now re-identifies `Driftwood.Work.Task`.
  PITR is the production control for the contract phase (no `down/0` round-trip).

### Changed

- **BREAKING (pre-1.0): CRM Opportunity + Billing Price money columns.** `Samen.Type.Money`
  (ADR-036 H1, a thin wrapper over `AshMoney.Types.Money` — ADR-037 §5.2 ADOPT) replaces the
  paired `value_cents`/`unit_amount_cents :integer` + `currency :string` convention with ONE
  `money_with_currency` Postgres composite column (`Opportunity.value`, `Price.unit_amount`).
  A destructive, single data-copy migration (no deprecation window — the integer-cents → composite
  transform is a lossless bijection) ships in every host (`demo`, `driftwood` — both the tenant and
  operator Billing mounts, `pawchart`) and in the `mix samen.gen.app` generator templates. Every
  production reader/writer of the old columns (the kernel MRR source, the raw-SQL revenue rollups,
  the `samen_web`/vertical UI, seeds/test-support) was repointed in the same change (ADR-036 §4.5).
  Money self-classifies non-PII behind a foundry-shipped `Samen.NonPii.TypeClearance` entry
  (ADR-034 gate). `Samen.Web.Csv` gained a Money cell clause (`"USD 12.34"`, ISO-4217).

## [0.1.0] — 2026-07-20

First tagged release — the public snapshot of the Samen foundry.

### Included

- **Kernel (`samen_core`)** — per-subject vault + KMS key hierarchy, crypto-shred with a
  destruction oracle, two-plane PII masking, token-blind cross-tenant aggregates, a
  hash-chained append-only audit log, the self-qualifying catalog, and the verifier gate.
- **Web framework (`samen_web`)** — inherited LiveView surfaces (CRUD + list ergonomics,
  notifications inbox, operator cockpit, global search, files, CSV import/export, self-serve
  settings) with per-plane masking by construction.
- **Generators** — `mix samen.gen.*` emit a running, correct-by-construction product with
  web / API / seed / observability / deploy scaffolds, including a readiness (`/readyz`)
  probe over Postgres, the KMS store, and Oban.
- **Verticals** — `driftwood` (freight) and `pawchart` (vet clinic) prove the substrate.
- Workstreams A / B / D / E shipped and adversarially gated — see
  [`docs/saas-gap-roadmap.md`](docs/saas-gap-roadmap.md).

### Notes

- **AI-authored.** Every commit is `Co-Authored-By: Claude` (see the README authorship note).
- Several adapters ship as documented **fail-honest stubs** (SMTP/ESP, S3, Stripe sync): they
  return `{:error, :not_configured}` or a labeled no-op, never a false success. End-user auth
  is **host-owned** — Samen governs the identity and billing you bring.

[0.1.0]: https://github.com/ckluis/samen/releases/tag/v0.1.0
