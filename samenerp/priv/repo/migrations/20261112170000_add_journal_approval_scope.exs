defmodule Samenerp.Repo.Migrations.AddJournalApprovalScope do
  @moduledoc """
  Adds the optional account/period scope to the ERP host's
  `JournalApprovalPolicy`.
  """

  use Samen.Migration

  @resources [Samenerp.Erp.JournalApprovalPolicy]

  def up do
    alter table(:ejp_journal_approval_policy) do
      add(:ejp_account_ids, {:array, :uuid}, null: false, default: [])
      add(:ejp_period_keys, {:array, :text}, null: false, default: [])
    end

    catalog_sync(@resources, only: [:account_ids, :period_keys])
  end

  def down do
    catalog_sync_down(@resources, only: [:account_ids, :period_keys])

    alter table(:ejp_journal_approval_policy) do
      remove(:ejp_account_ids)
      remove(:ejp_period_keys)
    end
  end
end
