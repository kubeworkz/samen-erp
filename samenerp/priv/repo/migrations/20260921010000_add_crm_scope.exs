defmodule Samenerp.Repo.Migrations.AddCrmScope do
  @moduledoc """
  Creates CRM scope tables for Samenerp (z-prefix abbreviations).

  Resources:
    * `zcm_company`     — a B2B company record (no PII)
    * `zpr_person`      — CRM person (full_name/emails/phones vault-routed)
    * `zpl_pipeline`    — Tier-0 config rows (deal-stage catalog per org)
    * `zop_opportunity` — a deal linked to company + pipeline stage
    * `zat_attachment`  — file reference linked to any CRM object
  """
  use Samen.Migration

  @resources [
    Samenerp.Crm.Company,
    Samenerp.Crm.Person,
    Samenerp.Crm.Pipeline,
    Samenerp.Crm.Opportunity,
    Samenerp.Crm.Attachment
  ]

  def up do
    create table(:zcm_company, primary_key: false) do
      add(:zcm_name, :text, null: false)
      add(:zcm_domain, :text)
      add(:zcm_industry, :text)
      add(:zcm_size, :text)
      add(:zcm_website, :text)
      add(:zcm_notes, :text)
      add(:zcm_custom, :map, default: fragment("'{}'::jsonb"))
      add(:zcm_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:zcm_org_id, :uuid, null: false)
      add(:zcm_inserted_at, :utc_datetime, null: false)
      add(:zcm_updated_at, :utc_datetime, null: false)
    end

    create table(:zpr_person, primary_key: false) do
      add(:zpr_display_name, :text)
      add(:zpr_full_name, :text)
      add(:zpr_emails, :text)
      add(:zpr_phones, :text)
      add(:zpr_job_title, :text)
      add(:zpr_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :zpr_company_id,
        references(:zcm_company,
          column: :zcm_id,
          name: "zpr_person_zpr_company_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:zpr_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:zpr_org_id, :uuid, null: false)
      add(:zpr_inserted_at, :utc_datetime, null: false)
      add(:zpr_updated_at, :utc_datetime, null: false)
    end

    create table(:zpl_pipeline, primary_key: false) do
      add(:zpl_name, :text, null: false)
      add(:zpl_label, :text)
      add(:zpl_stage_order, :integer, default: 0)
      add(:zpl_enabled, :boolean, default: true)
      add(:zpl_stage_type, :text, default: "open")
      add(:zpl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:zpl_org_id, :uuid, null: false)
      add(:zpl_inserted_at, :utc_datetime, null: false)
      add(:zpl_updated_at, :utc_datetime, null: false)
    end

    create table(:zop_opportunity, primary_key: false) do
      add(:zop_name, :text, null: false)
      # ADR-036 H1/D7: ONE Money composite column (money_with_currency, installed
      # by 20260709100000_app_resources) — the paired _cents/currency convention
      # was already replaced at the blueprint level when this migration was
      # authored; catalog_parity fails the stale pair as uncatalogued columns.
      add(:zop_value, :money_with_currency)
      add(:zop_probability, :integer, default: 0)
      add(:zop_status, :text, default: "open")
      add(:zop_close_date, :date)
      add(:zop_notes, :text)
      add(:zop_custom, :map, default: fragment("'{}'::jsonb"))

      add(
        :zop_company_id,
        references(:zcm_company,
          column: :zcm_id,
          name: "zop_opportunity_zop_company_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :zop_pipeline_id,
        references(:zpl_pipeline,
          column: :zpl_id,
          name: "zop_opportunity_zop_pipeline_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:zop_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:zop_org_id, :uuid, null: false)
      add(:zop_inserted_at, :utc_datetime, null: false)
      add(:zop_updated_at, :utc_datetime, null: false)
    end

    create table(:zat_attachment, primary_key: false) do
      add(:zat_file_name, :text, null: false)
      add(:zat_content_type, :text)
      add(:zat_size_bytes, :integer)
      add(:zat_storage_key, :text)

      add(
        :zat_company_id,
        references(:zcm_company,
          column: :zcm_id,
          name: "zat_attachment_zat_company_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :zat_person_id,
        references(:zpr_person,
          column: :zpr_id,
          name: "zat_attachment_zat_person_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :zat_opportunity_id,
        references(:zop_opportunity,
          column: :zop_id,
          name: "zat_attachment_zat_opportunity_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(:zat_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:zat_org_id, :uuid, null: false)
      add(:zat_inserted_at, :utc_datetime, null: false)
      add(:zat_updated_at, :utc_datetime, null: false)
    end

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(constraint(:zat_attachment, "zat_attachment_zat_opportunity_id_fkey"))
    drop(constraint(:zat_attachment, "zat_attachment_zat_person_id_fkey"))
    drop(constraint(:zat_attachment, "zat_attachment_zat_company_id_fkey"))
    drop(table(:zat_attachment))

    drop(constraint(:zop_opportunity, "zop_opportunity_zop_pipeline_id_fkey"))
    drop(constraint(:zop_opportunity, "zop_opportunity_zop_company_id_fkey"))
    drop(table(:zop_opportunity))

    drop(table(:zpl_pipeline))

    drop(constraint(:zpr_person, "zpr_person_zpr_company_id_fkey"))
    drop(table(:zpr_person))

    drop(table(:zcm_company))
  end
end
