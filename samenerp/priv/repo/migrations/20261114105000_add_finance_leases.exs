defmodule Samenerp.Repo.Migrations.AddFinanceLeases do
  @moduledoc """
  Lease accounting on the Kubeworkz books (`Samenerp.Erp`, `Lease` `els`,
  `LeasePayment` `lse`). The host has no office/lab lease rows yet; this
  migration opens the contract/payment tables so an operator can record one
  without a second schema change.
  """

  use Samen.Migration

  @resources [
    Samenerp.Erp.Lease,
    Samenerp.Erp.LeasePayment
  ]

  def up do
    create table(:els_lease, primary_key: false) do
      add(:els_code, :text, null: false)
      add(:els_name, :text, null: false)
      add(:els_memo, :text)
      add(:els_source_key, :text)
      add(:els_source_id, :uuid)
      add(:els_kind, :text, null: false)
      add(:els_start_on, :date, null: false)
      add(:els_months, :integer, null: false)
      add(:els_payment_cents, :bigint, null: false)
      add(:els_annual_rate_bps, :integer, null: false, default: 0)
      add(:els_dimension_key, :text, null: false, default: "project")
      add(:els_initial_entry_id, :uuid)

      add(
        :els_rou_asset_account_id,
        references(:eca_account,
          column: :eca_id,
          name: "els_lease_els_rou_asset_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :els_accumulated_amortization_account_id,
        references(:eca_account,
          column: :eca_id,
          name: "els_lease_els_accumulated_amortization_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :els_lease_liability_account_id,
        references(:eca_account,
          column: :eca_id,
          name: "els_lease_els_lease_liability_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :els_interest_expense_account_id,
        references(:eca_account,
          column: :eca_id,
          name: "els_lease_els_interest_expense_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :els_amortization_expense_account_id,
        references(:eca_account,
          column: :eca_id,
          name: "els_lease_els_amortization_expense_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :els_cash_account_id,
        references(:eca_account,
          column: :eca_id,
          name: "els_lease_els_cash_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :els_cost_object_id,
        references(:eco_cost_object,
          column: :eco_id,
          name: "els_lease_els_cost_object_id_fkey",
          type: :uuid
        )
      )

      add(:els_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:els_org_id, :uuid, null: false)
      add(:els_inserted_at, :utc_datetime, null: false)
      add(:els_updated_at, :utc_datetime, null: false)
    end

    create(index(:els_lease, [:els_org_id]))
    create(index(:els_lease, [:els_rou_asset_account_id]))
    create(index(:els_lease, [:els_accumulated_amortization_account_id]))
    create(index(:els_lease, [:els_lease_liability_account_id]))
    create(index(:els_lease, [:els_interest_expense_account_id]))
    create(index(:els_lease, [:els_amortization_expense_account_id]))
    create(index(:els_lease, [:els_cash_account_id]))
    create(index(:els_lease, [:els_cost_object_id]))
    create(unique_index(:els_lease, [:els_org_id, :els_code], name: :els_code_unique))

    create(constraint(:els_lease, :els_kind_valid, check: "els_kind IN ('office','lab')"))

    create(
      constraint(:els_lease, :els_dimension_key_valid,
        check: "els_dimension_key IN ('project','lot','fund','cost_pool')"
      )
    )

    create(
      constraint(:els_lease, :els_amounts_valid,
        check:
          "els_payment_cents > 0 AND els_months > 0 AND els_annual_rate_bps >= 0 AND els_payment_cents >= els_months"
      )
    )

    create(
      constraint(:els_lease, :els_source_pair_valid,
        check: "(els_source_key IS NULL) = (els_source_id IS NULL)"
      )
    )

    create table(:lse_lease_payment, primary_key: false) do
      add(:lse_period_key, :text, null: false)
      add(:lse_payment_cents, :bigint, null: false)
      add(:lse_interest_cents, :bigint, null: false)
      add(:lse_principal_cents, :bigint, null: false)
      add(:lse_amortization_cents, :bigint, null: false)
      add(:lse_paid_on, :date, null: false)

      add(
        :lse_lease_id,
        references(:els_lease,
          column: :els_id,
          name: "lse_lease_payment_lse_lease_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :lse_lease_liability_account_id,
        references(:eca_account,
          column: :eca_id,
          name: "lse_lease_payment_lse_lease_liability_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :lse_interest_expense_account_id,
        references(:eca_account,
          column: :eca_id,
          name: "lse_lease_payment_lse_interest_expense_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :lse_amortization_expense_account_id,
        references(:eca_account,
          column: :eca_id,
          name: "lse_lease_payment_lse_amortization_expense_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :lse_accumulated_amortization_account_id,
        references(:eca_account,
          column: :eca_id,
          name: "lse_lease_payment_lse_accumulated_amortization_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :lse_cash_account_id,
        references(:eca_account,
          column: :eca_id,
          name: "lse_lease_payment_lse_cash_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:lse_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:lse_org_id, :uuid, null: false)
      add(:lse_inserted_at, :utc_datetime, null: false)
      add(:lse_updated_at, :utc_datetime, null: false)
    end

    create(index(:lse_lease_payment, [:lse_org_id]))
    create(index(:lse_lease_payment, [:lse_lease_id]))
    create(index(:lse_lease_payment, [:lse_period_key]))

    create(
      unique_index(:lse_lease_payment, [:lse_org_id, :lse_lease_id, :lse_period_key],
        name: :lse_period_unique
      )
    )

    create(
      constraint(:lse_lease_payment, :lse_period_valid,
        check: "lse_period_key ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'"
      )
    )

    create(
      constraint(:lse_lease_payment, :lse_amounts_valid,
        check:
          "lse_payment_cents > 0 AND lse_interest_cents >= 0 AND lse_principal_cents >= 0 AND lse_amortization_cents >= 0"
      )
    )

    execute(
      """
      CREATE FUNCTION lse_lease_payment_append_only() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'lse_lease_payment: % is refused — a lease payment is an '
          'append-only fact; a correction is a reversing entry, never a rewrite. '
          'Payment id: %', TG_OP, OLD.lse_id;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS lse_lease_payment_append_only()"
    )

    execute(
      """
      CREATE TRIGGER lse_lease_payment_append_only_tg
      BEFORE UPDATE OR DELETE ON lse_lease_payment
      FOR EACH ROW EXECUTE FUNCTION lse_lease_payment_append_only()
      """,
      "DROP TRIGGER IF EXISTS lse_lease_payment_append_only_tg ON lse_lease_payment"
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute("DROP TRIGGER IF EXISTS lse_lease_payment_append_only_tg ON lse_lease_payment")
    execute("DROP FUNCTION IF EXISTS lse_lease_payment_append_only()")

    drop(table(:lse_lease_payment))
    drop(table(:els_lease))
  end
end
