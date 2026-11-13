defmodule Samenerp.Repo.Migrations.AddFinanceJournalTemplates do
  @moduledoc """
  The ERP host's reusable/recurring journal templates and the partial unique
  index on generated journal drafts.
  """

  use Samen.Migration

  @resources [Samenerp.Erp.JournalTemplate]

  def up do
    create table(:ejr_journal_template, primary_key: false) do
      add(:ejr_name, :text, null: false)
      add(:ejr_memo, :text)
      add(:ejr_frequency, :text, null: false, default: "none")
      add(:ejr_next_run_on, :date)
      add(:ejr_active, :boolean, null: false, default: true)
      add(:ejr_lines, :map, null: false, default: fragment("'[]'::jsonb"))
      add(:ejr_last_generated_on, :date)
      add(:ejr_last_entry_id, :uuid)
      add(:ejr_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:ejr_org_id, :uuid, null: false)
      add(:ejr_inserted_at, :utc_datetime, null: false)
      add(:ejr_updated_at, :utc_datetime, null: false)
    end

    create(index(:ejr_journal_template, [:ejr_org_id]))

    create(
      unique_index(:ejr_journal_template, [:ejr_org_id, :ejr_name],
        name: :ejr_journal_template_unique
      )
    )

    create(
      constraint(:ejr_journal_template, :ejr_frequency_valid,
        check: "ejr_frequency IN ('none','weekly','monthly','quarterly','yearly')"
      )
    )

    create(
      constraint(:ejr_journal_template, :ejr_lines_array,
        check: "jsonb_typeof(ejr_lines) = 'array'"
      )
    )

    create(
      unique_index(
        :ecj_journal_entry,
        [:ecj_org_id, :ecj_source_id, :ecj_entry_date],
        where: "ecj_source_key = 'journal_template'",
        name: :ecj_journal_template_instance_unique
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(
      index(
        :ecj_journal_entry,
        [:ecj_org_id, :ecj_source_id, :ecj_entry_date],
        name: :ecj_journal_template_instance_unique
      )
    )

    drop(table(:ejr_journal_template))
  end
end
