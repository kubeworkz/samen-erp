defmodule Samen.Ingest.EventMigration do
  @moduledoc """
  Shared DDL + catalog rows for the `ing_event` provider-ingestion store.

  Encoded once here so every host migration is a two-line delegate and the
  copies cannot drift (the `Samen.Webhook.EventMigration` precedent). `ing_event`
  is kernel infrastructure backed by a plain `Ecto.Schema` (`Samen.Ingest.Event`),
  not a per-tenant Ash blueprint, so its catalog rows are written by direct
  `execute/2` SQL inside the migration transaction.

  Usage:

      defmodule MyApp.Repo.Migrations.ProviderIngestEvent do
        use Ecto.Migration
        def up, do: Samen.Ingest.EventMigration.up()
        def down, do: Samen.Ingest.EventMigration.down()
      end
  """

  import Ecto.Migration

  @table "ing_event"
  @resource "Samen.Ingest.Event"

  # {physical column, logical name, catalog type}
  @fields [
    {"ing_id", "id", "UUID"},
    {"ing_provider", "provider", "String"},
    {"ing_idempotency_key", "idempotency_key", "String"},
    {"ing_schema_version", "schema_version", "Integer"},
    {"ing_event_id", "event_id", "String"},
    {"ing_event_type", "event_type", "String"},
    {"ing_occurred_at", "occurred_at", "UTCDatetime"},
    {"ing_payload", "payload", "Map"},
    {"ing_payload_digest", "payload_digest", "String"},
    {"ing_status", "status", "String"},
    {"ing_attempt_count", "attempt_count", "Integer"},
    {"ing_max_attempts", "max_attempts", "Integer"},
    {"ing_last_error", "last_error", "String"},
    {"ing_processed_at", "processed_at", "UTCDatetime"},
    {"ing_inserted_at", "inserted_at", "UTCDatetime"}
  ]

  @doc "Create the `ing_event` table, replay/idempotency indexes and catalog rows."
  def up do
    execute(
      """
      CREATE TABLE #{@table} (
        ing_id              UUID        NOT NULL DEFAULT gen_random_uuid(),
        ing_provider        TEXT        NOT NULL,
        ing_idempotency_key TEXT        NOT NULL,
        ing_schema_version  INTEGER     NOT NULL,
        ing_event_id        TEXT        NOT NULL,
        ing_event_type      TEXT        NOT NULL,
        ing_occurred_at     TIMESTAMPTZ NOT NULL,
        ing_payload         JSONB       NOT NULL DEFAULT '{}'::jsonb,
        ing_payload_digest  TEXT        NOT NULL,
        ing_status          TEXT        NOT NULL DEFAULT 'received',
        ing_attempt_count   INTEGER     NOT NULL DEFAULT 0,
        ing_max_attempts    INTEGER     NOT NULL DEFAULT 8,
        ing_last_error      TEXT,
        ing_processed_at    TIMESTAMPTZ,
        ing_inserted_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
        PRIMARY KEY (ing_id)
      )
      """,
      "DROP TABLE IF EXISTS #{@table}"
    )

    # Idempotency arbiter: a sender retry reuses the key and is a safe no-op.
    execute(
      """
      CREATE UNIQUE INDEX ing_event_provider_idempotency_key_index
      ON #{@table} (ing_provider, ing_idempotency_key)
      """,
      "DROP INDEX IF EXISTS ing_event_provider_idempotency_key_index"
    )

    # Replay arbiter: the same provider event under a fresh idempotency key is
    # still a duplicate, not a second effect.
    execute(
      """
      CREATE UNIQUE INDEX ing_event_provider_event_id_index
      ON #{@table} (ing_provider, ing_event_id)
      """,
      "DROP INDEX IF EXISTS ing_event_provider_event_id_index"
    )

    execute(
      """
      CREATE INDEX ing_event_status_inserted_at_index
      ON #{@table} (ing_status, ing_inserted_at DESC)
      """,
      "DROP INDEX IF EXISTS ing_event_status_inserted_at_index"
    )

    execute(
      """
      INSERT INTO tam_table (tam_table_name, tam_resource)
      VALUES ('#{@table}', '#{@resource}')
      ON CONFLICT (tam_table_name) DO NOTHING
      """,
      "DELETE FROM tam_table WHERE tam_table_name = '#{@table}'"
    )

    for {column, logical, type} <- @fields do
      execute(
        """
        INSERT INTO fld_field (fld_table_name, fld_column_name, fld_logical_name, fld_type)
        VALUES ('#{@table}', '#{column}', '#{logical}', '#{type}')
        ON CONFLICT (fld_table_name, fld_column_name) DO NOTHING
        """,
        """
        DELETE FROM fld_field
        WHERE fld_table_name = '#{@table}' AND fld_column_name = '#{column}'
        """
      )
    end
  end

  @doc "Drop the catalog rows, indexes and table (reverse order)."
  def down do
    for {column, _logical, _type} <- Enum.reverse(@fields) do
      execute("""
      DELETE FROM fld_field
      WHERE fld_table_name = '#{@table}' AND fld_column_name = '#{column}'
      """)
    end

    execute("DELETE FROM tam_table WHERE tam_table_name = '#{@table}'")
    execute("DROP INDEX IF EXISTS ing_event_status_inserted_at_index")
    execute("DROP INDEX IF EXISTS ing_event_provider_event_id_index")
    execute("DROP INDEX IF EXISTS ing_event_provider_idempotency_key_index")
    execute("DROP TABLE IF EXISTS #{@table}")
  end
end
