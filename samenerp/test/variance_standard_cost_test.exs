defmodule Samenerp.VarianceStandardCostTest do
  @moduledoc """
  WS-ACCT Phase 7 on the real Kubeworkz host: standard costing posts the seven
  variance classes through the seeded posting map — and **never revalues
  stock** (ADR-054 D4).

  The regression the ADR names explicitly: a standard is a variance layer, not
  a second valuation. The moving average (`StockLevel.avg_unit_cost_cents` /
  `stock_value_cents`, fed by the append-only stock ledger) must be
  byte-identical before and after a variance run, even when the standard price
  differs from the stock's actual cost. The variance prices the DIFFERENCE; the
  inventory stays where the one ledger put it.
  """

  use Samenerp.DataCase, async: false

  require Ash.Query

  alias Samenerp.Erp
  alias Samenerp.Kubeworkz.Books
  alias Samenerp.Operator, as: Op

  @period "2026-03"

  setup do
    org = create_org!("Kubeworkz Variance CoA")

    {:ok, org: org}
  end

  test "a variance run prices the difference and leaves the moving average untouched", %{
    org: org
  } do
    org_id = to_string(org.id)
    Books.seed!(org.id)

    chip =
      Erp.CostObject
      |> Ash.Query.filter(org_id == ^org_id and name == "RISC-V64 SoC")
      |> Ash.read_one!(authorize?: false)

    item = create_item!(org_id)
    warehouse = create_warehouse!(org_id)

    # Establish the moving average with a real receipt: 10 wafers at 3 000.00.
    {:ok, _event} =
      Erp.StockLedger
      |> Ash.Changeset.for_create(
        :record,
        %{
          org_id: org_id,
          kind: :receipt,
          qty: 10,
          unit_cost_cents: 300_000,
          item_id: item.id,
          warehouse_id: warehouse.id,
          source_key: "variance_test"
        },
        authorize?: false
      )
      |> Ash.create(authorize?: false)

    level_before = stock_level!(org_id, item.id, warehouse.id)
    assert level_before.avg_unit_cost_cents == 300_000
    assert level_before.stock_value_cents == 3_000_000

    card = card!(org_id, chip.id, item.id)
    lines = card_lines!(org_id, card.id, item.id)

    # Output 10 good wafers; material issued 11 at 310 000 (price + yield well
    # above standard); standard direct labour/overhead below actual.
    actuals = %{
      "output_units" => 10,
      "lines" => %{
        lines.material.id => %{"qty" => 11, "unit_price_cents" => 310_000},
        lines.labor.id => %{"qty" => 70, "unit_price_cents" => 2_500},
        lines.overhead.id => %{"qty" => 70, "unit_price_cents" => 4_500}
      }
    }

    assert {:ok, _} =
             card
             |> Ash.Changeset.for_update(
               :post_variances,
               %{period_key: @period, actuals: actuals},
               authorize?: false
             )
             |> Ash.update(authorize?: false)

    variances =
      Erp.CostVariance
      |> Ash.Query.filter(org_id == ^org_id and period_key == ^@period)
      |> Ash.read!(authorize?: false)

    # No BOM line on this card, so six classes are measured (the card's only
    # material line is yield-bearing).
    assert variances |> Enum.map(& &1.type) |> Enum.sort() ==
             [:labor_efficiency, :labor_rate, :overhead_spending, :overhead_volume, :ppv, :yield]

    # R8 is clean on the real host's tables and the seeded posting map.
    report =
      Samen.Scopes.Finance.ReconcileVariance.report(org_id, @period,
        variance: Erp.CostVariance,
        standard: Erp.CostStandard,
        standard_line: Erp.CostStandardLine,
        entry: Erp.JournalEntry,
        line: Erp.JournalLine,
        posting_account: Erp.PostingAccount
      )

    assert report.ok?, inspect(report.violations)

    # The standard never revalued stock: the level is byte-identical.
    level_after = stock_level!(org_id, item.id, warehouse.id)
    assert level_after.avg_unit_cost_cents == level_before.avg_unit_cost_cents
    assert level_after.stock_value_cents == level_before.stock_value_cents
    assert level_after.qty_on_hand == level_before.qty_on_hand
  end

  # ── fixture ───────────────────────────────────────────────────────────────

  defp create_org!(name) do
    Op.Org
    |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp create_item!(org_id) do
    Erp.Item
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, sku: "SOC-WAFER", name: "RISC-V64 SoC wafer"},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp create_warehouse!(org_id) do
    Erp.Warehouse
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, code: "FAB-WH", name: "Foundry stock"},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp stock_level!(org_id, item_id, warehouse_id) do
    Erp.StockLevel
    |> Ash.Query.filter(
      org_id == ^org_id and item_id == ^item_id and warehouse_id == ^warehouse_id
    )
    |> Ash.read_one!(authorize?: false)
  end

  defp card!(org_id, cost_object_id, item_id) do
    Erp.CostStandard
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        code: "SOC-STD-2026",
        cost_object_id: cost_object_id,
        output_item_id: item_id,
        effective_on: ~D[2026-01-01],
        dimension_key: :project
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp card_lines!(org_id, standard_id, item_id) do
    material =
      line!(org_id, standard_id, %{
        element: :material,
        item_id: item_id,
        standard_qty: 1,
        standard_unit_price_cents: 300_000,
        expected_yield_bp: 9_500,
        usage_basis: :yield
      })

    labor =
      line!(org_id, standard_id, %{
        element: :labor,
        standard_qty: 6,
        standard_unit_price_cents: 2_400,
        usage_basis: :none
      })

    overhead =
      line!(org_id, standard_id, %{
        element: :overhead,
        standard_qty: 6,
        standard_unit_price_cents: 4_200,
        usage_basis: :none
      })

    %{material: material, labor: labor, overhead: overhead}
  end

  defp line!(org_id, standard_id, attrs) do
    Erp.CostStandardLine
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{org_id: org_id, standard_id: standard_id}, attrs), authorize?: false)
    |> Ash.create!(authorize?: false)
  end
end
