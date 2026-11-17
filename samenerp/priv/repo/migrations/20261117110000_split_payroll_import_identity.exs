defmodule Samenerp.Repo.Migrations.SplitPayrollImportIdentity do
  @moduledoc """
  Keep conflict history when a later amendment imports the same payroll line set.

  The original unique index covered every status, so a conflict row from the
  old hard-stop path would block the replacement import even though the two
  rows describe different outcomes. The identity is now unique per status:
  one imported row and one conflict row may coexist; superseded rows are free
  to accumulate as the revision chain.
  """

  use Samen.Migration

  @identity [
    :esp_org_id,
    :esp_provider,
    :esp_external_id,
    :esp_line_set_hash,
    :esp_entry_date
  ]

  def up do
    drop(index(:esp_payroll_import, @identity, name: :esp_payroll_import_unique))

    create(
      unique_index(:esp_payroll_import, @identity,
        name: :esp_payroll_import_imported_unique,
        where: "esp_status = 'imported'"
      )
    )

    create(
      unique_index(:esp_payroll_import, @identity,
        name: :esp_payroll_import_conflict_unique,
        where: "esp_status = 'conflict'"
      )
    )
  end

  def down do
    drop(index(:esp_payroll_import, @identity, name: :esp_payroll_import_imported_unique))

    drop(index(:esp_payroll_import, @identity, name: :esp_payroll_import_conflict_unique))

    create(unique_index(:esp_payroll_import, @identity, name: :esp_payroll_import_unique))
  end
end
