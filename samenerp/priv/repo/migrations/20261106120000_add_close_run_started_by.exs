defmodule Samenerp.Repo.Migrations.AddCloseRunStartedBy do
  @moduledoc """
  WS-ACCT Phase 12 — the real ERP host's close run records WHO started it.

  Additive nullable principal id on `efq_close_run`: the `:start` action's
  guard stamps the acting principal's id, so the close dashboard's period card
  can name the starter. A run started before this column existed reads `nil` —
  an honest absence, never a fabricated name.

  Additive column on an already-catalogued resource → `catalog_sync/2`'s
  `only:` scoping, so `down` removes exactly this `fld_field` row.
  """

  use Samen.Migration

  def change do
    alter table(:efq_close_run) do
      add(:efq_started_by, :text)
    end

    catalog_sync([Samenerp.Erp.CloseRun], only: [:started_by])
  end
end
