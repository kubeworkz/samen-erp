defmodule Samen.Scopes.Inventory.ReconcileShipment do
  @moduledoc """
  The R6 reconciliation read (WS-LOG L1.2; design §4.7): for every shipped
  shipment, the stock side, the shipment-line facts, the invoice, the posted
  COGS entry and the sales order's open quantity are computed as INDEPENDENT
  bare-SQL sums. The read shares only ids with the posting path, never its
  arithmetic, so a bypass that lands one leg without the others DIVERGES.

  ## The legs

    * **stock** — `StockLedger` events anchored `source_key: "shipment"` +
      `source_id`: event count, Σ qty (the sale is negative) and Σ
      (`qty` × `unit_cost_cents`).
    * **lines** — the shipment's own `ShipmentLine` rows: count, Σ qty,
      Σ (`qty` × `unit_price_cents`) and Σ (`qty` × the frozen
      `unit_cost_cents`).
    * **invoice** — the shipment's `invoice_key`/`invoice_id` anchor and the
      invoice row's `amount_due_cents`, compared with the lines' price total.
    * **COGS** — the posted `JournalEntry` anchored `"shipment"` + shipment
      id: entry count and Σ debit, compared with `abs(stock value)` (the
      stock events' frozen cost snapshot). A zero-cost shipment posts no
      entry; an entry there is unexpected.
    * **order** — the SO's ordered qty (Σ `SoLine.qty`) and shipped qty
      (Σ lines on `:shipped` shipments), with `open = ordered - shipped`.
      Open is never negative.

  ## Divergences

  A shipped shipment is named when any of these fail:

    * `:stock_line_count_mismatch` / `:stock_line_qty_mismatch` /
      `:stock_line_value_mismatch` — the stock events and shipment lines
      disagree on count, quantity or frozen value;
    * `:empty_shipment` — a shipped shipment has no lines;
    * `:invoice_anchor_mismatch` / `:missing_invoice` /
      `:invoice_total_mismatch` — the anchor is wrong, the invoice row is
      absent, or its amount due disagrees with Σ qty × price;
    * `:missing_cogs` / `:foreign_cogs` / `:misvalued_cogs` — the COGS
      entry is absent, owned by another org, or its debit total disagrees;
    * `:negative_open_qty` — the SO's shipped quantity exceeds its ordered
      quantity (the over-ship shape).

  `shipment/3` returns one shipment's legs even while it is a draft (a draft
  has no posting obligations); `divergences/3` scans shipped shipments only.
  """

  @source_key "shipment"
  @invoice_key "billing_invoice"

  @doc "The shipment anchor source_key (stock + COGS legs)."
  def source_key, do: @source_key

  @doc "The invoice anchor key the shipment stamps."
  def invoice_key, do: @invoice_key

  @doc """
  One shipment's legs, each computed fresh from its own table.

  Returns `{:ok, map}` or `{:error, :shipment_not_found}` (also returned for
  a shipment outside the org). A draft's `:divergences` is empty by
  definition; the posting obligations apply once it is `:shipped`.
  """
  def shipment(repo, org_id, opts) do
    shipment_id = Keyword.fetch!(opts, :shipment_id)

    with {:ok, rows} <- query(repo, org_id, opts, {:id, shipment_id}) do
      case rows do
        [row] -> {:ok, row_to_map(row)}
        [] -> {:error, :shipment_not_found}
      end
    end
  end

  @doc """
  Every org shipment whose legs disagree — the standing R6 read. Shipped
  shipments only: a draft is a staged intention, not a fact.
  """
  def divergences(repo, org_id, opts) do
    with {:ok, rows} <- query(repo, org_id, opts, :shipped) do
      {:ok,
       rows
       |> Enum.map(&row_to_map/1)
       |> Enum.reject(&(&1.divergences == []))}
    end
  end

  # ── the query ───────────────────────────────────────────────────────────────

  defp query(repo, org_id, opts, scope) do
    ctx = context(opts)

    {scope_sql, params} =
      case scope do
        :shipped ->
          {" AND s.#{ctx.shipment_status} = 'shipped'", [dump_uuid(org_id)]}

        {:id, shipment_id} ->
          {" AND s.#{ctx.shipment_id} = $2", [dump_uuid(org_id), dump_uuid(shipment_id)]}
      end

    sql = """
    WITH stock AS (
      SELECT #{ctx.ledger_source_id} AS sid,
             COUNT(*) AS events,
             COALESCE(SUM(#{ctx.ledger_qty}), 0) AS qty,
             COALESCE(SUM(#{ctx.ledger_qty} * #{ctx.ledger_cost}), 0) AS value
      FROM #{ctx.ledger_table}
      WHERE #{ctx.ledger_org} = $1
        AND #{ctx.ledger_source_key} = '#{@source_key}'
      GROUP BY #{ctx.ledger_source_id}
    ),
    line_facts AS (
      SELECT #{ctx.line_shipment} AS sid,
             COUNT(*) AS line_count,
             COALESCE(SUM(#{ctx.line_qty}), 0) AS qty,
             COALESCE(SUM(#{ctx.line_qty} * #{ctx.line_price}), 0) AS price_cents,
             COALESCE(SUM(#{ctx.line_qty} * #{ctx.line_cost}), 0) AS cost_cents
      FROM #{ctx.shipment_line_table}
      WHERE #{ctx.line_org} = $1
      GROUP BY #{ctx.line_shipment}
    ),
    cogs AS (
      SELECT e.#{ctx.entry_source_id} AS sid,
             COUNT(DISTINCT e.#{ctx.entry_id}) AS entries,
             COALESCE(SUM(l.#{ctx.line_debit}), 0) AS debit_cents
      FROM #{ctx.entry_table} e
      LEFT JOIN #{ctx.journal_line_table} l ON l.#{ctx.line_entry_fk} = e.#{ctx.entry_id}
      WHERE e.#{ctx.entry_org} = $1
        AND e.#{ctx.entry_source_key} = '#{@source_key}'
        AND e.#{ctx.entry_status} = 'posted'
      GROUP BY e.#{ctx.entry_source_id}
    ),
    foreign_cogs AS (
      SELECT e.#{ctx.entry_source_id} AS sid, COUNT(*) AS entries
      FROM #{ctx.entry_table} e
      JOIN #{ctx.shipment_table} s2
        ON s2.#{ctx.shipment_id} = e.#{ctx.entry_source_id}
       AND s2.#{ctx.shipment_org} = $1
      WHERE e.#{ctx.entry_source_key} = '#{@source_key}'
        AND e.#{ctx.entry_org} <> $1
      GROUP BY e.#{ctx.entry_source_id}
    ),
    ordered AS (
      SELECT #{ctx.so_line_so} AS soid, COALESCE(SUM(#{ctx.so_line_qty}), 0) AS qty
      FROM #{ctx.so_line_table}
      WHERE #{ctx.so_line_org} = $1
      GROUP BY #{ctx.so_line_so}
    ),
    shipped AS (
      SELECT sh.#{ctx.shipment_so} AS soid, COALESCE(SUM(sl.#{ctx.line_qty}), 0) AS qty
      FROM #{ctx.shipment_line_table} sl
      JOIN #{ctx.shipment_table} sh
        ON sh.#{ctx.shipment_id} = sl.#{ctx.line_shipment}
       AND sh.#{ctx.shipment_org} = $1
      WHERE sl.#{ctx.line_org} = $1
        AND sh.#{ctx.shipment_status} = 'shipped'
      GROUP BY sh.#{ctx.shipment_so}
    )
    SELECT s.#{ctx.shipment_id},
           s.#{ctx.shipment_status},
           s.#{ctx.shipment_invoice_key},
           s.#{ctx.shipment_invoice_id},
           s.#{ctx.shipment_so},
           COALESCE(st.events, 0), COALESCE(st.qty, 0), COALESCE(st.value, 0),
           COALESCE(ln.line_count, 0), COALESCE(ln.qty, 0),
           COALESCE(ln.price_cents, 0), COALESCE(ln.cost_cents, 0),
           i.#{ctx.invoice_id}, COALESCE(i.#{ctx.invoice_due}, 0),
           COALESCE(cg.entries, 0), COALESCE(cg.debit_cents, 0), COALESCE(fc.entries, 0),
           COALESCE(o.qty, 0), COALESCE(sh.qty, 0)
    FROM #{ctx.shipment_table} s
    LEFT JOIN stock st ON st.sid = s.#{ctx.shipment_id}
    LEFT JOIN line_facts ln ON ln.sid = s.#{ctx.shipment_id}
    LEFT JOIN #{ctx.invoice_table} i
      ON i.#{ctx.invoice_id} = s.#{ctx.shipment_invoice_id}
     AND i.#{ctx.invoice_org} = $1
    LEFT JOIN cogs cg ON cg.sid = s.#{ctx.shipment_id}
    LEFT JOIN foreign_cogs fc ON fc.sid = s.#{ctx.shipment_id}
    LEFT JOIN ordered o ON o.soid = s.#{ctx.shipment_so}
    LEFT JOIN shipped sh ON sh.soid = s.#{ctx.shipment_so}
    WHERE s.#{ctx.shipment_org} = $1
    #{scope_sql}
    ORDER BY s.#{ctx.shipment_id}
    """

    case repo.query(sql, params) do
      {:ok, %{rows: rows}} -> {:ok, rows}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── row shaping ─────────────────────────────────────────────────────────────

  defp row_to_map([
         shipment_id,
         status,
         invoice_key,
         invoice_id,
         sales_order_id,
         stock_events,
         stock_qty,
         stock_value,
         line_count,
         line_qty,
         line_price,
         line_cost,
         invoice_row_id,
         invoice_due,
         cogs_entries,
         cogs_debit,
         cogs_foreign,
         ordered_qty,
         shipped_qty
       ]) do
    status = to_atom(status)

    stock = %{
      events: to_i(stock_events),
      qty: to_i(stock_qty),
      value_cents: to_i(stock_value)
    }

    lines = %{
      count: to_i(line_count),
      qty: to_i(line_qty),
      price_cents: to_i(line_price),
      cost_cents: to_i(line_cost)
    }

    invoice = %{
      key: invoice_key,
      id: to_uuid(invoice_id),
      exists: not is_nil(invoice_row_id),
      amount_due_cents: to_i(invoice_due),
      expected_cents: lines.price_cents
    }

    cogs = %{
      status:
        cogs_status(
          to_i(cogs_entries),
          to_i(cogs_debit),
          to_i(cogs_foreign),
          abs(stock.value_cents)
        ),
      entries: to_i(cogs_entries),
      debit_cents: to_i(cogs_debit),
      foreign_entries: to_i(cogs_foreign),
      expected_cents: abs(stock.value_cents)
    }

    order = %{
      sales_order_id: to_uuid(sales_order_id),
      ordered_qty: to_i(ordered_qty),
      shipped_qty: to_i(shipped_qty),
      open_qty: to_i(ordered_qty) - to_i(shipped_qty)
    }

    divergences =
      if status == :shipped do
        stock_divergences(stock, lines) ++
          invoice_divergences(invoice) ++
          cogs_divergences(cogs) ++
          order_divergences(order)
      else
        []
      end

    %{
      shipment_id: to_uuid(shipment_id),
      status: status,
      stock: stock,
      lines: lines,
      invoice: invoice,
      cogs: cogs,
      order: order,
      divergences: divergences
    }
  end

  # ── divergence classification ───────────────────────────────────────────────

  defp stock_divergences(stock, lines) do
    [
      if(stock.events != lines.count, do: :stock_line_count_mismatch),
      if(stock.qty != -lines.qty, do: :stock_line_qty_mismatch),
      if(stock.value_cents != -lines.cost_cents, do: :stock_line_value_mismatch),
      if(lines.count == 0, do: :empty_shipment)
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp invoice_divergences(invoice) do
    cond do
      invoice.key != @invoice_key -> [:invoice_anchor_mismatch]
      is_nil(invoice.id) or not invoice.exists -> [:missing_invoice]
      invoice.amount_due_cents != invoice.expected_cents -> [:invoice_total_mismatch]
      true -> []
    end
  end

  defp cogs_status(entries, debit_cents, foreign_entries, expected_cents) do
    cond do
      foreign_entries > 0 -> :foreign
      expected_cents > 0 and entries == 0 -> :missing
      expected_cents == 0 and entries == 0 -> :ok
      entries == 1 and debit_cents == expected_cents -> :ok
      true -> :misvalued
    end
  end

  defp cogs_divergences(%{status: :ok}), do: []
  defp cogs_divergences(%{status: :missing}), do: [:missing_cogs]
  defp cogs_divergences(%{status: :foreign}), do: [:foreign_cogs]
  defp cogs_divergences(%{status: :misvalued}), do: [:misvalued_cogs]

  defp order_divergences(order) do
    if order.open_qty < 0, do: [:negative_open_qty], else: []
  end

  # ── context ─────────────────────────────────────────────────────────────────

  defp context(opts) do
    shipment = Keyword.fetch!(opts, :shipment_resource)
    line = Keyword.fetch!(opts, :shipment_line_resource)
    ledger = Keyword.fetch!(opts, :ledger_resource)
    invoice = Keyword.fetch!(opts, :invoice_resource)
    entry = Keyword.fetch!(opts, :entry_resource)
    journal_line = Keyword.fetch!(opts, :line_resource)
    so_line = Keyword.fetch!(opts, :so_line_resource)

    %{
      shipment_table: table(shipment),
      shipment_id: col(shipment, :id),
      shipment_org: col(shipment, :org_id),
      shipment_status: col(shipment, :status),
      shipment_invoice_key: col(shipment, :invoice_key),
      shipment_invoice_id: col(shipment, :invoice_id),
      shipment_so: col(shipment, :sales_order_id),
      shipment_line_table: table(line),
      line_org: col(line, :org_id),
      line_shipment: col(line, :shipment_id),
      line_qty: col(line, :qty),
      line_price: col(line, :unit_price_cents),
      line_cost: col(line, :unit_cost_cents),
      ledger_table: table(ledger),
      ledger_org: col(ledger, :org_id),
      ledger_source_key: col(ledger, :source_key),
      ledger_source_id: col(ledger, :source_id),
      ledger_qty: col(ledger, :qty),
      ledger_cost: col(ledger, :unit_cost_cents),
      invoice_table: table(invoice),
      invoice_id: col(invoice, :id),
      invoice_org: col(invoice, :org_id),
      invoice_due: col(invoice, :amount_due_cents),
      entry_table: table(entry),
      entry_id: col(entry, :id),
      entry_org: col(entry, :org_id),
      entry_source_key: col(entry, :source_key),
      entry_source_id: col(entry, :source_id),
      entry_status: col(entry, :status),
      journal_line_table: table(journal_line),
      line_entry_fk: entry_fk_source(journal_line, entry),
      line_debit: col(journal_line, :debit_cents),
      so_line_table: table(so_line),
      so_line_org: col(so_line, :org_id),
      so_line_so: col(so_line, :sales_order_id),
      so_line_qty: col(so_line, :qty)
    }
  end

  # ── resource introspection ──────────────────────────────────────────────────

  defp table(resource), do: AshPostgres.DataLayer.Info.table(resource)

  defp col(resource, name) do
    case Ash.Resource.Info.attribute(resource, name) do
      nil -> raise ArgumentError, "no attribute #{inspect(name)} on #{inspect(resource)}"
      attr -> to_string(attr.source || attr.name)
    end
  end

  defp entry_fk_source(line_resource, entry_resource) do
    line_resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.type == :belongs_to and &1.destination == entry_resource))
    |> case do
      nil ->
        raise ArgumentError,
              "no belongs_to from #{inspect(line_resource)} to #{inspect(entry_resource)}"

      rel ->
        col(line_resource, rel.source_attribute)
    end
  end

  # ── value helpers ───────────────────────────────────────────────────────────

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
