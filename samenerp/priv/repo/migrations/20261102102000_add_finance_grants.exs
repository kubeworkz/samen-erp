defmodule Samenerp.Repo.Migrations.AddFinanceGrants do
  @moduledoc """
  WS-ACCT Phase 11 (ADR-054 D8) — grants and restricted funds on the Kubeworkz
  books (`Samenerp.Erp`): `egt_grant`, `egm_grant_milestone`,
  `egc_grant_claim`, `ego_grant_opportunity`, `egp_grant_personnel`. Same
  shape and belts as the `samen_core` fixture leg; the fund is an
  `eco_cost_object` of kind `:fund`, the budget reuses `ecb_budget`, and the
  recognition schedule is the Phase-6 `esd_revenue_schedule`.

  Catalog rows via `catalog_sync/1` in the same transaction (ADR-004).
  """

  use Samen.Migration

  @resources [
    Samenerp.Erp.Grant,
    Samenerp.Erp.GrantMilestone,
    Samenerp.Erp.GrantClaim,
    Samenerp.Erp.GrantOpportunity,
    Samenerp.Erp.GrantPersonnel
  ]

  def up do
    create table(:egt_grant, primary_key: false) do
      add(:egt_funder, :text, null: false)
      add(:egt_program, :text, null: false)
      add(:egt_award_ref, :text, null: false)
      add(:egt_award_cents, :bigint, null: false)
      add(:egt_period_start, :date, null: false)
      add(:egt_period_end, :date, null: false)
      add(:egt_restricted, :boolean, null: false, default: true)
      add(:egt_status, :text, null: false, default: "awarded")
      add(:egt_received_on, :date)
      add(:egt_closed_on, :date)

      add(
        :egt_budget_id,
        references(:ecb_budget,
          column: :ecb_id,
          name: "egt_grant_egt_budget_id_fkey",
          type: :uuid
        )
      )

      add(
        :egt_fund_cost_object_id,
        references(:eco_cost_object,
          column: :eco_id,
          name: "egt_grant_egt_fund_cost_object_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :egt_schedule_id,
        references(:esd_revenue_schedule,
          column: :esd_id,
          name: "egt_grant_egt_schedule_id_fkey",
          type: :uuid
        )
      )

      add(:egt_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:egt_org_id, :uuid, null: false)
      add(:egt_inserted_at, :utc_datetime, null: false)
      add(:egt_updated_at, :utc_datetime, null: false)
    end

    create(index(:egt_grant, [:egt_org_id]))
    create(index(:egt_grant, [:egt_fund_cost_object_id]))
    create(unique_index(:egt_grant, [:egt_org_id, :egt_award_ref], name: :egt_award_ref_unique))

    create(
      constraint(:egt_grant, :egt_status_valid,
        check: "egt_status IN ('awarded','active','closed')"
      )
    )

    create(
      constraint(:egt_grant, :egt_shape_valid,
        check:
          "egt_award_cents > 0 AND egt_period_end >= egt_period_start AND " <>
            "egt_award_cents >= ((date_part('year', egt_period_end) * 12 + date_part('month', egt_period_end)) - " <>
            "(date_part('year', egt_period_start) * 12 + date_part('month', egt_period_start)) + 1)"
      )
    )

    create table(:egm_grant_milestone, primary_key: false) do
      add(:egm_name, :text, null: false)
      add(:egm_due_on, :date, null: false)
      add(:egm_amount_cents, :bigint, null: false)
      add(:egm_status, :text, null: false, default: "planned")
      add(:egm_completed_on, :date)

      add(
        :egm_grant_id,
        references(:egt_grant,
          column: :egt_id,
          name: "egm_grant_milestone_egm_grant_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:egm_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:egm_org_id, :uuid, null: false)
      add(:egm_inserted_at, :utc_datetime, null: false)
      add(:egm_updated_at, :utc_datetime, null: false)
    end

    create(index(:egm_grant_milestone, [:egm_org_id]))
    create(index(:egm_grant_milestone, [:egm_grant_id]))

    create(
      unique_index(:egm_grant_milestone, [:egm_org_id, :egm_grant_id, :egm_name],
        name: :egm_milestone_name_unique
      )
    )

    create(
      constraint(:egm_grant_milestone, :egm_status_valid,
        check: "egm_status IN ('planned','met','waived') AND egm_amount_cents > 0"
      )
    )

    create table(:egc_grant_claim, primary_key: false) do
      add(:egc_claimed_on, :date, null: false)
      add(:egc_amount_cents, :bigint, null: false)
      add(:egc_evidence_files, {:array, :uuid}, null: false, default: [])
      add(:egc_status, :text, null: false, default: "submitted")
      add(:egc_approved_on, :date)

      add(
        :egc_grant_id,
        references(:egt_grant,
          column: :egt_id,
          name: "egc_grant_claim_egc_grant_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :egc_milestone_id,
        references(:egm_grant_milestone,
          column: :egm_id,
          name: "egc_grant_claim_egc_milestone_id_fkey",
          type: :uuid
        )
      )

      add(:egc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:egc_org_id, :uuid, null: false)
      add(:egc_inserted_at, :utc_datetime, null: false)
      add(:egc_updated_at, :utc_datetime, null: false)
    end

    create(index(:egc_grant_claim, [:egc_org_id]))
    create(index(:egc_grant_claim, [:egc_grant_id]))
    create(index(:egc_grant_claim, [:egc_milestone_id]))

    create(
      constraint(:egc_grant_claim, :egc_shape_valid,
        check: "egc_amount_cents > 0 AND egc_status IN ('submitted','approved','rejected')"
      )
    )

    create table(:ego_grant_opportunity, primary_key: false) do
      add(:ego_funder, :text, null: false)
      add(:ego_program, :text, null: false)
      add(:ego_stage, :text, null: false, default: "identified")
      add(:ego_deadline, :date)
      add(:ego_amount_cents, :bigint, null: false, default: 0)
      add(:ego_probability, :integer, null: false, default: 0)
      add(:ego_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ego_org_id, :uuid, null: false)
      add(:ego_inserted_at, :utc_datetime, null: false)
      add(:ego_updated_at, :utc_datetime, null: false)
    end

    create(index(:ego_grant_opportunity, [:ego_org_id]))

    create(
      constraint(:ego_grant_opportunity, :ego_shape_valid,
        check:
          "ego_amount_cents >= 0 AND ego_probability BETWEEN 0 AND 100 AND " <>
            "ego_stage IN ('identified','applied','awarded','declined')"
      )
    )

    create table(:egp_grant_personnel, primary_key: false) do
      add(:egp_employee_id, :uuid, null: false)
      add(:egp_effort_pct, :integer, null: false)
      add(:egp_effective_on, :date, null: false)

      add(
        :egp_grant_id,
        references(:egt_grant,
          column: :egt_id,
          name: "egp_grant_personnel_egp_grant_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:egp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:egp_org_id, :uuid, null: false)
      add(:egp_inserted_at, :utc_datetime, null: false)
      add(:egp_updated_at, :utc_datetime, null: false)
    end

    create(index(:egp_grant_personnel, [:egp_org_id]))
    create(index(:egp_grant_personnel, [:egp_grant_id]))
    create(index(:egp_grant_personnel, [:egp_employee_id]))

    create(
      unique_index(
        :egp_grant_personnel,
        [:egp_org_id, :egp_grant_id, :egp_employee_id, :egp_effective_on],
        name: :egp_effort_unique
      )
    )

    create(
      constraint(:egp_grant_personnel, :egp_effort_range,
        check: "egp_effort_pct > 0 AND egp_effort_pct <= 100"
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:egp_grant_personnel))
    drop(table(:ego_grant_opportunity))
    drop(table(:egc_grant_claim))
    drop(table(:egm_grant_milestone))
    drop(table(:egt_grant))
  end
end
