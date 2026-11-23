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

  WS-LOG L1 adds one refusal to this legacy path: a line whose item is
  lot-tracked, or whose item has any existing `Lot` row — including a row
  written out of band while the item's flag stayed `false` — refuses the whole
  order with `:lot_tracked_requires_l1b`, before any invoice, stock or COGS
  write. Lot-aware movement is L1b.

  Every refusal is fail-honest with a distinct formatted reason.
  """

  use Ash.Resource.Change

  alias Samen.Scopes.Inventory.ShipPosting

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
    lot_resource = Keyword.fetch!(opts, :lot)
    org_fx_settings = Keyword.get(opts, :org_fx_settings)

    so = changeset.data

    with :ok <- refuse_not_confirmed(so),
         {:ok, lines} <- frozen_lines(so_line_resource, org_id, so),
         {:ok, item_accounts, items} <- ShipPosting.item_accounts(item_resource, org_id, lines),
         :ok <- refuse_lot_backed(lot_resource, org_id, items, lines),
         {:ok, costs} <-
           ShipPosting.moving_averages(level_resource, org_id, so.warehouse_id, lines),
         {:ok, cogs_account} <-
           ShipPosting.posting_account(posting_account_resource, org_id, :cogs),
         {:ok, invoice} <-
           ShipPosting.emit_invoice(
             invoice_resource,
             org_id,
             so.customer_id,
             lines,
             org_fx_settings,
             "SO #{so.number} line"
           ) do
      # ── 1. the stock events (the negative-qty demand side) ─────────────
      # ── 2. the COGS entry (Dr :cogs / Cr each item's inventory account) ──
      with {:ok, _events} <-
             ShipPosting.write_stock_events(
               ledger_resource,
               org_id,
               so.warehouse_id,
               @source_key,
               so.id,
               lines,
               costs
             ),
           {:ok, _entry} <-
             ShipPosting.write_cogs_entry(
               entry_resource,
               org_id,
               Date.utc_today(),
               "COGS for sales order #{so.number}",
               @source_key,
               so.id,
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

  # WS-LOG L1: the legacy full-order path refuses a lot-tracked or lot-backed
  # item before any write. The maintained flag is one half; the live `Lot` read
  # is authoritative and catches rows written out of band (or by old writers)
  # while the flag stayed `false`. Lot-aware movement is L1b.
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

  # ── formatting ──────────────────────────────────────────────────────────────

  defp format({:not_fulfillable, status}),
    do: "the SO is #{inspect(status)} — only a :confirmed order fulfills (exactly-once)"

  defp format(:no_lines),
    do: "the SO carries no lines — an order without lines is a data error, not an empty sale"

  defp format({:lot_tracked_requires_l1b, item_id}),
    do:
      "item #{inspect(item_id)} is lot-tracked or has a Lot row — lot-aware movement is " <>
        "L1b; refusing the whole fulfillment before any stock, invoice or COGS write " <>
        "(:lot_tracked_requires_l1b)"

  defp format({:lots_read_failed, reason}),
    do: "the Lot existence read failed: #{inspect(reason)}"

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
