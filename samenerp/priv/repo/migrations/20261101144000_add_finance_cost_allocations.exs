defmodule Samenerp.Repo.Migrations.AddFinanceCostAllocations do
  @moduledoc """
  WS-ACCT Phase 10 (ADR-054 decision 11) — the reusable allocation step on the
  `samenerp` host (`Samenerp.Erp`): allocation `sec`, share `cse`. See
  `samen_core/priv/test_repo/migrations/20261101160000_add_finance_cost_allocations.exs`
  for the full table/belt rationale; the shapes are identical across hosts.
  """

  use Samen.Migration

  @resources [
    Samenerp.Erp.CostAllocation,
    Samenerp.Erp.CostAllocationShare
  ]

  def up do
    create table(:sec_cost_allocation, primary_key: false) do
      add(:sec_allocated_on, :date, null: false)
      add(:sec_basis, :text, null: false)
      add(:sec_axis, :text, null: false, default: "project")
      add(:sec_status, :text, null: false, default: "draft")
      add(:sec_amount_cents, :bigint, null: false)
      add(:sec_posted_at, :utc_datetime)

      add(
        :sec_ap_invoice_id,
        references(:ecp_ap_invoice,
          column: :ecp_id,
          name: "sec_cost_allocation_sec_ap_invoice_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :sec_source_account_id,
        references(:eca_account,
          column: :eca_id,
          name: "sec_cost_allocation_sec_source_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :sec_target_account_id,
        references(:eca_account,
          column: :eca_id,
          name: "sec_cost_allocation_sec_target_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :sec_entry_id,
        references(:ecj_journal_entry,
          column: :ecj_id,
          name: "sec_cost_allocation_sec_entry_id_fkey",
          type: :uuid
        )
      )

      add(:sec_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sec_org_id, :uuid, null: false)
      add(:sec_inserted_at, :utc_datetime, null: false)
      add(:sec_updated_at, :utc_datetime, null: false)
    end

    create(index(:sec_cost_allocation, [:sec_org_id]))
    create(index(:sec_cost_allocation, [:sec_ap_invoice_id]))
    create(index(:sec_cost_allocation, [:sec_source_account_id]))
    create(index(:sec_cost_allocation, [:sec_target_account_id]))
    create(index(:sec_cost_allocation, [:sec_entry_id]))

    create(
      unique_index(
        :sec_cost_allocation,
        [:sec_org_id, :sec_ap_invoice_id, :sec_source_account_id],
        name: :sec_allocation_unique
      )
    )

    create(
      constraint(:sec_cost_allocation, :sec_basis_valid,
        check: "sec_basis IN ('die_area','wafer','effort')"
      )
    )

    create(
      constraint(:sec_cost_allocation, :sec_axis_valid,
        check: "sec_axis IN ('project','lot','fund','cost_pool')"
      )
    )

    create(
      constraint(:sec_cost_allocation, :sec_status_valid,
        check: "sec_status IN ('draft','posted')"
      )
    )

    create(
      constraint(:sec_cost_allocation, :sec_amount_positive, check: "sec_amount_cents > 0")
    )

    create(
      constraint(:sec_cost_allocation, :sec_posted_complete,
        check: """
        ((sec_status = 'posted' AND sec_entry_id IS NOT NULL AND sec_posted_at IS NOT NULL) OR
         (sec_status = 'draft' AND sec_entry_id IS NULL AND sec_posted_at IS NULL))
        """
      )
    )

    create table(:cse_cost_allocation_share, primary_key: false) do
      add(:cse_driver, :bigint, null: false)
      add(:cse_allocated_cents, :bigint, null: false)

      add(
        :cse_cost_allocation_id,
        references(:sec_cost_allocation,
          column: :sec_id,
          name: "cse_share_cse_cost_allocation_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :cse_cost_object_id,
        references(:eco_cost_object,
          column: :eco_id,
          name: "cse_share_cse_cost_object_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:cse_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:cse_org_id, :uuid, null: false)
      add(:cse_inserted_at, :utc_datetime, null: false)
      add(:cse_updated_at, :utc_datetime, null: false)
    end

    create(index(:cse_cost_allocation_share, [:cse_org_id]))
    create(index(:cse_cost_allocation_share, [:cse_cost_allocation_id]))
    create(index(:cse_cost_allocation_share, [:cse_cost_object_id]))

    create(
      unique_index(
        :cse_cost_allocation_share,
        [:cse_org_id, :cse_cost_allocation_id, :cse_cost_object_id],
        name: :cse_target_unique
      )
    )

    create(
      constraint(:cse_cost_allocation_share, :cse_amount_positive,
        check: "cse_driver > 0 AND cse_allocated_cents > 0"
      )
    )

    execute(
      """
      CREATE FUNCTION sec_allocation_posted_final() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF OLD.sec_status = 'posted' THEN
          RAISE EXCEPTION 'sec_cost_allocation: % is refused — a posted allocation is final; a correction is a reversing entry, never a rewrite. Id: %', TG_OP, OLD.sec_id;
        END IF;
        RETURN NEW;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS sec_allocation_posted_final()"
    )

    execute(
      """
      CREATE TRIGGER sec_allocation_posted_final_tg
      BEFORE UPDATE ON sec_cost_allocation
      FOR EACH ROW EXECUTE FUNCTION sec_allocation_posted_final()
      """,
      "DROP TRIGGER IF EXISTS sec_allocation_posted_final_tg ON sec_cost_allocation"
    )

    execute(
      """
      CREATE FUNCTION cse_share_append_only() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'cse_cost_allocation_share: % is refused — an allocation share is an append-only fact. Share id: %', TG_OP, OLD.cse_id;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS cse_share_append_only()"
    )

    execute(
      """
      CREATE TRIGGER cse_share_append_only_tg
      BEFORE UPDATE OR DELETE ON cse_cost_allocation_share
      FOR EACH ROW EXECUTE FUNCTION cse_share_append_only()
      """,
      "DROP TRIGGER IF EXISTS cse_share_append_only_tg ON cse_cost_allocation_share"
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute("DROP TRIGGER IF EXISTS cse_share_append_only_tg ON cse_cost_allocation_share")
    execute("DROP FUNCTION IF EXISTS cse_share_append_only()")
    execute("DROP TRIGGER IF EXISTS sec_allocation_posted_final_tg ON sec_cost_allocation")
    execute("DROP FUNCTION IF EXISTS sec_allocation_posted_final()")

    drop(table(:cse_cost_allocation_share))
    drop(table(:sec_cost_allocation))
  end
end
