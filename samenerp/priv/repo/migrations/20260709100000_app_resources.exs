defmodule Samenerp.Repo.Migrations.AppResources do
  @moduledoc """
  Creates Samenerp's Billing scope (abbrevs erc/ers/erl/erp/eri/ery/eru/ere/erv)
  mounted AS-IS, the authored vertical table (rne_record with the scalar vault
  field pii_rne_secret), and the token-blind aggregate projection (era_record_count),
  and catalogs every resource in the SAME migration transaction (ADR-004 catalog-in-tx).
  """
  use Samen.Migration

  @resources [
    Samenerp.Billing.Customer,
    Samenerp.Billing.Subscription,
    Samenerp.Billing.Plan,
    Samenerp.Billing.Price,
    Samenerp.Billing.Invoice,
    Samenerp.Billing.Payment,
    Samenerp.Billing.Usage,
    Samenerp.Billing.Entitlement,
    Samenerp.Billing.SubscriptionEvent,
    Samenerp.Vertical.Record,
    Samenerp.Aggregate.RecordCountBySegment
  ]

  def up do
    # ADR-036 H1/D7: money_with_currency is the AshMoney.AshPostgresExtension
    # composite type erp_unit_amount (below) is stored as. Idempotent-per-DB
    # (this is the app's first migration to need it); a host that adds further
    # Money columns later installs the extension's full operator/aggregate set via
    # `AshMoney.AshPostgresExtension` in its repo's `installed_extensions/0` +
    # `mix ash_postgres.generate_migrations`.
    execute("CREATE TYPE public.money_with_currency AS (currency_code varchar, amount numeric);")

    # ---- Billing scope (Stripe-mirror shape) — mounted AS-IS ----
    create table(:erc_customer, primary_key: false) do
      add(:erc_provider_customer_ref, :text)
      add(:erc_status, :text, default: "active")
      add(:erc_currency, :text, default: "USD")
      add(:erc_custom, :map, default: fragment("'{}'::jsonb"))
      add(:pii_erc_billing_name, :text)
      add(:pii_erc_billing_email, :text)
      add(:erc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:erc_org_id, :uuid, null: false)
      add(:erc_inserted_at, :utc_datetime, null: false)
      add(:erc_updated_at, :utc_datetime, null: false)
    end

    create table(:erl_plan, primary_key: false) do
      add(:erl_name, :text, null: false)
      add(:erl_label, :text)
      add(:erl_description, :text)
      add(:erl_provider_plan_ref, :text)
      add(:erl_interval, :text, default: "monthly")
      add(:erl_enabled, :boolean, default: true)
      add(:erl_features, :map, default: fragment("'{}'::jsonb"))
      add(:erl_custom, :map, default: fragment("'{}'::jsonb"))
      add(:erl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:erl_org_id, :uuid, null: false)
      add(:erl_inserted_at, :utc_datetime, null: false)
      add(:erl_updated_at, :utc_datetime, null: false)
      add(:erl_archived_at, :utc_datetime_usec)
    end

    create table(:erp_price, primary_key: false) do
      add(:erp_provider_price_ref, :text)
      # ADR-036 H1/D7: one money_with_currency composite column, not a paired
      # _cents/currency convention (AshMoney.AshPostgresExtension below installs
      # the type).
      add(:erp_unit_amount, :money_with_currency, null: false)
      add(:erp_interval, :text, default: "monthly")
      add(:erp_active, :boolean, default: true)
      add(:erp_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :erp_plan_id,
        references(:erl_plan,
          column: :erl_id,
          name: "erp_price_erp_plan_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:erp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:erp_org_id, :uuid, null: false)
      add(:erp_inserted_at, :utc_datetime, null: false)
      add(:erp_updated_at, :utc_datetime, null: false)
      add(:erp_archived_at, :utc_datetime_usec)
    end

    create table(:ers_subscription, primary_key: false) do
      add(:ers_provider_subscription_ref, :text)
      add(:ers_status, :text, default: "active")
      add(:ers_current_period_start, :utc_datetime)
      add(:ers_current_period_end, :utc_datetime)
      add(:ers_trial_end, :utc_datetime)
      add(:ers_cancel_at, :utc_datetime)
      add(:ers_cancelled_at, :utc_datetime)
      add(:ers_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :ers_customer_id,
        references(:erc_customer,
          column: :erc_id,
          name: "ers_subscription_ers_customer_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :ers_plan_id,
        references(:erl_plan,
          column: :erl_id,
          name: "ers_subscription_ers_plan_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:ers_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ers_org_id, :uuid, null: false)
      add(:ers_inserted_at, :utc_datetime, null: false)
      add(:ers_updated_at, :utc_datetime, null: false)
    end

    # T106 decision (e): DB-unique-fence on the provider-subscription-ref (mirror idempotency).
    create(unique_index(:ers_subscription, [:ers_provider_subscription_ref], name: "ers_subscription_provider_ref_index"))

    create table(:eri_invoice, primary_key: false) do
      add(:eri_provider_invoice_ref, :text)
      add(:eri_status, :text, default: "draft")
      add(:eri_amount_due_cents, :integer, default: 0)
      add(:eri_amount_paid_cents, :integer, default: 0)
      add(:eri_currency, :text, default: "USD")
      add(:eri_period_start, :utc_datetime)
      add(:eri_period_end, :utc_datetime)
      add(:eri_due_date, :utc_datetime)
      add(:eri_paid_at, :utc_datetime)
      add(:eri_line_items, {:array, :map}, default: fragment("ARRAY[]::jsonb[]"))
      add(:eri_tax_amount_cents, :integer)
      add(:eri_tax_lines, {:array, :map}, default: fragment("ARRAY[]::jsonb[]"))
      add(:eri_hosted_invoice_url, :text)
      add(:eri_hosted_receipt_url, :text)
      add(:eri_last_event_id, :text)
      add(:eri_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :eri_customer_id,
        references(:erc_customer,
          column: :erc_id,
          name: "eri_invoice_eri_customer_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :eri_subscription_id,
        references(:ers_subscription,
          column: :ers_id,
          name: "eri_invoice_eri_subscription_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:eri_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eri_org_id, :uuid, null: false)
      add(:eri_inserted_at, :utc_datetime, null: false)
      add(:eri_updated_at, :utc_datetime, null: false)
    end

    create table(:ery_payment, primary_key: false) do
      add(:ery_provider_payment_ref, :text)
      add(:ery_status, :text, default: "pending")
      add(:ery_amount_cents, :integer, null: false)
      add(:ery_currency, :text, default: "USD")
      add(:ery_payment_method_type, :text, default: "card")
      add(:ery_last4, :text)
      add(:ery_paid_at, :utc_datetime)
      add(:ery_failure_code, :text)
      add(:ery_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :ery_invoice_id,
        references(:eri_invoice,
          column: :eri_id,
          name: "ery_payment_ery_invoice_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :ery_customer_id,
        references(:erc_customer,
          column: :erc_id,
          name: "ery_payment_ery_customer_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:ery_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ery_org_id, :uuid, null: false)
      add(:ery_inserted_at, :utc_datetime, null: false)
      add(:ery_updated_at, :utc_datetime, null: false)
    end

    create table(:eru_usage, primary_key: false) do
      add(:eru_metric, :text, null: false)
      add(:eru_quantity, :integer, default: 0)
      add(:eru_period_start, :utc_datetime)
      add(:eru_period_end, :utc_datetime)
      add(:eru_reported_at, :utc_datetime)

      add(
        :eru_subscription_id,
        references(:ers_subscription,
          column: :ers_id,
          name: "eru_usage_eru_subscription_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:eru_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eru_org_id, :uuid, null: false)
      add(:eru_inserted_at, :utc_datetime, null: false)
      add(:eru_updated_at, :utc_datetime, null: false)
    end

    create table(:ere_entitlement, primary_key: false) do
      add(:ere_feature, :text, null: false)
      add(:ere_granted, :boolean, default: true)
      add(:ere_expires_at, :utc_datetime)
      add(:ere_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :ere_subscription_id,
        references(:ers_subscription,
          column: :ers_id,
          name: "ere_entitlement_ere_subscription_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :ere_plan_id,
        references(:erl_plan,
          column: :erl_id,
          name: "ere_entitlement_ere_plan_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:ere_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ere_org_id, :uuid, null: false)
      add(:ere_inserted_at, :utc_datetime, null: false)
      add(:ere_updated_at, :utc_datetime, null: false)
    end

    # ---- Subscription-movement ledger (`mov`; ADR-017) — append-only, no PII,
    #      soft id refs (no FK: the immutable ledger outlives its subscription row) ----
    create table(:erv_subscription_event, primary_key: false) do
      add(:erv_subscription_id, :uuid, null: false)
      add(:erv_customer_id, :uuid)
      add(:erv_plan_id, :uuid)
      add(:erv_from_plan_id, :uuid)
      add(:erv_kind, :text, null: false)
      add(:erv_mrr_delta_cents, :integer, null: false, default: 0)
      add(:erv_mrr_before_cents, :integer, null: false, default: 0)
      add(:erv_mrr_after_cents, :integer, null: false, default: 0)
      add(:erv_from_status, :text)
      add(:erv_to_status, :text)
      add(:erv_reason, :text, default: "status_change")
      add(:erv_occurred_at, :utc_datetime, null: false)
      add(:erv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:erv_org_id, :uuid, null: false)
      add(:erv_inserted_at, :utc_datetime, null: false)
      add(:erv_updated_at, :utc_datetime, null: false)
    end

    # ---- Authored vertical table (the "20%") ----
    create table(:rne_record, primary_key: false) do
      # Scalar pii_ vault field → column pii_rne_secret (vt_* token):
      add(:pii_rne_secret, :text)
      add(:rne_name, :text)
      add(:rne_segment, :text)
      add(:rne_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:rne_org_id, :uuid, null: false)
      add(:rne_inserted_at, :utc_datetime, null: false)
      add(:rne_updated_at, :utc_datetime, null: false)
      add(:rne_archived_at, :utc_datetime_usec)
    end

    # ---- Token-blind aggregate projection (no pii_ columns) ----
    create table(:era_record_count, primary_key: false) do
      add(:era_segment, :text, null: false)
      add(:era_tenant_count, :integer, default: 0)
      add(:era_record_count, :integer, default: 0)
      add(:era_refreshed_at, :utc_datetime)
      add(:era_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:era_org_id, :uuid)
      add(:era_inserted_at, :utc_datetime, null: false)
      add(:era_updated_at, :utc_datetime, null: false)
    end

    # ---- catalog every resource in THIS transaction ----
    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:era_record_count))
    drop(table(:rne_record))

    drop(table(:erv_subscription_event))

    drop(constraint(:ere_entitlement, "ere_entitlement_ere_plan_id_fkey"))
    drop(constraint(:ere_entitlement, "ere_entitlement_ere_subscription_id_fkey"))
    drop(table(:ere_entitlement))

    drop(constraint(:eru_usage, "eru_usage_eru_subscription_id_fkey"))
    drop(table(:eru_usage))

    drop(constraint(:ery_payment, "ery_payment_ery_customer_id_fkey"))
    drop(constraint(:ery_payment, "ery_payment_ery_invoice_id_fkey"))
    drop(table(:ery_payment))

    drop(constraint(:eri_invoice, "eri_invoice_eri_subscription_id_fkey"))
    drop(constraint(:eri_invoice, "eri_invoice_eri_customer_id_fkey"))
    drop(table(:eri_invoice))

    drop(constraint(:ers_subscription, "ers_subscription_ers_plan_id_fkey"))
    drop(constraint(:ers_subscription, "ers_subscription_ers_customer_id_fkey"))
    drop(table(:ers_subscription))

    drop(constraint(:erp_price, "erp_price_erp_plan_id_fkey"))
    drop(table(:erp_price))

    drop(table(:erl_plan))
    drop(table(:erc_customer))
  end
end
