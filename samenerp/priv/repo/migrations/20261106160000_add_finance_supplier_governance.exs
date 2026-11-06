defmodule Samenerp.Repo.Migrations.AddFinanceSupplierGovernance do
  @moduledoc """
  WS-ACCT Phase 15 (ADR-054 D18) — supplier governance on the Kubeworkz books
  (`Samenerp.Erp`): `esi_supplier_scorecard`,
  `esj_supplier_scorecard_dimension` and `esk_supplier_risk`. Same shape and
  belts as the `samen_core` fixture leg, using the host's allocator-reserved
  abbreviations. The supplier remains a `vendor_id` reference; no contact data
  is copied here.
  """

  use Samen.Migration

  @resources [
    Samenerp.Erp.SupplierScorecard,
    Samenerp.Erp.SupplierScorecardDimension,
    Samenerp.Erp.SupplierRisk
  ]

  def up do
    create table(:esi_supplier_scorecard, primary_key: false) do
      add(:esi_vendor_id, :uuid, null: false)
      add(:esi_period_year, :integer, null: false)
      add(:esi_period_quarter, :integer, null: false)
      add(:esi_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:esi_org_id, :uuid, null: false)
      add(:esi_inserted_at, :utc_datetime, null: false)
      add(:esi_updated_at, :utc_datetime, null: false)
    end

    create(index(:esi_supplier_scorecard, [:esi_org_id]))
    create(index(:esi_supplier_scorecard, [:esi_vendor_id]))

    create(
      unique_index(
        :esi_supplier_scorecard,
        [:esi_org_id, :esi_vendor_id, :esi_period_year, :esi_period_quarter],
        name: :esi_supplier_scorecard_unique
      )
    )

    create(
      constraint(:esi_supplier_scorecard, :esi_period_valid,
        check: "esi_period_year BETWEEN 2000 AND 2100 AND esi_period_quarter BETWEEN 1 AND 4"
      )
    )

    create table(:esj_supplier_scorecard_dimension, primary_key: false) do
      add(:esj_dimension, :text, null: false)
      add(:esj_weight_pct, :integer, null: false)
      add(:esj_score, :integer, null: false)
      add(:esj_note, :text)

      add(
        :esj_scorecard_id,
        references(:esi_supplier_scorecard,
          column: :esi_id,
          name: "esj_supplier_scorecard_dimension_esj_scorecard_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:esj_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:esj_org_id, :uuid, null: false)
      add(:esj_inserted_at, :utc_datetime, null: false)
      add(:esj_updated_at, :utc_datetime, null: false)
    end

    create(index(:esj_supplier_scorecard_dimension, [:esj_org_id]))
    create(index(:esj_supplier_scorecard_dimension, [:esj_scorecard_id]))

    create(
      unique_index(
        :esj_supplier_scorecard_dimension,
        [:esj_org_id, :esj_scorecard_id, :esj_dimension],
        name: :esj_supplier_scorecard_dimension_unique
      )
    )

    create(
      constraint(:esj_supplier_scorecard_dimension, :esj_dimension_valid,
        check:
          "esj_dimension IN ('quality_yield','delivery_schedule','cost_commercial'," <>
            "'technical_support','compliance_sustainability')"
      )
    )

    create(
      constraint(:esj_supplier_scorecard_dimension, :esj_shape_valid,
        check:
          "esj_weight_pct BETWEEN 1 AND 100 AND esj_score BETWEEN 1 AND 5 AND " <>
            "(esj_note IS NULL OR char_length(esj_note) <= 300)"
      )
    )

    create table(:esk_supplier_risk, primary_key: false) do
      add(:esk_vendor_id, :uuid, null: false)
      add(:esk_code, :text, null: false)
      add(:esk_title, :text, null: false)
      add(:esk_category, :text, null: false)
      add(:esk_likelihood, :integer, null: false)
      add(:esk_impact, :integer, null: false)
      add(:esk_mitigation, :text, null: false)
      add(:esk_owner_role, :text, null: false)
      add(:esk_escalation_trigger, :text, null: false)
      add(:esk_status, :text, null: false, default: "open")
      add(:esk_reviewed_on, :date)
      add(:esk_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:esk_org_id, :uuid, null: false)
      add(:esk_inserted_at, :utc_datetime, null: false)
      add(:esk_updated_at, :utc_datetime, null: false)
    end

    create(index(:esk_supplier_risk, [:esk_org_id]))
    create(index(:esk_supplier_risk, [:esk_vendor_id]))

    create(
      unique_index(:esk_supplier_risk, [:esk_org_id, :esk_vendor_id, :esk_code],
        name: :esk_supplier_risk_unique
      )
    )

    create(
      constraint(:esk_supplier_risk, :esk_enums_valid,
        check:
          "esk_category IN ('quality','delivery','cost','compliance','financial'," <>
            "'operational','strategic','geopolitical') AND " <>
            "esk_owner_role IN ('procurement_lead','quality_lead','finance_lead'," <>
            "'operations_lead','engineering_lead','compliance_lead','executive') AND " <>
            "esk_status IN ('open','mitigating','accepted','closed')"
      )
    )

    create(
      constraint(:esk_supplier_risk, :esk_shape_valid,
        check:
          "esk_likelihood BETWEEN 1 AND 5 AND esk_impact BETWEEN 1 AND 5 AND " <>
            "char_length(esk_code) BETWEEN 1 AND 32 AND " <>
            "char_length(esk_title) BETWEEN 1 AND 240 AND " <>
            "char_length(esk_mitigation) BETWEEN 1 AND 1000 AND " <>
            "char_length(esk_escalation_trigger) BETWEEN 1 AND 500"
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:esj_supplier_scorecard_dimension))
    drop(table(:esi_supplier_scorecard))
    drop(table(:esk_supplier_risk))
  end
end
