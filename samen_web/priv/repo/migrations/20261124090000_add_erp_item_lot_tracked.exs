defmodule Samen.WebTest.Repo.Migrations.AddErpItemLotTracked do
  @moduledoc """
  WS-LOG L1 follow-up (surfaced by the L1.2 gate) — the `samen_web` ERP
  mount's `Item` carries the derived `lot_tracked` flag (added to the shared
  blueprint with the core fixture in 07fb4920), but this host's hand-written
  ERP schema never added the column. Every `Erp.Item.create` therefore failed with
  `undefined_column "ini_lot_tracked"`, taking the goods-receipt fixtures
  with it.

  Additive column on an already-catalogued resource → `catalog_sync/2`'s
  `only:` scoping, so the reversible `change/0` removes exactly this
  `fld_field` row. The fail-closed `false` default preserves every existing
  item as untracked.
  """

  use Samen.Migration

  def change do
    alter table(:ini_item) do
      add(:ini_lot_tracked, :boolean, null: false, default: false)
    end

    catalog_sync([Samen.WebTest.Erp.Item], only: [:lot_tracked])
  end
end
