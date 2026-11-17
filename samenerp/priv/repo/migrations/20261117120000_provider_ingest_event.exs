defmodule Samenerp.Repo.Migrations.ProviderIngestEvent do
  @moduledoc """
  Signed provider ingestion: the `ing_event` idempotency + retry store.

  Kernel infrastructure (plain Ecto schema `Samen.Ingest.Event`, no Ash resource):
  the table is created with its catalog rows in one transaction by the shared
  `Samen.Ingest.EventMigration` helper.
  """
  use Ecto.Migration
  def up, do: Samen.Ingest.EventMigration.up()
  def down, do: Samen.Ingest.EventMigration.down()
end
