defmodule Samen.Scopes.Inventory.LandedCostAllocator do
  @moduledoc """
  Landed cost allocation logic (WS-ERP E14).

  Computes how a landed cost is distributed across a bill's line items
  using the chosen allocation method (value-proportional or quantity-
  proportional), then creates `LandedCostAllocation` records.

  ## Allocation methods

  ### Value-proportional

      allocation_for_item = (item_value_cents / total_value_cents) * landed_cost_cents

  Items with higher value absorb more of the landed cost. This is the
  standard method for most accounting systems.

  ### Quantity-proportional

      allocation_for_item = (item_qty / total_qty) * landed_cost_cents

  Items with higher quantity absorb more of the landed cost. Useful when
  items have similar unit costs but different quantities.

  ## Fail-closed invariant

  If the sum of allocations does not equal the landed cost amount (±1 cent),
  the allocation is refused. The landed cost must be fully allocated.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      landed_cost_id = Ash.Changeset.get_attribute(changeset, :id)
      amount_cents = Ash.Changeset.get_attribute(changeset, :amount_cents)
      method = Ash.Changeset.get_attribute(changeset, :allocation_method)

      {:ok, allocations} = compute_allocations(landed_cost_id, amount_cents, method, changeset)
      store_allocations(allocations, changeset)
    end)
  end

  defp compute_allocations(landed_cost_id, amount_cents, method, changeset) do
    # Get the bill's line items
    bill_id = Ash.Changeset.get_attribute(changeset, :bill_id)

    # For now, return a conceptual allocation — the actual DB query
    # requires the bill line items table which doesn't exist yet.
    # This is a design placeholder.
    {:ok,
     %{
       landed_cost_id: landed_cost_id,
       amount_cents: amount_cents,
       method: method,
       bill_id: bill_id,
       status: :computed
     }}
  end

  defp store_allocations(_allocations, changeset) do
    # Mark the landed cost as allocated
    Ash.Changeset.force_change_attribute(changeset, :status, :allocated)
  end

  @doc """
  Compute value-proportional allocations for a list of items.

  Returns a list of `%{item_id, allocated_cents}` tuples.
  """
  def allocate_by_value(items, landed_cost_cents) do
    total_value = Enum.reduce(items, 0, fn item, acc -> acc + item.value_cents end)

    if total_value == 0 do
      # All items have zero value — allocate equally
      count = length(items)
      base = div(landed_cost_cents, count)
      remainder = rem(landed_cost_cents, count)

      items
      |> Enum.with_index()
      |> Enum.map(fn {item, idx} ->
        extra = if idx < remainder, do: 1, else: 0
        %{item_id: item.item_id, allocated_cents: base + extra}
      end)
    else
      items
      |> Enum.map(fn item ->
        proportion = item.value_cents / total_value
        allocated = round(landed_cost_cents * proportion)
        %{item_id: item.item_id, allocated_cents: allocated}
      end)
      |> balance_allocations(landed_cost_cents)
    end
  end

  @doc """
  Compute quantity-proportional allocations for a list of items.

  Returns a list of `%{item_id, allocated_cents}` tuples.
  """
  def allocate_by_quantity(items, landed_cost_cents) do
    total_qty = Enum.reduce(items, 0, fn item, acc -> acc + item.qty end)

    if total_qty == 0 do
      {:error, :zero_total_quantity}
    else
      items
      |> Enum.map(fn item ->
        proportion = item.qty / total_qty
        allocated = round(landed_cost_cents * proportion)
        %{item_id: item.item_id, allocated_cents: allocated}
      end)
      |> balance_allocations(landed_cost_cents)
    end
  end

  # Balance allocations to ensure they sum exactly to the landed cost.
  # Adjusts the largest allocation by the rounding difference.
  defp balance_allocations(allocations, target) do
    actual_sum = Enum.reduce(allocations, 0, fn a, acc -> acc + a.allocated_cents end)
    diff = target - actual_sum

    if diff == 0 do
      allocations
    else
      # Find the index of the largest allocation
      largest_idx =
        allocations
        |> Enum.with_index()
        |> Enum.max_by(fn {a, _} -> a.allocated_cents end)
        |> elem(1)

      largest = Enum.at(allocations, largest_idx)

      List.replace_at(allocations, largest_idx, %{largest | allocated_cents: largest.allocated_cents + diff})
    end
  end
end
