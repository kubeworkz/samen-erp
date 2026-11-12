defmodule Samen.WebTest.Repo.Migrations.AddJournalApprovalSteps do
  @moduledoc """
  Adds the optional ordered approver chain to the web test host's
  `JournalApprovalPolicy`.
  """

  use Samen.Migration

  @resources [Samen.WebTest.Erp.JournalApprovalPolicy]

  def up do
    alter table(:wja_journal_approval_policy) do
      add(:wja_steps, {:array, :map},
        null: false,
        default: fragment("ARRAY[]::jsonb[]")
      )
    end

    catalog_sync(@resources, only: [:steps])
  end

  def down do
    catalog_sync_down(@resources, only: [:steps])

    alter table(:wja_journal_approval_policy) do
      remove(:wja_steps)
    end
  end
end
