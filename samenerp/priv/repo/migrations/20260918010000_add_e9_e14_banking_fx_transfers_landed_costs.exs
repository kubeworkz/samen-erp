defmodule Samenerp.Repo.Migrations.AddE9E14BankingFxTransfersLandedCosts do
  @moduledoc """
  Adds tables for WS-ERP E9–E14: Banking, Multi-Currency, Warehouse
  Transfers, and Landed Costs.
  """
  use Samen.Migration

  def up do
    # ════ E10: Multi-Currency (ExchangeRate, OrgFxSettings) ════

    create table(:fxr_exchange_rate, primary_key: false) do
      add(:fxr_from_currency, :text, null: false)
      add(:fxr_to_currency, :text, null: false)
      add(:fxr_rate, :text, null: false)
      add(:fxr_source, :text, null: false, default: "manual")
      add(:fxr_valid_at, :utc_datetime, null: false)
      add(:fxr_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fxr_org_id, :uuid, null: false)
      add(:fxr_inserted_at, :utc_datetime, null: false)
      add(:fxr_updated_at, :utc_datetime, null: false)
    end

    create(index(:fxr_exchange_rate, [:fxr_org_id]))
    create(index(:fxr_exchange_rate, [:fxr_org_id, :fxr_from_currency, :fxr_to_currency, :fxr_valid_at]))

    create table(:fxf_org_fx_settings, primary_key: false) do
      add(:fxf_org_id, :uuid, null: false)
      add(:fxf_base_currency, :text, null: false, default: "USD")
      add(:fxf_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fxf_inserted_at, :utc_datetime, null: false)
      add(:fxf_updated_at, :utc_datetime, null: false)
      add(:fxf_archived_at, :utc_datetime_usec)
    end

    create(unique_index(:fxf_org_fx_settings, [:fxf_org_id]))

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

    create table(:trn_transfer_order, primary_key: false) do
      add(:trn_item_id, :uuid, null: false)
      add(:trn_source_warehouse_id, :uuid, null: false)
      add(:trn_dest_warehouse_id, :uuid, null: false)
      add(:trn_qty, :integer, null: false)
      add(:trn_status, :text, null: false, default: "draft")
      add(:trn_note, :text)
      add(:trn_posted_at, :utc_datetime)
      add(:trn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:trn_org_id, :uuid, null: false)
      add(:trn_inserted_at, :utc_datetime, null: false)
      add(:trn_updated_at, :utc_datetime, null: false)
      add(:trn_archived_at, :utc_datetime_usec)
    end

    create(index(:trn_transfer_order, [:trn_org_id]))

    # ════ E14: Landed Costs ════

    create table(:lcd_landed_cost, primary_key: false) do
      add(:lcd_bill_id, :uuid, null: false)
      add(:lcd_amount_cents, :bigint, null: false)
      add(:lcd_allocation_method, :text, null: false, default: "value")
      add(:lcd_status, :text, null: false, default: "draft")
      add(:lcd_cost_account_id, :uuid, null: false)
      add(:lcd_description, :text)
      add(:lcd_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:lcd_org_id, :uuid, null: false)
      add(:lcd_inserted_at, :utc_datetime, null: false)
      add(:lcd_updated_at, :utc_datetime, null: false)
      add(:lcd_archived_at, :utc_datetime_usec)
    end

    create(index(:lcd_landed_cost, [:lcd_org_id]))
  end

  def down do
    # Reverse order

    drop(table(:lcd_landed_cost))
    drop(table(:trn_transfer_order))
    drop(table(:bkr_rule))
    drop(table(:bkm_match))
    drop(table(:bki_statement_import))
    drop(table(:bkl_statement_line))
    drop(table(:bka_bank_account))
    drop(table(:fxf_org_fx_settings))
    drop(table(:fxr_exchange_rate))
  end
end
