defmodule Samen.Scopes.Inventory.ReconcileProcurement do
  @moduledoc """
  The R3-full reconciliation reads (WS-ERP E4; design §3.2 + §6.3): for every
  goods receipt, the stock side, the materialized facts, and the GL side are
  computed as INDEPENDENT bare-SQL sums (the three share only the receipt's
  id — never a code path), so a chokepoint bypass that lands one leg without
  the others DIVERGES and the red-path fails.

  * `receipt/3` — one receipt's three legs: the ledger events anchored
    `source_key: "goods_receipt"` + `source_id` (Σ qty, Σ qty×cost), the
    `ReceiptLine` facts (Σ qty, Σ qty×cost at the PO lines' frozen costs),
    and the `JournalEntry` anchored the same (Σ debits — the inventory-asset
    + AP-clearing entry's total movement). All three equal by construction.
  * `divergences/2` — every org receipt whose three legs disagree — the
    standing R3-full read the suite's green paths assert empty and the
    sabotage's bypass makes non-empty.

  The sums read the TABLES (not the structs): even a bypass that wrote rows
  with `authorize?: false` lands here — that is the point.
  """

  @source_key "goods_receipt"

  @doc "The goods-receipt anchor source_key (single source of truth, the PostingMarker guc/0 discipline)."
  def source_key, do: @source_key

  @doc """
  One receipt's three legs, each computed fresh from its own table:

    * `:stock` — Σ qty and Σ (qty × unit_cost) over the org's StockLedger
      events anchored this receipt;
    * `:facts` — Σ qty and Σ (qty × unit_cost) over the receipt's
      `ReceiptLine` rows (the PO lines' frozen costs);
    * `:gl` — Σ debits over the POSTED `JournalEntry` anchored this receipt
      (its lines' total movement — debits == credits by R1, so debits is
      the movement).

  By construction all three carry the same qty and the same value; a
  chokepoint that posted one leg without another diverges here.
  """
  def receipt(repo, org_id, opts) do
    receipt_id = Keyword.fetch!(opts, :receipt_id)

    with {:ok, stock} <- stock_leg(repo, org_id, receipt_id, opts),
         {:ok, facts} <- facts_leg(repo, org_id, receipt_id, opts),
         {:ok, gl} <- gl_leg(repo, org_id, receipt_id, opts) do
      {:ok, %{stock: stock, facts: facts, gl: gl}}
    end
  end

  @doc """
  Every org receipt whose three legs disagree (any pair of the stock /
  facts / gl sums) — the standing R3-full read. A receipt with NO legs at
  all (nothing landed anywhere) produces no rows: `:receive` refuses before
  any write, and a bare create carries no anchors; the danger the read
  exists for is the PARTIAL landing, which is exactly what it catches.
  """
  def divergences(repo, org_id, opts) do
    ledger_resource = Keyword.fetch!(opts, :ledger_resource)
    receipt_line_resource = Keyword.fetch!(opts, :receipt_line_resource)
    entry_resource = Keyword.fetch!(opts, :entry_resource)
    line_resource = Keyword.fetch!(opts, :line_resource)

    ledger_table = AshPostgres.DataLayer.Info.table(ledger_resource)
    rl_table = AshPostgres.DataLayer.Info.table(receipt_line_resource)
    entry_table = AshPostgres.DataLayer.Info.table(entry_resource)
    line_table = AshPostgres.DataLayer.Info.table(line_resource)

    l_org = col(ledger_resource, :org_id)
    l_src_id = col(ledger_resource, :source_id)
    l_src_key = col(ledger_resource, :source_key)
    l_qty = col(ledger_resource, :qty)
    l_cost = col(ledger_resource, :unit_cost_cents)

    rl_org = col(receipt_line_resource, :org_id)
    rl_receipt = col(receipt_line_resource, :goods_receipt_id)
    rl_qty = col(receipt_line_resource, :qty)
    rl_cost = col(receipt_line_resource, :unit_cost_cents)

    e_org = col(entry_resource, :org_id)
    e_src_id = col(entry_resource, :source_id)
    e_src_key = col(entry_resource, :source_key)
    e_status = col(entry_resource, :status)
    e_id = col(entry_resource, :id)

    line_entry_fk = entry_fk_source(line_resource, entry_resource)
    line_debit = col(line_resource, :debit_cents)

    case repo.query(
           """
           WITH stock AS (
             SELECT #{l_src_id} AS rid, SUM(#{l_qty}) AS qty, SUM(#{l_qty} * #{l_cost}) AS value
             FROM #{ledger_table}
             WHERE #{l_org} = $1 AND #{l_src_key} = '#{source_key()}'
             GROUP BY #{l_src_id}
           ),
           facts AS (
             SELECT #{rl_receipt} AS rid, SUM(#{rl_qty}) AS qty, SUM(#{rl_qty} * #{rl_cost}) AS value
             FROM #{rl_table}
             WHERE #{rl_org} = $1
             GROUP BY #{rl_receipt}
           ),
           gl AS (
             SELECT e.#{e_src_id} AS rid, SUM(l.#{line_debit}) AS value
             FROM #{entry_table} e
             JOIN #{line_table} l ON l.#{line_entry_fk} = e.#{e_id}
             WHERE e.#{e_org} = $1 AND e.#{e_src_key} = '#{source_key()}' AND e.#{e_status} = 'posted'
             GROUP BY e.#{e_src_id}
           )
           SELECT COALESCE(s.rid, f.rid, g.rid),
                  COALESCE(s.qty, 0), COALESCE(s.value, 0),
                  COALESCE(f.qty, 0), COALESCE(f.value, 0),
                  COALESCE(g.value, 0)
           FROM stock s
           FULL OUTER JOIN facts f ON f.rid = s.rid
           FULL OUTER JOIN gl g ON g.rid = COALESCE(s.rid, f.rid)
           WHERE COALESCE(s.qty, 0) IS DISTINCT FROM COALESCE(f.qty, 0)
              OR COALESCE(s.value, 0) IS DISTINCT FROM COALESCE(f.value, 0)
              OR COALESCE(s.value, 0) IS DISTINCT FROM COALESCE(g.value, 0)
           """,
           [dump_uuid(org_id)]
         ) do
      {:ok, %{rows: rows}} ->
        {:ok,
         Enum.map(rows, fn [rid, s_qty, s_val, f_qty, f_val, g_val] ->
           %{
             receipt_id: to_uuid(rid),
             stock_qty: to_i(s_qty),
             stock_value: to_i(s_val),
             facts_qty: to_i(f_qty),
             facts_value: to_i(f_val),
             gl_value: to_i(g_val)
           }
         end)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── the three legs ──────────────────────────────────────────────────────────

  defp stock_leg(repo, org_id, receipt_id, opts) do
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
           [dump_uuid(org_id), source_key(), dump_uuid(receipt_id)]
         ) do
      {:ok, %{rows: [[qty_sum, value_sum]]}} -> {:ok, %{qty: to_i(qty_sum), value: to_i(value_sum)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp facts_leg(repo, org_id, receipt_id, opts) do
    rl_resource = Keyword.fetch!(opts, :receipt_line_resource)
    table = AshPostgres.DataLayer.Info.table(rl_resource)
    org = col(rl_resource, :org_id)
    receipt = col(rl_resource, :goods_receipt_id)
    qty = col(rl_resource, :qty)
    cost = col(rl_resource, :unit_cost_cents)

    case repo.query(
           """
           SELECT COALESCE(SUM(#{qty}), 0), COALESCE(SUM(#{qty} * #{cost}), 0)
           FROM #{table}
           WHERE #{org} = $1 AND #{receipt} = $2
           """,
           [dump_uuid(org_id), dump_uuid(receipt_id)]
         ) do
      {:ok, %{rows: [[qty_sum, value_sum]]}} -> {:ok, %{qty: to_i(qty_sum), value: to_i(value_sum)}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp gl_leg(repo, org_id, receipt_id, opts) do
    entry_resource = Keyword.fetch!(opts, :entry_resource)
    line_resource = Keyword.fetch!(opts, :line_resource)

    entry_table = AshPostgres.DataLayer.Info.table(entry_resource)
    line_table = AshPostgres.DataLayer.Info.table(line_resource)

    e_org = col(entry_resource, :org_id)
    e_id = col(entry_resource, :id)
    e_src_id = col(entry_resource, :source_id)
    e_src_key = col(entry_resource, :source_key)
    e_status = col(entry_resource, :status)

    line_entry_fk = entry_fk_source(line_resource, entry_resource)
    line_debit = col(line_resource, :debit_cents)

    case repo.query(
           """
           SELECT COALESCE(SUM(l.#{line_debit}), 0)
           FROM #{entry_table} e
           JOIN #{line_table} l ON l.#{line_entry_fk} = e.#{e_id}
           WHERE e.#{e_org} = $1 AND e.#{e_src_key} = $2 AND e.#{e_src_id} = $3
             AND e.#{e_status} = 'posted'
           """,
           [dump_uuid(org_id), source_key(), dump_uuid(receipt_id)]
         ) do
      {:ok, %{rows: [[value]]}} -> {:ok, %{value: to_i(value)}}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp entry_fk_source(line_resource, entry_resource) do
    line_resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.type == :belongs_to and &1.destination == entry_resource))
    |> Map.fetch!(:source_attribute)
    |> then(&col(line_resource, &1))
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
end
