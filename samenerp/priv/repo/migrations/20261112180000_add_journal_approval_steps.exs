defmodule Samenerp.Repo.Migrations.AddJournalApprovalSteps do
  @moduledoc """
  Adds the optional ordered approver chain to the ERP host's
  `JournalApprovalPolicy`. Empty steps preserve the single-distinct-approver
  behavior.
  """

  use Samen.Migration

  @resources [Samenerp.Erp.JournalApprovalPolicy]

  def up do
    alter table(:ejp_journal_approval_policy) do
      add(:ejp_steps, {:array, :map},
        null: false,
        default: fragment("ARRAY[]::jsonb[]")
      )
    end

    catalog_sync(@resources, only: [:steps])
  end

  def down do
    catalog_sync_down(@resources, only: [:steps])

    alter table(:ejp_journal_approval_policy) do
      remove(:ejp_steps)
    end
  end
end
