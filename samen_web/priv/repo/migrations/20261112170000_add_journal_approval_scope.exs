defmodule Samen.WebTest.Repo.Migrations.AddJournalApprovalScope do
  @moduledoc """
  Adds the optional account/period scope to the web test host's
  `JournalApprovalPolicy`.
  """

  use Samen.Migration

  @resources [Samen.WebTest.Erp.JournalApprovalPolicy]

  def up do
    alter table(:wja_journal_approval_policy) do
      add(:wja_account_ids, {:array, :uuid}, null: false, default: [])
      add(:wja_period_keys, {:array, :text}, null: false, default: [])
    end

    catalog_sync(@resources, only: [:account_ids, :period_keys])
  end

  def down do
    catalog_sync_down(@resources, only: [:account_ids, :period_keys])

    alter table(:wja_journal_approval_policy) do
      remove(:wja_account_ids)
      remove(:wja_period_keys)
    end
  end
end
