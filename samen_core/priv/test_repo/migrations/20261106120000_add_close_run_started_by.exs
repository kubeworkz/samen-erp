defmodule SamenCore.TestRepo.Migrations.AddCloseRunStartedBy do
  @moduledoc """
  WS-ACCT Phase 12 — the close run records WHO started it.

  Additive nullable principal id on `clr_close_run`: the `:start` action's guard
  stamps the acting principal's id (`broker:<org>` on a disarmed host, a real
  `Identity.User` id when one resolves), so the close dashboard's period card
  can answer "who started this close?" without guessing. A run started before
  this column existed reads `nil` — an honest absence, never a fabricated name.

  Additive column on an already-catalogued resource → `catalog_sync/2`'s
  `only:` scoping, so `down` removes exactly this `fld_field` row.
  """

  use Samen.Migration

  def change do
    alter table(:clr_close_run) do
      add(:clr_started_by, :text)
    end

    catalog_sync([SamenCore.Support.FinanceFixture.CloseRun], only: [:started_by])
  end
end
