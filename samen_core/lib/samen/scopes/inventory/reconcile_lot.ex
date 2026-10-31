defmodule Samen.Scopes.Inventory.ReconcileLot do
  @moduledoc """
  The R7 reconciliation read (WS-ACCT Phase 4; ADR-054 D3, design §3):
  **WIP ↔ lot**. Supplier-location stock value per lot == the WIP balance the
  GL carries for that lot, and the lot's stage cost is the same stock ledger
  read over every location.

  ## Why the GL leg is WIP-accounts-only, never a net balance

  R6 makes the cost-object seam a *balancing segment*: every line of a
  dimensioned entry carries the dimension, so each cost object's debits equal
  its credits and the NET balance of any cost object is zero by construction.
  A net-per-lot read would therefore be a tautology that always reads clean.
  The honest measure is the WIP **debit** balance: Σ (`debit − credit`) over
  the lines whose account the posting map binds to a `wip_*` meaning. That is
  exactly what the manual means by "WIP – Foundry": a GL presentation of stock
  a supplier is holding (D3), not a second register.

  ## The three legs

    * **supplier stock** — Σ (`qty` × `unit_cost_cents`) over `StockLedger`
      events whose object-ref names the lot (`source_key: "lot"`,
      `source_id: <lot id>`) at a warehouse with `kind: :supplier`;
    * **WIP GL** — Σ (`debit − credit`) over POSTED lines dimensioned
      `"lot" => <that lot's cost_object_id>` on a `wip_*` posting account;
    * **stage cost** — the same stock sum over every location (a derived read,
      never a second balance). While the lot is in WIP the first and third
      agree; after delivery the stage cost includes owned stock and the WIP
      leg legitimately returns to zero.

  ## Per-mount reads

  A scope is materialized per host namespace, so no module name is hard-coded:

      Samen.Scopes.Inventory.ReconcileLot.reconciled?(org_id, repo,
        lot_resource: Demo.InventoryScope.Lot,
        ledger_resource: Demo.InventoryScope.StockLedger,
        warehouse_resource: Demo.InventoryScope.Warehouse,
        line_resource: Demo.FinanceScope.JournalLine,
        posting_account_resource: Demo.FinanceScope.PostingAccount
      )

  `divergences/3` is the detector: a lot whose supplier stock and WIP GL
  disagree is named, with both numbers, so the red path states its premise
  instead of asserting an opaque boolean.
  """

  @default_wip_keys [:wip_foundry, :wip_photonics, :wip_assembly]

  @doc """
  One row per lot: `supplier_value_cents` (WIP stock at a supplier location),
  `stage_value_cents` (the lot's stock at EVERY location) and
  `wip_balance_cents` (the GL's WIP balance dimensioned by the lot).
  """
  def lots(org_id, repo, opts) do
    ctx = context(opts)

    sql = """
    SELECT l.#{ctx.lot_id}::text,
           l.#{ctx.lot_code},
           COALESCE(stock.value, 0)::bigint,
           COALESCE(all_stock.value, 0)::bigint,
           COALESCE(gl.wip_balance, 0)::bigint
    FROM #{ctx.lot_table} l
    #{supplier_stock_sql(ctx)}
    #{all_stock_sql(ctx)}
    #{wip_gl_sql(ctx)}
    WHERE l.#{ctx.lot_org} = $1
    ORDER BY l.#{ctx.lot_code}
    """

    case repo.query(sql, [dump_uuid(org_id)]) do
      {:ok, %{rows: rows}} ->
        {:ok, Enum.map(rows, &row_to_map/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  The R7 violations: every lot whose supplier-location stock value differs
  from the WIP balance the GL carries for it. Empty is the guarantee; a
  non-empty list names the lot and both numbers.
  """
  def divergences(org_id, repo, opts) do
    with {:ok, rows} <- lots(org_id, repo, opts) do
      {:ok, Enum.reject(rows, &(&1.supplier_value_cents == &1.wip_balance_cents))}
    end
  end

  @doc """
  The R7 verdict: `true` iff no lot's supplier stock disagrees with its WIP
  GL balance. `false` is a broken books, not a rounding opinion.
  """
  def reconciled?(org_id, repo, opts) do
    with {:ok, divergent} <- divergences(org_id, repo, opts) do
      {:ok, divergent == []}
    end
  end

  # ── SQL fragments ──────────────────────────────────────────────────────────

  # Supplier-location stock: the WIP leg. `source_key = 'lot'` is the
  # object-ref anchor D3 specifies ("Σ StockLedger events whose ref names the
  # lot"); the warehouse join is the WIP boundary the sabotage drops.
  defp supplier_stock_sql(ctx) do
    """
    LEFT JOIN (
      SELECT sl.#{ctx.ledger_source_id} AS lot_id,
             SUM(sl.#{ctx.ledger_qty} * sl.#{ctx.ledger_cost}) AS value
      FROM #{ctx.ledger_table} sl
      JOIN #{ctx.warehouse_table} w
        ON w.#{ctx.warehouse_id} = sl.#{ctx.ledger_warehouse}
       AND w.#{ctx.warehouse_org} = sl.#{ctx.ledger_org}
      WHERE sl.#{ctx.ledger_org} = $1
        AND sl.#{ctx.ledger_source_key} = 'lot'
        AND w.#{ctx.warehouse_kind} = 'supplier'
      GROUP BY sl.#{ctx.ledger_source_id}
    ) stock ON stock.lot_id = l.#{ctx.lot_id}
    """
  end

  # The stage cost: the same ledger sum over EVERY location. Derived, never
  # stored — this is the "Σ lot stage costs" leg of R7.
  defp all_stock_sql(ctx) do
    """
    LEFT JOIN (
      SELECT sl.#{ctx.ledger_source_id} AS lot_id,
             SUM(sl.#{ctx.ledger_qty} * sl.#{ctx.ledger_cost}) AS value
      FROM #{ctx.ledger_table} sl
      WHERE sl.#{ctx.ledger_org} = $1
        AND sl.#{ctx.ledger_source_key} = 'lot'
      GROUP BY sl.#{ctx.ledger_source_id}
    ) all_stock ON all_stock.lot_id = l.#{ctx.lot_id}
    """
  end

  # The WIP GL balance per lot's cost object, over POSTED lines only (a draft
  # is a staged intention, not a fact — the `Reconcile`/`DimensionReconcile`
  # idiom), restricted to the accounts the posting map binds to a wip_* key.
  defp wip_gl_sql(ctx) do
    """
    LEFT JOIN (
      SELECT (jl.#{ctx.line_dimension}->>'lot')::uuid AS cost_object_id,
             SUM(jl.#{ctx.line_debit} - jl.#{ctx.line_credit}) AS wip_balance
      FROM #{ctx.line_table} jl
      JOIN #{ctx.entry_table} e
        ON e.#{ctx.entry_id} = jl.#{ctx.line_entry}
       AND e.#{ctx.entry_status} = 'posted'
      JOIN (
        SELECT DISTINCT pa.#{ctx.posting_account_account} AS account_id
        FROM #{ctx.posting_account_table} pa
        WHERE pa.#{ctx.posting_account_org} = $1
          AND pa.#{ctx.posting_account_key} IN (#{ctx.wip_key_list})
      ) wip ON wip.account_id = jl.#{ctx.line_account}
      WHERE jl.#{ctx.line_org} = $1
        AND jl.#{ctx.line_dimension} ? 'lot'
      GROUP BY 1
    ) gl ON gl.cost_object_id = l.#{ctx.lot_cost_object}
    """
  end

  defp row_to_map([lot_id, code, supplier_value, stage_value, wip_balance]) do
    %{
      lot_id: lot_id,
      code: code,
      supplier_value_cents: supplier_value,
      stage_value_cents: stage_value,
      wip_balance_cents: wip_balance
    }
  end

  # ── context ────────────────────────────────────────────────────────────────

  defp context(opts) do
    lot = Keyword.fetch!(opts, :lot_resource)
    ledger = Keyword.fetch!(opts, :ledger_resource)
    warehouse = Keyword.fetch!(opts, :warehouse_resource)
    line = Keyword.fetch!(opts, :line_resource)
    posting_account = Keyword.fetch!(opts, :posting_account_resource)

    entry = entry_resource(line)
    entry_fk = line_entry_fk_source(line)

    %{
      lot_table: table(lot),
      lot_id: col(lot, :id),
      lot_code: col(lot, :code),
      lot_org: col(lot, :org_id),
      lot_cost_object: col(lot, :cost_object_id),
      ledger_table: table(ledger),
      ledger_org: col(ledger, :org_id),
      ledger_qty: col(ledger, :qty),
      ledger_cost: col(ledger, :unit_cost_cents),
      ledger_source_key: col(ledger, :source_key),
      ledger_source_id: col(ledger, :source_id),
      ledger_warehouse: col(ledger, :warehouse_id),
      warehouse_table: table(warehouse),
      warehouse_id: col(warehouse, :id),
      warehouse_org: col(warehouse, :org_id),
      warehouse_kind: col(warehouse, :kind),
      line_table: table(line),
      line_org: col(line, :org_id),
      line_debit: col(line, :debit_cents),
      line_credit: col(line, :credit_cents),
      line_dimension: col(line, :dimension_refs),
      line_entry: entry_fk,
      line_account: col(line, :account_id),
      entry_table: table(entry),
      entry_id: col(entry, :id),
      entry_status: col(entry, :status),
      posting_account_table: table(posting_account),
      posting_account_org: col(posting_account, :org_id),
      posting_account_key: col(posting_account, :key),
      posting_account_account: col(posting_account, :account_id),
      wip_key_list: wip_key_list(Keyword.get(opts, :wip_keys, @default_wip_keys))
    }
  end

  # The key set is interpolated (not a parameter) because it is a closed list
  # of atoms, and every value is re-checked against a strict shape first — a
  # caller cannot smuggle SQL through an option.
  defp wip_key_list(keys) do
    Enum.map_join(keys, ", ", fn key ->
      text = to_string(key)

      unless text =~ ~r/\A[a-z_]+\z/ do
        raise ArgumentError, "wip_keys must be posting-map meanings, got: #{inspect(key)}"
      end

      "'#{text}'"
    end)
  end

  # ── resource introspection (the DimensionReconcile helpers) ────────────────

  defp table(resource), do: AshPostgres.DataLayer.Info.table(resource)

  defp col(resource, name) do
    case Ash.Resource.Info.attribute(resource, name) do
      nil -> raise ArgumentError, "no attribute #{inspect(name)} on #{inspect(resource)}"
      attr -> to_string(attr.source || attr.name)
    end
  end

  defp entry_resource(line_resource) do
    line_resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.type == :belongs_to and &1.name == :entry))
    |> Map.fetch!(:destination)
  end

  defp line_entry_fk_source(line_resource) do
    line_resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.type == :belongs_to and &1.name == :entry))
    |> Map.fetch!(:source_attribute)
    |> then(&col(line_resource, &1))
  end

  defp dump_uuid(value) when is_binary(value) and byte_size(value) == 16, do: value

  defp dump_uuid(value) do
    case Ecto.UUID.dump(value) do
      {:ok, bin} -> bin
      :error -> value
    end
  end
end
