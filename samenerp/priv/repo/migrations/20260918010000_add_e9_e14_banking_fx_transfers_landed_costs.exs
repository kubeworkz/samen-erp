defmodule Samenerp.Repo.Migrations.AddE9E14BankingFxTransfersLandedCosts do
  @moduledoc """
  Adds tables for WS-ERP E9–E14: Banking, Multi-Currency, Warehouse
  Transfers, and Landed Costs.

  Table/column names use the samenerp mount's own abbrevs:
  - E10 FX: efx_exchange_rate, efs_org_fx_settings
  - E9 Banking: bka_bank_account, bkl_statement_line, bki_statement_import,
    bkm_match, bkr_rule
  - E13 Transfers: etn_transfer_order
  - E14 Landed Costs: eld_landed_cost
  """
  use Samen.Migration

  def up do
    # ════ E10: Multi-Currency (ExchangeRate, OrgFxSettings) ════

    create table(:efx_exchange_rate, primary_key: false) do
      add(:efx_from_currency, :text, null: false)
      add(:efx_to_currency, :text, null: false)
      add(:efx_rate, :text, null: false)
      add(:efx_source, :text, null: false, default: "manual")
      add(:efx_valid_at, :utc_datetime, null: false)
      add(:efx_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:efx_org_id, :uuid, null: false)
      add(:efx_inserted_at, :utc_datetime, null: false)
      add(:efx_updated_at, :utc_datetime, null: false)
    end

    create(index(:efx_exchange_rate, [:efx_org_id]))
    create(index(:efx_exchange_rate, [:efx_org_id, :efx_from_currency, :efx_to_currency, :efx_valid_at]))

    create table(:efs_org_fx_settings, primary_key: false) do
      add(:efs_org_id, :uuid, null: false)
      add(:efs_base_currency, :text, null: false, default: "USD")
      add(:efs_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:efs_inserted_at, :utc_datetime, null: false)
      add(:efs_updated_at, :utc_datetime, null: false)
      add(:efs_archived_at, :utc_datetime_usec)
    end

    create(unique_index(:efs_org_fx_settings, [:efs_org_id]))

    # ════ E9: Banking (BankAccount, StatementLine, StatementImport, Match, Rule) ════

    create table(:bka_bank_account, primary_key: false) do
      add(:bka_name, :text, null: false)
      add(:bka_account_id, :uuid, null: false)
      add(:bka_statement_balance_cents, :bigint, null: false, default: 0)
      add(:bka_currency, :text, null: false, default: "USD")
      add(:bka_is_active, :boolean, null: false, default: true)
      add(:bka_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:bka_org_id, :uuid, null: false)
      add(:bka_inserted_at, :utc_datetime, null: false)
      add(:bka_updated_at, :utc_datetime, null: false)
      add(:bka_archived_at, :utc_datetime_usec)
    end

    create(index(:bka_bank_account, [:bka_org_id]))

    create table(:bkl_statement_line, primary_key: false) do
      add(:bkl_bank_account_id, :uuid, null: false)
      add(:bkl_posted_at, :utc_datetime, null: false)
      add(:bkl_amount_cents, :bigint, null: false)
      add(:bkl_description, :text, null: false)
      add(:bkl_counterparty, :text)
      add(:bkl_reference, :text)
      add(:bkl_import_hash, :text, null: false)
      add(:bkl_status, :text, null: false, default: "unmatched")
      add(:bkl_reconciled_at, :utc_datetime)
      add(:bkl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:bkl_org_id, :uuid, null: false)
      add(:bkl_inserted_at, :utc_datetime, null: false)
      add(:bkl_updated_at, :utc_datetime, null: false)
    end

    create(index(:bkl_statement_line, [:bkl_org_id]))
    create(index(:bkl_statement_line, [:bkl_bank_account_id, :bkl_import_hash], unique: true))

    create table(:bki_statement_import, primary_key: false) do
      add(:bki_bank_account_id, :uuid, null: false)
      add(:bki_file_hash, :text, null: false)
      add(:bki_filename, :text)
      add(:bki_line_count, :integer, null: false, default: 0)
      add(:bki_duplicate_count, :integer, null: false, default: 0)
      add(:bki_imported_at, :utc_datetime, null: false)
      add(:bki_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:bki_org_id, :uuid, null: false)
      add(:bki_inserted_at, :utc_datetime, null: false)
      add(:bki_updated_at, :utc_datetime, null: false)
    end

    create(index(:bki_statement_import, [:bki_org_id]))

    create table(:bkm_match, primary_key: false) do
      add(:bkm_statement_line_id, :uuid, null: false)
      add(:bkm_entry_id, :uuid, null: false)
      add(:bkm_matched_at, :utc_datetime, null: false)
      add(:bkm_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:bkm_org_id, :uuid, null: false)
      add(:bkm_inserted_at, :utc_datetime, null: false)
      add(:bkm_updated_at, :utc_datetime, null: false)
    end

    create(unique_index(:bkm_match, [:bkm_statement_line_id]))
    create(index(:bkm_match, [:bkm_org_id]))

    create table(:bkr_rule, primary_key: false) do
      add(:bkr_bank_account_id, :uuid)
      add(:bkr_pattern, :text, null: false)
      add(:bkr_account_id, :uuid, null: false)
      add(:bkr_min_amount_cents, :bigint)
      add(:bkr_max_amount_cents, :bigint)
      add(:bkr_priority, :integer, null: false, default: 0)
      add(:bkr_is_active, :boolean, null: false, default: true)
      add(:bkr_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:bkr_org_id, :uuid, null: false)
      add(:bkr_inserted_at, :utc_datetime, null: false)
      add(:bkr_updated_at, :utc_datetime, null: false)
      add(:bkr_archived_at, :utc_datetime_usec)
    end

    create(index(:bkr_rule, [:bkr_org_id]))

    # ════ E13: Warehouse Transfers ════

    create table(:etn_transfer_order, primary_key: false) do
      add(:etn_item_id, :uuid, null: false)
      add(:etn_source_warehouse_id, :uuid, null: false)
      add(:etn_dest_warehouse_id, :uuid, null: false)
      add(:etn_qty, :integer, null: false)
      add(:etn_status, :text, null: false, default: "draft")
      add(:etn_note, :text)
      add(:etn_posted_at, :utc_datetime)
      add(:etn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:etn_org_id, :uuid, null: false)
      add(:etn_inserted_at, :utc_datetime, null: false)
      add(:etn_updated_at, :utc_datetime, null: false)
      add(:etn_archived_at, :utc_datetime_usec)
    end

    create(index(:etn_transfer_order, [:etn_org_id]))

    # ════ E14: Landed Costs ════

    create table(:eld_landed_cost, primary_key: false) do
      add(:eld_bill_id, :uuid, null: false)
      add(:eld_amount_cents, :bigint, null: false)
      add(:eld_allocation_method, :text, null: false, default: "value")
      add(:eld_status, :text, null: false, default: "draft")
      add(:eld_cost_account_id, :uuid, null: false)
      add(:eld_description, :text)
      add(:eld_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:eld_org_id, :uuid, null: false)
      add(:eld_inserted_at, :utc_datetime, null: false)
      add(:eld_updated_at, :utc_datetime, null: false)
      add(:eld_archived_at, :utc_datetime_usec)
    end

    create(index(:eld_landed_cost, [:eld_org_id]))

    # C1 catalog-in-tx (ADR-004): these four E10/E13/E14 resources were created
    # without catalog_sync — catalog_parity (rightly) failed them as ghost tables.
    catalog_sync([
      Samenerp.Erp.ExchangeRate,
      Samenerp.Erp.OrgFxSettings,
      Samenerp.Erp.TransferOrder,
      Samenerp.Erp.LandedCost
    ])
  end

  def down do
    catalog_sync_down([
      Samenerp.Erp.ExchangeRate,
      Samenerp.Erp.OrgFxSettings,
      Samenerp.Erp.TransferOrder,
      Samenerp.Erp.LandedCost
    ])

    drop(table(:eld_landed_cost))
    drop(table(:etn_transfer_order))
    drop(table(:bkr_rule))
    drop(table(:bkm_match))
    drop(table(:bki_statement_import))
    drop(table(:bkl_statement_line))
    drop(table(:bka_bank_account))
    drop(table(:efs_org_fx_settings))
    drop(table(:efx_exchange_rate))
  end
end
