defmodule Samen.WebTest.Repo.Migrations.AddFinanceForecasts do
  @moduledoc """
  WS-ACCT Phase 14 (ADR-054 D11) — the rolling forecast on the `samen_web` test
  host (`Samen.WebTest.Erp`): `fcv_forecast_version` and
  `fcd_forecast_driver`, the same shape and belts as the `samen_core` fixture
  leg. The web host takes the scope's default abbrevs; no surface reads these
  tables yet, but the Phase-13 board pack's runway follow-up and the Phase-14
  reads have a real host schema to exercise.
  """

  use Samen.Migration

  @resources [
    Samen.WebTest.Erp.ForecastVersion,
    Samen.WebTest.Erp.ForecastDriver
  ]

  def up do
    create table(:fcv_forecast_version, primary_key: false) do
      add(:fcv_name, :text, null: false)
      add(:fcv_version, :integer, null: false)
      add(:fcv_starts_on, :date, null: false)
      add(:fcv_ends_on, :date, null: false)
      add(:fcv_status, :text, null: false, default: "draft")
      add(:fcv_scenario_weights, :map, null: false)
      add(:fcv_source_version_id, :uuid)
      add(:fcv_published_at, :utc_datetime)
      add(:fcv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fcv_org_id, :uuid, null: false)
      add(:fcv_inserted_at, :utc_datetime, null: false)
      add(:fcv_updated_at, :utc_datetime, null: false)
    end

    create(index(:fcv_forecast_version, [:fcv_org_id]))
    create(index(:fcv_forecast_version, [:fcv_source_version_id]))

    create(
      unique_index(:fcv_forecast_version, [:fcv_org_id, :fcv_name, :fcv_version],
        name: :fcv_forecast_version_unique
      )
    )

    create(
      constraint(:fcv_forecast_version, :fcv_status_valid,
        check: "fcv_status IN ('draft','published','archived')"
      )
    )

    create(
      constraint(:fcv_forecast_version, :fcv_shape_valid,
        check:
          "fcv_version > 0 AND fcv_ends_on >= fcv_starts_on AND " <>
            "jsonb_typeof(fcv_scenario_weights) = 'object'"
      )
    )

    create table(:fcd_forecast_driver, primary_key: false) do
      add(:fcd_driver, :text, null: false)
      add(:fcd_scenario, :text, null: false)
      add(:fcd_category, :text, null: false, default: "revenue")
      add(:fcd_period_on, :date, null: false)
      add(:fcd_amount_cents, :bigint, null: false)
      add(:fcd_memo, :text)

      add(
        :fcd_version_id,
        references(:fcv_forecast_version,
          column: :fcv_id,
          name: "fcd_forecast_driver_fcd_version_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:fcd_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fcd_org_id, :uuid, null: false)
      add(:fcd_inserted_at, :utc_datetime, null: false)
      add(:fcd_updated_at, :utc_datetime, null: false)
    end

    create(index(:fcd_forecast_driver, [:fcd_org_id]))
    create(index(:fcd_forecast_driver, [:fcd_version_id]))

    create(
      unique_index(
        :fcd_forecast_driver,
        [:fcd_org_id, :fcd_version_id, :fcd_scenario, :fcd_driver, :fcd_period_on],
        name: :fcd_forecast_driver_unique
      )
    )

    create(
      constraint(:fcd_forecast_driver, :fcd_enums_valid,
        check:
          "fcd_driver IN ('slot_price','die_yield','eda_spend','headcount','burn','grant_pipeline') AND " <>
            "fcd_scenario IN ('base','upside','downside') AND " <>
            "fcd_category IN ('revenue','cogs','operating_expense','cash_in','cash_out')"
      )
    )

    create(
      constraint(:fcd_forecast_driver, :fcd_shape_valid,
        check:
          "fcd_amount_cents >= 0 AND " <>
            "fcd_period_on = date_trunc('month', fcd_period_on)::date AND " <>
            "((fcd_driver = 'slot_price' AND fcd_category = 'revenue') OR " <>
            "(fcd_driver = 'die_yield' AND fcd_category = 'cogs') OR " <>
            "(fcd_driver IN ('eda_spend','headcount') AND fcd_category = 'operating_expense') OR " <>
            "(fcd_driver = 'burn' AND fcd_category = 'cash_out') OR " <>
            "(fcd_driver = 'grant_pipeline' AND fcd_category = 'cash_in'))"
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:fcd_forecast_driver))
    drop(table(:fcv_forecast_version))
  end
end
