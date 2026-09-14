defmodule Samen.Scopes.Inventory.FulfillOrder do
  @moduledoc """
  THE BRIDGE (WS-ERP E5; design §3.3): on `SalesOrder :fulfill`, per line —
  a `StockLedger :sale` event (qty NEGATIVE in the item's UOM, cost = the
  rollup's moving-average snapshot at fulfillment, anchored
  `source_key: "sales_order"`) — plus the emission of the host's Billing
  invoice (`:open`, `amount_due` = Σ qty×price, the bounded line-items
  jsonb), the SO's own flip to `:fulfilled` and its invoice anchor — ALL
  inside the action's single transaction: stock and billing commit or roll
  back TOGETHER. An order that moved stock but emitted no invoice (or vice
  versa) is structurally impossible (and `ReconcileFulfillment` reads the
  two sides independently, so even a future bypass DIVERGES).

  Ordering inside the transaction (why it is safe):

    * the `:fulfill` action carries `Samen.Scopes.Finance.PostingMarker`
      BEFORE this change, so the belt marker is armed for the SO's own
      flip (`→fulfilled` is marker-gated in the belt);
    * each `StockLedger :record` create runs its own resource-wide changes
      (`NegativeStock` — selling below zero is REFUSED fail-closed unless
      the warehouse opted out; `StockLevelSync` re-derives the rollup and
      arms/restores ITS marker per write);
    * the invoice emission runs through the host module's generic create
      with `authorize?: false` (the system path — the caller is the
      salesperson, Billing's write surface is admin-gated; the house
      system-cascade posture).

  The stock cost side is the rollup's moving-average snapshot BEFORE the
  sale lands (read from the level row in-transaction — design §9's
  read-your-writes note), never the sale price: price is revenue, cost is
  inventory. The SO consumes its own FROZEN lines — no partial shipments
  in the base system (the documented P2 carry). Fulfillment is
  exactly-once: a second `:fulfill` is refused on the pre-state.

  Every refusal is fail-honest with a distinct formatted reason.
  """

  use Ash.Resource.Change

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

    so = changeset.data

    with :ok <- refuse_not_confirmed(so),
         {:ok, lines} <- frozen_lines(so_line_resource, org_id, so),
         {:ok, costs} <- moving_averages(level_resource, org_id, so.warehouse_id, lines),
         {:ok, invoice} <- emit_invoice(invoice_resource, org_id, so, lines) do
      # ── 1. the stock events (the negative-qty demand side) ─────────────
      case write_stock_events(ledger_resource, org_id, so, lines, costs) do
        {:ok, _events} ->
          # ── 2. the SO's own flip + the invoice anchor ───────────────────
          # before_action hooks return the BARE changeset (Ash re-wraps it).
          changeset
          |> Ash.Changeset.force_change_attribute(:status, :fulfilled)
          |> Ash.Changeset.force_change_attribute(:invoice_key, @invoice_key)
          |> Ash.Changeset.force_change_attribute(:invoice_id, invoice.id)
          |> Ash.Changeset.force_change_attribute(
            :fulfilled_at,
            DateTime.utc_now() |> DateTime.truncate(:second)
          )

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

  # The invoice emission: the host module's generic create (admin-gated for
  # humans; the cascade is the system path — authorize?: false). amount_due
  # = Σ qty×price; the line items carry the bounded jsonb shape.
  defp emit_invoice(invoice_resource, org_id, so, lines) do
    line_items =
      Enum.map(lines, fn line ->
        %{
          "description" => "SO #{so.number} line",
          "quantity" => line.qty,
          "amount_cents" => line.qty * line.unit_price_cents
        }
      end)

    amount_due = Enum.sum(Enum.map(lines, &(&1.qty * &1.unit_price_cents)))

    case invoice_resource
         |> Ash.Changeset.for_create(:create, %{
           org_id: org_id,
           customer_id: so.customer_id,
           status: :open,
           amount_due_cents: amount_due,
           amount_paid_cents: 0,
           currency: "USD",
           line_items: line_items
         })
         |> Ash.create(authorize?: false) do
      {:ok, invoice} -> {:ok, invoice}
      {:error, reason} -> {:error, {:invoice_failed, reason}}
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
