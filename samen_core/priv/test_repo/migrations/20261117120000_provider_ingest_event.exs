defmodule SamenCore.TestRepo.Migrations.ProviderIngestEvent do
  @moduledoc "Signed provider ingestion: the `ing_event` idempotency + retry store."
  use Ecto.Migration
  def up, do: Samen.Ingest.EventMigration.up()
  def down, do: Samen.Ingest.EventMigration.down()
end
