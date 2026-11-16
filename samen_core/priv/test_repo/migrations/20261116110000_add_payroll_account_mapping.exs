defmodule SamenCore.TestRepo.Migrations.AddPayrollAccountMapping do
  @moduledoc """
  Per-provider payroll account mapping for the core fixture: a provider's
  external account code resolves to one same-org `Finance.Account`.

  The table stores configuration only — provider identity, external code, org
  and account. It holds no payroll amounts, employee data or raw provider
  payloads.
  """

  use Samen.Migration

  @resources [SamenCore.Support.FinanceFixture.PayrollAccountMapping]

  def up do
    create table(:aab_payroll_account_mapping, primary_key: false) do
      add(:aab_provider, :text, null: false)
      add(:aab_external_code, :text, null: false)
      add(:aab_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:aab_org_id, :uuid, null: false)
      add(:aab_inserted_at, :utc_datetime, null: false)
      add(:aab_updated_at, :utc_datetime, null: false)

      add(
        :aab_account_id,
        references(:sac_account,
          column: :sac_id,
          name: "aab_payroll_account_mapping_aab_account_id_fkey",
          type: :uuid
        ),
        null: false
      )
    end

    create(index(:aab_payroll_account_mapping, [:aab_org_id]))
    create(index(:aab_payroll_account_mapping, [:aab_account_id]))

    create(
      unique_index(
        :aab_payroll_account_mapping,
        [:aab_org_id, :aab_provider, :aab_external_code],
        name: :aab_payroll_account_mapping_unique
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:aab_payroll_account_mapping))
  end
end
