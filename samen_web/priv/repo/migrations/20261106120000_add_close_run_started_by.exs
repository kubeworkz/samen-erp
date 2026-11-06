defmodule Samen.WebTest.Repo.Migrations.AddCloseRunStartedBy do
  @moduledoc """
  WS-ACCT Phase 12 — the web test host's close run records WHO started it.

  Additive nullable principal id on `fcr_close_run`, mirroring the
  `samen_core` fixture migration: the `:start` action's guard stamps the acting
  principal's id, so the close dashboard's period card can name the starter.
  A run started before this column existed reads `nil` — an honest absence.

  Additive column on an already-catalogued resource → `catalog_sync/2`'s
  `only:` scoping, so `down` removes exactly this `fld_field` row.
  """

  use Samen.Migration

  def change do
    alter table(:fcr_close_run) do
      add(:fcr_started_by, :text)
    end

    catalog_sync([Samen.WebTest.Erp.CloseRun], only: [:started_by])
  end
end
