defmodule Samen.WebTest.Repo.Migrations.AddFinanceLabourAllocations do
  @moduledoc """
  WS-ACCT Unit 10.2 (ADR-054 D17) — payroll allocation on the `samen_web` test
  host (`Samen.WebTest.Erp`): allocation `wel`, share `wle`. This host mounts
  Finance WITHOUT `labour:` wiring (it is not a Work host), so the resources
  exist and the actions refuse fail-honest (`:timesheets_not_wired`); the
  tables still ship so the scope's resource set and the catalog stay complete.
  See
  `samen_core/priv/test_repo/migrations/20261101170000_add_work_timesheets_and_finance_labour.exs`
  for the full belt rationale.
  """

  use Samen.Migration

  @resources [
    Samen.WebTest.Erp.LabourAllocation,
    Samen.WebTest.Erp.LabourAllocationShare
  ]

  def up do
    create table(:wel_labour_allocation, primary_key: false) do
      add(:wel_period_start, :date, null: false)
      add(:wel_period_end, :date, null: false)
      add(:wel_total_cents, :bigint, null: false)
      add(:wel_axis, :text, null: false, default: "project")
      add(:wel_status, :text, null: false, default: "draft")
      add(:wel_posted_at, :utc_datetime)

      add(
        :wel_source_account_id,
        references(:fca_account,
          column: :fca_id,
          name: "wel_labour_wel_source_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :wel_target_account_id,
        references(:fca_account,
          column: :fca_id,
          name: "wel_labour_wel_target_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :wel_entry_id,
        references(:fje_journal_entry,
          column: :fje_id,
          name: "wel_labour_wel_entry_id_fkey",
          type: :uuid
        )
      )

      add(:wel_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wel_org_id, :uuid, null: false)
      add(:wel_inserted_at, :utc_datetime, null: false)
      add(:wel_updated_at, :utc_datetime, null: false)
    end

    create(index(:wel_labour_allocation, [:wel_org_id]))
    create(index(:wel_labour_allocation, [:wel_source_account_id]))
    create(index(:wel_labour_allocation, [:wel_target_account_id]))
    create(index(:wel_labour_allocation, [:wel_entry_id]))

    create(
      unique_index(
        :wel_labour_allocation,
        [:wel_org_id, :wel_period_start, :wel_period_end, :wel_source_account_id],
        name: :wel_payroll_unique,
        where: "wel_status <> 'discarded'"
      )
    )

    create(
      constraint(:wel_labour_allocation, :wel_period_valid,
        check: "wel_period_end >= wel_period_start"
      )
    )

    create(
      constraint(:wel_labour_allocation, :wel_axis_valid,
        check: "wel_axis IN ('project','lot','fund','cost_pool')"
      )
    )

    create(
      constraint(:wel_labour_allocation, :wel_status_valid,
        check: "wel_status IN ('draft','posted','discarded')"
      )
    )

    create(
      constraint(:wel_labour_allocation, :wel_total_positive, check: "wel_total_cents > 0")
    )

    create(
      constraint(:wel_labour_allocation, :wel_posted_complete,
        check: """
        ((wel_status = 'posted' AND wel_entry_id IS NOT NULL AND wel_posted_at IS NOT NULL) OR
         (wel_status IN ('draft','discarded') AND wel_entry_id IS NULL AND wel_posted_at IS NULL))
        """
      )
    )

    create table(:wle_labour_allocation_share, primary_key: false) do
      add(:wle_minutes, :integer, null: false)
      add(:wle_allocated_cents, :bigint, null: false)

      add(
        :wle_labour_allocation_id,
        references(:wel_labour_allocation,
          column: :wel_id,
          name: "wle_share_wle_labour_allocation_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :wle_cost_object_id,
        references(:fco_cost_object,
          column: :fco_id,
          name: "wle_share_wle_cost_object_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:wle_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wle_org_id, :uuid, null: false)
      add(:wle_inserted_at, :utc_datetime, null: false)
      add(:wle_updated_at, :utc_datetime, null: false)
    end

    create(index(:wle_labour_allocation_share, [:wle_org_id]))
    create(index(:wle_labour_allocation_share, [:wle_labour_allocation_id]))
    create(index(:wle_labour_allocation_share, [:wle_cost_object_id]))

    create(
      unique_index(
        :wle_labour_allocation_share,
        [:wle_org_id, :wle_labour_allocation_id, :wle_cost_object_id],
        name: :wle_target_unique
      )
    )

    create(
      constraint(:wle_labour_allocation_share, :wle_amount_positive,
        check: "wle_minutes > 0 AND wle_allocated_cents > 0"
      )
    )

    execute(
      """
      CREATE FUNCTION wel_allocation_posted_final() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF OLD.wel_status = 'posted' THEN
          RAISE EXCEPTION 'wel_labour_allocation: % is refused — a posted allocation is final; a correction is a reversing entry, never a rewrite. Id: %', TG_OP, OLD.wel_id;
        END IF;

        IF OLD.wel_status = 'discarded' THEN
          RAISE EXCEPTION 'wel_labour_allocation: % is refused — a discarded proposal is final; re-draft instead of reviving it. Id: %', TG_OP, OLD.wel_id;
        END IF;

        IF NOT (
          (OLD.wel_status = 'draft' AND NEW.wel_status = 'posted') OR
          (OLD.wel_status = 'draft' AND NEW.wel_status = 'discarded')
        ) THEN
          RAISE EXCEPTION 'wel_labour_allocation: transition % -> % is refused — the only moves are draft -> posted and draft -> discarded. Id: %', OLD.wel_status, NEW.wel_status, OLD.wel_id;
        END IF;

        RETURN NEW;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS wel_allocation_posted_final()"
    )

    execute(
      """
      CREATE TRIGGER wel_allocation_posted_final_tg
      BEFORE UPDATE ON wel_labour_allocation
      FOR EACH ROW EXECUTE FUNCTION wel_allocation_posted_final()
      """,
      "DROP TRIGGER IF EXISTS wel_allocation_posted_final_tg ON wel_labour_allocation"
    )

    execute(
      """
      CREATE FUNCTION wle_share_append_only() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'wle_labour_allocation_share: % is refused — a labour allocation share is an append-only fact. Share id: %', TG_OP, OLD.wle_id;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS wle_share_append_only()"
    )

    execute(
      """
      CREATE TRIGGER wle_share_append_only_tg
      BEFORE UPDATE OR DELETE ON wle_labour_allocation_share
      FOR EACH ROW EXECUTE FUNCTION wle_share_append_only()
      """,
      "DROP TRIGGER IF EXISTS wle_share_append_only_tg ON wle_labour_allocation_share"
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute("DROP TRIGGER IF EXISTS wle_share_append_only_tg ON wle_labour_allocation_share")
    execute("DROP FUNCTION IF EXISTS wle_share_append_only()")
    execute("DROP TRIGGER IF EXISTS wel_allocation_posted_final_tg ON wel_labour_allocation")
    execute("DROP FUNCTION IF EXISTS wel_allocation_posted_final()")

    drop(table(:wle_labour_allocation_share))
    drop(table(:wel_labour_allocation))
  end
end
