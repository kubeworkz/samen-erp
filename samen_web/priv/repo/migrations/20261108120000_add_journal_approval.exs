defmodule Samen.WebTest.Repo.Migrations.AddJournalApproval do
  @moduledoc """
  Journal approval + segregation of duties (WS-ACCT journal controls) for the
  web host's `fje_journal_entry` and `wja_journal_approval_policy`.
  """

  use Samen.Migration

  @resources [Samen.WebTest.Erp.JournalApprovalPolicy]

  def up do
    alter table(:fje_journal_entry) do
      add(:fje_prepared_by, :text)
      add(:fje_approved_by, :text)
      add(:fje_approved_at, :utc_datetime)
      add(:fje_approval_id, :uuid)
    end

    create table(:wja_journal_approval_policy, primary_key: false) do
      add(:wja_org_id, :uuid, null: false)
      add(:wja_enabled, :boolean, null: false, default: true)
      add(:wja_threshold_cents, :bigint, null: false, default: 0)
      add(:wja_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wja_inserted_at, :utc_datetime, null: false)
      add(:wja_updated_at, :utc_datetime, null: false)
    end

    create(
      unique_index(:wja_journal_approval_policy, [:wja_org_id],
        name: :wja_journal_approval_policy_org_idx
      )
    )

    execute(
      """
      ALTER TABLE wja_journal_approval_policy
        ADD CONSTRAINT wja_threshold_non_negative CHECK (wja_threshold_cents >= 0)
      """,
      "ALTER TABLE wja_journal_approval_policy DROP CONSTRAINT wja_threshold_non_negative"
    )

    catalog_sync(@resources)

    catalog_sync([Samen.WebTest.Erp.JournalEntry],
      only: [:prepared_by, :approved_by, :approved_at, :approval_id]
    )
  end

  def down do
    catalog_sync_down([Samen.WebTest.Erp.JournalEntry],
      only: [:prepared_by, :approved_by, :approved_at, :approval_id]
    )

    catalog_sync_down(@resources)

    drop(constraint(:wja_journal_approval_policy, :wja_threshold_non_negative))

    drop(table(:wja_journal_approval_policy))

    alter table(:fje_journal_entry) do
      remove(:fje_prepared_by)
      remove(:fje_approved_by)
      remove(:fje_approved_at)
      remove(:fje_approval_id)
    end
  end
end
