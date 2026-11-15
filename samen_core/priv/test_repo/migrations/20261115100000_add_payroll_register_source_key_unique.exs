defmodule SamenCore.TestRepo.Migrations.AddPayrollRegisterSourceKeyUnique do
  @moduledoc """
  The database-level exactly-once guarantee for the reference payroll register
  importer. Only payroll keys are constrained; other journal source keys keep
  their existing semantics.
  """

  use Samen.Migration

  @index_name :sje_payroll_register_source_key_unique

  def up do
    create(
      unique_index(:sje_journal_entry, [:sje_org_id, :sje_source_key],
        name: @index_name,
        where: "sje_source_key LIKE 'payroll\\_register:%' ESCAPE '\\'"
      )
    )
  end

  def down do
    drop(index(:sje_journal_entry, [:sje_org_id, :sje_source_key], name: @index_name))
  end
end
