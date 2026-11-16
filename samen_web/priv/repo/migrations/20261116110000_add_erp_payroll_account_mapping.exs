defmodule Samen.WebTest.Repo.Migrations.AddErpPayrollAccountMapping do
  @moduledoc """
  Per-provider payroll account mapping for the `samen_web` ERP test host: a
  provider's external account code resolves to one same-org
  `Samen.WebTest.Erp.Account`.

  The table stores configuration only — provider identity, external code, org
  and account. It holds no payroll amounts, employee data or raw provider
  payloads.
  """

  use Samen.Migration

  @resources [Samen.WebTest.Erp.PayrollAccountMapping]

  def up do
    create table(:pwe_payroll_account_mapping, primary_key: false) do
      add(:pwe_provider, :text, null: false)
      add(:pwe_external_code, :text, null: false)
      add(:pwe_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pwe_org_id, :uuid, null: false)
      add(:pwe_inserted_at, :utc_datetime, null: false)
      add(:pwe_updated_at, :utc_datetime, null: false)

      add(
        :pwe_account_id,
        references(:fca_account,
          column: :fca_id,
          name: "pwe_payroll_account_mapping_pwe_account_id_fkey",
          type: :uuid
        ),
        null: false
      )
    end

    create(index(:pwe_payroll_account_mapping, [:pwe_org_id]))
    create(index(:pwe_payroll_account_mapping, [:pwe_account_id]))

    create(
      unique_index(
        :pwe_payroll_account_mapping,
        [:pwe_org_id, :pwe_provider, :pwe_external_code],
        name: :pwe_payroll_account_mapping_unique
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:pwe_payroll_account_mapping))
  end
end
