defmodule SamenCore.TestRepo.Migrations.AddFinanceJournalTemplates do
  @moduledoc """
  Reusable/recurring journal templates for the Finance fixture, plus the
  partial unique index that makes generated drafts idempotent per
  `{template, entry_date}`.
  """

  use Samen.Migration

  @resources [SamenCore.Support.FinanceFixture.JournalTemplate]

  def up do
    create table(:sjt_journal_template, primary_key: false) do
      add(:sjt_name, :text, null: false)
      add(:sjt_memo, :text)
      add(:sjt_frequency, :text, null: false, default: "none")
      add(:sjt_next_run_on, :date)
      add(:sjt_active, :boolean, null: false, default: true)
      add(:sjt_lines, :map, null: false, default: fragment("'[]'::jsonb"))
      add(:sjt_last_generated_on, :date)
      add(:sjt_last_entry_id, :uuid)
      add(:sjt_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sjt_org_id, :uuid, null: false)
      add(:sjt_inserted_at, :utc_datetime, null: false)
      add(:sjt_updated_at, :utc_datetime, null: false)
    end

    create(index(:sjt_journal_template, [:sjt_org_id]))

    create(
      unique_index(:sjt_journal_template, [:sjt_org_id, :sjt_name],
        name: :sjt_journal_template_unique
      )
    )

    create(
      constraint(:sjt_journal_template, :sjt_frequency_valid,
        check: "sjt_frequency IN ('none','weekly','monthly','quarterly','yearly')"
      )
    )

    create(
      constraint(:sjt_journal_template, :sjt_lines_array,
        check: "jsonb_typeof(sjt_lines) = 'array'"
      )
    )

    create(
      unique_index(
        :sje_journal_entry,
        [:sje_org_id, :sje_source_id, :sje_entry_date],
        where: "sje_source_key = 'journal_template'",
        name: :sje_journal_template_instance_unique
      )
    )

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(
      index(
        :sje_journal_entry,
        [:sje_org_id, :sje_source_id, :sje_entry_date],
        name: :sje_journal_template_instance_unique
      )
    )

    drop(table(:sjt_journal_template))
  end
end
