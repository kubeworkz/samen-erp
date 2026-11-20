defmodule SamenCore.TestRepo.Migrations.AddBillingAnchorUniques do
  @moduledoc """
  B0 schema belt: one journal entry per billing invoice / sales-order anchor.

  The index is partial so unrelated journal source keys keep their existing
  semantics. This migration adds no Billing table and no posting service.
  """

  use Samen.Migration

  @index_name :sje_billing_anchor_unique

  def up do
    create(
      unique_index(
        :sje_journal_entry,
        [:sje_org_id, :sje_source_key, :sje_source_id],
        name: @index_name,
        where: "sje_source_key IN ('billing_invoice','sales_order') AND sje_source_id IS NOT NULL"
      )
    )
  end

  def down do
    drop(
      index(:sje_journal_entry, [:sje_org_id, :sje_source_key, :sje_source_id], name: @index_name)
    )
  end
end
