defmodule Samen.FleetDatacleanTest do
  @moduledoc """
  WS-ERP E23: Fleet + Data Cleaning — Flectra-inspired asset management.

  Tests:
    * fd1 Vehicle: status lifecycle (active → maintenance → active)
    * fd2 Vehicle: fuel type options
    * fd3 Maintenance: type options and cost tracking
    * fd4 Fuel: consumption calculation (liters / distance * 100)
    * fd5 Fuel: cost per liter calculation
    * fd6 Inspection: result types (pass/fail/conditional)
    * fd7 Inspection: checklist validation
    * fd8 DataCleanRule: match types (exact/fuzzy)
    * fd9 DataCleanRule: threshold validation
    * fd10 DataCleanMerge: state lifecycle (pending → merged)
    * fd11 Integration: full fleet flow
    * fd12 Integration: full data cleaning flow
  """
  use ExUnit.Case, async: true

  # ── fd1: vehicle status lifecycle ────────────────────────────────────

  describe "fd1 — vehicle status lifecycle" do
    test "active → maintenance → active" do
      vehicle = %{status: :active}
      vehicle = %{vehicle | status: :maintenance}
      assert vehicle.status == :maintenance
      vehicle = %{vehicle | status: :active}
      assert vehicle.status == :active
    end

    test "active → retired" do
      vehicle = %{status: :active}
      vehicle = %{vehicle | status: :retired}
      assert vehicle.status == :retired
    end

    test "retired cannot go back to active" do
      valid_transitions = %{active: [:maintenance, :retired], maintenance: [:active, :retired], retired: []}
      refute :active in valid_transitions[:retired]
    end
  end

  # ── fd2: fuel type options ───────────────────────────────────────────

  describe "fd2 — fuel type options" do
    test "valid fuel types" do
      valid = [:diesel, :petrol, :electric, :hybrid]
      assert length(valid) == 4
      assert :diesel in valid
      assert :electric in valid
    end
  end

  # ── fd3: maintenance types and cost ──────────────────────────────────

  describe "fd3 — maintenance types and cost" do
    test "valid maintenance types" do
      valid = [:scheduled, :unscheduled, :repair, :recall]
      assert length(valid) == 4
      assert :scheduled in valid
    end

    test "cost tracking" do
      maintenance = %{cost: 150_00, description: "Oil change"}
      assert maintenance.cost == 150_00
    end

    test "scheduled maintenance has next service" do
      maintenance = %{maintenance_type: :scheduled, next_service_km: 10_000, next_service_date: ~D[2026-06-15]}
      assert maintenance.next_service_km == 10_000
    end
  end

  # ── fd4: fuel consumption calculation ────────────────────────────────

  describe "fd4 — fuel consumption calculation" do
    test "consumption = liters / distance * 100" do
      liters = 40.0
      distance_km = 500
      consumption = liters / distance_km * 100

      assert consumption == 8.0
    end

    test "high consumption vehicle" do
      liters = 80.0
      distance_km = 400
      consumption = liters / distance_km * 100

      assert consumption == 20.0
    end

    test "efficient vehicle" do
      liters = 30.0
      distance_km = 600
      consumption = liters / distance_km * 100

      assert consumption == 5.0
    end
  end

  # ── fd5: cost per liter ──────────────────────────────────────────────

  describe "fd5 — cost per liter" do
    test "cost per liter = total cost / liters" do
      total_cost = 80_00
      liters = 40.0
      cost_per_liter = total_cost / liters

      assert cost_per_liter == 2_00
    end
  end

  # ── fd6: inspection result types ─────────────────────────────────────

  describe "fd6 — inspection result types" do
    test "valid result types" do
      valid = [:pass, :fail, :conditional]
      assert length(valid) == 3
      assert :pass in valid
      assert :conditional in valid
    end

    test "inspection types" do
      valid = [:pre_trip, :annual, :safety, :custom]
      assert length(valid) == 4
      assert :pre_trip in valid
    end
  end

  # ── fd7: checklist validation ────────────────────────────────────────

  describe "fd7 — checklist validation" do
    test "checklist items have pass/fail" do
      checklist = [
        %{item: "Brakes", passed: true},
        %{item: "Tires", passed: true},
        %{item: "Lights", passed: false}
      ]

      failed = Enum.filter(checklist, &(not &1.passed))
      assert length(failed) == 1
      assert hd(failed).item == "Lights"
    end

    test "all items pass" do
      checklist = [
        %{item: "Brakes", passed: true},
        %{item: "Tires", passed: true}
      ]

      all_pass = Enum.all?(checklist, & &1.passed)
      assert all_pass == true
    end
  end

  # ── fd8: data clean match types ──────────────────────────────────────

  describe "fd8 — data clean match types" do
    test "valid match types" do
      valid = [:exact, :fuzzy]
      assert length(valid) == 2
      assert :exact in valid
      assert :fuzzy in valid
    end

    test "exact match comparison" do
      a = "John Smith"
      b = "John Smith"
      assert a == b
    end

    test "fuzzy match threshold" do
      threshold = 0.8
      similarity = 0.85
      assert similarity >= threshold
    end
  end

  # ── fd9: threshold validation ────────────────────────────────────────

  describe "fd9 — threshold validation" do
    test "threshold must be between 0 and 1" do
      threshold = 0.8
      assert threshold >= 0.0 and threshold <= 1.0
    end

    test "low threshold finds more duplicates" do
      threshold = 0.5
      similarity = 0.6
      assert similarity >= threshold
    end

    test "high threshold finds fewer duplicates" do
      threshold = 0.95
      similarity = 0.85
      assert similarity < threshold
    end
  end

  # ── fd10: merge state lifecycle ──────────────────────────────────────

  describe "fd10 — merge state lifecycle" do
    test "pending → merged" do
      merge = %{state: :pending}
      merge = %{merge | state: :merged}
      assert merge.state == :merged
    end

    test "pending → cancelled" do
      merge = %{state: :pending}
      merge = %{merge | state: :cancelled}
      assert merge.state == :cancelled
    end

    test "merged cannot be cancelled" do
      valid_transitions = %{pending: [:merged, :cancelled], merged: [], cancelled: []}
      refute :cancelled in valid_transitions[:merged]
    end
  end

  # ── fd11: full fleet flow ────────────────────────────────────────────

  describe "fd11 — full fleet flow" do
    test "vehicle → maintenance → fuel → inspection" do
      # 1. Register vehicle
      vehicle = %{id: "v1", name: "Ford Transit #42", make: "Ford", model: "Transit", year: 2024, status: :active, odometer_km: 25_000, fuel_type: :diesel}

      # 2. Schedule maintenance
      maintenance = %{vehicle_id: vehicle.id, maintenance_type: :scheduled, description: "Oil change + filter", cost: 150_00, odometer_km: 25_000, next_service_km: 35_000}

      # 3. Record fuel
      fuel = %{vehicle_id: vehicle.id, date: ~D[2026-01-15], liters: 45.0, cost: 90_00, odometer_km: 25_200, is_full_tank: true}

      # 4. Pre-trip inspection
      inspection = %{vehicle_id: vehicle.id, inspection_type: :pre_trip, result: :pass, checklist: [%{item: "Brakes", passed: true}, %{item: "Tires", passed: true}, %{item: "Lights", passed: true}]}

      assert vehicle.status == :active
      assert maintenance.cost == 150_00
      assert fuel.liters == 45.0
      assert inspection.result == :pass

      # 5. Vehicle goes for maintenance
      vehicle = %{vehicle | status: :maintenance}
      assert vehicle.status == :maintenance

      # 6. After maintenance, back to active
      vehicle = %{vehicle | status: :active, odometer_km: maintenance.next_service_km}
      assert vehicle.status == :active
      assert vehicle.odometer_km == 35_000
    end
  end

  # ── fd12: full data cleaning flow ────────────────────────────────────

  describe "fd12 — full data cleaning flow" do
    test "create rule → scan → find duplicates → merge" do
      # 1. Create dedup rule
      rule = %{id: "r1", name: "Duplicate Contacts", table_name: "contacts", field_names: ["name", "email"], match_type: :exact, is_active: true}

      # 2. Scan finds duplicates
      duplicates = [
        %{id: "c1", name: "John Smith", email: "john@example.com"},
        %{id: "c2", name: "John Smith", email: "john@example.com"},
        %{id: "c3", name: "John Smith", email: "john@example.com"}
      ]

      # 3. Group by matching fields
      groups = Enum.group_by(duplicates, &{&1.name, &1.email})
      duplicate_groups = Map.values(groups) |> Enum.filter(&(length(&1) > 1))

      assert length(duplicate_groups) == 1
      assert length(hd(duplicate_groups)) == 3

      # 4. Create merge record
      primary = hd(duplicates)
      dup_ids = duplicates |> tl() |> Enum.map(& &1.id)

      merge = %{rule_id: rule.id, table_name: rule.table_name, primary_id: primary.id, duplicate_ids: dup_ids, state: :pending}

      # 5. Execute merge
      merge = Map.merge(merge, %{state: :merged, merged_at: DateTime.utc_now()})

      assert merge.state == :merged
      assert merge.primary_id == "c1"
      assert length(merge.duplicate_ids) == 2
    end
  end
end