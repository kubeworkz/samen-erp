defmodule SamenCore.TestRepo.Migrations.AddJournalApprovalSteps do
  @moduledoc """
  Adds the optional ordered approver chain to the finance fixture's
  `JournalApprovalPolicy`.
  """

  use Samen.Migration

  @resources [SamenCore.Support.FinanceFixture.JournalApprovalPolicy]

  def up do
    alter table(:jap_journal_approval_policy) do
      add(:jap_steps, {:array, :map},
        null: false,
        default: fragment("ARRAY[]::jsonb[]")
      )
    end

    catalog_sync(@resources, only: [:steps])
  end

  def down do
    catalog_sync_down(@resources, only: [:steps])

    alter table(:jap_journal_approval_policy) do
      remove(:jap_steps)
    end
  end
end
