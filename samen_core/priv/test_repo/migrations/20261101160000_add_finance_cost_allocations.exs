defmodule SamenCore.TestRepo.Migrations.AddFinanceCostAllocations do
  @moduledoc """
  WS-ACCT Phase 10 (ADR-054 decision 11) — the reusable allocation step in the
  `samen_core` test fixture (`SamenCore.Support.FinanceFixture`): allocation
  `fcs`, share `csf`.

    * `fcs_cost_allocation` — one AP bill's cost on one expense account, the
      target account it lands in, the declared basis/axis, and the derived
      amount. A posted row is final.
    * `csf_cost_allocation_share` — one cost object's driver and cents; the
      evidence a reviewer re-runs the split against.

  DB belts (over the Ash-side braces):

    * `fcs_allocation_unique` — one allocation per {org, bill, source account};
      re-allocating the same cost is a double reclass, never a correction;
    * `fcs_basis_valid` / `fcs_axis_valid` / `fcs_status_valid` — the closed
      enums, refused below Ash too;
    * `fcs_amount_positive` — a zero-cent allocation is not a fact;
    * `fcs_posted_complete` — `posted` iff dated and anchored to an entry;
    * `fcs_posted_final` trigger — a posted allocation can never be updated;
    * `csf_target_unique` — one share per cost object per allocation;
    * `csf_amount_positive` — a zero driver or zero-cent share is refused;
    * `csf_share_append_only` trigger — the split is never rewritten.

  Catalog rows via `catalog_sync/1` in the same transaction (ADR-004).
  """

  use Samen.Migration

  @resources [
    SamenCore.Support.FinanceFixture.CostAllocation,
    SamenCore.Support.FinanceFixture.CostAllocationShare
  ]

  def up do
    create table(:fcs_cost_allocation, primary_key: false) do
      add(:fcs_allocated_on, :date, null: false)
      add(:fcs_basis, :text, null: false)
      add(:fcs_axis, :text, null: false, default: "project")
      add(:fcs_status, :text, null: false, default: "draft")
      add(:fcs_amount_cents, :bigint, null: false)
      add(:fcs_posted_at, :utc_datetime)

      add(
        :fcs_ap_invoice_id,
        references(:sap_ap_invoice,
          column: :sap_id,
          name: "fcs_cost_allocation_fcs_ap_invoice_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :fcs_source_account_id,
        references(:sac_account,
          column: :sac_id,
          name: "fcs_cost_allocation_fcs_source_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :fcs_target_account_id,
        references(:sac_account,
          column: :sac_id,
          name: "fcs_cost_allocation_fcs_target_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :fcs_entry_id,
        references(:sje_journal_entry,
          column: :sje_id,
          name: "fcs_cost_allocation_fcs_entry_id_fkey",
          type: :uuid
        )
      )

      add(:fcs_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fcs_org_id, :uuid, null: false)
      add(:fcs_inserted_at, :utc_datetime, null: false)
      add(:fcs_updated_at, :utc_datetime, null: false)
    end

    create(index(:fcs_cost_allocation, [:fcs_org_id]))
    create(index(:fcs_cost_allocation, [:fcs_ap_invoice_id]))
    create(index(:fcs_cost_allocation, [:fcs_source_account_id]))
    create(index(:fcs_cost_allocation, [:fcs_target_account_id]))
    create(index(:fcs_cost_allocation, [:fcs_entry_id]))

    create(
      unique_index(
        :fcs_cost_allocation,
        [:fcs_org_id, :fcs_ap_invoice_id, :fcs_source_account_id],
        name: :fcs_allocation_unique
      )
    )

    create(
      constraint(:fcs_cost_allocation, :fcs_basis_valid,
        check: "fcs_basis IN ('die_area','wafer','effort')"
      )
    )

    create(
      constraint(:fcs_cost_allocation, :fcs_axis_valid,
        check: "fcs_axis IN ('project','lot','fund','cost_pool')"
      )
    )

    create(
      constraint(:fcs_cost_allocation, :fcs_status_valid,
        check: "fcs_status IN ('draft','posted')"
      )
    )

    create(
      constraint(:fcs_cost_allocation, :fcs_amount_positive, check: "fcs_amount_cents > 0")
    )

    create(
      constraint(:fcs_cost_allocation, :fcs_posted_complete,
        check: """
        ((fcs_status = 'posted' AND fcs_entry_id IS NOT NULL AND fcs_posted_at IS NOT NULL) OR
         (fcs_status = 'draft' AND fcs_entry_id IS NULL AND fcs_posted_at IS NULL))
        """
      )
    )

    create table(:csf_cost_allocation_share, primary_key: false) do
      add(:csf_driver, :bigint, null: false)
      add(:csf_allocated_cents, :bigint, null: false)

      add(
        :csf_cost_allocation_id,
        references(:fcs_cost_allocation,
          column: :fcs_id,
          name: "csf_share_csf_cost_allocation_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :csf_cost_object_id,
        references(:cob_cost_object,
          column: :cob_id,
          name: "csf_share_csf_cost_object_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:csf_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:csf_org_id, :uuid, null: false)
      add(:csf_inserted_at, :utc_datetime, null: false)
      add(:csf_updated_at, :utc_datetime, null: false)
    end

    create(index(:csf_cost_allocation_share, [:csf_org_id]))
    create(index(:csf_cost_allocation_share, [:csf_cost_allocation_id]))
    create(index(:csf_cost_allocation_share, [:csf_cost_object_id]))

    create(
      unique_index(
        :csf_cost_allocation_share,
        [:csf_org_id, :csf_cost_allocation_id, :csf_cost_object_id],
        name: :csf_target_unique
      )
    )

    create(
      constraint(:csf_cost_allocation_share, :csf_amount_positive,
        check: "csf_driver > 0 AND csf_allocated_cents > 0"
      )
    )

    execute(
      """
      CREATE FUNCTION fcs_allocation_posted_final() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        IF OLD.fcs_status = 'posted' THEN
          RAISE EXCEPTION 'fcs_cost_allocation: % is refused — a posted allocation is final; a correction is a reversing entry, never a rewrite. Id: %', TG_OP, OLD.fcs_id;
        END IF;
        RETURN NEW;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS fcs_allocation_posted_final()"
    )

    execute(
      """
      CREATE TRIGGER fcs_allocation_posted_final_tg
      BEFORE UPDATE ON fcs_cost_allocation
      FOR EACH ROW EXECUTE FUNCTION fcs_allocation_posted_final()
      """,
      "DROP TRIGGER IF EXISTS fcs_allocation_posted_final_tg ON fcs_cost_allocation"
    )

    execute(
      """
      CREATE FUNCTION csf_share_append_only() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'csf_cost_allocation_share: % is refused — an allocation share is an append-only fact. Share id: %', TG_OP, OLD.csf_id;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS csf_share_append_only()"
    )

    execute(
      """
      CREATE TRIGGER csf_share_append_only_tg
      BEFORE UPDATE OR DELETE ON csf_cost_allocation_share
      FOR EACH ROW EXECUTE FUNCTION csf_share_append_only()
      """,
      "DROP TRIGGER IF EXISTS csf_share_append_only_tg ON csf_cost_allocation_share"
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute("DROP TRIGGER IF EXISTS csf_share_append_only_tg ON csf_cost_allocation_share")
    execute("DROP FUNCTION IF EXISTS csf_share_append_only()")
    execute("DROP TRIGGER IF EXISTS fcs_allocation_posted_final_tg ON fcs_cost_allocation")
    execute("DROP FUNCTION IF EXISTS fcs_allocation_posted_final()")

    drop(table(:csf_cost_allocation_share))
    drop(table(:fcs_cost_allocation))
  end
end
