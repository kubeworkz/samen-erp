defmodule Samen.Scopes.Inventory.ReconcileFulfillment do
  @moduledoc """
  The fulfillment reconciliation reads (WS-ERP E5; design §3.3 + §6.3):
  for every fulfilled sales order, the stock side, the billing side and the
  two GL sides are computed as INDEPENDENT bare-SQL sums (they share only the
  order's or invoice's id — never a code path), so a bridge bypass that lands
  one side without the others DIVERGES and the red-path fails.

  * `order/3` — one SO's legs: the ledger events anchored
    `source_key: "sales_order"` + `source_id` (Σ qty as a NEGATIVE sum's
    absolute value, Σ qty×cost), the emitted invoice's `amount_due`, and the
    two GL anchors — the posted `billing_invoice` revenue/AR entry and the
    posted `sales_order` COGS entry.
  * `divergences/2` — every org SO whose stock, billing or GL side disagrees —
    the standing read the suite's green paths assert empty and the sabotage's
    bypass makes non-empty. (Stock and revenue are DIFFERENT quantities by
    nature — qty vs cents — so the standing equality is structural, not
    arithmetic: an order is `:fulfilled` with its invoice anchor SET iff its
    `:sale` events exist. The GL read compares each anchor's posted debit
    total to its expected document/stock value and reports a MISSING, FOREIGN
    or MISVALUED side.)

  ## The GL sides

  * `billing_invoice` — the invoice's revenue/AR entry. Its debit total is
    expected to equal the invoice's `amount_due_cents`.
  * `sales_order` — the fulfillment's COGS entry. Its debit total is expected
    to equal `abs(stock_value)` (the same qty×moving-average snapshot the
    stock events took). A zero-cost sale legitimately has NO COGS entry; an
    entry there is unexpected.

  A GL side is `:missing` when the document expects a posted entry and none
  exists, `:foreign` when another org's entry claims the same anchor, and
  `:misvalued` when the entry count or debit total disagrees. The read is
  intentionally org-filtered for its own sums; the foreign probe only looks
  for another org's entry on OUR anchor, so a cross-org row is named rather
  than silently appearing as "missing".
  """

  @source_key "sales_order"
  @invoice_source_key "billing_invoice"

  @doc "The sales-order anchor source_key (single source of truth, the FulfillOrder discipline)."
  def source_key, do: @source_key

  @doc "The invoice/AR anchor source_key (the B0 ArInvoicePosting discipline)."
  def invoice_source_key, do: @invoice_source_key

  @doc """
  One fulfilled SO's legs, each computed fresh from its own table:

    * `:stock` — Σ qty (negative) and Σ (qty × unit_cost) over the org's
      StockLedger events anchored this order;
    * `:billing` — the emitted invoice's (`:id`, `:amount_due_cents`,
      `:status`) resolved through the SO's `invoice_key`/`invoice_id`
      anchor;
    * `:gl` — `%{ar: ..., cogs: ...}`, each a classification map with
      `:status` (`:ok | :missing | :foreign | :misvalued`), `:entries`,
      `:debit_cents`, `:foreign_entries` and `:expected_cents`. `:ar` is
      `nil` when the SO has no invoice row.

  By construction the invoice exists iff the events do; a bypass that
  landed one side without the other diverges here.
  """
  def order(repo, org_id, opts) do
    so_id = Keyword.fetch!(opts, :sales_order_id)

    with {:ok, stock} <- stock_leg(repo, org_id, so_id, opts),
         {:ok, billing} <- billing_leg(repo, org_id, so_id, opts),
         {:ok, ar} <- ar_gl(repo, org_id, billing, opts),
         {:ok, cogs} <- cogs_gl(repo, org_id, so_id, stock, opts) do
      {:ok, %{stock: stock, billing: billing, gl: %{ar: ar, cogs: cogs}}}
    end
  end

  @doc """
  Every org SO whose legs disagree — the standing fulfillment read.

  Four structural half-landed shapes are refused (any one flags the order):

    * a `:fulfilled` SO with NO `:sale` events;
    * a `:fulfilled` SO with NO invoice anchor;
    * `:sale` events anchored to a SO that never fulfilled (a forged
      demand event);
    * an anchored SO whose invoice row does not exist.

  The GL read adds the missing/foreign/misvalued shapes for both anchors
  (see the moduledoc). Each returned map carries `:gl_divergences` — the
  named atoms such as `:missing_ar_gl`, `:foreign_ar_gl`,
  `:misvalued_ar_gl`, `:missing_cogs_gl`, `:foreign_cogs_gl`,
  `:misvalued_cogs_gl` — plus the raw `:ar_gl` / `:cogs_gl` classifications.

  Requires `:entry_resource` and `:line_resource` in addition to the
  structural resources: a reconciliation that cannot read the GL is not a
  reconciliation.
  """
  def divergences(repo, org_id, opts) do
    so_resource = Keyword.fetch!(opts, :so_resource)
    ledger_resource = Keyword.fetch!(opts, :ledger_resource)
    invoice_resource = Keyword.fetch!(opts, :invoice_resource)
    entry_resource = Keyword.fetch!(opts, :entry_resource)
    line_resource = Keyword.fetch!(opts, :line_resource)

    so_table = AshPostgres.DataLayer.Info.table(so_resource)
    ledger_table = AshPostgres.DataLayer.Info.table(ledger_resource)
    inv_table = AshPostgres.DataLayer.Info.table(invoice_resource)
    entry_table = AshPostgres.DataLayer.Info.table(entry_resource)
    line_table = AshPostgres.DataLayer.Info.table(line_resource)

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

    e_id = col(entry_resource, :id)
    e_org = col(entry_resource, :org_id)
    e_src_id = col(entry_resource, :source_id)
    e_src_key = col(entry_resource, :source_key)
    e_status = col(entry_resource, :status)

    line_entry_fk = entry_fk_source(line_resource, entry_resource)
    line_debit = col(line_resource, :debit_cents)

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
           ),
           ar_gl AS (
             SELECT e.#{e_src_id} AS iid,
                    COUNT(DISTINCT e.#{e_id}) AS entries,
                    COALESCE(SUM(l.#{line_debit}), 0) AS debit_cents
             FROM #{entry_table} e
             LEFT JOIN #{line_table} l ON l.#{line_entry_fk} = e.#{e_id}
             WHERE e.#{e_org} = $1 AND e.#{e_src_key} = '#{invoice_source_key()}'
               AND e.#{e_status} = 'posted'
             GROUP BY e.#{e_src_id}
           ),
           cogs_gl AS (
             SELECT e.#{e_src_id} AS sid,
                    COUNT(DISTINCT e.#{e_id}) AS entries,
                    COALESCE(SUM(l.#{line_debit}), 0) AS debit_cents
             FROM #{entry_table} e
             LEFT JOIN #{line_table} l ON l.#{line_entry_fk} = e.#{e_id}
             WHERE e.#{e_org} = $1 AND e.#{e_src_key} = '#{source_key()}'
               AND e.#{e_status} = 'posted'
             GROUP BY e.#{e_src_id}
           ),
           foreign_ar AS (
             SELECT e.#{e_src_id} AS iid, COUNT(*) AS entries
             FROM #{entry_table} e
             JOIN #{so_table} so2
               ON so2.#{so_inv_id} = e.#{e_src_id} AND so2.#{so_org} = $1
             WHERE e.#{e_src_key} = '#{invoice_source_key()}' AND e.#{e_org} <> $1
             GROUP BY e.#{e_src_id}
           ),
           foreign_cogs AS (
             SELECT e.#{e_src_id} AS sid, COUNT(*) AS entries
             FROM #{entry_table} e
             JOIN #{so_table} so2
               ON so2.#{so_id} = e.#{e_src_id} AND so2.#{so_org} = $1
             WHERE e.#{e_src_key} = '#{source_key()}' AND e.#{e_org} <> $1
             GROUP BY e.#{e_src_id}
           )
           SELECT so.#{so_id},
                  COALESCE(s.events, 0), COALESCE(s.qty, 0), COALESCE(s.value, 0),
                  so.#{so_inv_key}, so.#{so_inv_id},
                  COALESCE(i.#{i_due}, 0), COALESCE(i.#{i_id} IS NOT NULL, false),
                  COALESCE(ag.entries, 0), COALESCE(ag.debit_cents, 0), COALESCE(fa.entries, 0),
                  COALESCE(cg.entries, 0), COALESCE(cg.debit_cents, 0), COALESCE(fc.entries, 0)
           FROM #{so_table} so
           LEFT JOIN stock s ON s.sid = so.#{so_id}
           LEFT JOIN #{inv_table} i ON i.#{i_id} = so.#{so_inv_id} AND i.#{i_org} = $1
           LEFT JOIN ar_gl ag ON ag.iid = so.#{so_inv_id}
           LEFT JOIN cogs_gl cg ON cg.sid = so.#{so_id}
           LEFT JOIN foreign_ar fa ON fa.iid = so.#{so_inv_id}
           LEFT JOIN foreign_cogs fc ON fc.sid = so.#{so_id}
           WHERE so.#{so_org} = $1
             AND (
               (so.#{so_status} = 'fulfilled' AND COALESCE(s.events, 0) = 0)
               OR (so.#{so_status} = 'fulfilled' AND so.#{so_inv_id} IS NULL)
               OR (so.#{so_status} IS DISTINCT FROM 'fulfilled' AND COALESCE(s.events, 0) > 0)
               OR (so.#{so_status} = 'fulfilled' AND so.#{so_inv_id} IS NOT NULL AND i.#{i_id} IS NULL)
               OR (so.#{so_inv_id} IS NOT NULL AND i.#{i_id} IS NOT NULL
                   AND COALESCE(fa.entries, 0) > 0)
               OR (so.#{so_inv_id} IS NOT NULL AND i.#{i_id} IS NOT NULL
                   AND COALESCE(i.#{i_due}, 0) > 0 AND COALESCE(ag.entries, 0) = 0)
               OR (so.#{so_inv_id} IS NOT NULL AND i.#{i_id} IS NOT NULL
                   AND COALESCE(ag.entries, 0) > 0
                   AND (COALESCE(ag.entries, 0) <> 1
                        OR COALESCE(ag.debit_cents, 0) <> COALESCE(i.#{i_due}, 0)))
               OR (COALESCE(fc.entries, 0) > 0)
               OR (ABS(COALESCE(s.value, 0)) > 0 AND COALESCE(cg.entries, 0) = 0)
               OR (ABS(COALESCE(s.value, 0)) > 0 AND COALESCE(cg.entries, 0) > 0
                   AND (COALESCE(cg.entries, 0) <> 1
                        OR COALESCE(cg.debit_cents, 0) <> ABS(COALESCE(s.value, 0))))
               OR (ABS(COALESCE(s.value, 0)) = 0 AND COALESCE(cg.entries, 0) > 0)
             )
           """,
           [dump_uuid(org_id)]
         ) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [
                             sid,
                             events,
                             qty,
                             value,
                             inv_key,
                             inv_id,
                             due,
                             invoice_exists,
                             ar_entries,
                             ar_debit,
                             ar_foreign,
                             cogs_entries,
                             cogs_debit,
                             cogs_foreign
                           ] ->
           ar_gl = classify_gl(ar_entries, ar_debit, ar_foreign, due)
           cogs_gl = classify_gl(cogs_entries, cogs_debit, cogs_foreign, abs(to_i(value)))

           %{
             sales_order_id: to_uuid(sid),
             stock_events: to_i(events),
             stock_qty: to_i(qty),
             stock_value: to_i(value),
             invoice_key: inv_key,
             invoice_id: to_uuid(inv_id),
             invoice_amount_due: to_i(due),
             invoice_exists: invoice_exists,
             ar_gl: ar_gl,
             cogs_gl: cogs_gl,
             gl_divergences: gl_divergences(:ar, ar_gl) ++ gl_divergences(:cogs, cogs_gl)
           }
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── the legs ────────────────────────────────────────────────────────────────

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

  defp ar_gl(_repo, _org_id, nil, _opts), do: {:ok, nil}

  defp ar_gl(repo, org_id, %{id: invoice_id, amount_due_cents: amount}, opts) do
    with {:ok, leg} <- gl_leg(repo, org_id, invoice_source_key(), invoice_id, opts) do
      {:ok, classify_gl(leg.entries, leg.debit_cents, leg.foreign_entries, amount)}
    end
  end

  defp cogs_gl(repo, org_id, so_id, stock, opts) do
    with {:ok, leg} <- gl_leg(repo, org_id, source_key(), so_id, opts) do
      {:ok, classify_gl(leg.entries, leg.debit_cents, leg.foreign_entries, abs(stock.value))}
    end
  end

  defp gl_leg(repo, org_id, source_key, source_id, opts) do
    entry_resource = Keyword.fetch!(opts, :entry_resource)
    line_resource = Keyword.fetch!(opts, :line_resource)

    entry_table = AshPostgres.DataLayer.Info.table(entry_resource)
    line_table = AshPostgres.DataLayer.Info.table(line_resource)

    e_id = col(entry_resource, :id)
    e_org = col(entry_resource, :org_id)
    e_src_id = col(entry_resource, :source_id)
    e_src_key = col(entry_resource, :source_key)
    e_status = col(entry_resource, :status)

    line_entry_fk = entry_fk_source(line_resource, entry_resource)
    line_debit = col(line_resource, :debit_cents)

    case repo.query(
           """
           WITH own AS (
             SELECT e.#{e_id} AS id
             FROM #{entry_table} e
             WHERE e.#{e_org} = $1 AND e.#{e_src_key} = $2 AND e.#{e_src_id} = $3
               AND e.#{e_status} = 'posted'
           ),
           foreign_e AS (
             SELECT e.#{e_id} AS id
             FROM #{entry_table} e
             WHERE e.#{e_org} <> $1 AND e.#{e_src_key} = $2 AND e.#{e_src_id} = $3
           )
           SELECT
             (SELECT COUNT(*) FROM own),
             COALESCE(
               (SELECT SUM(l.#{line_debit})
                FROM #{line_table} l
                JOIN own o ON l.#{line_entry_fk} = o.id),
               0
             ),
             (SELECT COUNT(*) FROM foreign_e)
           """,
           [dump_uuid(org_id), source_key, dump_uuid(source_id)]
         ) do
      {:ok, %{rows: [[entries, debit_cents, foreign_entries]]}} ->
        {:ok,
         %{
           entries: to_i(entries),
           debit_cents: to_i(debit_cents),
           foreign_entries: to_i(foreign_entries)
         }}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── classification ──────────────────────────────────────────────────────────

  defp classify_gl(entries, debit_cents, foreign_entries, expected_cents) do
    entries = to_i(entries)
    debit_cents = to_i(debit_cents)
    foreign_entries = to_i(foreign_entries)
    expected_cents = to_i(expected_cents)

    status =
      cond do
        foreign_entries > 0 ->
          :foreign

        expected_cents > 0 and entries == 0 ->
          :missing

        expected_cents == 0 and entries == 0 ->
          :ok

        entries == 1 and debit_cents == expected_cents ->
          :ok

        true ->
          :misvalued
      end

    %{
      status: status,
      entries: entries,
      debit_cents: debit_cents,
      foreign_entries: foreign_entries,
      expected_cents: expected_cents
    }
  end

  defp gl_divergences(_anchor, %{status: :ok}), do: []
  defp gl_divergences(anchor, %{status: status}), do: [:"#{status}_#{anchor}_gl"]

  # ── helpers ─────────────────────────────────────────────────────────────────

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
