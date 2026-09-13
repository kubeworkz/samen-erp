defmodule Samen.Scopes.Finance.ReconcilePayments do
  @moduledoc """
  The R2 reconciliation reads (WS-ERP E2; design §6.3): bare SQL sums over the
  posted rows — the ledger-side number is computed INDEPENDENTLY of the
  intake rows it must equal, so a posting that silently fails (or a bypass
  that skips it) DIVERGES and the red-path test fails. This is the
  reconciliation discipline: the two sums share only the org id, not a code
  path.

  * `receipts_total/3` — Σ `amount_cents` over the org's POSTED
    `PaymentReceipt` rows (what the intake claims it received), optionally
    bounded by a `paid_at` period (`:from`/`:to` Dates — the design's "for any
    period").
  * `posted_cash_total/3` — Σ `debit_cents` over the org's POSTED
    `JournalEntry` rows anchored `source_key: "billing_payment"` joined to
    their lines (what the GL actually holds). Each anchored entry IS a cash
    receipt posting (debit cash + credit AR by construction), so its total
    debits == the cash it received.
  * `mirror_total/3` — Σ `amount_cents` over the Billing mirror rows the
    caller names (the subledger side of R2 — in the base system's fixture,
    the mounted Billing `Payment` object).

  R2: `receipts_total == posted_cash_total == mirror_total` for any period.
  The equality is load-bearing (sabotage 303's bypass flips it) — the R2
  red-path suite proves it, the same way E1's c8 proves R1's zero.
  """

  @cash_source_key "billing_payment"

  @doc """
  Σ `amount_cents` over the org's POSTED receipts. Opts: `:from` / `:to`
  (Dates bounding `paid_at`, inclusive).
  """
  def receipts_total(org_id, repo, opts) do
    receipt_resource = Keyword.fetch!(opts, :receipt_resource)
    table = AshPostgres.DataLayer.Info.table(receipt_resource)
    amount = attr_source(receipt_resource, :amount_cents)
    status = attr_source(receipt_resource, :status)
    org = attr_source(receipt_resource, :org_id)
    paid_at = attr_source(receipt_resource, :paid_at)

    period = period_filter(paid_at, opts, 2)

    case repo.query(
           """
           SELECT COALESCE(SUM(#{amount}), 0) FROM #{table}
           WHERE #{org} = $1 AND #{status} = 'posted'#{period.sql}
           """,
           [dump_uuid(org_id)] ++ period.args
         ) do
      {:ok, %{rows: [[total]]}} -> {:ok, to_i(total)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Σ `debit_cents` over the org's POSTED entries anchored
  `source_key: "billing_payment"` (the GL side — computed from the entry/line
  tables, never from the receipt rows). Opts: `:from` / `:to` (Dates bounding
  `entry_date` — aligned with `paid_at` by ReceiptPosting's construction).
  """
  def posted_cash_total(org_id, repo, opts) do
    entry_resource = Keyword.fetch!(opts, :entry_resource)
    line_resource = Keyword.fetch!(opts, :line_resource)

    entry_table = AshPostgres.DataLayer.Info.table(entry_resource)
    line_table = AshPostgres.DataLayer.Info.table(line_resource)

    entry_id = attr_source(entry_resource, :id)
    entry_org = attr_source(entry_resource, :org_id)
    entry_status = attr_source(entry_resource, :status)
    entry_skey = attr_source(entry_resource, :source_key)
    entry_date = attr_source(entry_resource, :entry_date)
    line_entry_fk = entry_fk_source(line_resource, entry_resource)
    line_debit = attr_source(line_resource, :debit_cents)

    period = period_filter(entry_date, opts, 2)

    case repo.query(
           """
           SELECT COALESCE(SUM(l.#{line_debit}), 0)
           FROM #{line_table} l
           JOIN #{entry_table} e ON e.#{entry_id} = l.#{line_entry_fk}
           WHERE e.#{entry_org} = $1
             AND e.#{entry_status} = 'posted'
             AND e.#{entry_skey} = '#{@cash_source_key}'#{period.sql}
           """,
           [dump_uuid(org_id)] ++ period.args
         ) do
      {:ok, %{rows: [[total]]}} -> {:ok, to_i(total)}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Σ `amount_cents` over the caller-named Billing mirror rows for the org
  (the subledger side). Opts: `:from` / `:to` (Dates bounding the mirror's
  `paid_at`), `:status` (defaults to `:succeeded` — only settled payments
  count as received cash).
  """
  def mirror_total(org_id, repo, opts) do
    mirror_resource = Keyword.fetch!(opts, :mirror_resource)
    status = Keyword.get(opts, :status, :succeeded)

    table = AshPostgres.DataLayer.Info.table(mirror_resource)
    amount = attr_source(mirror_resource, :amount_cents)
    org = attr_source(mirror_resource, :org_id)
    paid_at = attr_source(mirror_resource, :paid_at)
    status_col = attr_source(mirror_resource, :status)

    period = period_filter(paid_at, opts, 3)

    case repo.query(
           """
           SELECT COALESCE(SUM(#{amount}), 0) FROM #{table}
           WHERE #{org} = $1 AND #{status_col} = $2#{period.sql}
           """,
           [dump_uuid(org_id), to_string(status)] ++ period.args
         ) do
      {:ok, %{rows: [[total]]}} -> {:ok, to_i(total)}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  # `col` is the resolved physical column name (a string) — inlined into the
  # SQL fragment; the VALUES are always parameterized ($N).
  defp period_filter(col, opts, param_start) do
    from = Keyword.get(opts, :from)
    to = Keyword.get(opts, :to)

    case {from, to} do
      {nil, nil} ->
        %{sql: "", args: []}

      {nil, to} ->
        %{sql: " AND #{col} <= $#{param_start}", args: [to]}

      {from, nil} ->
        %{sql: " AND #{col} >= $#{param_start}", args: [from]}

      {from, to} ->
        %{
          sql:
            " AND #{col} >= $#{param_start} AND " <>
              "#{col} <= $#{param_start + 1}",
          args: [from, to]
        }
    end
  end

  defp attr_source(resource, name) do
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
        to_string(attr_source(line_resource, rel.source_attribute))
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
end
