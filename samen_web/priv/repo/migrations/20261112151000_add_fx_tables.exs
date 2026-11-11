defmodule Samen.WebTest.Repo.Migrations.AddFxTables do
  @moduledoc """
  The web test host's E10 FX tables. AP approval now resolves the org's
  functional currency and, for foreign bills, a dated exchange rate; the host
  already mounted the resources but had no tables for them.
  """

  use Samen.Migration

  def up do
    create table(:fex_exchange_rate, primary_key: false) do
      add(:fex_from_currency, :text, null: false)
      add(:fex_to_currency, :text, null: false)
      add(:fex_rate, :text, null: false)
      add(:fex_source, :text, null: false, default: "manual")
      add(:fex_valid_at, :utc_datetime, null: false)
      add(:fex_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fex_org_id, :uuid, null: false)
      add(:fex_inserted_at, :utc_datetime, null: false)
      add(:fex_updated_at, :utc_datetime, null: false)
    end

    create(index(:fex_exchange_rate, [:fex_org_id]))

    create(
      index(:fex_exchange_rate, [
        :fex_org_id,
        :fex_from_currency,
        :fex_to_currency,
        :fex_valid_at
      ])
    )

    create table(:ofx_org_fx_settings, primary_key: false) do
      add(:ofx_org_id, :uuid, null: false)
      add(:ofx_base_currency, :text, null: false, default: "USD")
      add(:ofx_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ofx_inserted_at, :utc_datetime, null: false)
      add(:ofx_updated_at, :utc_datetime, null: false)
      add(:ofx_archived_at, :utc_datetime_usec)
    end

    create(unique_index(:ofx_org_fx_settings, [:ofx_org_id]))
  end

  def down do
    drop(table(:ofx_org_fx_settings))
    drop(table(:fex_exchange_rate))
  end
end
