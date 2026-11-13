defmodule Samen.WebTest.Repo.Migrations.AddFinanceJournalTemplates do
  @moduledoc """
  The web test host's reusable/recurring journal templates and the partial
  unique index on generated journal drafts.
  """

  use Samen.Migration

  @resources [Samen.WebTest.Erp.JournalTemplate]

  def up do
    create table(:fjr_journal_template, primary_key: false) do
      add(:fjr_name, :text, null: false)
      add(:fjr_memo, :text)
      add(:fjr_frequency, :text, null: false, default: "none")
      add(:fjr_next_run_on, :date)
      add(:fjr_active, :boolean, null: false, default: true)
      add(:fjr_lines, :map, null: false, default: fragment("'[]'::jsonb"))
      add(:fjr_last_generated_on, :date)
      add(:fjr_last_entry_id, :uuid)
      add(:fjr_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:fjr_org_id, :uuid, null: false)
      add(:fjr_inserted_at, :utc_datetime, null: false)
      add(:fjr_updated_at, :utc_datetime, null: false)
    end

    create(index(:fjr_journal_template, [:fjr_org_id]))

    create(
      unique_index(:fjr_journal_template, [:fjr_org_id, :fjr_name],
        name: :fjr_journal_template_unique
      )
    )

    create(
      constraint(:fjr_journal_template, :fjr_frequency_valid,
        check: "fjr_frequency IN ('none','weekly','monthly','quarterly','yearly')"
      )
    )

    create(
      constraint(:fjr_journal_template, :fjr_lines_array,
        check: "jsonb_typeof(fjr_lines) = 'array'"
      )
    )

    create(
      unique_index(
        :fje_journal_entry,
        [:fje_org_id, :fje_source_id, :fje_entry_date],
        where: "fje_source_key = 'journal_template'",
        name: :fje_journal_template_instance_unique
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(
      index(
        :fje_journal_entry,
        [:fje_org_id, :fje_source_id, :fje_entry_date],
        name: :fje_journal_template_instance_unique
      )
    )

    drop(table(:fjr_journal_template))
  end
end
