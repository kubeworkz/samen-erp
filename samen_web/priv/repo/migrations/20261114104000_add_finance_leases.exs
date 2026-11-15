defmodule Samen.WebTest.Repo.Migrations.AddFinanceLeases do
  @moduledoc """
  Lease accounting on the `samen_web` test host (`Samen.WebTest.Erp`,
  `Lease` `ewl`, `LeasePayment` `elw`). Same derived schedule and
  append-only/exactly-once belts as the core fixture.
  """

  use Samen.Migration

  @resources [
    Samen.WebTest.Erp.Lease,
    Samen.WebTest.Erp.LeasePayment
  ]

  def up do
    create table(:ewl_lease, primary_key: false) do
      add(:ewl_code, :text, null: false)
      add(:ewl_name, :text, null: false)
      add(:ewl_memo, :text)
      add(:ewl_source_key, :text)
      add(:ewl_source_id, :uuid)
      add(:ewl_kind, :text, null: false)
      add(:ewl_start_on, :date, null: false)
      add(:ewl_months, :integer, null: false)
      add(:ewl_payment_cents, :bigint, null: false)
      add(:ewl_annual_rate_bps, :integer, null: false, default: 0)
      add(:ewl_dimension_key, :text, null: false, default: "project")
      add(:ewl_initial_entry_id, :uuid)

      add(
        :ewl_rou_asset_account_id,
        references(:fca_account,
          column: :fca_id,
          name: "ewl_lease_ewl_rou_asset_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :ewl_accumulated_amortization_account_id,
        references(:fca_account,
          column: :fca_id,
          name: "ewl_lease_ewl_accumulated_amortization_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :ewl_lease_liability_account_id,
        references(:fca_account,
          column: :fca_id,
          name: "ewl_lease_ewl_lease_liability_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :ewl_interest_expense_account_id,
        references(:fca_account,
          column: :fca_id,
          name: "ewl_lease_ewl_interest_expense_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :ewl_amortization_expense_account_id,
        references(:fca_account,
          column: :fca_id,
          name: "ewl_lease_ewl_amortization_expense_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :ewl_cash_account_id,
        references(:fca_account,
          column: :fca_id,
          name: "ewl_lease_ewl_cash_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :ewl_cost_object_id,
        references(:fco_cost_object,
          column: :fco_id,
          name: "ewl_lease_ewl_cost_object_id_fkey",
          type: :uuid
        )
      )

      add(:ewl_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ewl_org_id, :uuid, null: false)
      add(:ewl_inserted_at, :utc_datetime, null: false)
      add(:ewl_updated_at, :utc_datetime, null: false)
    end

    create(index(:ewl_lease, [:ewl_org_id]))
    create(index(:ewl_lease, [:ewl_rou_asset_account_id]))
    create(index(:ewl_lease, [:ewl_accumulated_amortization_account_id]))
    create(index(:ewl_lease, [:ewl_lease_liability_account_id]))
    create(index(:ewl_lease, [:ewl_interest_expense_account_id]))
    create(index(:ewl_lease, [:ewl_amortization_expense_account_id]))
    create(index(:ewl_lease, [:ewl_cash_account_id]))
    create(index(:ewl_lease, [:ewl_cost_object_id]))
    create(unique_index(:ewl_lease, [:ewl_org_id, :ewl_code], name: :ewl_code_unique))

    create(constraint(:ewl_lease, :ewl_kind_valid, check: "ewl_kind IN ('office','lab')"))

    create(
      constraint(:ewl_lease, :ewl_dimension_key_valid,
        check: "ewl_dimension_key IN ('project','lot','fund','cost_pool')"
      )
    )

    create(
      constraint(:ewl_lease, :ewl_amounts_valid,
        check:
          "ewl_payment_cents > 0 AND ewl_months > 0 AND ewl_annual_rate_bps >= 0 AND ewl_payment_cents >= ewl_months"
      )
    )

    create(
      constraint(:ewl_lease, :ewl_source_pair_valid,
        check: "(ewl_source_key IS NULL) = (ewl_source_id IS NULL)"
      )
    )

    create table(:elw_lease_payment, primary_key: false) do
      add(:elw_period_key, :text, null: false)
      add(:elw_payment_cents, :bigint, null: false)
      add(:elw_interest_cents, :bigint, null: false)
      add(:elw_principal_cents, :bigint, null: false)
      add(:elw_amortization_cents, :bigint, null: false)
      add(:elw_paid_on, :date, null: false)

      add(
        :elw_lease_id,
        references(:ewl_lease,
          column: :ewl_id,
          name: "elw_lease_payment_elw_lease_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :elw_lease_liability_account_id,
        references(:fca_account,
          column: :fca_id,
          name: "elw_lease_payment_elw_lease_liability_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :elw_interest_expense_account_id,
        references(:fca_account,
          column: :fca_id,
          name: "elw_lease_payment_elw_interest_expense_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :elw_amortization_expense_account_id,
        references(:fca_account,
          column: :fca_id,
          name: "elw_lease_payment_elw_amortization_expense_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :elw_accumulated_amortization_account_id,
        references(:fca_account,
          column: :fca_id,
          name: "elw_lease_payment_elw_accumulated_amortization_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(
        :elw_cash_account_id,
        references(:fca_account,
          column: :fca_id,
          name: "elw_lease_payment_elw_cash_account_id_fkey",
          type: :uuid
        ),
        null: false
      )

      add(:elw_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:elw_org_id, :uuid, null: false)
      add(:elw_inserted_at, :utc_datetime, null: false)
      add(:elw_updated_at, :utc_datetime, null: false)
    end

    create(index(:elw_lease_payment, [:elw_org_id]))
    create(index(:elw_lease_payment, [:elw_lease_id]))
    create(index(:elw_lease_payment, [:elw_period_key]))

    create(
      unique_index(:elw_lease_payment, [:elw_org_id, :elw_lease_id, :elw_period_key],
        name: :elw_period_unique
      )
    )

    create(
      constraint(:elw_lease_payment, :elw_period_valid,
        check: "elw_period_key ~ '^[0-9]{4}-(0[1-9]|1[0-2])$'"
      )
    )

    create(
      constraint(:elw_lease_payment, :elw_amounts_valid,
        check:
          "elw_payment_cents > 0 AND elw_interest_cents >= 0 AND elw_principal_cents >= 0 AND elw_amortization_cents >= 0"
      )
    )

    execute(
      """
      CREATE FUNCTION elw_lease_payment_append_only() RETURNS trigger
      LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'elw_lease_payment: % is refused — a lease payment is an '
          'append-only fact; a correction is a reversing entry, never a rewrite. '
          'Payment id: %', TG_OP, OLD.elw_id;
      END;
      $$;
      """,
      "DROP FUNCTION IF EXISTS elw_lease_payment_append_only()"
    )

    execute(
      """
      CREATE TRIGGER elw_lease_payment_append_only_tg
      BEFORE UPDATE OR DELETE ON elw_lease_payment
      FOR EACH ROW EXECUTE FUNCTION elw_lease_payment_append_only()
      """,
      "DROP TRIGGER IF EXISTS elw_lease_payment_append_only_tg ON elw_lease_payment"
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    execute("DROP TRIGGER IF EXISTS elw_lease_payment_append_only_tg ON elw_lease_payment")
    execute("DROP FUNCTION IF EXISTS elw_lease_payment_append_only()")

    drop(table(:elw_lease_payment))
    drop(table(:ewl_lease))
  end
end
