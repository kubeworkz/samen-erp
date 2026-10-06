defmodule Samenerp.Repo.Migrations.AddWorkScope do
  @moduledoc """
  Mounts the Work universal scope (F1, ADR-041 §3) into the samenerp host and
  catalogs every resource in the SAME migration transaction (ADR-004
  catalog-in-tx). Mirrors `demo/priv/repo/migrations/20260727150000_add_work_scope.exs`
  field-for-field, on THIS host's allocator-reserved abbrevs (`wsp`/`wst` — demo
  owns the scope-default `wpj`/`wtk`; ADR-023 one-owner-per-namespace).

    * `wsp_project` — a container noun (name/status/owner). No PII.
    * `wst_task`    — the canonical Task (ADR-041 §3.2, field-for-field): kind,
      title, body, status (plain enum), priority (`Samen.Type.Priority`, stored as
      an integer RANK — low=10/normal=20/high=30/urgent=40), due_at, completed_at,
      the generic `(subject_key, subject_id)` object-ref anchor, custom, owner_id,
      self-referential parent_id (the Subtask tree, cycle-refused at the Ash change
      level), project_id. No PII.

  Both tables carry `<abbrev>_archived_at` (ADR-040 §5.9 — archivable true).
  """
  use Samen.Migration

  @resources [
    Samenerp.Work.Project,
    Samenerp.Work.Task
  ]

  def up do
    create table(:wsp_project, primary_key: false) do
      add(:wsp_name, :text, null: false)
      add(:wsp_status, :text, default: "active")
      add(:wsp_owner_id, :uuid)
      add(:wsp_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wsp_org_id, :uuid, null: false)
      add(:wsp_inserted_at, :utc_datetime, null: false)
      add(:wsp_updated_at, :utc_datetime, null: false)
      add(:wsp_archived_at, :utc_datetime_usec)
    end

    create(index(:wsp_project, [:wsp_org_id]))

    create table(:wst_task, primary_key: false) do
      add(:wst_kind, :text, default: "task")
      add(:wst_title, :text)
      add(:wst_body, :text)
      add(:wst_status, :text, default: "pending")
      add(:wst_priority, :integer, default: 20)
      add(:wst_due_at, :utc_datetime)
      add(:wst_completed_at, :utc_datetime)
      add(:wst_subject_key, :text)
      add(:wst_subject_id, :uuid)
      add(:wst_custom, :map, default: fragment("'{}'::jsonb"))
      add(:wst_owner_id, :uuid)
      add(:wst_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:wst_org_id, :uuid, null: false)
      add(:wst_inserted_at, :utc_datetime, null: false)
      add(:wst_updated_at, :utc_datetime, null: false)
      add(:wst_archived_at, :utc_datetime_usec)

      add(
        :wst_parent_id,
        references(:wst_task,
          column: :wst_id,
          name: "wst_task_wst_parent_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )

      add(
        :wst_project_id,
        references(:wsp_project,
          column: :wsp_id,
          name: "wst_task_wsp_project_id_fkey",
          type: :uuid,
          prefix: "public"
        )
      )
    end

    create(index(:wst_task, [:wst_org_id]))
    create(index(:wst_task, [:wst_parent_id]))
    create(index(:wst_task, [:wst_project_id]))
    create(index(:wst_task, [:wst_subject_key, :wst_subject_id]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)

    drop(constraint(:wst_task, "wst_task_wsp_project_id_fkey"))
    drop(constraint(:wst_task, "wst_task_wst_parent_id_fkey"))
    drop(table(:wst_task))
    drop(table(:wsp_project))
  end
end
