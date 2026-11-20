defmodule Samenerp.Repo.Migrations.AddBillingAnchorUniques do
  @moduledoc """
  B0 schema belt: one journal entry per billing invoice / sales-order anchor.

  The index is partial so unrelated journal source keys keep their existing
  semantics. This migration adds no Billing table and no posting service.
  """

  use Ecto.Migration

  @index_name :ecj_billing_anchor_unique

  def up do
    create(
      unique_index(
        :ecj_journal_entry,
        [:ecj_org_id, :ecj_source_key, :ecj_source_id],
        name: @index_name,
        where: "ecj_source_key IN ('billing_invoice','sales_order') AND ecj_source_id IS NOT NULL"
      )
    )
  end

  def down do
    drop(
      index(:ecj_journal_entry, [:ecj_org_id, :ecj_source_key, :ecj_source_id], name: @index_name)
    )
  end
end
