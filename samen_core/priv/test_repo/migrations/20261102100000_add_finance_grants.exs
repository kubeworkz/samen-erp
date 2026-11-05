defmodule SamenCore.TestRepo.Migrations.AddFinanceGrants do
  @moduledoc """
  WS-ACCT Phase 11 (ADR-054 D8) — grants and restricted funds in the
  `samen_core` test fixture (`SamenCore.Support.FinanceFixture`):

    * `fgn_grant` — the award document, its fund `CostObject`, optional
      `Budget` reuse and optional recognition schedule;
    * `fgl_grant_milestone` — a due date and the amount expected against it;
    * `fgk_grant_claim` — a claim for allowable cost, its evidence file ids and
      its single decision;
    * `fgt_grant_opportunity` — the application tracker;
    * `fgu_grant_personnel` — the opaque employee id and effort percentage the
      compliance report resolves.

  DB belts over the Ash braces: positive awards/claims/milestones, the closed
  status/stage enums, the period ordering, the effort range, and the
  per-grant milestone/effort identities. Catalog rows via `catalog_sync/1` in
  the same transaction (ADR-004).
  """

  use Samen.Migration

  @resources [
    SamenCore.Support.FinanceFixture.Grant,
    SamenCore.Support.FinanceFixture.GrantMilestone,
    SamenCore.Support.FinanceFixture.GrantClaim,
    SamenCore.Support.FinanceFixture.GrantOpportunity,
    SamenCore.Support.FinanceFixture.GrantPersonnel
  ]

  def up do
    create table(:fgn_grant, primary_key: false) do
      add(:fgn_funder, :text, null: false)
      add(:fgn_program, :text, null: false)
      add(:fgn_award_ref, :text, null: false)
      add(:fgn_award_cents, :bigint, null: false)
      add(:fgn_period_start, :date, null: false)
      add(:fgn_period_end, :date, null: false)
      add(:fgn_restricted, :boolean, null: false, default: true)
      add(:fgn_status, :text, null: false, default: "awarded")
      add(:fgn_received_on, :date)
      add(:fgn_closed_on, :date)

      add(
        :fgn_budget_id,
        references(:sbg_budget,
          column: :sbg_id,
          name: "fgn_grant_fgn_budget_id_fkey",
          type: :uuid
        )
      )

      add(
        :fgn_fund_cost_object_id,
        references(:cob_cost_object,
          column: :cob_id,
          name: "fgn_grant_fgn_fund_cost_object_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :fgn_schedule_id,
        references(:fsd_revenue_schedule,
          column: :fsd_id,
          name: "fgn_grant_fgn_schedule_id_fkey",
          type: :uuid
        )
      )

      add(:fgn_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fgn_org_id, :uuid, null: false)
      add(:fgn_inserted_at, :utc_datetime, null: false)
      add(:fgn_updated_at, :utc_datetime, null: false)
    end

    create(index(:fgn_grant, [:fgn_org_id]))
    create(index(:fgn_grant, [:fgn_fund_cost_object_id]))
    create(unique_index(:fgn_grant, [:fgn_org_id, :fgn_award_ref], name: :fgn_award_ref_unique))

    create(
      constraint(:fgn_grant, :fgn_status_valid,
        check: "fgn_status IN ('awarded','active','closed')"
      )
    )

    create(
      constraint(:fgn_grant, :fgn_shape_valid,
        check:
          "fgn_award_cents > 0 AND fgn_period_end >= fgn_period_start AND " <>
            "fgn_award_cents >= ((date_part('year', fgn_period_end) * 12 + date_part('month', fgn_period_end)) - " <>
            "(date_part('year', fgn_period_start) * 12 + date_part('month', fgn_period_start)) + 1)"
      )
    )

    create table(:fgl_grant_milestone, primary_key: false) do
      add(:fgl_name, :text, null: false)
      add(:fgl_due_on, :date, null: false)
      add(:fgl_amount_cents, :bigint, null: false)
      add(:fgl_status, :text, null: false, default: "planned")
      add(:fgl_completed_on, :date)

      add(
        :fgl_grant_id,
        references(:fgn_grant,
          column: :fgn_id,
          name: "fgl_grant_milestone_fgl_grant_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:fgl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fgl_org_id, :uuid, null: false)
      add(:fgl_inserted_at, :utc_datetime, null: false)
      add(:fgl_updated_at, :utc_datetime, null: false)
    end

    create(index(:fgl_grant_milestone, [:fgl_org_id]))
    create(index(:fgl_grant_milestone, [:fgl_grant_id]))

    create(
      unique_index(:fgl_grant_milestone, [:fgl_org_id, :fgl_grant_id, :fgl_name],
        name: :fgl_milestone_name_unique
      )
    )

    create(
      constraint(:fgl_grant_milestone, :fgl_status_valid,
        check: "fgl_status IN ('planned','met','waived') AND fgl_amount_cents > 0"
      )
    )

    create table(:fgk_grant_claim, primary_key: false) do
      add(:fgk_claimed_on, :date, null: false)
      add(:fgk_amount_cents, :bigint, null: false)
      add(:fgk_evidence_files, {:array, :uuid}, null: false, default: [])
      add(:fgk_status, :text, null: false, default: "submitted")
      add(:fgk_approved_on, :date)

      add(
        :fgk_grant_id,
        references(:fgn_grant,
          column: :fgn_id,
          name: "fgk_grant_claim_fgk_grant_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :fgk_milestone_id,
        references(:fgl_grant_milestone,
          column: :fgl_id,
          name: "fgk_grant_claim_fgk_milestone_id_fkey",
          type: :uuid
        )
      )

      add(:fgk_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fgk_org_id, :uuid, null: false)
      add(:fgk_inserted_at, :utc_datetime, null: false)
      add(:fgk_updated_at, :utc_datetime, null: false)
    end

    create(index(:fgk_grant_claim, [:fgk_org_id]))
    create(index(:fgk_grant_claim, [:fgk_grant_id]))
    create(index(:fgk_grant_claim, [:fgk_milestone_id]))

    create(
      constraint(:fgk_grant_claim, :fgk_shape_valid,
        check: "fgk_amount_cents > 0 AND fgk_status IN ('submitted','approved','rejected')"
      )
    )

    create table(:fgt_grant_opportunity, primary_key: false) do
      add(:fgt_funder, :text, null: false)
      add(:fgt_program, :text, null: false)
      add(:fgt_stage, :text, null: false, default: "identified")
      add(:fgt_deadline, :date)
      add(:fgt_amount_cents, :bigint, null: false, default: 0)
      add(:fgt_probability, :integer, null: false, default: 0)
      add(:fgt_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fgt_org_id, :uuid, null: false)
      add(:fgt_inserted_at, :utc_datetime, null: false)
      add(:fgt_updated_at, :utc_datetime, null: false)
    end

    create(index(:fgt_grant_opportunity, [:fgt_org_id]))

    create(
      constraint(:fgt_grant_opportunity, :fgt_shape_valid,
        check:
          "fgt_amount_cents >= 0 AND fgt_probability BETWEEN 0 AND 100 AND " <>
            "fgt_stage IN ('identified','applied','awarded','declined')"
      )
    )

    create table(:fgu_grant_personnel, primary_key: false) do
      add(:fgu_employee_id, :uuid, null: false)
      add(:fgu_effort_pct, :integer, null: false)
      add(:fgu_effective_on, :date, null: false)

      add(
        :fgu_grant_id,
        references(:fgn_grant,
          column: :fgn_id,
          name: "fgu_grant_personnel_fgu_grant_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:fgu_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fgu_org_id, :uuid, null: false)
      add(:fgu_inserted_at, :utc_datetime, null: false)
      add(:fgu_updated_at, :utc_datetime, null: false)
    end

    create(index(:fgu_grant_personnel, [:fgu_org_id]))
    create(index(:fgu_grant_personnel, [:fgu_grant_id]))
    create(index(:fgu_grant_personnel, [:fgu_employee_id]))

    create(
      unique_index(
        :fgu_grant_personnel,
        [:fgu_org_id, :fgu_grant_id, :fgu_employee_id, :fgu_effective_on],
        name: :fgu_effort_unique
      )
    )

    create(
      constraint(:fgu_grant_personnel, :fgu_effort_range,
        check: "fgu_effort_pct > 0 AND fgu_effort_pct <= 100"
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:fgu_grant_personnel))
    drop(table(:fgt_grant_opportunity))
    drop(table(:fgk_grant_claim))
    drop(table(:fgl_grant_milestone))
    drop(table(:fgn_grant))
  end
end
