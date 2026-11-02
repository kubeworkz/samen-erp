defmodule Samen.WebTest.Repo.Migrations.AddFinanceCostAllocations do
  @moduledoc """
  WS-ACCT Phase 10 (ADR-054 decision 11) — the reusable allocation step on the
  `samen_web` test host (`Samen.WebTest.Erp`): allocation `wec`, share `ewc`.
  See `samen_core/priv/test_repo/migrations/20261101160000_add_finance_cost_allocations.exs`
  for the full table/belt rationale; the shapes are identical across hosts.
  """

  use Samen.Migration

  @resources [
    Samen.WebTest.Erp.CostAllocation,
    Samen.WebTest.Erp.CostAllocationShare
  ]

  def up do
    create table(:wec_cost_allocation, primary_key: false) do
      add(:wec_allocated_on, :date, null: false)
      add(:wec_basis, :text, null: false)
      add(:wec_axis, :text, null: false, default: "project")
      add(:wec_status, :text, null: false, default: "draft")
      add(:wec_amount_cents, :bigint, null: false)
      add(:wec_posted_at, :utc_datetime)

      add(
        :wec_ap_invoice_id,
        references(:fai_ap_invoice,
          column: :fai_id,
          name: "wec_cost_allocation_wec_ap_invoice_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :wec_source_account_id,
        references(:fca_account,
          column: :fca_id,
          name: "wec_cost_allocation_wec_source_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :wec_target_account_id,
        references(:fca_account,
          column: :fca_id,
          name: "wec_cost_allocation_wec_target_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :wec_entry_id,
        references(:fje_journal_entry,
          column: :fje_id,
          name: "wec_cost_allocation_wec_entry_id_fkey",
          type: :uuid
        )
      )

      add(:wec_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wec_org_id, :uuid, null: false)
      add(:wec_inserted_at, :utc_datetime, null: false)
      add(:wec_updated_at, :utc_datetime, null: false)
    end

    create(index(:wec_cost_allocation, [:wec_org_id]))
    create(index(:wec_cost_allocation, [:wec_ap_invoice_id]))
    create(index(:wec_cost_allocation, [:wec_source_account_id]))
    create(index(:wec_cost_allocation, [:wec_target_account_id]))
    create(index(:wec_cost_allocation, [:wec_entry_id]))

    create(
      unique_index(
        :wec_cost_allocation,
        [:wec_org_id, :wec_ap_invoice_id, :wec_source_account_id],
        name: :wec_allocation_unique
      )
    )

    create(
      constraint(:wec_cost_allocation, :wec_basis_valid,
        check: "wec_basis IN ('die_area','wafer','effort')"
      )
    )

    create(
      constraint(:wec_cost_allocation, :wec_axis_valid,
        check: "wec_axis IN ('project','lot','fund','cost_pool')"
      )
    )

    create(
      constraint(:wec_cost_allocation, :wec_status_valid,
        check: "wec_status IN ('draft','posted')"
      )
    )

    create(
      constraint(:wec_cost_allocation, :wec_amount_positive, check: "wec_amount_cents > 0")
    )

    create(
      constraint(:wec_cost_allocation, :wec_posted_complete,
        check: """
        ((wec_status = 'posted' AND wec_entry_id IS NOT NULL AND wec_posted_at IS NOT NULL) OR
         (wec_status = 'draft' AND wec_entry_id IS NULL AND wec_posted_at IS NULL))
        """
      )
    )

    create table(:ewc_cost_allocation_share, primary_key: false) do
      add(:ewc_driver, :bigint, null: false)
      add(:ewc_allocated_cents, :bigint, null: false)

      add(
        :ewc_cost_allocation_id,
        references(:wec_cost_allocation,
          column: :wec_id,
          name: "ewc_share_ewc_cost_allocation_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :ewc_cost_object_id,
        references(:fco_cost_object,
          column: :fco_id,
          name: "ewc_share_ewc_cost_object_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:ewc_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ewc_org_id, :uuid, null: false)
      add(:ewc_inserted_at, :utc_datetime, null: false)
      add(:ewc_updated_at, :utc_datetime, null: false)
    end

    create(index(:ewc_cost_allocation_share, [:ewc_org_id]))
    create(index(:ewc_cost_allocation_share, [:ewc_cost_allocation_id]))
    create(index(:ewc_cost_allocation_share, [:ewc_cost_object_id]))

    create(
      unique_index(
        :ewc_cost_allocation_share,
        [:ewc_org_id, :ewc_cost_allocation_id, :ewc_cost_object_id],
        name: :ewc_target_unique
      )
    )

    create(
      constraint(:ewc_cost_allocation_share, :ewc_amount_positive,
        check: "ewc_driver > 0 AND ewc_allocated_cents > 0"
      )
    )

    execute(
      """
      CREATE FUNCTION wec_allocation_posted_final() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF OLD.wec_status = 'posted' THEN
          RAISE EXCEPTION 'wec_cost_allocation: % is refused — a posted allocation is final; a correction is a reversing entry, never a rewrite. Id: %', TG_OP, OLD.wec_id;
        END IF;
        RETURN NEW;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS wec_allocation_posted_final()"
    )

    execute(
      """
      CREATE TRIGGER wec_allocation_posted_final_tg
      BEFORE UPDATE ON wec_cost_allocation
      FOR EACH ROW EXECUTE FUNCTION wec_allocation_posted_final()
      """,
      "DROP TRIGGER IF EXISTS wec_allocation_posted_final_tg ON wec_cost_allocation"
    )

    execute(
      """
      CREATE FUNCTION ewc_share_append_only() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'ewc_cost_allocation_share: % is refused — an allocation share is an append-only fact. Share id: %', TG_OP, OLD.ewc_id;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS ewc_share_append_only()"
    )

    execute(
      """
      CREATE TRIGGER ewc_share_append_only_tg
      BEFORE UPDATE OR DELETE ON ewc_cost_allocation_share
      FOR EACH ROW EXECUTE FUNCTION ewc_share_append_only()
      """,
      "DROP TRIGGER IF EXISTS ewc_share_append_only_tg ON ewc_cost_allocation_share"
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute("DROP TRIGGER IF EXISTS ewc_share_append_only_tg ON ewc_cost_allocation_share")
    execute("DROP FUNCTION IF EXISTS ewc_share_append_only()")
    execute("DROP TRIGGER IF EXISTS wec_allocation_posted_final_tg ON wec_cost_allocation")
    execute("DROP FUNCTION IF EXISTS wec_allocation_posted_final()")

    drop(table(:ewc_cost_allocation_share))
    drop(table(:wec_cost_allocation))
  end
end
