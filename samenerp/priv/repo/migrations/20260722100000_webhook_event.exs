defmodule Samenerp.Repo.Migrations.WebhookEvent do
  @moduledoc """
  T19/B9: the \`whk_event\` webhook ingress replay-store + DLQ table (ADR-038 §5.3).

  Phase 4 (Integrations) enabler — samenerp mounts \`samen_webhook_routes\` now,
  and the ingress persists its verified envelope through
  \`Samen.Webhook.Event.insert_received/2\` BEFORE any org is attributed (raw
  Ecto kernel substrate, no Ash resource, no abbrev-registry row, excluded from
  schema.dict.json by the same rule as demo/driftwood/pawchart). Without this
  table every verified delivery would 500 at store — the same class of
  missing-table hole the Phase-3 rollup migration closed for the analytics
  readers. Delegates to the shared \`Samen.Webhook.EventMigration\` so every
  host's DDL/catalog rows stay byte-identical.
  """
  use Ecto.Migration
  def up, do: Samen.Webhook.EventMigration.up()
  def down, do: Samen.Webhook.EventMigration.down()
end
