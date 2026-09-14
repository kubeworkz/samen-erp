defmodule Samen.Scopes.Inventory.ProduceWo do
  @moduledoc """
  THE POSTING FACADE (WS-ERP E6; design §4): on `WorkOrder :complete`,
  per frozen snapshot line — a `StockLedger :production_consume` event
  (qty NEGATIVE, cost = the rollup's moving-average snapshot at
  completion, anchored `source_key: "work_order"`) — plus the
  `:production_in` event of the finished item at the ROLLED-UP actual
  cost (Σ component consumption value + labor/overhead adjustments, ÷
  wo_qty), plus the ProductionLog rows (one per event + the adjustment
  rows), plus the order's flip to `:completed` — ALL inside the action's
  single transaction: commit or roll back TOGETHER. Exactly-once: a
  second `:complete` is refused on the pre-state (WoState).

  Manufacturing is thus a bundle of StockLedger events with a cost
  roll-up — zero new quantity mechanisms; the E3 machinery (NegativeStock,
  StockLevelSync, the belts) runs resource-wide on every event, so the
  facade can never disagree with stock.

  Refusals are fail-honest BEFORE any write: a never-stocked component
  (no moving average to snapshot — consumption cost must be a fact), an
  oversell past NegativeStock (unless the warehouse opted out), and the
  empty-snapshot data error. Labor/overhead are carried as ProductionLog
  `:adjust` rows (Money adjustments — design §4) and divided into the
  unit cost; they never become stock events.
  """

  use Ash.Resource.Change

  @source_key "work_order"

  @doc "The work-order anchor source_key (the PostingMarker guc/0 discipline)."
  def source_key, do: @source_key

  @impl true
  def change(changeset, opts, _context) do
    org_id = resolve_org(changeset)

    Ash.Changeset.before_action(changeset, fn changeset ->
      do_complete(changeset, org_id, opts)
    end)
  end

  defp do_complete(changeset, org_id, opts) do
    ledger_resource = Keyword.fetch!(opts, :ledger)
    level_resource = Keyword.fetch!(opts, :level)
    production_log_resource = Keyword.fetch!(opts, :production_log)

    wo = changeset.data

    with :ok <- refuse_no_snapshot(wo),
         {:ok, consumes} <- snapshot_consumes(wo),
         {:ok, costs} <- moving_averages(level_resource, org_id, wo.warehouse_id, consumes),
         {:ok, _log_rows, material_cents} <-
           write_consumes(ledger_resource, org_id, wo, consumes, costs, production_log_resource),
         {:ok, unit_cost} <-
           rolled_up_unit_cost(material_cents, wo) do
      case write_produce(ledger_resource, org_id, wo, unit_cost, production_log_resource) do
        {:ok, _produce_row} ->
          # The adjustment row is written with the flip (no ledger event
          # behind it — it is a cost carry, not a movement).
          write_adjust_row(
            production_log_resource,
            org_id,
            wo,
            wo.labor_cents + wo.overhead_cents
          )

          # before_action hooks return the BARE changeset.
          changeset
          |> Ash.Changeset.force_change_attribute(:status, :completed)
          |> Ash.Changeset.force_change_attribute(:actual_material_cents, material_cents)
          |> Ash.Changeset.force_change_attribute(:actual_unit_cost_cents, unit_cost)
          |> Ash.Changeset.force_change_attribute(
            :completed_at,
            DateTime.utc_now() |> DateTime.truncate(:second)
          )

        {:error, reason} ->
          Ash.Changeset.add_error(changeset,
            field: :base,
            message: "the completion failed to land: #{format(reason)}"
          )
      end
    else
      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :base,
          message: "the work order cannot be completed: #{format(reason)}"
        )
    end
  end

  # ── the write steps (any failure rolls the WHOLE transaction back) ──────────

  defp write_consumes(ledger_resource, org_id, wo, consumes, costs, log_resource) do
    Enum.reduce_while(consumes, {:ok, [], 0}, fn {item_id, qty}, {:ok, acc, cents_acc} ->
      cost = Map.fetch!(costs, item_id)
      value = qty * cost

      with {:ok, event} <-
             create_event(ledger_resource, org_id, wo, %{
               item_id: item_id,
               kind: :production_consume,
               qty: -qty,
               unit_cost_cents: cost
             }),
           {:ok, row} <-
             create_log_row(log_resource, org_id, wo, %{
               item_id: item_id,
               entry_kind: :consume,
               qty: -qty,
               unit_cost_cents: cost,
               adjustment_cents: nil,
               ledger_event_id: event.id
             }) do
        {:cont, {:ok, acc ++ [row], cents_acc + value}}
      else
        {:error, reason} -> {:halt, {:error, {:consume_failed, reason}}}
      end
    end)
  end

  defp write_produce(ledger_resource, org_id, wo, unit_cost, log_resource) do
    with {:ok, event} <-
           create_event(ledger_resource, org_id, wo, %{
             item_id: wo.item_id,
             kind: :production_in,
             qty: wo.qty,
             unit_cost_cents: unit_cost
           }),
         {:ok, row} <-
           create_log_row(log_resource, org_id, wo, %{
             item_id: wo.item_id,
             entry_kind: :produce,
             qty: wo.qty,
             unit_cost_cents: unit_cost,
             adjustment_cents: nil,
             ledger_event_id: event.id
           }) do
      {:ok, row}
    end
  end

  defp write_adjust_row(log_resource, org_id, wo, total_adjustment_cents) do
    # Labor/overhead roll into the produce event's cost; the log row is the
    # audit trail of the carry. A zero adjustment writes no row.
    if total_adjustment_cents > 0 do
      log_resource
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          work_order_id: wo.id,
          item_id: wo.item_id,
          entry_kind: :adjust,
          qty: 0,
          unit_cost_cents: nil,
          adjustment_cents: total_adjustment_cents,
          ledger_event_id: nil
        },
        authorize?: false
      )
      |> Ash.create(authorize?: false)
    else
      {:ok, nil}
    end
  end

  # ── reads + refusals ────────────────────────────────────────────────────────

  defp refuse_no_snapshot(wo) do
    if wo.bom_snapshot == [] or is_nil(wo.bom_snapshot),
      do: {:error, :no_snapshot},
      else: :ok
  end

  # The frozen snapshot: aggregate duplicate components (a bill may list
  # the same component twice — consumption is per-item).
  defp snapshot_consumes(wo) do
    Enum.reduce(wo.bom_snapshot, {:ok, %{}}, fn line, {:ok, acc} ->
      item_id = Map.get(line, "component_item_id")
      qty = Map.get(line, "qty")

      if is_integer(qty) and qty > 0 do
        {:ok, Map.update(acc, item_id, qty, &(&1 + qty))}
      else
        {:error, {:bad_snapshot_line, line}}
      end
    end)
    |> case do
      {:ok, map} -> {:ok, Enum.sort(map)}
      other -> other
    end
  end

  # The moving-average snapshot per component, BEFORE the consumption lands
  # (read-your-writes inside the transaction — the E5 discipline).
  defp moving_averages(level_resource, org_id, warehouse_id, consumes) do
    require Ash.Query

    Enum.reduce_while(consumes, {:ok, %{}}, fn {item_id, _qty}, {:ok, acc} ->
      cond do
        Map.has_key?(acc, item_id) ->
          {:cont, {:ok, acc}}

        true ->
          case level_resource
               |> Ash.Query.filter(
                 org_id == ^org_id and item_id == ^item_id and warehouse_id == ^warehouse_id
               )
               |> Ash.read_one(authorize?: false) do
            {:ok, %{avg_unit_cost_cents: avg}} when is_integer(avg) ->
              {:cont, {:ok, Map.put(acc, item_id, avg)}}

            {:ok, _} ->
              {:halt, {:error, {:never_stocked, item_id}}}

            {:error, reason} ->
              {:halt, {:error, {:level_read_failed, reason}}}
          end
      end
    end)
  end

  # (Σ material value + labor + overhead) ÷ wo_qty — integer floor, the
  # produce event's unit cost. The ledger's own sums (R4) recompute the
  # same quantities independently.
  defp rolled_up_unit_cost(material_cents, wo) do
    total = material_cents + wo.labor_cents + wo.overhead_cents
    {:ok, floor(total / wo.qty)}
  end

  # ── formatting ──────────────────────────────────────────────────────────────

  defp format(:no_snapshot),
    do: "the WO carries no BOM snapshot — a WO is released (snapshot frozen) before it " <>
          "can complete, never completed from a live read"

  defp format({:bad_snapshot_line, line}),
    do: "the frozen snapshot carries a bad line: #{inspect(line)} — a data error, " <>
          "not an empty completion"

  defp format({:never_stocked, item_id}),
    do: "component #{inspect(item_id)} has no moving-average cost — it was never stocked. " <>
          "Consume what the org received: receive it first (fail-honest — consumption cost " <>
          "must be a fact, not an invention)"

  defp format({:level_read_failed, reason}),
    do: "the rollup read failed: #{inspect(reason)}"

  defp format({:consume_failed, reason}),
    do: "the completion's consumption failed: #{inspect(reason)} (NegativeStock refuses " <>
          "consuming below zero unless the warehouse opted out)"

  defp format({:produce_failed, reason}),
    do: "the completion's production_in event failed: #{inspect(reason)}"

  defp format({:log_failed, reason}),
    do: "the completion's ProductionLog write failed: #{inspect(reason)}"

  defp format(reason), do: inspect(reason)

  # ── event/log helpers ───────────────────────────────────────────────────────

  defp create_event(ledger_resource, org_id, wo, attrs) do
    ledger_resource
    |> Ash.Changeset.for_create(
      :record,
      Map.merge(
        %{
          org_id: org_id,
          warehouse_id: wo.warehouse_id,
          source_key: @source_key,
          source_id: wo.id
        },
        attrs
      )
    )
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, event} -> {:ok, event}
      {:error, reason} -> {:error, {:produce_failed, reason}}
    end
  end

  defp create_log_row(log_resource, org_id, wo, attrs) do
    log_resource
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{org_id: org_id, work_order_id: wo.id}, attrs),
      authorize?: false
    )
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, {:log_failed, reason}}
    end
  end

  # ── plumbing ────────────────────────────────────────────────────────────────

  defp resolve_org(changeset) do
    require Ash.Query

    case Ash.Changeset.get_attribute(changeset, :org_id) do
      value when is_binary(value) ->
        value

      _ ->
        changeset.resource
        |> Ash.Query.filter(id == ^changeset.data.id)
        |> Ash.Query.select(:org_id)
        |> Ash.read_one(authorize?: false)
        |> case do
          {:ok, %{org_id: org_id}} -> org_id
          other -> raise "the WO's org could not be resolved: #{inspect(other)}"
        end
    end
  end
end
