defmodule Samenerp.Repo.Migrations.AddAnalyticsScope do
  @moduledoc """
  WS-B / G12 (ADR-021): the governed, token-blind product-analytics event ledger
  (`sae`) — `Samenerp.Analytics.ProductEvent`, the host mount of the Analytics scope
  on driftwood's `AddAnalyticsScope` (`fae`) pattern. Catalogued in the SAME
  transaction (ADR-004 catalog-in-tx).

  ## Why this migration exists

  Phase 3 (migration `20261006140000`) created the RAW rollup tables the analytics
  surfaces READ — `paf_product_event_rollup` among them — and recorded, explicitly,
  that Samenerp shipped no product-event ledger to source them: "the tables start
  EMPTY and every reader renders its honest empty/zero state … Registering the specs
  is the host's follow-on once a ledger exists."

  This is that follow-on. The `paf_product_event_rollup` funnel/retention rows are
  derived by the domain-sourced `:product_event_rollup` spec in
  `config/config.exs`, whose `rebuild_sql` reads the ledger created here. Without a
  ledger the funnel cannot be non-empty no matter how much activity the org has, so
  the tenant `/analytics` surface was permanently empty — honest, but useless.

  Token-blind by construction: every column is a bounded id (uuid), a bounded enum
  (`sae_event_name`/`sae_event_kind` as text), a per-subject HMAC pseudonym token
  (`sae_actor_ref`), an opaque bounded ref (`sae_entity_ref`), a bounded map
  (`sae_props`), or a timestamp — NO PII column. Rows are appended ONLY by
  `Samen.Analytics.track/1`, which refuses PII at capture (ADR-021 §5), and the
  framework emitter is wired in config (`product_event_resource:`), so the events
  the app already fires (sign-in · first-run · record create · search · flag
  assignment) reach it.
  """
  use Samen.Migration

  @resources [Samenerp.Analytics.ProductEvent]

  def up do
    create table(:sae_product_event, primary_key: false) do
      add(:sae_actor_ref, :text)
      add(:sae_event_name, :text, null: false)
      add(:sae_entity_ref, :text)
      add(:sae_event_kind, :text)
      add(:sae_props, :map, null: false, default: "{}")
      add(:sae_occurred_at, :utc_datetime, null: false)
      add(:sae_id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:sae_org_id, :uuid, null: false)
      add(:sae_inserted_at, :utc_datetime, null: false)
      add(:sae_updated_at, :utc_datetime, null: false)
    end

    # Read paths filter by (org_id, event_name, occurred_at) for the funnel /
    # retention rollup rebuild (ADR-021 B8). A bounded, non-PII composite index.
    create index(:sae_product_event, [:sae_org_id, :sae_event_name, :sae_occurred_at])

    catalog_sync(@resources)
  end

  def down do
    catalog_sync_down(@resources)
    drop(table(:sae_product_event))
  end
end
