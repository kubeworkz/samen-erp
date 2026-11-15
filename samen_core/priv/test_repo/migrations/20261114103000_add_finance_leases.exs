defmodule SamenCore.TestRepo.Migrations.AddFinanceLeases do
  @moduledoc """
  Lease accounting on the `samen_core` fixture (`Lease` `fls`,
  `LeasePayment` `lsf`). The contract carries the six accounts and the
  payment table is the append-only per-period fact; the liability/ROU schedule
  itself is derived.
  """

  use Samen.Migration

  @resources [
    SamenCore.Support.FinanceFixture.Lease,
    SamenCore.Support.FinanceFixture.LeasePayment
  ]

  def up do
    create table(:fls_lease, primary_key: false) do
      add(:fls_code, :text, null: false)
      add(:fls_name, :text, null: false)
      add(:fls_memo, :text)
      add(:fls_source_key, :text)
      add(:fls_source_id, :uuid)
      add(:fls_kind, :text, null: false)
      add(:fls_start_on, :date, null: false)
      add(:fls_months, :integer, null: false)
      add(:fls_payment_cents, :bigint, null: false)
      add(:fls_annual_rate_bps, :integer, null: false, default: 0)
      add(:fls_dimension_key, :text, null: false, default: "project")
      add(:fls_initial_entry_id, :uuid)

      add(
        :fls_rou_asset_account_id,
        references(:sac_account,
          column: :sac_id,
          name: "fls_lease_fls_rou_asset_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :fls_accumulated_amortization_account_id,
        references(:sac_account,
          column: :sac_id,
          name: "fls_lease_fls_accumulated_amortization_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :fls_lease_liability_account_id,
        references(:sac_account,
          column: :sac_id,
          name: "fls_lease_fls_lease_liability_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :fls_interest_expense_account_id,
        references(:sac_account,
          column: :sac_id,
          name: "fls_lease_fls_interest_expense_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :fls_amortization_expense_account_id,
        references(:sac_account,
          column: :sac_id,
          name: "fls_lease_fls_amortization_expense_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :fls_cash_account_id,
        references(:sac_account,
          column: :sac_id,
          name: "fls_lease_fls_cash_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :fls_cost_object_id,
        references(:cob_cost_object,
          column: :cob_id,
          name: "fls_lease_fls_cost_object_id_fkey",
          type: :uuid
        )
      )

      add(:fls_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fls_org_id, :uuid, null: false)
      add(:fls_inserted_at, :utc_datetime, null: false)
      add(:fls_updated_at, :utc_datetime, null: false)
    end

    create(index(:fls_lease, [:fls_org_id]))
    create(index(:fls_lease, [:fls_rou_asset_account_id]))
    create(index(:fls_lease, [:fls_accumulated_amortization_account_id]))
    create(index(:fls_lease, [:fls_lease_liability_account_id]))
    create(index(:fls_lease, [:fls_interest_expense_account_id]))
    create(index(:fls_lease, [:fls_amortization_expense_account_id]))
    create(index(:fls_lease, [:fls_cash_account_id]))
    create(index(:fls_lease, [:fls_cost_object_id]))
    create(unique_index(:fls_lease, [:fls_org_id, :fls_code], name: :fls_code_unique))

    create(constraint(:fls_lease, :fls_kind_valid, check: "fls_kind IN ('office','lab')"))

    create(
      constraint(:fls_lease, :fls_dimension_key_valid,
        check: "fls_dimension_key IN ('project','lot','fund','cost_pool')"
      )
    )

    create(
      constraint(:fls_lease, :fls_amounts_valid,
        check:
          "fls_payment_cents > 0 AND fls_months > 0 AND fls_annual_rate_bps >= 0 AND fls_payment_cents >= fls_months"
      )
    )

    create(
      constraint(:fls_lease, :fls_source_pair_valid,
        check: "(fls_source_key IS NULL) = (fls_source_id IS NULL)"
      )
    )

    create table(:lsf_lease_payment, primary_key: false) do
      add(:lsf_period_key, :text, null: false)
      add(:lsf_payment_cents, :bigint, null: false)
      add(:lsf_interest_cents, :bigint, null: false)
      add(:lsf_principal_cents, :bigint, null: false)
      add(:lsf_amortization_cents, :bigint, null: false)
      add(:lsf_paid_on, :date, null: false)

      add(
        :lsf_lease_id,
        references(:fls_lease,
          column: :fls_id,
          name: "lsf_lease_payment_lsf_lease_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :lsf_lease_liability_account_id,
        references(:sac_account,
          column: :sac_id,
          name: "lsf_lease_payment_lsf_lease_liability_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :lsf_interest_expense_account_id,
        references(:sac_account,
          column: :sac_id,
          name: "lsf_lease_payment_lsf_interest_expense_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :lsf_amortization_expense_account_id,
        references(:sac_account,
          column: :sac_id,
          name: "lsf_lease_payment_lsf_amortization_expense_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :lsf_accumulated_amortization_account_id,
        references(:sac_account,
          column: :sac_id,
          name: "lsf_lease_payment_lsf_accumulated_amortization_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :lsf_cash_account_id,
        references(:sac_account,
          column: :sac_id,
          name: "lsf_lease_payment_lsf_cash_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:lsf_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:lsf_org_id, :uuid, null: false)
      add(:lsf_inserted_at, :utc_datetime, null: false)
      add(:lsf_updated_at, :utc_datetime, null: false)
    end

    create(index(:lsf_lease_payment, [:lsf_org_id]))
    create(index(:lsf_lease_payment, [:lsf_lease_id]))
    create(index(:lsf_lease_payment, [:lsf_period_key]))

    create(
      unique_index(:lsf_lease_payment, [:lsf_org_id, :lsf_lease_id, :lsf_period_key],
        name: :lsf_period_unique
      )
    )

    create(
      constraint(:lsf_lease_payment, :lsf_period_valid,
        check: "lsf_period_key ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'"
      )
    )

    create(
      constraint(:lsf_lease_payment, :lsf_amounts_valid,
        check:
          "lsf_payment_cents > 0 AND lsf_interest_cents >= 0 AND lsf_principal_cents >= 0 AND lsf_amortization_cents >= 0"
      )
    )

    execute(
      """
      CREATE FUNCTION lsf_lease_payment_append_only() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'lsf_lease_payment: % is refused — a lease payment is an '
          'append-only fact; a correction is a reversing entry, never a rewrite. '
          'Payment id: %', TG_OP, OLD.lsf_id;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS lsf_lease_payment_append_only()"
    )

    execute(
      """
      CREATE TRIGGER lsf_lease_payment_append_only_tg
      BEFORE UPDATE OR DELETE ON lsf_lease_payment
      FOR EACH ROW EXECUTE FUNCTION lsf_lease_payment_append_only()
      """,
      "DROP TRIGGER IF EXISTS lsf_lease_payment_append_only_tg ON lsf_lease_payment"
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute("DROP TRIGGER IF EXISTS lsf_lease_payment_append_only_tg ON lsf_lease_payment")
    execute("DROP FUNCTION IF EXISTS lsf_lease_payment_append_only()")

    drop(table(:lsf_lease_payment))
    drop(table(:fls_lease))
  end
end
