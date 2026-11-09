defmodule SamenCore.TestRepo.Migrations.AddJournalApproval do
  @moduledoc """
  Journal approval + segregation of duties (WS-ACCT journal controls).

  Adds the preparer/approver evidence columns to the finance fixture's journal
  entry and the one-per-org `JournalApprovalPolicy`.
  """

  use Samen.Migration

  @resources [SamenCore.Support.FinanceFixture.JournalApprovalPolicy]

  def up do
    alter table(:sje_journal_entry) do
      add(:sje_prepared_by, :text)
      add(:sje_approved_by, :text)
      add(:sje_approved_at, :utc_datetime)
      add(:sje_approval_id, :uuid)
    end

    create table(:jap_journal_approval_policy, primary_key: false) do
      add(:jap_org_id, :uuid, null: false)
      add(:jap_enabled, :boolean, null: false, default: true)
      add(:jap_threshold_cents, :bigint, null: false, default: 0)
      add(:jap_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:jap_inserted_at, :utc_datetime, null: false)
      add(:jap_updated_at, :utc_datetime, null: false)
    end

    create(
      unique_index(:jap_journal_approval_policy, [:jap_org_id],
        name: :jap_journal_approval_policy_org_idx
      )
    )

    execute(
      """
      ALTER TABLE jap_journal_approval_policy
        ADD CONSTRAINT jap_threshold_non_negative CHECK (jap_threshold_cents >= 0)
      """,
      "ALTER TABLE jap_journal_approval_policy DROP CONSTRAINT jap_threshold_non_negative"
    )

    catalog_sync(@resources)

    catalog_sync([SamenCore.Support.FinanceFixture.JournalEntry],
      only: [:prepared_by, :approved_by, :approved_at, :approval_id]
    )
  end

  def down do
    catalog_sync_down([SamenCore.Support.FinanceFixture.JournalEntry],
      only: [:prepared_by, :approved_by, :approved_at, :approval_id]
    )

    catalog_sync_down(@resources)

    drop(constraint(:jap_journal_approval_policy, :jap_threshold_non_negative))

    drop(table(:jap_journal_approval_policy))

    alter table(:sje_journal_entry) do
      remove(:sje_prepared_by)
      remove(:sje_approved_by)
      remove(:sje_approved_at)
      remove(:sje_approval_id)
    end
  end
end
