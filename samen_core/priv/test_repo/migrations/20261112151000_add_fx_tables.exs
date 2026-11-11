defmodule SamenCore.TestRepo.Migrations.AddFxTables do
  @moduledoc """
  The fixture DB's E10 FX tables. AP approval now resolves the org's functional
  currency and, for foreign bills, a dated exchange rate; the fixture already
  mounted the resources but had no tables for them.
  """

  use Samen.Migration

  def up do
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

    create(
      index(:fxr_exchange_rate, [
        :fxr_org_id,
        :fxr_from_currency,
        :fxr_to_currency,
        :fxr_valid_at
      ])
    )

    create table(:fxf_org_fx_settings, primary_key: false) do
      add(:fxf_org_id, :uuid, null: false)
      add(:fxf_base_currency, :text, null: false, default: "USD")
      add(:fxf_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fxf_inserted_at, :utc_datetime, null: false)
      add(:fxf_updated_at, :utc_datetime, null: false)
      add(:fxf_archived_at, :utc_datetime_usec)
    end

    create(unique_index(:fxf_org_fx_settings, [:fxf_org_id]))
  end

  def down do
    drop(table(:fxf_org_fx_settings))
    drop(table(:fxr_exchange_rate))
  end
end
