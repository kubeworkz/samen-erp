defmodule Samen.WebTest.Repo.Migrations.AddCloseRunCompletedBy do
  @moduledoc """
  WS-ACCT Phase 12 — the web test host's close run records WHO completed it.

  Additive nullable principal id on `fcr_close_run`, mirroring the
  `samen_core` fixture migration: the `:finish` action's guard stamps the
  acting principal's id, so the close dashboard's period card can name the
  finisher beside the run status. It stays `nil` while the run is in progress,
  and for a run completed before this column existed.

  Additive column on an already-catalogued resource → `catalog_sync/2`'s
  `only:` scoping, so `down` removes exactly this `fld_field` row.
  """

  use Samen.Migration

  def change do
    alter table(:fcr_close_run) do
      add(:fcr_completed_by, :text)
    end

    catalog_sync([Samen.WebTest.Erp.CloseRun], only: [:completed_by])
  end
end
