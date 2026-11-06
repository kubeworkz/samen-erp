defmodule SamenCore.TestRepo.Migrations.AddCloseRunCompletedBy do
  @moduledoc """
  WS-ACCT Phase 12 — the close run records WHO completed it.

  Additive nullable principal id on `clr_close_run`: the `:finish` action's
  guard stamps the acting principal's id, so the close dashboard's period card
  can name the finisher beside the run status. It stays `nil` while the run is
  in progress, and for a run completed before this column existed — an honest
  absence, never a fabricated name.

  Additive column on an already-catalogued resource → `catalog_sync/2`'s
  `only:` scoping, so `down` removes exactly this `fld_field` row.
  """

  use Samen.Migration

  def change do
    alter table(:clr_close_run) do
      add(:clr_completed_by, :text)
    end

    catalog_sync([SamenCore.Support.FinanceFixture.CloseRun], only: [:completed_by])
  end
end
