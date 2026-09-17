defmodule Samenerp.Repo.Migrations.MountOperatorScopes do
  @moduledoc """
  Mounts the OPERATOR namespace (ADR-010 §8.2) into the host's one Postgres: a SECOND
  mount of Identity + Billing + Support whose rows describe the SaaS company's OWN
  book of business — its tenant-org ACCOUNTS, their tenant-ADMINS (PII the SaaS owns,
  CLEAR), each tenant's subscription-to-the-SaaS (incl. the ADR-017 movement ledger),
  and the tickets tenants file WITH the SaaS. Mirrors driftwood's
  `mount_operator_scopes`. Catalogued in the SAME transaction (ADR-004 catalog-in-tx).

  PII columns hold vault `vt_*` tokens (plaintext never lands here):
    * `eou_user.eou_full_name` / `.eou_emails`
    * `epc_customer.pii_epc_billing_name` / `.pii_epc_billing_email`
    * `eqg_agent.eqg_full_name` / `.pii_eqg_email`,
      `eqm_message.pii_eqm_body`
  """
  use Samen.Migration

  @resources [
    # Identity (operator: accounts + admins)
    Samenerp.Operator.Org,
    Samenerp.Operator.User,
    Samenerp.Operator.Membership,
    Samenerp.Operator.Role,
    Samenerp.Operator.ApiKey,
    Samenerp.Operator.Invitation,
    # ADR-035 — the identity spine's two org-less resources (T02x integration).
    Samenerp.Operator.Credential,
    Samenerp.Operator.AuthToken,
    # ADR-035 §3.1/§4.3, §5 A6 — the identity spine's other two org-less resources
    # (T04's Session, T06's UserIdentity; T06x integration).
    Samenerp.Operator.Session,
    Samenerp.Operator.UserIdentity,
    # ADR-038 §6.4 (T109) — the durable brute-force failure counter.
    Samenerp.Operator.LoginFailure,
    # Billing (operator: tenant subscriptions-to-the-SaaS + the movement ledger)
    Samenerp.Operator.Customer,
    Samenerp.Operator.Subscription,
    Samenerp.Operator.Plan,
    Samenerp.Operator.Price,
    Samenerp.Operator.Invoice,
    Samenerp.Operator.Payment,
    Samenerp.Operator.Usage,
    Samenerp.Operator.Entitlement,
    Samenerp.Operator.SubscriptionEvent,
    # Support (operator: tenant-filed desk tickets)
    Samenerp.Operator.Sla,
    Samenerp.Operator.Ticket,
    Samenerp.Operator.Conversation,
    Samenerp.Operator.Agent,
    Samenerp.Operator.Message,
    Samenerp.Operator.Macro,
    Samenerp.Operator.Csat,
    # I6 (T79) — the CSAT request→response loop's single-use survey link.
    Samenerp.Operator.CsatSurveyToken
  ]

  def up do
    # =====================================================================
    # IDENTITY — accounts (Org) + admins (User) + membership + role/key/invite
    # =====================================================================

    # --- eoo_org : the tenant anchor. Here: an ACCOUNT (a tenant org
    #     mirrored). The slug carries the tenant_org_id back-reference (Bridge-B). ---
    create table(:eoo_org, primary_key: false) do
      add(:eoo_name, :text, null: false)
      add(:eoo_slug, :text)
      add(:eoo_plan, :text, default: "free")
      # ADR-035 §4.3/§5 A4 (spec-questions c3, T04) — the OPTIONAL org-level
      # concurrent-session cap; nil = unlimited (the default).
      add(:eoo_max_concurrent_sessions, :integer)
      # ADR-035 §5 A8 (T08) — set once the first-run onboarding wizard completes
      # (`Samen.Web.Onboarding.complete!/3`); nil until then (`needed?/3` reads it).
      add(:eoo_onboarded_at, :utc_datetime)
      add(:eoo_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eoo_org_id, :uuid)
      add(:eoo_inserted_at, :utc_datetime, null: false)
      add(:eoo_updated_at, :utc_datetime, null: false)
    end

    # --- eou_user : the tenant-ADMIN 🔒 (full_name/emails vault-routed) ---
    create table(:eou_user, primary_key: false) do
      add(:eou_handle, :text)
      add(:eou_status, :text, default: "active")
      add(:eou_full_name, :text)
      add(:eou_emails, :text)
      add(:eou_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eou_org_id, :uuid, null: false)
      add(:eou_inserted_at, :utc_datetime, null: false)
      add(:eou_updated_at, :utc_datetime, null: false)
    end

    # --- eom_membership : (user, org, role) ---
    create table(:eom_membership, primary_key: false) do
      add(:eom_role, :text, default: "member")
      add(:eom_status, :text, default: "active")

      add(
        :eom_user_id,
        references(:eou_user,
          column: :eou_id,
          name: "eom_membership_eom_user_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:eom_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eom_org_id, :uuid, null: false)
      add(:eom_inserted_at, :utc_datetime, null: false)
      add(:eom_updated_at, :utc_datetime, null: false)
    end

    # --- eor_role : Tier-0 config rows (per-org role catalog) ---
    create table(:eor_role, primary_key: false) do
      add(:eor_name, :text, null: false)
      add(:eor_label, :text)
      add(:eor_rank, :integer, null: false)
      add(:eor_enabled, :boolean, default: true)
      add(:eor_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eor_org_id, :uuid, null: false)
      add(:eor_inserted_at, :utc_datetime, null: false)
      add(:eor_updated_at, :utc_datetime, null: false)
    end

    # --- eok_api_key : scoped credential (two planes) ---
    create table(:eok_api_key, primary_key: false) do
      add(:eok_token_digest, :text, null: false)
      add(:eok_plane, :text, null: false, default: "tenant")
      add(:eok_scopes, :map, default: fragment("'{}'::jsonb"))
      add(:eok_minter_role, :text)
      add(:eok_revoked_at, :utc_datetime)
      # F3.4 — bounded API-key expiry (deny-on-read) + last-use observability.
      add(:eok_expires_at, :utc_datetime)
      add(:eok_last_used_at, :utc_datetime)

      add(
        :eok_membership_id,
        references(:eom_membership,
          column: :eom_id,
          name: "eok_api_key_eok_membership_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:eok_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eok_org_id, :uuid, null: false)
      add(:eok_inserted_at, :utc_datetime, null: false)
      add(:eok_updated_at, :utc_datetime, null: false)
    end

    # --- eon_invitation : a pending invite 🔒 (email vault-routed).
    #     ADR-035 §4.1/§4.2/§5 A5 (T05 hardening): `token_digest` (SHA-256 digest at
    #     rest, the ApiKey precedent) + `email_bidx` (the §4.1 non-reversible keyed-HMAC
    #     lookup — accept-time credential matching never needs a vault reveal) +
    #     `expires_at`/`accepted_at`/`revoked_at` (the 4-state lifecycle's terminal
    #     timestamps). Mirrors demo/driftwood's `harden_identity_invitation` shape,
    #     emitted directly (fresh app — no rename dance needed). ---
    create table(:eon_invitation, primary_key: false) do
      add(:eon_role, :text, default: "member")
      add(:eon_status, :text, default: "pending")
      add(:eon_token_digest, :text)
      add(:eon_email_bidx, :text)
      add(:eon_expires_at, :utc_datetime)
      add(:eon_accepted_at, :utc_datetime)
      add(:eon_revoked_at, :utc_datetime)
      add(:eon_email, :text)
      add(:eon_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eon_org_id, :uuid, null: false)
      add(:eon_inserted_at, :utc_datetime, null: false)
      add(:eon_updated_at, :utc_datetime, null: false)
    end

    create(unique_index(:eon_invitation, [:eon_token_digest]))

    # --- eoc_credential : THE authentication principal (org-less; ADR-035). ---
    create table(:eoc_credential, primary_key: false) do
      add(:eoc_email_bidx, :text, null: false)
      add(:eoc_password_hash, :text)
      add(:eoc_hash_scheme, :text)
      add(:eoc_verified_at, :utc_datetime)
      # ADR-035 §5 A7 (T07) — the TOTP 2FA columns the Identity Credential blueprint
      # declares. `pii_<abbrev>_totp_secret`/`pii_<abbrev>_recovery_codes` are 🔒
      # vault-routed (`:pii_secret` — `text` holding a `vt_*` token only, INV-1; the
      # scalar `pii_attribute` `pii_<abbrev>_<name>` storage prefix); the two
      # `*_totp_*_at` timestamps are plain non-PII. Without these four columns the
      # generated app has schema drift the moment TotpEnrollLive enrolls (the
      # driftwood `add_credential_totp_fields` migration, folded into this create).
      add(:pii_eoc_totp_secret, :text)
      add(:pii_eoc_recovery_codes, :text)
      add(:eoc_totp_enabled_at, :utc_datetime)
      add(:eoc_totp_last_verified_at, :utc_datetime)
      add(:eoc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eoc_org_id, :uuid)
      add(:eoc_inserted_at, :utc_datetime, null: false)
      add(:eoc_updated_at, :utc_datetime, null: false)
    end

    # ADR-035 §4.1 — the global "one account per email" invariant.
    create(unique_index(:eoc_credential, [:eoc_email_bidx]))

    # --- eot_auth_token : single-use, expiring, hashed-at-rest emailed secrets. ---
    create table(:eot_auth_token, primary_key: false) do
      add(:eot_token_digest, :text, null: false)
      add(:eot_context, :text, null: false)
      add(:eot_sent_to_bidx, :text)
      add(:eot_expires_at, :utc_datetime, null: false)
      add(:eot_consumed_at, :utc_datetime)

      add(
        :eot_credential_id,
        references(:eoc_credential,
          column: :eoc_id,
          name: "eot_auth_token_eot_credential_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:eot_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eot_org_id, :uuid)
      add(:eot_inserted_at, :utc_datetime, null: false)
      add(:eot_updated_at, :utc_datetime, null: false)
    end

    create(unique_index(:eot_auth_token, [:eot_token_digest]))

    # --- eos_session : a revocable, DB-backed login session (org-less;
    #     ADR-035 §3.1/§4.3, T04). No PII: device_label is a bounded browser/OS-family
    #     string (never the raw user-agent, never an IP); token_digest is the SHA-256
    #     digest of the raw session token (the ApiKey token_digest precedent) — never
    #     vault-routed, never allowlisted. ---
    create table(:eos_session, primary_key: false) do
      add(:eos_token_digest, :text, null: false)
      add(:eos_last_seen_at, :utc_datetime)
      add(:eos_expires_at, :utc_datetime, null: false)
      add(:eos_revoked_at, :utc_datetime)
      add(:eos_device_label, :text)

      add(
        :eos_credential_id,
        references(:eoc_credential,
          column: :eoc_id,
          name: "eos_session_eos_credential_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:eos_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eos_org_id, :uuid)
      # ADR-035 §4.3 A4 (T104) — microsecond precision so the concurrent-session
      # cap eviction sorts a total order (same-second sign-ins get a sub-second
      # creation key); mirrors the Identity.Session blueprint's usec inserted_at.
      add(:eos_inserted_at, :utc_datetime_usec, null: false)
      add(:eos_updated_at, :utc_datetime, null: false)
    end

    create(unique_index(:eos_session, [:eos_token_digest]))

    # --- eoi_user_identity : the SSO link (org-less; ADR-035 §3.1/§5 A6, T06) —
    #     binds an external IdP subject (provider + opaque provider_uid) to a Credential.
    #     No PII: provider is a bounded name and provider_uid is an IdP-scoped opaque
    #     handle — the IdP-asserted email is used only transiently for a bidx lookup at
    #     link time and, on JIT signup, vaulted on the eou_user row; it is
    #     NEVER persisted on this table (INV-1). ---
    create table(:eoi_user_identity, primary_key: false) do
      add(:eoi_provider, :text, null: false)
      add(:eoi_provider_uid, :text, null: false)
      add(:eoi_linked_at, :utc_datetime, null: false)

      add(
        :eoi_credential_id,
        references(:eoc_credential,
          column: :eoc_id,
          name: "eoi_user_identity_eoi_credential_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:eoi_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eoi_org_id, :uuid)
      add(:eoi_inserted_at, :utc_datetime, null: false)
      add(:eoi_updated_at, :utc_datetime, null: false)
    end

    create(unique_index(:eoi_user_identity, [:eoi_provider, :eoi_provider_uid]))

    # --- eol_login_failure : the DURABLE brute-force failure counter (org-less;
    #     ADR-038 §6.4, T109). One row per (key_kind, key_value) — key_value is a
    #     non-reversible email_bidx HMAC or an opaque credential UUID, never PII. Makes
    #     the T103-shaped bounded login_failed signal survive a node restart. ---
    create table(:eol_login_failure, primary_key: false) do
      add(:eol_key_kind, :text, null: false)
      add(:eol_key_value, :text, null: false)
      add(:eol_failure_count, :integer, null: false, default: 1)
      add(:eol_window_started_at, :utc_datetime_usec, null: false)
      add(:eol_last_failed_at, :utc_datetime_usec, null: false)

      add(:eol_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eol_org_id, :uuid)
      add(:eol_inserted_at, :utc_datetime, null: false)
      add(:eol_updated_at, :utc_datetime, null: false)
    end

    create(unique_index(:eol_login_failure, [:eol_key_kind, :eol_key_value]))

    # ADR-035 §3.1 — additive, nullable FK on the already-created eou_user table.
    alter table(:eou_user) do
      add(:eou_credential_id, :uuid)
    end

    # =====================================================================
    # BILLING — each tenant's subscription TO the SaaS
    # =====================================================================

    create table(:epc_customer, primary_key: false) do
      add(:epc_provider_customer_ref, :text)
      add(:epc_status, :text, default: "active")
      add(:epc_currency, :text, default: "USD")
      add(:epc_custom, :map, default: fragment("'{}'::jsonb"))
      add(:pii_epc_billing_name, :text)
      add(:pii_epc_billing_email, :text)
      add(:epc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:epc_org_id, :uuid, null: false)
      add(:epc_inserted_at, :utc_datetime, null: false)
      add(:epc_updated_at, :utc_datetime, null: false)
    end

    create table(:epp_plan, primary_key: false) do
      add(:epp_name, :text, null: false)
      add(:epp_label, :text)
      add(:epp_description, :text)
      add(:epp_provider_plan_ref, :text)
      add(:epp_interval, :text, default: "monthly")
      add(:epp_enabled, :boolean, default: true)
      add(:epp_features, :map, default: fragment("'{}'::jsonb"))
      add(:epp_custom, :map, default: fragment("'{}'::jsonb"))
      add(:epp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:epp_org_id, :uuid, null: false)
      add(:epp_inserted_at, :utc_datetime, null: false)
      add(:epp_updated_at, :utc_datetime, null: false)
      add(:epp_archived_at, :utc_datetime_usec)
    end

    create table(:epr_price, primary_key: false) do
      add(:epr_provider_price_ref, :text)
      # ADR-036 H1/D7: one money_with_currency composite column (the type was
      # installed by the app_resources migration this one runs after).
      add(:epr_unit_amount, :money_with_currency, null: false)
      add(:epr_interval, :text, default: "monthly")
      add(:epr_active, :boolean, default: true)
      add(:epr_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :epr_plan_id,
        references(:epp_plan,
          column: :epp_id,
          name: "epr_price_epr_plan_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:epr_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:epr_org_id, :uuid, null: false)
      add(:epr_inserted_at, :utc_datetime, null: false)
      add(:epr_updated_at, :utc_datetime, null: false)
      add(:epr_archived_at, :utc_datetime_usec)
    end

    create table(:eps_subscription, primary_key: false) do
      add(:eps_provider_subscription_ref, :text)
      add(:eps_status, :text, default: "active")
      add(:eps_current_period_start, :utc_datetime)
      add(:eps_current_period_end, :utc_datetime)
      add(:eps_trial_end, :utc_datetime)
      add(:eps_cancel_at, :utc_datetime)
      add(:eps_cancelled_at, :utc_datetime)
      add(:eps_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :eps_customer_id,
        references(:epc_customer,
          column: :epc_id,
          name: "eps_subscription_eps_customer_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :eps_plan_id,
        references(:epp_plan,
          column: :epp_id,
          name: "eps_subscription_eps_plan_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:eps_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eps_org_id, :uuid, null: false)
      add(:eps_inserted_at, :utc_datetime, null: false)
      add(:eps_updated_at, :utc_datetime, null: false)
    end

    # T106 decision (e): DB-unique-fence on the provider-subscription-ref (mirror idempotency).
    create(unique_index(:eps_subscription, [:eps_provider_subscription_ref], name: "eps_subscription_provider_ref_index"))

    create table(:epi_invoice, primary_key: false) do
      add(:epi_provider_invoice_ref, :text)
      add(:epi_status, :text, default: "draft")
      add(:epi_amount_due_cents, :integer, default: 0)
      add(:epi_amount_paid_cents, :integer, default: 0)
      add(:epi_currency, :text, default: "USD")
      add(:epi_period_start, :utc_datetime)
      add(:epi_period_end, :utc_datetime)
      add(:epi_due_date, :utc_datetime)
      add(:epi_paid_at, :utc_datetime)
      add(:epi_line_items, {:array, :map}, default: fragment("ARRAY[]::jsonb[]"))
      add(:epi_tax_amount_cents, :integer)
      add(:epi_tax_lines, {:array, :map}, default: fragment("ARRAY[]::jsonb[]"))
      add(:epi_hosted_invoice_url, :text)
      add(:epi_hosted_receipt_url, :text)
      add(:epi_last_event_id, :text)
      add(:epi_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :epi_customer_id,
        references(:epc_customer,
          column: :epc_id,
          name: "epi_invoice_epi_customer_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :epi_subscription_id,
        references(:eps_subscription,
          column: :eps_id,
          name: "epi_invoice_epi_subscription_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:epi_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:epi_org_id, :uuid, null: false)
      add(:epi_inserted_at, :utc_datetime, null: false)
      add(:epi_updated_at, :utc_datetime, null: false)
    end

    create table(:epy_payment, primary_key: false) do
      add(:epy_provider_payment_ref, :text)
      add(:epy_status, :text, default: "pending")
      add(:epy_amount_cents, :integer, null: false)
      add(:epy_currency, :text, default: "USD")
      add(:epy_payment_method_type, :text, default: "card")
      add(:epy_last4, :text)
      add(:epy_paid_at, :utc_datetime)
      add(:epy_failure_code, :text)
      add(:epy_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :epy_invoice_id,
        references(:epi_invoice,
          column: :epi_id,
          name: "epy_payment_epy_invoice_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :epy_customer_id,
        references(:epc_customer,
          column: :epc_id,
          name: "epy_payment_epy_customer_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:epy_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:epy_org_id, :uuid, null: false)
      add(:epy_inserted_at, :utc_datetime, null: false)
      add(:epy_updated_at, :utc_datetime, null: false)
    end

    create table(:epu_usage, primary_key: false) do
      add(:epu_metric, :text, null: false)
      add(:epu_quantity, :integer, default: 0)
      add(:epu_period_start, :utc_datetime)
      add(:epu_period_end, :utc_datetime)
      add(:epu_reported_at, :utc_datetime)

      add(
        :epu_subscription_id,
        references(:eps_subscription,
          column: :eps_id,
          name: "epu_usage_epu_subscription_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:epu_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:epu_org_id, :uuid, null: false)
      add(:epu_inserted_at, :utc_datetime, null: false)
      add(:epu_updated_at, :utc_datetime, null: false)
    end

    create table(:epe_entitlement, primary_key: false) do
      add(:epe_feature, :text, null: false)
      add(:epe_granted, :boolean, default: true)
      add(:epe_expires_at, :utc_datetime)
      add(:epe_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :epe_subscription_id,
        references(:eps_subscription,
          column: :eps_id,
          name: "epe_entitlement_epe_subscription_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :epe_plan_id,
        references(:epp_plan,
          column: :epp_id,
          name: "epe_entitlement_epe_plan_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:epe_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:epe_org_id, :uuid, null: false)
      add(:epe_inserted_at, :utc_datetime, null: false)
      add(:epe_updated_at, :utc_datetime, null: false)
    end

    # --- Subscription-movement ledger (`mov`; ADR-017) — append-only, no PII,
    #     soft id refs (no FK: the immutable ledger outlives its subscription row) ---
    create table(:epv_subscription_event, primary_key: false) do
      add(:epv_subscription_id, :uuid, null: false)
      add(:epv_customer_id, :uuid)
      add(:epv_plan_id, :uuid)
      add(:epv_from_plan_id, :uuid)
      add(:epv_kind, :text, null: false)
      add(:epv_mrr_delta_cents, :integer, null: false, default: 0)
      add(:epv_mrr_before_cents, :integer, null: false, default: 0)
      add(:epv_mrr_after_cents, :integer, null: false, default: 0)
      add(:epv_from_status, :text)
      add(:epv_to_status, :text)
      add(:epv_reason, :text, default: "status_change")
      add(:epv_occurred_at, :utc_datetime, null: false)
      add(:epv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:epv_org_id, :uuid, null: false)
      add(:epv_inserted_at, :utc_datetime, null: false)
      add(:epv_updated_at, :utc_datetime, null: false)
    end

    # =====================================================================
    # SUPPORT — the SaaS help desk (tenants file tickets WITH the SaaS)
    # =====================================================================

    create table(:eql_sla, primary_key: false) do
      add(:eql_name, :text, null: false)
      add(:eql_label, :text)
      add(:eql_first_response_minutes, :integer, default: 60)
      add(:eql_resolve_minutes, :integer, default: 480)
      add(:eql_priority, :text, default: "normal")
      add(:eql_enabled, :boolean, default: true)
      add(:eql_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eql_org_id, :uuid, null: false)
      add(:eql_inserted_at, :utc_datetime, null: false)
      add(:eql_updated_at, :utc_datetime, null: false)
      add(:eql_archived_at, :utc_datetime_usec)
    end

    # The ticket's custom bag carries the requester back-references
    # (`requester_org_id` → account Org, `requester_user_id` → tenant-admin User).
    create table(:eqk_ticket, primary_key: false) do
      add(:eqk_subject, :text, null: false)
      add(:eqk_status, :text, default: "open")
      add(:eqk_priority, :text, default: "normal")
      add(:eqk_sla_breach_at, :utc_datetime)
      add(:eqk_breached, :boolean, default: false, null: false)
      add(:eqk_resolved_at, :utc_datetime)
      add(:eqk_closed_at, :utc_datetime)
      add(:eqk_custom, :map, default: fragment("'{}'::jsonb"))
      add(:eqk_external_id, :text)

      add(
        :eqk_sla_id,
        references(:eql_sla,
          column: :eql_id,
          name: "eqk_ticket_eqk_sla_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:eqk_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eqk_org_id, :uuid, null: false)
      add(:eqk_inserted_at, :utc_datetime, null: false)
      add(:eqk_updated_at, :utc_datetime, null: false)
      add(:eqk_archived_at, :utc_datetime_usec)
    end

    create(
      index(:eqk_ticket, [:eqk_sla_breach_at, :eqk_breached],
        name: "eqk_ticket_sla_breach_idx",
        where: "eqk_sla_breach_at IS NOT NULL AND eqk_breached = false"
      )
    )

    # T60: the chat offline-escalation dedupe backstop — a partial-unique index makes a
    # CONCURRENT double-escalation of the same chat impossible (one ticket per chat). This
    # is emitted for EVERY generated app so the framework guarantee is inherited, not
    # demo-only. Partial (external_id IS NOT NULL) so normal tickets are unconstrained.
    create(
      unique_index(:eqk_ticket, [:eqk_org_id, :eqk_external_id],
        name: "eqk_ticket_chat_dedupe_idx",
        where: "eqk_external_id IS NOT NULL"
      )
    )

    create table(:eqc_conversation, primary_key: false) do
      add(:eqc_channel, :text, default: "email")
      add(:eqc_status, :text, default: "open")
      add(:eqc_subject, :text)

      add(
        :eqc_ticket_id,
        references(:eqk_ticket,
          column: :eqk_id,
          name: "eqc_conversation_eqc_ticket_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:eqc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eqc_org_id, :uuid, null: false)
      add(:eqc_inserted_at, :utc_datetime, null: false)
      add(:eqc_updated_at, :utc_datetime, null: false)
      add(:eqc_archived_at, :utc_datetime_usec)
    end

    # The SaaS support AGENT 🔒 (the SaaS's own employee — CLEAR on its own plane).
    create table(:eqg_agent, primary_key: false) do
      add(:eqg_handle, :text)
      add(:eqg_status, :text, default: "active")
      add(:eqg_role, :text, default: "agent")
      add(:eqg_external_id, :text)
      add(:eqg_timezone, :text)
      add(:eqg_custom, :map, default: fragment("'{}'::jsonb"))
      add(:eqg_full_name, :text)
      add(:pii_eqg_email, :text)
      add(:eqg_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eqg_org_id, :uuid, null: false)
      add(:eqg_inserted_at, :utc_datetime, null: false)
      add(:eqg_updated_at, :utc_datetime, null: false)
      add(:eqg_archived_at, :utc_datetime_usec)
    end

    create table(:eqm_message, primary_key: false) do
      add(:eqm_sender_type, :text, default: "customer")
      add(:eqm_sender_id, :uuid)
      add(:eqm_message_type, :text, default: "reply")
      add(:eqm_attachments, {:array, :text}, default: [])
      add(:eqm_created_via, :text, default: "web")
      add(:pii_eqm_body, :text)

      add(
        :eqm_conversation_id,
        references(:eqc_conversation,
          column: :eqc_id,
          name: "eqm_message_eqm_conversation_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(
        :eqm_agent_id,
        references(:eqg_agent,
          column: :eqg_id,
          name: "eqm_message_eqm_agent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:eqm_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eqm_org_id, :uuid, null: false)
      add(:eqm_inserted_at, :utc_datetime, null: false)
      add(:eqm_updated_at, :utc_datetime, null: false)
      add(:eqm_archived_at, :utc_datetime_usec)
    end

    create table(:eqn_macro, primary_key: false) do
      add(:eqn_name, :text, null: false)
      add(:eqn_description, :text)
      add(:eqn_body_template, :text)
      add(:eqn_tags, {:array, :text}, default: [])
      add(:eqn_enabled, :boolean, default: true)
      add(:eqn_category, :text)
      add(:eqn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eqn_org_id, :uuid, null: false)
      add(:eqn_inserted_at, :utc_datetime, null: false)
      add(:eqn_updated_at, :utc_datetime, null: false)
      add(:eqn_archived_at, :utc_datetime_usec)
    end

    create table(:eqs_csat, primary_key: false) do
      add(:eqs_score, :integer, null: false)
      add(:eqs_comments, :text)
      add(:eqs_channel, :text, default: "email")
      add(:eqs_responded_at, :utc_datetime)

      add(
        :eqs_ticket_id,
        references(:eqk_ticket,
          column: :eqk_id,
          name: "eqs_csat_eqs_ticket_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(
        :eqs_agent_id,
        references(:eqg_agent,
          column: :eqg_id,
          name: "eqs_csat_eqs_agent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:eqs_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eqs_org_id, :uuid, null: false)
      add(:eqs_inserted_at, :utc_datetime, null: false)
      add(:eqs_updated_at, :utc_datetime, null: false)
    end

    # I6 (T79) — the CSAT request→response loop's single-use survey link.
    create table(:eqt_csat_survey_token, primary_key: false) do
      add(:eqt_token_digest, :text, null: false)
      add(:eqt_expires_at, :utc_datetime, null: false)
      add(:eqt_consumed_at, :utc_datetime)
      add(:eqt_sent_at, :utc_datetime)

      add(
        :eqt_ticket_id,
        references(:eqk_ticket,
          column: :eqk_id,
          name: "eqt_csat_survey_token_eqt_ticket_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(
        :eqt_agent_id,
        references(:eqg_agent,
          column: :eqg_id,
          name: "eqt_csat_survey_token_eqt_agent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:eqt_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eqt_org_id, :uuid, null: false)
      add(:eqt_inserted_at, :utc_datetime, null: false)
      add(:eqt_updated_at, :utc_datetime, null: false)
    end

    create(index(:eqt_csat_survey_token, [:eqt_token_digest], name: "eqt_csat_survey_token_digest_idx"))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    # --- Support (reverse FK order) ---
    drop(index(:eqt_csat_survey_token, [:eqt_token_digest], name: "eqt_csat_survey_token_digest_idx"))
    drop(constraint(:eqt_csat_survey_token, "eqt_csat_survey_token_eqt_agent_id_fkey"))
    drop(constraint(:eqt_csat_survey_token, "eqt_csat_survey_token_eqt_ticket_id_fkey"))
    drop(table(:eqt_csat_survey_token))
    drop(constraint(:eqs_csat, "eqs_csat_eqs_agent_id_fkey"))
    drop(constraint(:eqs_csat, "eqs_csat_eqs_ticket_id_fkey"))
    drop(table(:eqs_csat))
    drop(table(:eqn_macro))
    drop(constraint(:eqm_message, "eqm_message_eqm_agent_id_fkey"))
    drop(constraint(:eqm_message, "eqm_message_eqm_conversation_id_fkey"))
    drop(table(:eqm_message))
    drop(table(:eqg_agent))
    drop(constraint(:eqc_conversation, "eqc_conversation_eqc_ticket_id_fkey"))
    drop(table(:eqc_conversation))
    drop(index(:eqk_ticket, [:eqk_org_id, :eqk_external_id], name: "eqk_ticket_chat_dedupe_idx"))
    drop(index(:eqk_ticket, [:eqk_sla_breach_at, :eqk_breached], name: "eqk_ticket_sla_breach_idx"))
    drop(constraint(:eqk_ticket, "eqk_ticket_eqk_sla_id_fkey"))
    drop(table(:eqk_ticket))
    drop(table(:eql_sla))

    # --- Billing (reverse FK order; ledger has no FKs) ---
    drop(table(:epv_subscription_event))
    drop(constraint(:epe_entitlement, "epe_entitlement_epe_plan_id_fkey"))
    drop(constraint(:epe_entitlement, "epe_entitlement_epe_subscription_id_fkey"))
    drop(table(:epe_entitlement))
    drop(constraint(:epu_usage, "epu_usage_epu_subscription_id_fkey"))
    drop(table(:epu_usage))
    drop(constraint(:epy_payment, "epy_payment_epy_customer_id_fkey"))
    drop(constraint(:epy_payment, "epy_payment_epy_invoice_id_fkey"))
    drop(table(:epy_payment))
    drop(constraint(:epi_invoice, "epi_invoice_epi_subscription_id_fkey"))
    drop(constraint(:epi_invoice, "epi_invoice_epi_customer_id_fkey"))
    drop(table(:epi_invoice))
    drop(constraint(:eps_subscription, "eps_subscription_eps_plan_id_fkey"))
    drop(constraint(:eps_subscription, "eps_subscription_eps_customer_id_fkey"))
    drop(table(:eps_subscription))
    drop(constraint(:epr_price, "epr_price_epr_plan_id_fkey"))
    drop(table(:epr_price))
    drop(table(:epp_plan))
    drop(table(:epc_customer))

    # --- Identity (reverse FK order) ---
    alter table(:eou_user) do
      remove(:eou_credential_id)
    end

    drop(table(:eol_login_failure))
    drop(constraint(:eoi_user_identity, "eoi_user_identity_eoi_credential_id_fkey"))
    drop(table(:eoi_user_identity))
    drop(constraint(:eos_session, "eos_session_eos_credential_id_fkey"))
    drop(table(:eos_session))
    drop(constraint(:eot_auth_token, "eot_auth_token_eot_credential_id_fkey"))
    drop(table(:eot_auth_token))
    drop(table(:eoc_credential))
    drop(constraint(:eok_api_key, "eok_api_key_eok_membership_id_fkey"))
    drop(table(:eok_api_key))
    drop(table(:eon_invitation))
    drop(table(:eor_role))
    drop(constraint(:eom_membership, "eom_membership_eom_user_id_fkey"))
    drop(table(:eom_membership))
    drop(table(:eou_user))
    drop(table(:eoo_org))
  end
end
