defmodule Samen.Scopes.Inventory.ShipPosting do
  @moduledoc """
  THE PARTIAL-SHIPMENT CHOKEPOINT (WS-LOG L1.2; design §3.1): on
  `Shipment :ship`, per line — a `StockLedger :sale` event (qty NEGATIVE in
  the item's UOM, cost = the rollup's moving-average snapshot at shipment,
  anchored `source_key: "shipment"`) — plus one posted COGS entry for the
  shipped lines (skipped when zero), one Billing invoice for those lines,
  the shipment's own flip to `:shipped`, and the SalesOrder's flip through
  the private `:apply_shipment` action — ALL inside the action's single
  transaction: stock, billing, COGS and both document states commit or roll
  back TOGETHER.

  The posting mechanics are shared with `FulfillOrder` (the E5 full-order
  bridge) through this module's public helpers, so the two paths cannot
  drift into different stock/COGS/invoice behavior. `FulfillOrder` keeps its
  full-order shape and its own legacy lot guard; this module owns the
  partial grain.

  ## The lock/re-read/flip protocol

    1. lock the org-pinned shipment row (`FOR UPDATE`), then its
       SalesOrder row — never the reverse order;
    2. re-read the shipment's lines, the SO's lines and the already-posted
       quantity per SO line AFTER both locks;
    3. refuse a shipment that is not `:draft`, an SO outside
       `:confirmed | :partially_fulfilled`, a warehouse mismatch, an empty
       shipment, an unknown/foreign `so_line`, a line whose item disagrees
       with its SO line, a non-positive qty, or a qty above the live
       remaining quantity — all before any write;
    4. freeze each line's `unit_cost_cents` through `:stamp_cost`, then
       post the stock, COGS and invoice legs;
    5. flip the shipment to `:shipped`; flip the SO through
       `:apply_shipment` (`confirmed -> :partially_fulfilled`, and
       `-> :fulfilled` when this shipment completes the order; a first
       complete shipment makes both transitions in order).

  Exactly-once is the lock/re-read/flip protocol: two concurrent `:ship`
  calls serialize on the shipment row, and the loser re-reads `:shipped`
  and refuses. Two concurrent shipments on one SO serialize on the SO row,
  so the second re-reads the reduced remaining quantity.

  The live `Lot` check remains authoritative: a lot-tracked item or any
  existing `Lot` row refuses with `:lot_tracked_requires_l1b` before any
  write, even when the maintained flag is still `false`.
  """

  use Ash.Resource.Change

  alias Samen.Scopes.Finance.ApFx

  @source_key "shipment"
  @invoice_key "billing_invoice"

  @doc "The shipment anchor source_key (stock + COGS legs)."
  def source_key, do: @source_key

  @doc "The invoice anchor key the shipment stamps."
  def invoice_key, do: @invoice_key

  @impl true
  def change(changeset, opts, _context) do
    org_id = resolve_org(changeset)

    Ash.Changeset.before_action(changeset, fn changeset ->
      do_ship(changeset, org_id, opts)
    end)
  end

  defp do_ship(changeset, org_id, opts) do
    shipment_line_resource = Keyword.fetch!(opts, :shipment_line)
    so_line_resource = Keyword.fetch!(opts, :so_line)
    so_resource = Keyword.fetch!(opts, :sales_order)
    ledger_resource = Keyword.fetch!(opts, :ledger)
    level_resource = Keyword.fetch!(opts, :level)
    invoice_resource = Keyword.fetch!(opts, :invoice)
    entry_resource = Keyword.fetch!(opts, :entry)
    posting_account_resource = Keyword.fetch!(opts, :posting_account)
    item_resource = Keyword.fetch!(opts, :item)
    lot_resource = Keyword.fetch!(opts, :lot)
    org_fx_settings = Keyword.get(opts, :org_fx_settings)

    shipment = changeset.data

    with {:ok, locked} <- lock_row(changeset.resource, org_id, shipment.id, :shipment),
         :ok <- refuse_not_draft(locked),
         {:ok, so} <- lock_row(so_resource, org_id, locked.sales_order_id, :sales_order),
         :ok <- refuse_so_state(so),
         :ok <- refuse_same_warehouse(locked, so),
         {:ok, lines} <- shipment_lines(shipment_line_resource, org_id, locked.id),
         :ok <- refuse_no_lines(lines),
         {:ok, so_lines} <- so_lines(so_line_resource, org_id, so.id),
         {:ok, expanded} <- expand_lines(so_lines, lines),
         {:ok, posted} <-
           posted_quantities(shipment_line_resource, changeset.resource, org_id, so_lines),
         :ok <- refuse_over_ship(expanded, posted),
         {:ok, costs} <- moving_averages(level_resource, org_id, locked.warehouse_id, expanded),
         {:ok, item_accounts, items} <- item_accounts(item_resource, org_id, expanded),
         :ok <- refuse_lot_backed(lot_resource, org_id, items, expanded),
         {:ok, cogs_account} <- posting_account(posting_account_resource, org_id, :cogs),
         {:ok, _stamped} <- stamp_costs(expanded, costs),
         {:ok, _events} <-
           write_stock_events(
             ledger_resource,
             org_id,
             locked.warehouse_id,
             @source_key,
             locked.id,
             expanded,
             costs
           ),
         {:ok, _entry} <-
           write_cogs_entry(
             entry_resource,
             org_id,
             Date.utc_today(),
             "COGS for shipment #{locked.number}",
             @source_key,
             locked.id,
             expanded,
             costs,
             item_accounts,
             cogs_account
           ),
         {:ok, invoice} <-
           emit_invoice(
             invoice_resource,
             org_id,
             so.customer_id,
             expanded,
             org_fx_settings,
             "Shipment #{locked.number} line"
           ),
         {:ok, _so} <- apply_shipment(so, so_lines, expanded, posted) do
      changeset
      |> Ash.Changeset.force_change_attribute(:status, :shipped)
      |> Ash.Changeset.force_change_attribute(:shipped_at, now())
      |> Ash.Changeset.force_change_attribute(:invoice_key, @invoice_key)
      |> Ash.Changeset.force_change_attribute(:invoice_id, invoice.id)
    else
      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :base,
          message: "the shipment cannot be shipped: #{format(reason)}"
        )
    end
  end

  # ── shared posting mechanics (also used by FulfillOrder) ────────────────────

  @doc """
  The moving-average snapshot per line's item, read BEFORE the sale lands.

  A missing level row refuses (never stocked); a nil average is a stocked
  zero-cost pair, not a missing cost.
  """
  def moving_averages(level_resource, org_id, warehouse_id, lines) do
    require Ash.Query

    Enum.reduce_while(lines, {:ok, %{}}, fn line, {:ok, acc} ->
      cond do
        Map.has_key?(acc, line.item_id) ->
          {:cont, {:ok, acc}}

        true ->
          case level_resource
               |> Ash.Query.filter(
                 org_id == ^org_id and item_id == ^line.item_id and
                   warehouse_id == ^warehouse_id
               )
               |> Ash.read_one(authorize?: false) do
            {:ok, %{avg_unit_cost_cents: avg}} when is_integer(avg) ->
              {:cont, {:ok, Map.put(acc, line.item_id, avg)}}

            {:ok, %{avg_unit_cost_cents: nil}} ->
              {:cont, {:ok, Map.put(acc, line.item_id, 0)}}

            {:ok, _} ->
              {:halt, {:error, {:never_stocked, line.item_id}}}

            {:error, reason} ->
              {:halt, {:error, {:level_read_failed, reason}}}
          end
      end
    end)
  end

  @doc """
  The per-item inventory-account link plus the item rows (the lot gate reads
  the maintained flag from the same read).
  """
  def item_accounts(item_resource, org_id, lines) do
    require Ash.Query

    item_ids = lines |> Enum.map(& &1.item_id) |> Enum.uniq()

    case item_resource
         |> Ash.Query.filter(org_id == ^org_id and id in ^item_ids)
         |> Ash.read(authorize?: false) do
      {:ok, items} ->
        by_id = Map.new(items, &{&1.id, &1})

        with {:ok, accounts} <-
               Enum.reduce_while(lines, {:ok, %{}}, fn line, {:ok, acc} ->
                 case Map.fetch(by_id, line.item_id) do
                   {:ok, %{default_inventory_account_id: account_id}}
                   when is_binary(account_id) ->
                     {:cont, {:ok, Map.put(acc, line.item_id, account_id)}}

                   {:ok, _item} ->
                     {:halt, {:error, {:missing_inventory_account, line.item_id}}}

                   :error ->
                     {:halt, {:error, {:item_not_found, line.item_id}}}
                 end
               end) do
          {:ok, accounts, by_id}
        end

      {:error, reason} ->
        {:error, {:items_read_failed, reason}}
    end
  end

  @doc "Resolve an org posting account by key."
  def posting_account(pa_resource, org_id, key) do
    require Ash.Query

    case pa_resource
         |> Ash.Query.filter(org_id == ^org_id and key == ^key)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, {:unmapped_posting_account, key}}
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, {:posting_account_read_failed, key, reason}}
    end
  end

  @doc "Post the negative-qty sale events for the shipped lines."
  def write_stock_events(
        ledger_resource,
        org_id,
        warehouse_id,
        source_key,
        source_id,
        lines,
        costs
      ) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case ledger_resource
           |> Ash.Changeset.for_create(:record, %{
             org_id: org_id,
             item_id: line.item_id,
             warehouse_id: warehouse_id,
             kind: :sale,
             qty: -line.qty,
             unit_cost_cents: Map.fetch!(costs, line.item_id),
             source_key: source_key,
             source_id: source_id
           })
           |> Ash.create(authorize?: false) do
        {:ok, event} -> {:cont, {:ok, [event | acc]}}
        {:error, reason} -> {:halt, {:error, {:stock_event_failed, reason}}}
      end
    end)
  end

  @doc """
  One posted COGS entry for the lines: Dr `:cogs`, Cr each line's item
  inventory account for qty × the frozen cost. A zero total posts no entry.
  """
  def write_cogs_entry(
        entry_resource,
        org_id,
        entry_date,
        memo,
        source_key,
        source_id,
        lines,
        costs,
        item_accounts,
        cogs
      ) do
    value = cogs_value(lines, costs)

    if value == 0 do
      {:ok, nil}
    else
      entry_lines =
        [
          %{account_id: cogs.account_id, debit_cents: value, credit_cents: 0}
        ] ++
          (lines
           |> Enum.map(fn line ->
             %{
               account_id: Map.fetch!(item_accounts, line.item_id),
               debit_cents: 0,
               credit_cents: line.qty * Map.fetch!(costs, line.item_id)
             }
           end)
           |> Enum.reject(&(&1.credit_cents == 0)))

      entry_attrs = %{
        org_id: org_id,
        entry_date: entry_date,
        memo: memo,
        source_key: source_key,
        source_id: source_id,
        lines: entry_lines
      }

      case entry_resource
           |> Ash.Changeset.for_create(:create_reversal, entry_attrs, authorize?: false)
           |> Ash.create(authorize?: false) do
        {:ok, entry} -> {:ok, entry}
        {:error, reason} -> {:error, {:cogs_entry_failed, reason}}
      end
    end
  end

  @doc """
  Emit and open one Billing invoice for the lines (the B0 `:issue` action).
  """
  def emit_invoice(invoice_resource, org_id, customer_id, lines, org_fx_settings, description) do
    if Ash.Resource.Info.action(invoice_resource, :issue) do
      line_items =
        Enum.map(lines, fn line ->
          %{
            "description" => description,
            "quantity" => line.qty,
            "amount_cents" => line.qty * line.unit_price_cents
          }
        end)

      amount_due = Enum.sum(Enum.map(lines, &(&1.qty * &1.unit_price_cents)))
      currency = ApFx.base_currency(org_fx_settings, org_id)

      with {:ok, draft} <-
             create_invoice(invoice_resource, %{
               org_id: org_id,
               customer_id: customer_id,
               amount_due_cents: amount_due,
               amount_paid_cents: 0,
               currency: currency,
               line_items: line_items
             }),
           {:ok, issued} <- issue_invoice(draft) do
        {:ok, issued}
      end
    else
      {:error, {:invoice_issue_action_missing, invoice_resource}}
    end
  end

  # ── shipment preflight ──────────────────────────────────────────────────────

  defp refuse_not_draft(shipment) do
    case shipment.status do
      :draft -> :ok
      other -> {:error, {:not_draft, other}}
    end
  end

  defp lock_row(resource, org_id, id, label) do
    require Ash.Query

    resource
    |> Ash.Query.filter(id == ^id and org_id == ^org_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %{} = row} -> {:ok, row}
      {:ok, nil} -> {:error, {:"#{label}_not_found", id}}
      {:error, reason} -> {:error, {:"#{label}_lock_failed", reason}}
    end
  end

  defp refuse_so_state(so) do
    case so.status do
      status when status in [:confirmed, :partially_fulfilled] -> :ok
      other -> {:error, {:so_not_shippable, other}}
    end
  end

  defp refuse_same_warehouse(shipment, so) do
    if shipment.warehouse_id == so.warehouse_id do
      :ok
    else
      {:error, {:warehouse_mismatch, shipment.warehouse_id, so.warehouse_id}}
    end
  end

  defp shipment_lines(resource, org_id, shipment_id) do
    require Ash.Query

    resource
    |> Ash.Query.filter(org_id == ^org_id and shipment_id == ^shipment_id)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, lines} -> {:ok, Enum.sort_by(lines, & &1.id)}
      {:error, reason} -> {:error, {:lines_read_failed, reason}}
    end
  end

  defp so_lines(resource, org_id, sales_order_id) do
    require Ash.Query

    resource
    |> Ash.Query.filter(org_id == ^org_id and sales_order_id == ^sales_order_id)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, lines} -> {:ok, Enum.sort_by(lines, & &1.id)}
      {:error, reason} -> {:error, {:so_lines_read_failed, reason}}
    end
  end

  defp refuse_no_lines([]), do: {:error, :no_lines}
  defp refuse_no_lines(_), do: :ok

  defp expand_lines(so_lines, lines) do
    by_id = Map.new(so_lines, &{&1.id, &1})

    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case Map.fetch(by_id, line.so_line_id) do
        {:ok, so_line} ->
          cond do
            so_line.item_id != line.item_id ->
              {:halt, {:error, {:line_item_mismatch, line.id}}}

            not is_integer(line.qty) or line.qty <= 0 ->
              {:halt, {:error, {:bad_qty, line.qty}}}

            true ->
              {:cont,
               {:ok,
                acc ++
                  [
                    %{
                      line: line,
                      so_line: so_line,
                      item_id: line.item_id,
                      qty: line.qty,
                      unit_price_cents: line.unit_price_cents
                    }
                  ]}}
          end

        :error ->
          {:halt, {:error, {:so_line_not_in_order, line.so_line_id}}}
      end
    end)
  end

  defp posted_quantities(line_resource, shipment_resource, org_id, so_lines) do
    Enum.reduce_while(so_lines, {:ok, %{}}, fn so_line, {:ok, acc} ->
      case posted_qty(line_resource, shipment_resource, org_id, so_line.id) do
        {:ok, qty} -> {:cont, {:ok, Map.put(acc, so_line.id, qty)}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  defp posted_qty(line_resource, shipment_resource, org_id, so_line_id) do
    line_table = AshPostgres.DataLayer.Info.table(line_resource)
    shipment_table = AshPostgres.DataLayer.Info.table(shipment_resource)
    repo = AshPostgres.DataLayer.Info.repo(line_resource, :mutate)

    l_org = col(line_resource, :org_id)
    l_so_line = col(line_resource, :so_line_id)
    l_qty = col(line_resource, :qty)
    l_shipment = col(line_resource, :shipment_id)
    s_id = col(shipment_resource, :id)
    s_status = col(shipment_resource, :status)

    case repo.query(
           """
           SELECT COALESCE(SUM(l.#{l_qty}), 0)
           FROM #{line_table} l
           JOIN #{shipment_table} s ON s.#{s_id} = l.#{l_shipment}
           WHERE l.#{l_org} = $1 AND l.#{l_so_line} = $2 AND s.#{s_status} = 'shipped'
           """,
           [dump_uuid(org_id), dump_uuid(so_line_id)]
         ) do
      {:ok, %{rows: [[total]]}} -> {:ok, to_i(total)}
      {:error, reason} -> {:error, {:posted_qty_read_failed, reason}}
    end
  end

  defp refuse_over_ship(expanded, posted) do
    Enum.reduce_while(expanded, :ok, fn %{so_line: so_line, qty: qty}, :ok ->
      remaining = so_line.qty - Map.get(posted, so_line.id, 0)

      if qty > remaining do
        {:halt, {:error, {:over_ship, so_line.id, remaining, qty}}}
      else
        {:cont, :ok}
      end
    end)
  end

  defp refuse_lot_backed(lot_resource, org_id, items, lines) do
    case Enum.find(lines, fn line ->
           match?(%{lot_tracked: true}, Map.get(items, line.item_id))
         end) do
      %{item_id: item_id} ->
        {:error, {:lot_tracked_requires_l1b, item_id}}

      nil ->
        existing_lots(lot_resource, org_id, lines)
    end
  end

  defp existing_lots(lot_resource, org_id, lines) do
    require Ash.Query

    item_ids = lines |> Enum.map(& &1.item_id) |> Enum.uniq()

    case lot_resource
         |> Ash.Query.filter(org_id == ^org_id and item_id in ^item_ids)
         |> Ash.read(authorize?: false) do
      {:ok, []} -> :ok
      {:ok, [lot | _]} -> {:error, {:lot_tracked_requires_l1b, lot.item_id}}
      {:error, reason} -> {:error, {:lots_read_failed, reason}}
    end
  end

  defp stamp_costs(expanded, costs) do
    Enum.reduce_while(expanded, {:ok, []}, fn %{line: line}, {:ok, acc} ->
      case line
           |> Ash.Changeset.for_update(
             :stamp_cost,
             %{unit_cost_cents: Map.fetch!(costs, line.item_id)},
             authorize?: false
           )
           |> Ash.update(authorize?: false) do
        {:ok, stamped} -> {:cont, {:ok, [stamped | acc]}}
        {:error, reason} -> {:halt, {:error, {:stamp_cost_failed, reason}}}
      end
    end)
  end

  defp apply_shipment(so, so_lines, expanded, posted) do
    shipped_now =
      Enum.reduce(expanded, %{}, fn %{so_line: so_line, qty: qty}, acc ->
        Map.update(acc, so_line.id, qty, &(&1 + qty))
      end)

    complete? =
      Enum.all?(so_lines, fn so_line ->
        Map.get(posted, so_line.id, 0) + Map.get(shipped_now, so_line.id, 0) >= so_line.qty
      end)

    targets =
      cond do
        so.status == :confirmed and complete? -> [:partially_fulfilled, :fulfilled]
        so.status == :confirmed -> [:partially_fulfilled]
        so.status == :partially_fulfilled and complete? -> [:fulfilled]
        true -> []
      end

    Enum.reduce_while(targets, {:ok, so}, fn target, {:ok, current} ->
      case current
           |> Ash.Changeset.for_update(:apply_shipment, %{status: target}, authorize?: false)
           |> Ash.update(authorize?: false) do
        {:ok, next} -> {:cont, {:ok, next}}
        {:error, reason} -> {:halt, {:error, {:so_flip_failed, target, reason}}}
      end
    end)
  end

  # ── private helpers ─────────────────────────────────────────────────────────

  defp cogs_value(lines, costs) do
    Enum.sum(Enum.map(lines, &(&1.qty * Map.fetch!(costs, &1.item_id))))
  end

  defp create_invoice(invoice_resource, attrs) do
    case invoice_resource
         |> Ash.Changeset.for_create(:create, attrs)
         |> Ash.create(authorize?: false) do
      {:ok, invoice} -> {:ok, invoice}
      {:error, reason} -> {:error, {:invoice_failed, reason}}
    end
  end

  defp issue_invoice(invoice) do
    case invoice
         |> Ash.Changeset.for_update(:issue, %{})
         |> Ash.update(authorize?: false) do
      {:ok, issued} -> {:ok, issued}
      {:error, reason} -> {:error, {:invoice_issue_failed, reason}}
    end
  end

  # ── formatting ──────────────────────────────────────────────────────────────

  defp format({:not_draft, status}),
    do: "the shipment is #{inspect(status)} — a shipment ships exactly once"

  defp format({:shipment_not_found, id}),
    do: "shipment #{inspect(id)} was not found in this org"

  defp format({:shipment_lock_failed, reason}),
    do: "the shipment row could not be locked: #{inspect(reason)}"

  defp format({:sales_order_not_found, id}),
    do: "the shipment's sales order #{inspect(id)} was not found in this org"

  defp format({:sales_order_lock_failed, reason}),
    do: "the sales order row could not be locked: #{inspect(reason)}"

  defp format({:so_not_shippable, status}),
    do: "the SO is #{inspect(status)} — only :confirmed or :partially_fulfilled ships"

  defp format(:no_lines), do: "the shipment carries no lines"

  defp format({:warehouse_mismatch, shipment_wh, so_wh}),
    do:
      "the shipment's warehouse #{inspect(shipment_wh)} is not the SO's #{inspect(so_wh)} — " <>
        "a shipment ships from the order's warehouse"

  defp format({:so_line_not_in_order, id}),
    do: "shipment line names a so_line that is not on this shipment's sales order: #{inspect(id)}"

  defp format({:line_item_mismatch, id}),
    do: "shipment line #{inspect(id)} names an item that disagrees with its so_line"

  defp format({:bad_qty, qty}),
    do: "every shipment line qty must be a positive integer — got: #{inspect(qty)}"

  defp format({:over_ship, so_line_id, remaining, qty}),
    do:
      "over-ship refused: so_line #{inspect(so_line_id)} has #{remaining} remaining and " <>
        "#{qty} were demanded"

  defp format({:lines_read_failed, reason}),
    do: "the shipment's line read failed: #{inspect(reason)}"

  defp format({:so_lines_read_failed, reason}),
    do: "the SO's line read failed: #{inspect(reason)}"

  defp format({:posted_qty_read_failed, reason}),
    do: "the posted-quantity read failed: #{inspect(reason)}"

  defp format({:never_stocked, item_id}),
    do:
      "item #{inspect(item_id)} has no moving-average cost — it was never stocked. " <>
        "Receive it first (fail-honest — inventory cost must be a fact)"

  defp format({:level_read_failed, reason}),
    do: "the rollup read failed: #{inspect(reason)}"

  defp format({:missing_inventory_account, item_id}),
    do:
      "item #{inspect(item_id)} has no default_inventory_account_id — an unlinked item " <>
        "cannot post COGS; refusing the whole shipment (fail-honest)"

  defp format({:item_not_found, item_id}),
    do: "item #{inspect(item_id)} was not found in this org; refusing the shipment"

  defp format({:items_read_failed, reason}),
    do: "the item inventory-account read failed: #{inspect(reason)}"

  defp format({:lot_tracked_requires_l1b, item_id}),
    do:
      "item #{inspect(item_id)} is lot-tracked or has a Lot row — lot-aware movement is " <>
        "L1b; refusing the whole shipment before any stock, invoice or COGS write " <>
        "(:lot_tracked_requires_l1b)"

  defp format({:lots_read_failed, reason}),
    do: "the Lot existence read failed: #{inspect(reason)}"

  defp format({:unmapped_posting_account, key}),
    do:
      "no PostingAccount row maps `#{key}` for this org (fail-honest — accounts are a " <>
        "host decision)"

  defp format({:posting_account_read_failed, key, reason}),
    do: "the posting account #{inspect(key)} could not be read: #{inspect(reason)}"

  defp format({:stamp_cost_failed, reason}),
    do: "freezing the shipment line's cost failed: #{inspect(reason)}"

  defp format({:stock_event_failed, reason}),
    do: "the shipment's stock event failed: #{inspect(reason)}"

  defp format({:cogs_entry_failed, reason}),
    do: "the shipment's COGS entry failed to land: #{inspect(reason)}"

  defp format({:invoice_failed, reason}),
    do: "the shipment's invoice emission failed: #{inspect(reason)}"

  defp format({:invoice_issue_action_missing, invoice_resource}),
    do: "the invoice module #{inspect(invoice_resource)} does not expose the B0 :issue action"

  defp format({:invoice_issue_failed, reason}),
    do: "the shipment's invoice issue failed: #{inspect(reason)}"

  defp format({:so_flip_failed, target, reason}),
    do: "the SO could not move to #{inspect(target)}: #{inspect(reason)}"

  defp format(reason), do: inspect(reason)

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
          other -> raise "the shipment's org could not be resolved: #{inspect(other)}"
        end
    end
  end

  defp col(resource, name) do
    case Ash.Resource.Info.attribute(resource, name) do
      nil -> raise ArgumentError, "no attribute #{inspect(name)} on #{inspect(resource)}"
      attr -> to_string(attr.source || attr.name)
    end
  end

  defp dump_uuid(value) when is_binary(value) and byte_size(value) == 16, do: value

  defp dump_uuid(value) do
    case Ecto.UUID.dump(value) do
      {:ok, bin} -> bin
      :error -> value
    end
  end

  defp to_i(nil), do: 0
  defp to_i(v) when is_integer(v), do: v
  defp to_i(%Decimal{} = d), do: Decimal.to_integer(d)

  defp to_i(bin) when is_binary(bin) do
    case Integer.parse(bin) do
      {i, ""} -> i
      _ -> 0
    end
  end

  defp to_i(_), do: 0

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
