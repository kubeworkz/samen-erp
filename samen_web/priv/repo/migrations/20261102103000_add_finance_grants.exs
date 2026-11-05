defmodule Samen.WebTest.Repo.Migrations.AddFinanceGrants do
  @moduledoc """
  WS-ACCT Phase 11 (ADR-054 D8) — grants and restricted funds on the
  `samen_web` test host (`Samen.WebTest.Erp`): `fgr_grant`,
  `fgm_grant_milestone`, `fgc_grant_claim`, `fgo_grant_opportunity`,
  `fgp_grant_personnel`. Same shape and belts as the `samen_core` fixture leg;
  the fund is an `fco_cost_object` of kind `:fund`, the budget reference is
  carried as an unconstrained uuid (this test host deliberately does not table
  Budget — its mount doc: the web surfaces never read budgets), and the
  recognition schedule is the Phase-6 `frs_revenue_schedule`.

  Catalog rows via `catalog_sync/1` in the same transaction (ADR-004).
  """

  use Samen.Migration

  @resources [
    Samen.WebTest.Erp.Grant,
    Samen.WebTest.Erp.GrantMilestone,
    Samen.WebTest.Erp.GrantClaim,
    Samen.WebTest.Erp.GrantOpportunity,
    Samen.WebTest.Erp.GrantPersonnel
  ]

  def up do
    create table(:fgr_grant, primary_key: false) do
      add(:fgr_funder, :text, null: false)
      add(:fgr_program, :text, null: false)
      add(:fgr_award_ref, :text, null: false)
      add(:fgr_award_cents, :bigint, null: false)
      add(:fgr_period_start, :date, null: false)
      add(:fgr_period_end, :date, null: false)
      add(:fgr_restricted, :boolean, null: false, default: true)
      add(:fgr_status, :text, null: false, default: "awarded")
      add(:fgr_received_on, :date)
      add(:fgr_closed_on, :date)

      # The web test host never tables Budget; a host that does gets the FK
      # (see samenerp). SameOrgFk still validates a set reference in Ash.
      add(:fgr_budget_id, :uuid)

      add(
        :fgr_fund_cost_object_id,
        references(:fco_cost_object,
          column: :fco_id,
          name: "fgr_grant_fgr_fund_cost_object_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :fgr_schedule_id,
        references(:frs_revenue_schedule,
          column: :frs_id,
          name: "fgr_grant_fgr_schedule_id_fkey",
          type: :uuid
        )
      )

      add(:fgr_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fgr_org_id, :uuid, null: false)
      add(:fgr_inserted_at, :utc_datetime, null: false)
      add(:fgr_updated_at, :utc_datetime, null: false)
    end

    create(index(:fgr_grant, [:fgr_org_id]))
    create(index(:fgr_grant, [:fgr_fund_cost_object_id]))
    create(unique_index(:fgr_grant, [:fgr_org_id, :fgr_award_ref], name: :fgr_award_ref_unique))

    create(
      constraint(:fgr_grant, :fgr_status_valid,
        check: "fgr_status IN ('awarded','active','closed')"
      )
    )

    create(
      constraint(:fgr_grant, :fgr_shape_valid,
        check:
          "fgr_award_cents > 0 AND fgr_period_end >= fgr_period_start AND " <>
            "fgr_award_cents >= ((date_part('year', fgr_period_end) * 12 + date_part('month', fgr_period_end)) - " <>
            "(date_part('year', fgr_period_start) * 12 + date_part('month', fgr_period_start)) + 1)"
      )
    )

    create table(:fgm_grant_milestone, primary_key: false) do
      add(:fgm_name, :text, null: false)
      add(:fgm_due_on, :date, null: false)
      add(:fgm_amount_cents, :bigint, null: false)
      add(:fgm_status, :text, null: false, default: "planned")
      add(:fgm_completed_on, :date)

      add(
        :fgm_grant_id,
        references(:fgr_grant,
          column: :fgr_id,
          name: "fgm_grant_milestone_fgm_grant_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:fgm_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fgm_org_id, :uuid, null: false)
      add(:fgm_inserted_at, :utc_datetime, null: false)
      add(:fgm_updated_at, :utc_datetime, null: false)
    end

    create(index(:fgm_grant_milestone, [:fgm_org_id]))
    create(index(:fgm_grant_milestone, [:fgm_grant_id]))

    create(
      unique_index(:fgm_grant_milestone, [:fgm_org_id, :fgm_grant_id, :fgm_name],
        name: :fgm_milestone_name_unique
      )
    )

    create(
      constraint(:fgm_grant_milestone, :fgm_status_valid,
        check: "fgm_status IN ('planned','met','waived') AND fgm_amount_cents > 0"
      )
    )

    create table(:fgc_grant_claim, primary_key: false) do
      add(:fgc_claimed_on, :date, null: false)
      add(:fgc_amount_cents, :bigint, null: false)
      add(:fgc_evidence_files, {:array, :uuid}, null: false, default: [])
      add(:fgc_status, :text, null: false, default: "submitted")
      add(:fgc_approved_on, :date)

      add(
        :fgc_grant_id,
        references(:fgr_grant,
          column: :fgr_id,
          name: "fgc_grant_claim_fgc_grant_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :fgc_milestone_id,
        references(:fgm_grant_milestone,
          column: :fgm_id,
          name: "fgc_grant_claim_fgc_milestone_id_fkey",
          type: :uuid
        )
      )

      add(:fgc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fgc_org_id, :uuid, null: false)
      add(:fgc_inserted_at, :utc_datetime, null: false)
      add(:fgc_updated_at, :utc_datetime, null: false)
    end

    create(index(:fgc_grant_claim, [:fgc_org_id]))
    create(index(:fgc_grant_claim, [:fgc_grant_id]))
    create(index(:fgc_grant_claim, [:fgc_milestone_id]))

    create(
      constraint(:fgc_grant_claim, :fgc_shape_valid,
        check: "fgc_amount_cents > 0 AND fgc_status IN ('submitted','approved','rejected')"
      )
    )

    create table(:fgo_grant_opportunity, primary_key: false) do
      add(:fgo_funder, :text, null: false)
      add(:fgo_program, :text, null: false)
      add(:fgo_stage, :text, null: false, default: "identified")
      add(:fgo_deadline, :date)
      add(:fgo_amount_cents, :bigint, null: false, default: 0)
      add(:fgo_probability, :integer, null: false, default: 0)
      add(:fgo_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fgo_org_id, :uuid, null: false)
      add(:fgo_inserted_at, :utc_datetime, null: false)
      add(:fgo_updated_at, :utc_datetime, null: false)
    end

    create(index(:fgo_grant_opportunity, [:fgo_org_id]))

    create(
      constraint(:fgo_grant_opportunity, :fgo_shape_valid,
        check:
          "fgo_amount_cents >= 0 AND fgo_probability BETWEEN 0 AND 100 AND " <>
            "fgo_stage IN ('identified','applied','awarded','declined')"
      )
    )

    create table(:fgp_grant_personnel, primary_key: false) do
      add(:fgp_employee_id, :uuid, null: false)
      add(:fgp_effort_pct, :integer, null: false)
      add(:fgp_effective_on, :date, null: false)

      add(
        :fgp_grant_id,
        references(:fgr_grant,
          column: :fgr_id,
          name: "fgp_grant_personnel_fgp_grant_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:fgp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fgp_org_id, :uuid, null: false)
      add(:fgp_inserted_at, :utc_datetime, null: false)
      add(:fgp_updated_at, :utc_datetime, null: false)
    end

    create(index(:fgp_grant_personnel, [:fgp_org_id]))
    create(index(:fgp_grant_personnel, [:fgp_grant_id]))
    create(index(:fgp_grant_personnel, [:fgp_employee_id]))

    create(
      unique_index(
        :fgp_grant_personnel,
        [:fgp_org_id, :fgp_grant_id, :fgp_employee_id, :fgp_effective_on],
        name: :fgp_effort_unique
      )
    )

    create(
      constraint(:fgp_grant_personnel, :fgp_effort_range,
        check: "fgp_effort_pct > 0 AND fgp_effort_pct <= 100"
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:fgp_grant_personnel))
    drop(table(:fgo_grant_opportunity))
    drop(table(:fgc_grant_claim))
    drop(table(:fgm_grant_milestone))
    drop(table(:fgr_grant))
  end
end
