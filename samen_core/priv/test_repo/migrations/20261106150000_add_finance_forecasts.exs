defmodule SamenCore.TestRepo.Migrations.AddFinanceForecasts do
  @moduledoc """
  WS-ACCT Phase 14 (ADR-054 D11) — the rolling forecast in the `samen_core`
  fixture: `ffv_forecast_version` (the append-only, weighted lineage) and
  `ffd_forecast_driver` (one bounded monthly driver fact per version).

  The database belts mirror the Ash guards: the status and driver enums, the
  positive version, the ordered date range, the month-start period, the
  non-negative driver amount, the derived driver-to-category mapping, and the
  per-version driver identity. Catalog rows via `catalog_sync/1` in the same
  transaction (ADR-004).
  """

  use Samen.Migration

  @resources [
    SamenCore.Support.FinanceFixture.ForecastVersion,
    SamenCore.Support.FinanceFixture.ForecastDriver
  ]

  def up do
    create table(:ffv_forecast_version, primary_key: false) do
      add(:ffv_name, :text, null: false)
      add(:ffv_version, :integer, null: false)
      add(:ffv_starts_on, :date, null: false)
      add(:ffv_ends_on, :date, null: false)
      add(:ffv_status, :text, null: false, default: "draft")
      add(:ffv_scenario_weights, :map, null: false)
      add(:ffv_source_version_id, :uuid)
      add(:ffv_published_at, :utc_datetime)
      add(:ffv_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ffv_org_id, :uuid, null: false)
      add(:ffv_inserted_at, :utc_datetime, null: false)
      add(:ffv_updated_at, :utc_datetime, null: false)
    end

    create(index(:ffv_forecast_version, [:ffv_org_id]))
    create(index(:ffv_forecast_version, [:ffv_source_version_id]))

    create(
      unique_index(:ffv_forecast_version, [:ffv_org_id, :ffv_name, :ffv_version],
        name: :ffv_forecast_version_unique
      )
    )

    create(
      constraint(:ffv_forecast_version, :ffv_status_valid,
        check: "ffv_status IN ('draft','published','archived')"
      )
    )

    create(
      constraint(:ffv_forecast_version, :ffv_shape_valid,
        check:
          "ffv_version > 0 AND ffv_ends_on >= ffv_starts_on AND " <>
            "jsonb_typeof(ffv_scenario_weights) = 'object'"
      )
    )

    create table(:ffd_forecast_driver, primary_key: false) do
      add(:ffd_driver, :text, null: false)
      add(:ffd_scenario, :text, null: false)
      add(:ffd_category, :text, null: false, default: "revenue")
      add(:ffd_period_on, :date, null: false)
      add(:ffd_amount_cents, :bigint, null: false)
      add(:ffd_memo, :text)

      add(
        :ffd_version_id,
        references(:ffv_forecast_version,
          column: :ffv_id,
          name: "ffd_forecast_driver_ffd_version_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:ffd_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ffd_org_id, :uuid, null: false)
      add(:ffd_inserted_at, :utc_datetime, null: false)
      add(:ffd_updated_at, :utc_datetime, null: false)
    end

    create(index(:ffd_forecast_driver, [:ffd_org_id]))
    create(index(:ffd_forecast_driver, [:ffd_version_id]))

    create(
      unique_index(
        :ffd_forecast_driver,
        [:ffd_org_id, :ffd_version_id, :ffd_scenario, :ffd_driver, :ffd_period_on],
        name: :ffd_forecast_driver_unique
      )
    )

    create(
      constraint(:ffd_forecast_driver, :ffd_enums_valid,
        check:
          "ffd_driver IN ('slot_price','die_yield','eda_spend','headcount','burn','grant_pipeline') AND " <>
            "ffd_scenario IN ('base','upside','downside') AND " <>
            "ffd_category IN ('revenue','cogs','operating_expense','cash_in','cash_out')"
      )
    )

    create(
      constraint(:ffd_forecast_driver, :ffd_shape_valid,
        check:
          "ffd_amount_cents >= 0 AND " <>
            "ffd_period_on = date_trunc('month', ffd_period_on)::date AND " <>
            "((ffd_driver = 'slot_price' AND ffd_category = 'revenue') OR " <>
            "(ffd_driver = 'die_yield' AND ffd_category = 'cogs') OR " <>
            "(ffd_driver IN ('eda_spend','headcount') AND ffd_category = 'operating_expense') OR " <>
            "(ffd_driver = 'burn' AND ffd_category = 'cash_out') OR " <>
            "(ffd_driver = 'grant_pipeline' AND ffd_category = 'cash_in'))"
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:ffd_forecast_driver))
    drop(table(:ffv_forecast_version))
  end
end
