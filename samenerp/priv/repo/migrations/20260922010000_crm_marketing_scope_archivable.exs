defmodule Samenerp.Repo.Migrations.CrmMarketingScopeArchivable do
  @moduledoc """
  ADR-040 §5.9 — the archived_at ADOPTION columns for the CRM + Marketing scope
  tables this host mounted WITHOUT them (`20260921010000_add_crm_scope` /
  `20260921010001_add_marketing_scope` created the tables before the archivable
  roster was considered). Every `archivable: true` resource injects
  `<abbrev>_archived_at :utc_datetime_usec` into its default read as an
  exclusion filter, so a table missing the column 500s on EVERY list read
  (`Postgrex.Error 42703 column z0.zpl_archived_at does not exist` — the live
  CRM Dashboard failure).

  Mirrors demo's `crm_scope_archivable` + `marketing_scope_archivable` pair:

    * CRM       — company, person, pipeline, opportunity, attachment (all five)
    * Marketing — campaign, segment, subscriber, template (the four adopting;
                  send/email_event/suppression/consent_event are excluded
                  ledgers per the marketing blueprint)

  Additive columns on already-catalogued resources → `catalog_sync/2`'s
  `only:` scoping, so `down` removes exactly these nine `fld_field` rows.
  """
  use Samen.Migration

  def change do
    # --- CRM scope (all five resources are archivable) ---
    alter table(:zcm_company) do
      add(:zcm_archived_at, :utc_datetime_usec)
    end

    alter table(:zpr_person) do
      add(:zpr_archived_at, :utc_datetime_usec)
    end

    alter table(:zpl_pipeline) do
      add(:zpl_archived_at, :utc_datetime_usec)
    end

    alter table(:zop_opportunity) do
      add(:zop_archived_at, :utc_datetime_usec)
    end

    alter table(:zat_attachment) do
      add(:zat_archived_at, :utc_datetime_usec)
    end

    # --- Marketing scope (the four adopting resources) ---
    alter table(:zmc_campaign) do
      add(:zmc_archived_at, :utc_datetime_usec)
    end

    alter table(:zmg_segment) do
      add(:zmg_archived_at, :utc_datetime_usec)
    end

    alter table(:zms_subscriber) do
      add(:zms_archived_at, :utc_datetime_usec)
    end

    alter table(:zmt_template) do
      add(:zmt_archived_at, :utc_datetime_usec)
    end

    catalog_sync([Samenerp.Crm.Company], only: [:archived_at])
    catalog_sync([Samenerp.Crm.Person], only: [:archived_at])
    catalog_sync([Samenerp.Crm.Pipeline], only: [:archived_at])
    catalog_sync([Samenerp.Crm.Opportunity], only: [:archived_at])
    catalog_sync([Samenerp.Crm.Attachment], only: [:archived_at])

    catalog_sync([Samenerp.Marketing.Campaign], only: [:archived_at])
    catalog_sync([Samenerp.Marketing.Segment], only: [:archived_at])
    catalog_sync([Samenerp.Marketing.Subscriber], only: [:archived_at])
    catalog_sync([Samenerp.Marketing.Template], only: [:archived_at])
  end
end
