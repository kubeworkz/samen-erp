defmodule Samenerp.Repo.Migrations.MountCalendarScope do
  @moduledoc """
  Phase 6 — mounts the framework Calendar scope (F2, T44) into the Samenerp
  host's Postgres, and catalogs the resource in the SAME migration transaction
  (ADR-004 catalog-in-tx). Fresh mount, so the whole scope lands at once;
  mirrors the demo host's `AddCalendarScope` and this host's own
  `MountCmsScope`.

    * `evt_event` — Event/Meeting (`kind` distinguishes): start/end, 🔒
      vaulted `attendees` (`Samen.Type.Emails`, `vault: :pii_attendees`, no
      `pii_` prefix — the composite convention), `location`, an optional
      `recurrence` rule (a plain jsonb map, expanded via
      `Samen.Scopes.Calendar.Recurrence.expand/4,5`). Archivable (ADR-040 §5.9).

  ## Abbrev

  `evt` (`Samenerp.Calendar.Event`) — reserved through
  `mix samen.abbrev.reserve` under host `samenerp` (ADR-023), never
  hand-edited.

  ## PII

  Exactly one 🔒 object: the composite `evt_attendees` column, which holds an
  opaque `vt_*` vault token at rest and resolves per plane through
  `Samen.Api.PiiResolution`. It carries no `pii_` prefix (the composite
  convention — the vault name, not a column prefix, is the routing key), so
  `no_pii_columns` stays green because the column is a token, not plaintext.
  """
  use Samen.Migration

  @resources [
    Samenerp.Calendar.Event
  ]

  def up do
    create table(:evt_event, primary_key: false) do
      add(:evt_kind, :text, default: "event")
      add(:evt_title, :text)
      add(:evt_description, :text)
      add(:evt_starts_at, :utc_datetime_usec, null: false)
      add(:evt_ends_at, :utc_datetime_usec)
      add(:evt_location, :text)
      add(:evt_timezone, :text, default: "Etc/UTC")
      add(:evt_recurrence, :map)
      add(:evt_custom, :map)
      add(:evt_owner_id, :uuid)
      # Composite PII vault token: attendees routes by vault name (no pii_ prefix).
      add(:evt_attendees, :text)
      add(:evt_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:evt_org_id, :uuid, null: false)
      add(:evt_inserted_at, :utc_datetime, null: false)
      add(:evt_updated_at, :utc_datetime, null: false)
      add(:evt_archived_at, :utc_datetime_usec)
    end

    create(index(:evt_event, [:evt_org_id]))
    create(index(:evt_event, [:evt_starts_at]))

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:evt_event))
  end
end
