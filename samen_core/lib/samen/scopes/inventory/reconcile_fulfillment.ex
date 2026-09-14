defmodule Samen.Scopes.Inventory.ReconcileFulfillment do
  @moduledoc """
  The fulfillment reconciliation reads (WS-ERP E5; design §3.3 + §6.3):
  for every fulfilled sales order, the stock side and the billing side are
  computed as INDEPENDENT bare-SQL sums (the two share only the order's id
  — never a code path), so a bridge bypass that lands one side without the
  other DIVERGES and the red-path fails.

  * `order/3` — one SO's two legs: the ledger events anchored
    `source_key: "sales_order"` + `source_id` (Σ qty as a NEGATIVE sum's
    absolute value, Σ qty×cost), and the emitted invoice's `amount_due`
    (the revenue side).
  * `divergences/2` — every org SO whose stock leg disagrees with its
    billing leg — the standing read the suite's green paths assert empty
    and the sabotage's bypass makes non-empty. (Stock and revenue are
    DIFFERENT quantities by nature — qty vs cents — so the standing
    equality is structural, not arithmetic: an order is `:fulfilled` with
    its invoice anchor SET iff its `:sale` events exist. The read refuses
    exactly the half-landed shapes: events without an anchor, an anchor
    without events.)
  """

  @source_key "sales_order"

  @doc "The sales-order anchor source_key (single source of truth, the FulfillOrder discipline)."
  def source_key, do: @source_key

  @doc """
  One fulfilled SO's two legs, each computed fresh from its own table:

    * `:stock` — Σ qty (negative) and Σ (qty × unit_cost) over the org's
      StockLedger events anchored this order;
    * `:billing` — the emitted invoice's (`:id`, `:amount_due_cents`,
      `:status`) resolved through the SO's `invoice_key`/`invoice_id`
      anchor.

  By construction the invoice exists iff the events do; a bypass that
  landed one side without the other diverges here.
  """
  def order(repo, org_id, opts) do
    so_id = Keyword.fetch!(opts, :sales_order_id)

    with {:ok, stock} <- stock_leg(repo, org_id, so_id, opts),
         {:ok, billing} <- billing_leg(repo, org_id, so_id, opts) do
      {:ok, %{stock: stock, billing: billing}}
    end
  end

  @doc """
  Every org SO whose two sides disagree — the standing fulfillment read.
  Four half-landed shapes are refused (any one flags the order):

    * a `:fulfilled` SO with NO `:sale` events;
    * a `:fulfilled` SO with NO invoice anchor;
    * `:sale` events anchored to a SO that never fulfilled (a forged
      demand event);
    * an anchored SO whose invoice row does not exist.
  """
  def divergences(repo, org_id, opts) do
    so_resource = Keyword.fetch!(opts, :so_resource)
    ledger_resource = Keyword.fetch!(opts, :ledger_resource)
    invoice_resource = Keyword.fetch!(opts, :invoice_resource)

    so_table = AshPostgres.DataLayer.Info.table(so_resource)
    ledger_table = AshPostgres.DataLayer.Info.table(ledger_resource)
    inv_table = AshPostgres.DataLayer.Info.table(invoice_resource)

    so_org = col(so_resource, :org_id)
    so_id = col(so_resource, :id)
    so_status = col(so_resource, :status)
    so_inv_key = col(so_resource, :invoice_key)
    so_inv_id = col(so_resource, :invoice_id)

    l_org = col(ledger_resource, :org_id)
    l_src_id = col(ledger_resource, :source_id)
    l_src_key = col(ledger_resource, :source_key)
    l_qty = col(ledger_resource, :qty)
    l_cost = col(ledger_resource, :unit_cost_cents)

    i_org = col(invoice_resource, :org_id)
    i_id = col(invoice_resource, :id)
    i_due = col(invoice_resource, :amount_due_cents)

    case repo.query(
           """
           WITH stock AS (
             SELECT #{l_src_id} AS sid,
                    COUNT(*) AS events,
                    SUM(#{l_qty}) AS qty,
                    SUM(#{l_qty} * #{l_cost}) AS value
             FROM #{ledger_table}
             WHERE #{l_org} = $1 AND #{l_src_key} = '#{source_key()}'
             GROUP BY #{l_src_id}
           )
           SELECT so.#{so_id},
                  COALESCE(s.events, 0), COALESCE(s.qty, 0), COALESCE(s.value, 0),
                  so.#{so_inv_key}, so.#{so_inv_id},
                  COALESCE(i.#{i_due}, 0), COALESCE(i.#{i_id} IS NOT NULL, false)
           FROM #{so_table} so
           LEFT JOIN stock s ON s.sid = so.#{so_id}
           LEFT JOIN #{inv_table} i ON i.#{i_id} = so.#{so_inv_id} AND i.#{i_org} = $1
           WHERE so.#{so_org} = $1
             AND (
               (so.#{so_status} = 'fulfilled' AND COALESCE(s.events, 0) = 0)
               OR (so.#{so_status} = 'fulfilled' AND so.#{so_inv_id} IS NULL)
               OR (so.#{so_status} IS DISTINCT FROM 'fulfilled' AND COALESCE(s.events, 0) > 0)
               OR (so.#{so_status} = 'fulfilled' AND so.#{so_inv_id} IS NOT NULL AND i.#{i_id} IS NULL)
             )
           """,
           [dump_uuid(org_id)]
         ) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [sid, events, qty, value, inv_key, inv_id, due, invoice_exists] ->
           %{
             sales_order_id: to_uuid(sid),
             stock_events: to_i(events),
             stock_qty: to_i(qty),
             stock_value: to_i(value),
             invoice_key: inv_key,
             invoice_id: to_uuid(inv_id),
             invoice_amount_due: to_i(due),
             invoice_exists: invoice_exists
           }
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── the two legs ────────────────────────────────────────────────────────────

  defp stock_leg(repo, org_id, so_id, opts) do
    ledger_resource = Keyword.fetch!(opts, :ledger_resource)
    table = AshPostgres.DataLayer.Info.table(ledger_resource)
    org = col(ledger_resource, :org_id)
    src_id = col(ledger_resource, :source_id)
    src_key = col(ledger_resource, :source_key)
    qty = col(ledger_resource, :qty)
    cost = col(ledger_resource, :unit_cost_cents)

    case repo.query(
           """
           SELECT COALESCE(SUM(#{qty}), 0), COALESCE(SUM(#{qty} * #{cost}), 0)
           FROM #{table}
           WHERE #{org} = $1 AND #{src_key} = $2 AND #{src_id} = $3
           """,
           [dump_uuid(org_id), source_key(), dump_uuid(so_id)]
         ) do
      {:ok, %{rows: [[qty_sum, value_sum]]}} ->
        {:ok, %{qty: to_i(qty_sum), value: to_i(value_sum)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp billing_leg(repo, org_id, sales_order_id, opts) do
    so_resource = Keyword.fetch!(opts, :so_resource)
    invoice_resource = Keyword.fetch!(opts, :invoice_resource)

    so_table = AshPostgres.DataLayer.Info.table(so_resource)
    inv_table = AshPostgres.DataLayer.Info.table(invoice_resource)

    so_org = col(so_resource, :org_id)
    so_id = col(so_resource, :id)
    so_inv_id = col(so_resource, :invoice_id)

    i_org = col(invoice_resource, :org_id)
    i_id = col(invoice_resource, :id)
    i_due = col(invoice_resource, :amount_due_cents)
    i_status = col(invoice_resource, :status)

    case repo.query(
           """
           SELECT i.#{i_id}, i.#{i_due}, i.#{i_status}
           FROM #{so_table} so
           LEFT JOIN #{inv_table} i ON i.#{i_id} = so.#{so_inv_id} AND i.#{i_org} = $1
           WHERE so.#{so_org} = $1 AND so.#{so_id} = $2
           """,
           [dump_uuid(org_id), dump_uuid(sales_order_id)]
         ) do
      {:ok, %{rows: []}} ->
        {:error, :order_not_found}

      {:ok, %{rows: [[nil, nil, nil]]}} ->
        {:ok, nil}

      {:ok, %{rows: [[id, due, status]]}} ->
        {:ok, %{id: to_uuid(id), amount_due_cents: to_i(due), status: to_atom(status)}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

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

  defp to_uuid(<<_::128>> = bin), do: Ecto.UUID.load!(bin)
  defp to_uuid(bin) when is_binary(bin), do: bin
  defp to_uuid(nil), do: nil

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

  defp to_atom(nil), do: nil
  defp to_atom(bin) when is_binary(bin), do: String.to_existing_atom(bin)
  defp to_atom(a) when is_atom(a), do: a
end
