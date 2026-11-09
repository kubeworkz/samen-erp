defmodule Samenerp.Repo.Migrations.AddJournalApproval do
  @moduledoc """
  Journal approval + segregation of duties (WS-ACCT journal controls) for the
  ERP host's `ecj_journal_entry` and `ejp_journal_approval_policy`.
  """

  use Samen.Migration

  @resources [Samenerp.Erp.JournalApprovalPolicy]

  def up do
    alter table(:ecj_journal_entry) do
      add(:ecj_prepared_by, :text)
      add(:ecj_approved_by, :text)
      add(:ecj_approved_at, :utc_datetime)
      add(:ecj_approval_id, :uuid)
    end

    create table(:ejp_journal_approval_policy, primary_key: false) do
      add(:ejp_org_id, :uuid, null: false)
      add(:ejp_enabled, :boolean, null: false, default: true)
      add(:ejp_threshold_cents, :bigint, null: false, default: 0)
      add(:ejp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ejp_inserted_at, :utc_datetime, null: false)
      add(:ejp_updated_at, :utc_datetime, null: false)
    end

    create(
      unique_index(:ejp_journal_approval_policy, [:ejp_org_id],
        name: :ejp_journal_approval_policy_org_idx
      )
    )

    execute(
      """
      ALTER TABLE ejp_journal_approval_policy
        ADD CONSTRAINT ejp_threshold_non_negative CHECK (ejp_threshold_cents >= 0)
      """,
      "ALTER TABLE ejp_journal_approval_policy DROP CONSTRAINT ejp_threshold_non_negative"
    )

    catalog_sync(@resources)

    catalog_sync([Samenerp.Erp.JournalEntry],
      only: [:prepared_by, :approved_by, :approved_at, :approval_id]
    )
  end

  def down do
    catalog_sync_down([Samenerp.Erp.JournalEntry],
      only: [:prepared_by, :approved_by, :approved_at, :approval_id]
    )

    catalog_sync_down(@resources)

    drop(constraint(:ejp_journal_approval_policy, :ejp_threshold_non_negative))

    drop(table(:ejp_journal_approval_policy))

    alter table(:ecj_journal_entry) do
      remove(:ecj_prepared_by)
      remove(:ecj_approved_by)
      remove(:ecj_approved_at)
      remove(:ecj_approval_id)
    end
  end
end
