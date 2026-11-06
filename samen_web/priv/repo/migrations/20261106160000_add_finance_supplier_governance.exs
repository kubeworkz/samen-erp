defmodule Samen.WebTest.Repo.Migrations.AddFinanceSupplierGovernance do
  @moduledoc """
  WS-ACCT Phase 15 (ADR-054 D18) — supplier governance on the `samen_web` test
  host (`Samen.WebTest.Erp`): `fsg_supplier_scorecard`,
  `fsi_supplier_scorecard_dimension` and `fsj_supplier_risk`. Same shape and
  belts as the `samen_core` fixture leg; the web host takes the scope's default
  abbreviations. No supplier contact data is stored here.
  """

  use Samen.Migration

  @resources [
    Samen.WebTest.Erp.SupplierScorecard,
    Samen.WebTest.Erp.SupplierScorecardDimension,
    Samen.WebTest.Erp.SupplierRisk
  ]

  def up do
    create table(:fsg_supplier_scorecard, primary_key: false) do
      add(:fsg_vendor_id, :uuid, null: false)
      add(:fsg_period_year, :integer, null: false)
      add(:fsg_period_quarter, :integer, null: false)
      add(:fsg_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fsg_org_id, :uuid, null: false)
      add(:fsg_inserted_at, :utc_datetime, null: false)
      add(:fsg_updated_at, :utc_datetime, null: false)
    end

    create(index(:fsg_supplier_scorecard, [:fsg_org_id]))
    create(index(:fsg_supplier_scorecard, [:fsg_vendor_id]))

    create(
      unique_index(
        :fsg_supplier_scorecard,
        [:fsg_org_id, :fsg_vendor_id, :fsg_period_year, :fsg_period_quarter],
        name: :fsg_supplier_scorecard_unique
      )
    )

    create(
      constraint(:fsg_supplier_scorecard, :fsg_period_valid,
        check: "fsg_period_year BETWEEN 2000 AND 2100 AND fsg_period_quarter BETWEEN 1 AND 4"
      )
    )

    create table(:fsi_supplier_scorecard_dimension, primary_key: false) do
      add(:fsi_dimension, :text, null: false)
      add(:fsi_weight_pct, :integer, null: false)
      add(:fsi_score, :integer, null: false)
      add(:fsi_note, :text)

      add(
        :fsi_scorecard_id,
        references(:fsg_supplier_scorecard,
          column: :fsg_id,
          name: "fsi_supplier_scorecard_dimension_fsi_scorecard_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:fsi_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fsi_org_id, :uuid, null: false)
      add(:fsi_inserted_at, :utc_datetime, null: false)
      add(:fsi_updated_at, :utc_datetime, null: false)
    end

    create(index(:fsi_supplier_scorecard_dimension, [:fsi_org_id]))
    create(index(:fsi_supplier_scorecard_dimension, [:fsi_scorecard_id]))

    create(
      unique_index(
        :fsi_supplier_scorecard_dimension,
        [:fsi_org_id, :fsi_scorecard_id, :fsi_dimension],
        name: :fsi_supplier_scorecard_dimension_unique
      )
    )

    create(
      constraint(:fsi_supplier_scorecard_dimension, :fsi_dimension_valid,
        check:
          "fsi_dimension IN ('quality_yield','delivery_schedule','cost_commercial'," <>
            "'technical_support','compliance_sustainability')"
      )
    )

    create(
      constraint(:fsi_supplier_scorecard_dimension, :fsi_shape_valid,
        check:
          "fsi_weight_pct BETWEEN 1 AND 100 AND fsi_score BETWEEN 1 AND 5 AND " <>
            "(fsi_note IS NULL OR char_length(fsi_note) <= 300)"
      )
    )

    create table(:fsj_supplier_risk, primary_key: false) do
      add(:fsj_vendor_id, :uuid, null: false)
      add(:fsj_code, :text, null: false)
      add(:fsj_title, :text, null: false)
      add(:fsj_category, :text, null: false)
      add(:fsj_likelihood, :integer, null: false)
      add(:fsj_impact, :integer, null: false)
      add(:fsj_mitigation, :text, null: false)
      add(:fsj_owner_role, :text, null: false)
      add(:fsj_escalation_trigger, :text, null: false)
      add(:fsj_status, :text, null: false, default: "open")
      add(:fsj_reviewed_on, :date)
      add(:fsj_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fsj_org_id, :uuid, null: false)
      add(:fsj_inserted_at, :utc_datetime, null: false)
      add(:fsj_updated_at, :utc_datetime, null: false)
    end

    create(index(:fsj_supplier_risk, [:fsj_org_id]))
    create(index(:fsj_supplier_risk, [:fsj_vendor_id]))

    create(
      unique_index(:fsj_supplier_risk, [:fsj_org_id, :fsj_vendor_id, :fsj_code],
        name: :fsj_supplier_risk_unique
      )
    )

    create(
      constraint(:fsj_supplier_risk, :fsj_enums_valid,
        check:
          "fsj_category IN ('quality','delivery','cost','compliance','financial'," <>
            "'operational','strategic','geopolitical') AND " <>
            "fsj_owner_role IN ('procurement_lead','quality_lead','finance_lead'," <>
            "'operations_lead','engineering_lead','compliance_lead','executive') AND " <>
            "fsj_status IN ('open','mitigating','accepted','closed')"
      )
    )

    create(
      constraint(:fsj_supplier_risk, :fsj_shape_valid,
        check:
          "fsj_likelihood BETWEEN 1 AND 5 AND fsj_impact BETWEEN 1 AND 5 AND " <>
            "char_length(fsj_code) BETWEEN 1 AND 32 AND " <>
            "char_length(fsj_title) BETWEEN 1 AND 240 AND " <>
            "char_length(fsj_mitigation) BETWEEN 1 AND 1000 AND " <>
            "char_length(fsj_escalation_trigger) BETWEEN 1 AND 500"
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:fsi_supplier_scorecard_dimension))
    drop(table(:fsg_supplier_scorecard))
    drop(table(:fsj_supplier_risk))
  end
end
