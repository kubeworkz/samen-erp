defmodule Samenerp.Repo.Migrations.AddFinanceForecasts do
  @moduledoc """
  WS-ACCT Phase 14 (ADR-054 D11) — the rolling forecast on the Kubeworkz books
  (`Samenerp.Erp`): `efv_forecast_version` and `efw_forecast_driver`. Same
  shape and belts as the `samen_core` fixture leg, using the host's allocator-
  reserved forecast abbrevs.
  """

  use Samen.Migration

  @resources [
    Samenerp.Erp.ForecastVersion,
    Samenerp.Erp.ForecastDriver
  ]

  def up do
    create table(:efv_forecast_version, primary_key: false) do
      add(:efv_name, :text, null: false)
      add(:efv_version, :integer, null: false)
      add(:efv_starts_on, :date, null: false)
      add(:efv_ends_on, :date, null: false)
      add(:efv_status, :text, null: false, default: "draft")
      add(:efv_scenario_weights, :map, null: false)
      add(:efv_source_version_id, :uuid)
      add(:efv_published_at, :utc_datetime)
      add(:efv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:efv_org_id, :uuid, null: false)
      add(:efv_inserted_at, :utc_datetime, null: false)
      add(:efv_updated_at, :utc_datetime, null: false)
    end

    create(index(:efv_forecast_version, [:efv_org_id]))
    create(index(:efv_forecast_version, [:efv_source_version_id]))

    create(
      unique_index(:efv_forecast_version, [:efv_org_id, :efv_name, :efv_version],
        name: :efv_forecast_version_unique
      )
    )

    create(
      constraint(:efv_forecast_version, :efv_status_valid,
        check: "efv_status IN ('draft','published','archived')"
      )
    )

    create(
      constraint(:efv_forecast_version, :efv_shape_valid,
        check:
          "efv_version > 0 AND efv_ends_on >= efv_starts_on AND " <>
            "jsonb_typeof(efv_scenario_weights) = 'object'"
      )
    )

    create table(:efw_forecast_driver, primary_key: false) do
      add(:efw_driver, :text, null: false)
      add(:efw_scenario, :text, null: false)
      add(:efw_category, :text, null: false, default: "revenue")
      add(:efw_period_on, :date, null: false)
      add(:efw_amount_cents, :bigint, null: false)
      add(:efw_memo, :text)

      add(
        :efw_version_id,
        references(:efv_forecast_version,
          column: :efv_id,
          name: "efw_forecast_driver_efw_version_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:efw_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:efw_org_id, :uuid, null: false)
      add(:efw_inserted_at, :utc_datetime, null: false)
      add(:efw_updated_at, :utc_datetime, null: false)
    end

    create(index(:efw_forecast_driver, [:efw_org_id]))
    create(index(:efw_forecast_driver, [:efw_version_id]))

    create(
      unique_index(
        :efw_forecast_driver,
        [:efw_org_id, :efw_version_id, :efw_scenario, :efw_driver, :efw_period_on],
        name: :efw_forecast_driver_unique
      )
    )

    create(
      constraint(:efw_forecast_driver, :efw_enums_valid,
        check:
          "efw_driver IN ('slot_price','die_yield','eda_spend','headcount','burn','grant_pipeline') AND " <>
            "efw_scenario IN ('base','upside','downside') AND " <>
            "efw_category IN ('revenue','cogs','operating_expense','cash_in','cash_out')"
      )
    )

    create(
      constraint(:efw_forecast_driver, :efw_shape_valid,
        check:
          "efw_amount_cents >= 0 AND " <>
            "efw_period_on = date_trunc('month', efw_period_on)::date AND " <>
            "((efw_driver = 'slot_price' AND efw_category = 'revenue') OR " <>
            "(efw_driver = 'die_yield' AND efw_category = 'cogs') OR " <>
            "(efw_driver IN ('eda_spend','headcount') AND efw_category = 'operating_expense') OR " <>
            "(efw_driver = 'burn' AND efw_category = 'cash_out') OR " <>
            "(efw_driver = 'grant_pipeline' AND efw_category = 'cash_in'))"
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:efw_forecast_driver))
    drop(table(:efv_forecast_version))
  end
end
