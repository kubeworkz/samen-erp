defmodule Samenerp.Repo.Migrations.MountFleetScope do
  @moduledoc """
  ADR-050 (with ADR-044 §4.1) — mounts the framework fleet-registry blueprint
  (`Samen.Fleet.Scope`, `lib/samenerp/fleet.ex`) into the Samenerp host, and
  catalogs the resources in the SAME migration transaction (ADR-004
  catalog-in-tx). This is the substrate the PUBLIC status page
  (`Samen.Web.Fleet.PublicStatus`) projects: without these rows a mounted
  `/status` would fail closed to a permanent 503 by design.

  Fresh mount, so the whole registry lands at once, mirroring the other hosts'
  fleet mounts. Abbrevs are the ones reserved for this host through the
  sanctioned allocator (`mix samen.abbrev.reserve --host samenerp`):
  `efa`/`efc`/`efe`/`efr`/`efd`.

  No `pii_` column anywhere — every column is a bounded scalar, a KMS-wrapped
  opaque blob (`efc_secret_ciphertext`), or schema-validated jsonb
  (`efr_payload`/`efd_payload`/`efd_target`). INV-2 (C7 `NoPiiColumns`) runs on
  each resource because they are `use Samen.Aggregate.Resource`.

  `efr_report`/`efd_directive` carry NULLABLE `org_id` — the registry is
  cross-tenant/operator-owned data, not a tenant-plane resource (the blueprint's
  explicit override), so the universal non-null `org_id` injection is opted out
  per resource.
  """
  use Samen.Migration

  @resources [
    Samenerp.Fleet.App,
    Samenerp.Fleet.Credential,
    Samenerp.Fleet.EnrollmentToken,
    Samenerp.Fleet.Report,
    Samenerp.Fleet.Directive
  ]

  def up do
    # --- efa_app : one registered product ---
    create table(:efa_app, primary_key: false) do
      add(:efa_slug, :text, null: false)
      add(:efa_display_name, :text, null: false)
      add(:efa_mode, :text, null: false)
      add(:efa_base_url, :text)
      add(:efa_status, :text, null: false, default: "active")
      add(:efa_registered_at, :utc_datetime_usec, null: false)
      add(:efa_stale_after_s, :integer, null: false, default: 300)
      # ADR-050 §4.1 — the per-app OPT-IN to the public status page. The default is
      # the whole safety property: every row that existed before this column (and
      # every row registered after) is UNPUBLISHED until an operator flips it with
      # Samen.Fleet.Registry.set_publish_status/4.
      add(:efa_publish_status, :boolean, null: false, default: false)

      add(:efa_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:efa_org_id, :uuid)
      add(:efa_inserted_at, :utc_datetime, null: false)
      add(:efa_updated_at, :utc_datetime, null: false)
    end

    create(unique_index(:efa_app, [:efa_slug], name: :efa_app_slug_index))

    # --- efc_credential : one key version for one app ---
    create table(:efc_credential, primary_key: false) do
      add(:efc_app_id, :uuid, null: false)
      add(:efc_key_version, :integer, null: false, default: 1)
      add(:efc_kind, :text, null: false)
      add(:efc_public_key, :text)
      add(:efc_secret_ciphertext, :text)
      add(:efc_capability, :text, null: false)
      add(:efc_activated_at, :utc_datetime_usec, null: false)
      add(:efc_retire_at, :utc_datetime_usec)
      add(:efc_revoked_at, :utc_datetime_usec)

      add(:efc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:efc_org_id, :uuid)
      add(:efc_inserted_at, :utc_datetime, null: false)
      add(:efc_updated_at, :utc_datetime, null: false)
    end

    create(index(:efc_credential, [:efc_app_id]))
    create(index(:efc_credential, [:efc_app_id, :efc_key_version]))

    # --- efe_enrollment_token : a single-use mode-B enrollment grant ---
    create table(:efe_enrollment_token, primary_key: false) do
      add(:efe_token_digest, :text, null: false)
      add(:efe_app_slug, :text, null: false)
      add(:efe_display_name, :text, null: false)
      add(:efe_expires_at, :utc_datetime_usec, null: false)
      add(:efe_consumed_at, :utc_datetime_usec)
      add(:efe_consumed_app_id, :uuid)

      add(:efe_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:efe_org_id, :uuid)
      add(:efe_inserted_at, :utc_datetime, null: false)
      add(:efe_updated_at, :utc_datetime, null: false)
    end

    create(unique_index(:efe_enrollment_token, [:efe_token_digest], name: :efe_token_digest_index))

    # --- efr_report : one received FleetReport ---
    create table(:efr_report, primary_key: false) do
      add(:efr_app_id, :uuid, null: false)
      add(:efr_schema_version, :integer, null: false, default: 1)
      add(:efr_generated_at_us, :bigint, null: false)
      add(:efr_received_at, :utc_datetime_usec, null: false)
      add(:efr_transport, :text, null: false)
      add(:efr_payload, :map, null: false, default: %{})

      add(:efr_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:efr_org_id, :uuid)
      add(:efr_inserted_at, :utc_datetime, null: false)
      add(:efr_updated_at, :utc_datetime, null: false)
    end

    create(index(:efr_report, [:efr_app_id, :efr_received_at]))

    # --- efd_directive : one published fleet directive ---
    create table(:efd_directive, primary_key: false) do
      add(:efd_fleet_revision, :integer, null: false)
      add(:efd_target, :map, null: false, default: %{})
      add(:efd_payload, :map, null: false, default: %{})
      add(:efd_published_by, :text, null: false)
      add(:efd_published_at, :utc_datetime_usec, null: false)

      add(:efd_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:efd_org_id, :uuid)
      add(:efd_inserted_at, :utc_datetime, null: false)
      add(:efd_updated_at, :utc_datetime, null: false)
    end

    create(index(:efd_directive, [:efd_fleet_revision]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:efd_directive))
    drop(table(:efr_report))
    drop(table(:efe_enrollment_token))
    drop(table(:efc_credential))
    drop(table(:efa_app))
  end
end
