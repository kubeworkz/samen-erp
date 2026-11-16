defmodule Samenerp.Repo.Migrations.AddPayrollAccountMapping do
  @moduledoc """
  Per-provider payroll account mapping for the host: a provider's external
  account code resolves to one same-org `Samenerp.Erp.Account`.

  The table stores configuration only — provider identity, external code, org
  and account. It holds no payroll amounts, employee data or raw provider
  payloads.
  """

  use Samen.Migration

  @resources [Samenerp.Erp.PayrollAccountMapping]

  def up do
    create table(:pse_payroll_account_mapping, primary_key: false) do
      add(:pse_provider, :text, null: false)
      add(:pse_external_code, :text, null: false)
      add(:pse_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:pse_org_id, :uuid, null: false)
      add(:pse_inserted_at, :utc_datetime, null: false)
      add(:pse_updated_at, :utc_datetime, null: false)

      add(
        :pse_account_id,
        references(:eca_account,
          column: :eca_id,
          name: "pse_payroll_account_mapping_pse_account_id_fkey",
          type: :uuid
        ),
        null: false
      )
    end

    create(index(:pse_payroll_account_mapping, [:pse_org_id]))
    create(index(:pse_payroll_account_mapping, [:pse_account_id]))

    create(
      unique_index(
        :pse_payroll_account_mapping,
        [:pse_org_id, :pse_provider, :pse_external_code],
        name: :pse_payroll_account_mapping_unique
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(table(:pse_payroll_account_mapping))
  end
end
