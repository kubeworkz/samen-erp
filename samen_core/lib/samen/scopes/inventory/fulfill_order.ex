defmodule Samen.Scopes.Inventory.FulfillOrder do
  @moduledoc """
  THE BRIDGE (WS-ERP E5; design §3.3): on `SalesOrder :fulfill`, per line —
  a `StockLedger :sale` event (qty NEGATIVE in the item's UOM, cost = the
  rollup's moving-average snapshot at fulfillment, anchored
  `source_key: "sales_order"`) — plus the emission of the host's Billing
  invoice (`:open`, `amount_due` = Σ qty×price, the bounded line-items
  jsonb), the posted COGS entry (Dr `:cogs`, Cr each line item's
  `default_inventory_account_id` for the same qty×moving-average snapshot),
  the SO's own flip to `:fulfilled` and its invoice anchor — ALL inside the
  action's single transaction: stock, billing and COGS commit or roll back
  TOGETHER. An order that moved stock but emitted no invoice/COGS (or vice
  versa) is structurally impossible (and `ReconcileFulfillment` reads the
  sides independently, so even a future bypass DIVERGES).

  Ordering inside the transaction (why it is safe):

    * the `:fulfill` action carries `Samen.Scopes.Finance.PostingMarker`
      BEFORE this change, so the belt marker is armed for the SO's own
      flip (`→fulfilled` is marker-gated in the belt);
    * each `StockLedger :record` create runs its own resource-wide changes
      (`NegativeStock` — selling below zero is REFUSED fail-closed unless
      the warehouse opted out; `StockLevelSync` re-derives the rollup and
      arms/restores ITS marker per write);
    * the invoice emission creates a DRAFT through the host module's generic
      create and opens it through the B0 `:issue` action, both with
      `authorize?: false` (the system path — the caller is the salesperson,
      Billing's write surface is admin-gated; the house system-cascade
      posture);
    * after the stock events, the COGS entry is born through the governed
      posted `:create_reversal` factory. Its per-item inventory-account links
      and the org's `:cogs` mapping are resolved BEFORE any write; a missing
      link refuses the whole fulfillment rather than posting a partial COGS
      leg (the `GoodsPosting` posture).

  The stock cost side is the rollup's moving-average snapshot BEFORE the
  sale lands (read from the level row in-transaction — design §9's
  read-your-writes note), never the sale price: price is revenue, cost is
  inventory. The COGS debit total and each inventory credit use that same
  snapshot, so the P&L and balance-sheet legs cannot disagree. A zero-cost
  sale still fulfills, but posts NO COGS entry: `LineAmounts` rightly refuses
  a zero-zero line, and a zero-value journal is not a fact. The SO consumes
  its own FROZEN lines — no partial shipments in the base system (the
  documented P2 carry). Fulfillment is exactly-once: a second `:fulfill` is
  refused on the pre-state.

  Every refusal is fail-honest with a distinct formatted reason.
  """

  use Ash.Resource.Change

  alias Samen.Scopes.Finance.ApFx

  @source_key "sales_order"
  @invoice_key "billing_invoice"

  @doc "The sales-order anchor source_key (the PostingMarker guc/0 discipline)."
  def source_key, do: @source_key

  @doc "The invoice-anchor key the SO stamps (the PaymentReceipt contract)."
  def invoice_key, do: @invoice_key

  @impl true
  def change(changeset, opts, _context) do
    # Capture at change/2 time; resolve at the QUERY layer (fixture structs
    # never select org_id — the E4 lesson).
    org_id = resolve_org(changeset)

    Ash.Changeset.before_action(changeset, fn changeset ->
      do_fulfill(changeset, org_id, opts)
    end)
  end

  defp do_fulfill(changeset, org_id, opts) do
    so_line_resource = Keyword.fetch!(opts, :so_line)
    ledger_resource = Keyword.fetch!(opts, :ledger)
    level_resource = Keyword.fetch!(opts, :level)
    invoice_resource = Keyword.fetch!(opts, :invoice)
    entry_resource = Keyword.fetch!(opts, :entry)
    posting_account_resource = Keyword.fetch!(opts, :posting_account)
    item_resource = Keyword.fetch!(opts, :item)
    org_fx_settings = Keyword.get(opts, :org_fx_settings)

    so = changeset.data

    with :ok <- refuse_not_confirmed(so),
         {:ok, lines} <- frozen_lines(so_line_resource, org_id, so),
         {:ok, costs} <- moving_averages(level_resource, org_id, so.warehouse_id, lines),
         {:ok, item_accounts} <- item_accounts(item_resource, org_id, lines),
         {:ok, cogs_account} <- posting_account(posting_account_resource, org_id, :cogs),
         {:ok, invoice} <-
           emit_invoice(invoice_resource, org_id, so, lines, org_fx_settings) do
      # ── 1. the stock events (the negative-qty demand side) ─────────────
      # ── 2. the COGS entry (Dr :cogs / Cr each item's inventory account) ──
      with {:ok, _events} <- write_stock_events(ledger_resource, org_id, so, lines, costs),
           {:ok, _entry} <-
             write_cogs_entry(
               entry_resource,
               org_id,
               so,
               lines,
               costs,
               item_accounts,
               cogs_account
             ) do
        # ── 3. the SO's own flip + the invoice anchor ───────────────────
        # before_action hooks return the BARE changeset (Ash re-wraps it).
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :fulfilled)
        |> Ash.Changeset.force_change_attribute(:invoice_key, @invoice_key)
        |> Ash.Changeset.force_change_attribute(:invoice_id, invoice.id)
        |> Ash.Changeset.force_change_attribute(
          :fulfilled_at,
          DateTime.utc_now() |> DateTime.truncate(:second)
        )
      else
        {:error, reason} ->
          Ash.Changeset.add_error(changeset,
            field: :base,
            message: "the fulfillment failed to land: #{format(reason)}"
          )
      end
    else
      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :base,
          message: "the sales order cannot be fulfilled: #{format(reason)}"
        )
    end
  end

  # ── the write steps (any failure rolls the WHOLE transaction back) ──────────

  defp write_stock_events(ledger_resource, org_id, so, lines, costs) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      case ledger_resource
           |> Ash.Changeset.for_create(:record, %{
             org_id: org_id,
             item_id: line.item_id,
             warehouse_id: so.warehouse_id,
             kind: :sale,
             qty: -line.qty,
             unit_cost_cents: Map.fetch!(costs, line.item_id),
             source_key: @source_key,
             source_id: so.id
           })
           |> Ash.create(authorize?: false) do
        {:ok, event} -> {:cont, {:ok, [event | acc]}}
        {:error, reason} -> {:halt, {:error, {:stock_event_failed, reason}}}
      end
    end)
  end

  # The COGS leg: one posted entry anchored to the sales order, Dr :cogs and
  # Cr each line's item `default_inventory_account_id` for qty × the
  # moving-average cost snapshot. It runs after the stock events, inside the
  # outer `:fulfill` transaction, so a missing item link / unmapped :cogs /
  # closed period rolls the whole fulfillment back.
  #
  # A zero total is deliberately a SKIP, not a zero-value entry: LineAmounts
  # refuses a line with both amounts zero, and an entry with no amount is
  # accounting noise rather than a fact. In a mixed sale, zero-cost lines are
  # omitted so the positive lines remain a valid balanced entry.
  defp write_cogs_entry(entry_resource, org_id, so, lines, costs, item_accounts, cogs) do
    value = cogs_value(lines, costs)

    if value == 0 do
      {:ok, nil}
    else
      entry_lines =
        [
          %{
            account_id: cogs.account_id,
            debit_cents: value,
            credit_cents: 0
          }
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
        entry_date: Date.utc_today(),
        memo: "COGS for sales order #{so.number}",
        source_key: @source_key,
        source_id: so.id,
        lines: entry_lines
      }

      # The posted-born internal factory (the GoodsPosting shape): the COGS
      # entry is a fact at fulfillment, not a draft hidden from the GL.
      case entry_resource
           |> Ash.Changeset.for_create(:create_reversal, entry_attrs, authorize?: false)
           |> Ash.create(authorize?: false) do
        {:ok, entry} -> {:ok, entry}
        {:error, reason} -> {:error, {:cogs_entry_failed, reason}}
      end
    end
  end

  defp cogs_value(lines, costs) do
    Enum.sum(Enum.map(lines, &(&1.qty * Map.fetch!(costs, &1.item_id))))
  end

  # The per-item inventory-account link is a precondition of the whole
  # fulfillment (the GoodsPosting posture): an unlinked item cannot post a
  # COGS credit, so it refuses before the invoice or any stock event lands.
  defp item_accounts(item_resource, org_id, lines) do
    require Ash.Query

    item_ids = lines |> Enum.map(& &1.item_id) |> Enum.uniq()

    case item_resource
         |> Ash.Query.filter(org_id == ^org_id and id in ^item_ids)
         |> Ash.read(authorize?: false) do
      {:ok, items} ->
        by_id = Map.new(items, &{&1.id, &1})

        Enum.reduce_while(lines, {:ok, %{}}, fn line, {:ok, acc} ->
          case Map.fetch(by_id, line.item_id) do
            {:ok, %{default_inventory_account_id: account_id}} when is_binary(account_id) ->
              {:cont, {:ok, Map.put(acc, line.item_id, account_id)}}

            {:ok, _item} ->
              {:halt, {:error, {:missing_inventory_account, line.item_id}}}

            :error ->
              {:halt, {:error, {:item_not_found, line.item_id}}}
          end
        end)

      {:error, reason} ->
        {:error, {:items_read_failed, reason}}
    end
  end

  defp posting_account(pa_resource, org_id, key) do
    require Ash.Query

    case pa_resource
         |> Ash.Query.filter(org_id == ^org_id and key == ^key)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, {:unmapped_posting_account, key}}
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, {:posting_account_read_failed, key, reason}}
    end
  end

  # The invoice emission: create the host's real invoice as a DRAFT in the
  # org's functional currency, then open it through the one sanctioned
  # `:issue` action. Both writes are inside the outer `:fulfill` transaction
  # (whose PostingMarker is already armed), so stock, the AR entry, COGS and
  # the invoice flip commit or roll back together. amount_due = Σ qty×price;
  # the line items carry the bounded jsonb shape.
  defp emit_invoice(invoice_resource, org_id, so, lines, org_fx_settings) do
    if Ash.Resource.Info.action(invoice_resource, :issue) do
      line_items =
        Enum.map(lines, fn line ->
          %{
            "description" => "SO #{so.number} line",
            "quantity" => line.qty,
            "amount_cents" => line.qty * line.unit_price_cents
          }
        end)

      amount_due = Enum.sum(Enum.map(lines, &(&1.qty * &1.unit_price_cents)))
      currency = ApFx.base_currency(org_fx_settings, org_id)

      with {:ok, draft} <-
             create_invoice(invoice_resource, %{
               org_id: org_id,
               customer_id: so.customer_id,
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

  # ── reads + refusals ────────────────────────────────────────────────────────

  defp refuse_not_confirmed(so) do
    case so.status do
      :confirmed -> :ok
      other -> {:error, {:not_fulfillable, other}}
    end
  end

  # The order's own frozen lines (query-layer org pin — the E4 lesson). An
  # order whose lines vanished is a data error, not an empty fulfillment.
  defp frozen_lines(so_line_resource, org_id, so) do
    require Ash.Query

    case so_line_resource
         |> Ash.Query.filter(sales_order_id == ^so.id and org_id == ^org_id)
         |> Ash.read(authorize?: false) do
      {:ok, []} -> {:error, :no_lines}
      {:ok, lines} -> {:ok, Enum.sort_by(lines, & &1.id)}
      {:error, reason} -> {:error, {:lines_read_failed, reason}}
    end
  end

  # The moving-average snapshot per line's item, BEFORE the sale lands —
  # read off the rollup rows in-transaction. A level row is guaranteed to
  # exist for any pair the goods receipts touched; a NEVER-stocked pair is
  # refused fail-honest (selling stock the org never received is a data
  # error even when the warehouse would allow negative).
  defp moving_averages(level_resource, org_id, warehouse_id, lines) do
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

            # StockLevelSync leaves the average NULL when no observed event was
            # VALUED (cost > 0) — a zero-cost receipt is exactly that case. A
            # level row means the pair was stocked, so its cost is zero, not
            # "never stocked".
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

  # ── formatting ──────────────────────────────────────────────────────────────

  defp format({:not_fulfillable, status}),
    do: "the SO is #{inspect(status)} — only a :confirmed order fulfills (exactly-once)"

  defp format(:no_lines),
    do: "the SO carries no lines — an order without lines is a data error, not an empty sale"

  defp format({:lines_read_failed, reason}),
    do: "the SO's line read failed: #{inspect(reason)}"

  defp format({:never_stocked, item_id}),
    do: "item #{inspect(item_id)} has no moving-average cost — it was never stocked. " <>
          "Sell what the org received: receive it first (fail-honest — inventory cost " <>
          "must be a fact, not an invention)"

  defp format({:level_read_failed, reason}),
    do: "the rollup read failed: #{inspect(reason)}"

  defp format({:stock_event_failed, reason}),
    do: "the fulfillment's stock event failed: #{inspect(reason)} (NegativeStock refuses " <>
          "selling below zero unless the warehouse opted out)"

  defp format({:invoice_failed, reason}),
    do: "the fulfillment's invoice emission failed: #{inspect(reason)}"

  defp format({:invoice_issue_action_missing, invoice_resource}),
    do:
      "the invoice module #{inspect(invoice_resource)} does not expose the B0 :issue action " <>
        "(the Inventory billing mount requires a B0-capable invoice)"

  defp format({:invoice_issue_failed, reason}),
    do: "the fulfillment's invoice issue failed: #{inspect(reason)}"

  defp format({:missing_inventory_account, item_id}),
    do:
      "item #{inspect(item_id)} has no default_inventory_account_id — an unlinked item " <>
        "cannot post COGS; refusing the whole fulfillment (fail-honest)"

  defp format({:item_not_found, item_id}),
    do: "item #{inspect(item_id)} was not found in this org; refusing the fulfillment"

  defp format({:items_read_failed, reason}),
    do: "the item inventory-account read failed: #{inspect(reason)}"

  defp format({:unmapped_posting_account, key}),
    do:
      "no PostingAccount row maps `#{key}` for this org (fail-honest — accounts are a " <>
        "host decision)"

  defp format({:posting_account_read_failed, key, reason}),
    do: "the posting account #{inspect(key)} could not be read: #{inspect(reason)}"

  defp format({:cogs_entry_failed, reason}),
    do: "the fulfillment's COGS entry failed to land: #{inspect(reason)}"

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
          other -> raise "the SO's org could not be resolved: #{inspect(other)}"
        end
    end
  end
end
