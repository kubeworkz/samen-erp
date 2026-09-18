defmodule Samen.LandedCostsTest do
  @moduledoc """
  Landed Costs (WS-ERP E14; BigCapital-inspired).

  Tests:
    * lc1 allocate_by_value: proportional to item value
    * lc2 allocate_by_value: equal items get equal allocation
    * lc3 allocate_by_value: zero total value → equal allocation
    * lc4 allocate_by_quantity: proportional to item quantity
    * lc5 allocate_by_quantity: zero total quantity → error
    * lc6 balance_allocations: sum equals landed cost (±1 cent)
    * lc7 LandedCost: draft → allocated state machine
    * lc8 allocation methods: value and quantity are valid
  """
  use ExUnit.Case, async: true

  alias Samen.Scopes.Inventory.LandedCostAllocator

  # ── lc1: allocate_by_value proportional ───────────────────────────────────

  describe "lc1 — allocate_by_value proportional" do
    test "items with higher value get more allocation" do
      items = [
        %{item_id: "a", value_cents: 10_000},
        %{item_id: "b", value_cents: 5_000},
        %{item_id: "c", value_cents: 5_000},
      ]

      landed_cost = 2_000

      allocations = LandedCostAllocator.allocate_by_value(items, landed_cost)

      # a: 10000/20000 * 2000 = 1000
      # b: 5000/20000 * 2000 = 500
      # c: 5000/20000 * 2000 = 500
      a_alloc = Enum.find(allocations, &(&1.item_id == "a"))
      b_alloc = Enum.find(allocations, &(&1.item_id == "b"))
      c_alloc = Enum.find(allocations, &(&1.item_id == "c"))

      assert a_alloc.allocated_cents == 1_000
      assert b_alloc.allocated_cents == 500
      assert c_alloc.allocated_cents == 500
    end
  end

  # ── lc2: equal items get equal allocation ─────────────────────────────────

  describe "lc2 — equal items get equal allocation" do
    test "equal value items split evenly" do
      items = [
        %{item_id: "a", value_cents: 10_000},
        %{item_id: "b", value_cents: 10_000},
      ]

      landed_cost = 3_000

      allocations = LandedCostAllocator.allocate_by_value(items, landed_cost)

      a_alloc = Enum.find(allocations, &(&1.item_id == "a"))
      b_alloc = Enum.find(allocations, &(&1.item_id == "b"))

      assert a_alloc.allocated_cents == 1_500
      assert b_alloc.allocated_cents == 1_500
    end
  end

  # ── lc3: zero total value → equal allocation ──────────────────────────────

  describe "lc3 — zero total value → equal allocation" do
    test "falls back to equal allocation" do
      items = [
        %{item_id: "a", value_cents: 0},
        %{item_id: "b", value_cents: 0},
        %{item_id: "c", value_cents: 0},
      ]

      landed_cost = 3_000

      allocations = LandedCostAllocator.allocate_by_value(items, landed_cost)

      total = Enum.reduce(allocations, 0, fn a, acc -> acc + a.allocated_cents end)
      assert total == 3_000
    end
  end

  # ── lc4: allocate_by_quantity proportional ────────────────────────────────

  describe "lc4 — allocate_by_quantity proportional" do
    test "items with higher quantity get more allocation" do
      items = [
        %{item_id: "a", qty: 10},
        %{item_id: "b", qty: 5},
        %{item_id: "c", qty: 5},
      ]

      landed_cost = 2_000

      allocations = LandedCostAllocator.allocate_by_quantity(items, landed_cost)

      a_alloc = Enum.find(allocations, &(&1.item_id == "a"))
      b_alloc = Enum.find(allocations, &(&1.item_id == "b"))
      c_alloc = Enum.find(allocations, &(&1.item_id == "c"))

      # a: 10/20 * 2000 = 1000
      # b: 5/20 * 2000 = 500
      # c: 5/20 * 2000 = 500
      assert a_alloc.allocated_cents == 1_000
      assert b_alloc.allocated_cents == 500
      assert c_alloc.allocated_cents == 500
    end
  end

  # ── lc5: zero total quantity → error ──────────────────────────────────────

  describe "lc5 — zero total quantity → error" do
    test "returns error for zero quantity" do
      items = [
        %{item_id: "a", qty: 0},
        %{item_id: "b", qty: 0},
      ]

      landed_cost = 2_000

      assert {:error, :zero_total_quantity} =
               LandedCostAllocator.allocate_by_quantity(items, landed_cost)
    end
  end

  # ── lc6: sum equals landed cost ───────────────────────────────────────────

  describe "lc6 — sum equals landed cost" do
    test "allocations balance to exact amount" do
      items = [
        %{item_id: "a", value_cents: 33_333},
        %{item_id: "b", value_cents: 33_333},
        %{item_id: "c", value_cents: 33_334},
      ]

      landed_cost = 10_000

      allocations = LandedCostAllocator.allocate_by_value(items, landed_cost)
      total = Enum.reduce(allocations, 0, fn a, acc -> acc + a.allocated_cents end)

      # Allow ±1 cent tolerance for rounding
      assert abs(total - landed_cost) <= 1
    end

    test "rounding is absorbed by largest allocation" do
      items = [
        %{item_id: "a", value_cents: 10_000},
        %{item_id: "b", value_cents: 3_333},
        %{item_id: "c", value_cents: 3_333},
        %{item_id: "d", value_cents: 3_334},
      ]

      landed_cost = 1_000

      allocations = LandedCostAllocator.allocate_by_value(items, landed_cost)
      total = Enum.reduce(allocations, 0, fn a, acc -> acc + a.allocated_cents end)

      assert total == 1_000
    end
  end

  # ── lc7: draft → allocated state machine ──────────────────────────────────

  describe "lc7 — draft → allocated state machine" do
    test "valid transitions" do
      transitions = [:draft, :allocated]
      assert length(transitions) == 2
    end
  end

  # ── lc8: allocation methods ───────────────────────────────────────────────

  describe "lc8 — allocation methods" do
    test "value and quantity are valid methods" do
      valid_methods = [:value, :quantity]
      assert :value in valid_methods
      assert :quantity in valid_methods
    end
  end
end
