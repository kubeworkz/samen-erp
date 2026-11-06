defmodule SamenCore.TestRepo.Migrations.AddFinanceSupplierGovernance do
  @moduledoc """
  WS-ACCT Phase 15 (ADR-054 D18) — supplier governance in the `samen_core`
  fixture: `ssg_supplier_scorecard` (one quarterly scorecard per vendor),
  `ssh_supplier_scorecard_dimension` (its five weighted rows) and
  `ssj_supplier_risk` (the 5×5 register).

  The database belts mirror the Ash guards: period bounds and the exact five
  dimensions, weights summing to 100, 1–5 scores, 1–5 likelihood/impact, the
  closed category/owner/status enums, and the per-vendor identities. The
  supplier is named only by `*_vendor_id`; there are no contact/PII columns.
  Catalog rows via `catalog_sync/1` in the same transaction (ADR-004).
  """

  use Samen.Migration

  @resources [
    SamenCore.Support.FinanceFixture.SupplierScorecard,
    SamenCore.Support.FinanceFixture.SupplierScorecardDimension,
    SamenCore.Support.FinanceFixture.SupplierRisk
  ]

  def up do
    create table(:ssg_supplier_scorecard, primary_key: false) do
      add(:ssg_vendor_id, :uuid, null: false)
      add(:ssg_period_year, :integer, null: false)
      add(:ssg_period_quarter, :integer, null: false)
      add(:ssg_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ssg_org_id, :uuid, null: false)
      add(:ssg_inserted_at, :utc_datetime, null: false)
      add(:ssg_updated_at, :utc_datetime, null: false)
    end

    create(index(:ssg_supplier_scorecard, [:ssg_org_id]))
    create(index(:ssg_supplier_scorecard, [:ssg_vendor_id]))

    create(
      unique_index(
        :ssg_supplier_scorecard,
        [:ssg_org_id, :ssg_vendor_id, :ssg_period_year, :ssg_period_quarter],
        name: :ssg_supplier_scorecard_unique
      )
    )

    create(
      constraint(:ssg_supplier_scorecard, :ssg_period_valid,
        check: "ssg_period_year BETWEEN 2000 AND 2100 AND ssg_period_quarter BETWEEN 1 AND 4"
      )
    )

    create table(:ssh_supplier_scorecard_dimension, primary_key: false) do
      add(:ssh_dimension, :text, null: false)
      add(:ssh_weight_pct, :integer, null: false)
      add(:ssh_score, :integer, null: false)
      add(:ssh_note, :text)

      add(
        :ssh_scorecard_id,
        references(:ssg_supplier_scorecard,
          column: :ssg_id,
          name: "ssh_supplier_scorecard_dimension_ssh_scorecard_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:ssh_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ssh_org_id, :uuid, null: false)
      add(:ssh_inserted_at, :utc_datetime, null: false)
      add(:ssh_updated_at, :utc_datetime, null: false)
    end

    create(index(:ssh_supplier_scorecard_dimension, [:ssh_org_id]))
    create(index(:ssh_supplier_scorecard_dimension, [:ssh_scorecard_id]))

    create(
      unique_index(
        :ssh_supplier_scorecard_dimension,
        [:ssh_org_id, :ssh_scorecard_id, :ssh_dimension],
        name: :ssh_supplier_scorecard_dimension_unique
      )
    )

    create(
      constraint(:ssh_supplier_scorecard_dimension, :ssh_dimension_valid,
        check:
          "ssh_dimension IN ('quality_yield','delivery_schedule','cost_commercial'," <>
            "'technical_support','compliance_sustainability')"
      )
    )

    create(
      constraint(:ssh_supplier_scorecard_dimension, :ssh_shape_valid,
        check:
          "ssh_weight_pct BETWEEN 1 AND 100 AND ssh_score BETWEEN 1 AND 5 AND " <>
            "(ssh_note IS NULL OR char_length(ssh_note) <= 300)"
      )
    )

    create table(:ssj_supplier_risk, primary_key: false) do
      add(:ssj_vendor_id, :uuid, null: false)
      add(:ssj_code, :text, null: false)
      add(:ssj_title, :text, null: false)
      add(:ssj_category, :text, null: false)
      add(:ssj_likelihood, :integer, null: false)
      add(:ssj_impact, :integer, null: false)
      add(:ssj_mitigation, :text, null: false)
      add(:ssj_owner_role, :text, null: false)
      add(:ssj_escalation_trigger, :text, null: false)
      add(:ssj_status, :text, null: false, default: "open")
      add(:ssj_reviewed_on, :date)
      add(:ssj_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ssj_org_id, :uuid, null: false)
      add(:ssj_inserted_at, :utc_datetime, null: false)
      add(:ssj_updated_at, :utc_datetime, null: false)
    end

    create(index(:ssj_supplier_risk, [:ssj_org_id]))
    create(index(:ssj_supplier_risk, [:ssj_vendor_id]))

    create(
      unique_index(:ssj_supplier_risk, [:ssj_org_id, :ssj_vendor_id, :ssj_code],
        name: :ssj_supplier_risk_unique
      )
    )

    create(
      constraint(:ssj_supplier_risk, :ssj_enums_valid,
        check:
          "ssj_category IN ('quality','delivery','cost','compliance','financial'," <>
            "'operational','strategic','geopolitical') AND " <>
            "ssj_owner_role IN ('procurement_lead','quality_lead','finance_lead'," <>
            "'operations_lead','engineering_lead','compliance_lead','executive') AND " <>
            "ssj_status IN ('open','mitigating','accepted','closed')"
      )
    )

    create(
      constraint(:ssj_supplier_risk, :ssj_shape_valid,
        check:
          "ssj_likelihood BETWEEN 1 AND 5 AND ssj_impact BETWEEN 1 AND 5 AND " <>
            "char_length(ssj_code) BETWEEN 1 AND 32 AND " <>
            "char_length(ssj_title) BETWEEN 1 AND 240 AND " <>
            "char_length(ssj_mitigation) BETWEEN 1 AND 1000 AND " <>
            "char_length(ssj_escalation_trigger) BETWEEN 1 AND 500"
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:ssh_supplier_scorecard_dimension))
    drop(table(:ssg_supplier_scorecard))
    drop(table(:ssj_supplier_risk))
  end
end
