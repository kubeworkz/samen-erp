defmodule Samen.Scopes.Inventory.ThreeWayMatch do
  @moduledoc """
  The R5 three-way match (WS-ERP E4; design §3.2 + §6.3): **AP bill ≤ PO +
  GR at tolerance, flagged otherwise** — a variance FLAG, not a hard block
  (the design's documented-tolerance decision; a bill over the PO+received
  total is suspicious, not impossible).

  * `variance/4` — one AP bill's three-way arithmetic: `billed_cents` (the
    bill's Σ line amounts) against `po_received_cents` (Σ received qty × the
    PO lines' frozen costs over the vendor's receipts) and `po_ordered_cents`
    (Σ ordered qty × cost over the vendor's POs). The flag: billed exceeds
    the received value by more than `tolerance_cents` (absolute) or
    `tolerance_pct` of the received value (whichever is LARGER — small
    absolute bills get a real floor, large bills get a real percentage).
  * `flagged/3` — every org bill whose flag fires — the standing R5 read
    the suite's green paths keep empty and the over-billed fixture row
    makes non-empty.

  LINKAGE (documented heuristic — the honest shape): an AP bill carries no
  PO/receipt FK in the base system, so the bill matches against the
  receipted/ordered value of ITS VENDOR (`vendor_id`). That is the correct
  strictness for the single-vendor-per-bill reality and a documented
  approximation otherwise; the P2 bill-line→po_line carry replaces the
  heuristic with per-line matching (design §3.2's own note).
  """

  # The match's default tolerance (cents / percent): fail-honest strictness —
  # a host widens explicitly per call.
  @default_tolerance_cents 0
  @default_tolerance_pct 0

  @doc """
  One AP bill's three-way arithmetic. `opts`:

    * `:po_resource` / `:po_line_resource` (required) — the PO pair;
    * `:receipt_line_resource` (required) — the received-quantity facts;
    * `:tolerance_cents` / `:tolerance_pct` (optional, default 0/0 —
      fail-honest strictness; a host widens explicitly).

  Returns `{:ok, %{billed_cents, po_ordered_cents, po_received_cents,
  variance_cents, flagged?}}` — `variance_cents = billed − received`
  (positive ⇒ the bill over-bills the receipts), `flagged?` when the
  positive variance exceeds the effective tolerance.
  """
  def variance(repo, org_id, bill, opts) do
    billed = billed_cents(bill)

    with {:ok, ordered} <- ordered_cents(repo, org_id, bill.vendor_id, opts),
         {:ok, received} <- received_cents(repo, org_id, bill.vendor_id, opts) do
      variance = billed - received

      tol_cents = Keyword.get(opts, :tolerance_cents, @default_tolerance_cents)
      tol_pct = Keyword.get(opts, :tolerance_pct, @default_tolerance_pct)

      effective =
        max(
          tol_cents,
          div(received * tol_pct, 100)
        )

      {:ok,
       %{
         billed_cents: billed,
         po_ordered_cents: ordered,
         po_received_cents: received,
         variance_cents: variance,
         flagged?: variance > effective
       }}
    end
  end

  @doc """
  Every org AP bill whose three-way flag fires (Σ line amounts vs the
  vendor's received value beyond tolerance) — the standing R5 read.
  """
  def flagged(repo, org_id, opts) do
    bill_resource = Keyword.fetch!(opts, :bill_resource)

    require Ash.Query

    bill_resource
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.read(authorize?: false)
    |> case do
      {:ok, bills} ->
        Enum.reduce_while(bills, {:ok, []}, fn bill, {:ok, acc} ->
          case variance(repo, org_id, bill, opts) do
            {:ok, %{flagged?: true} = v} -> {:cont, {:ok, [Map.put(v, :bill_id, bill.id) | acc]}}
            {:ok, _} -> {:cont, {:ok, acc}}
            {:error, reason} -> {:halt, {:error, reason}}
          end
        end)
        |> case do
          {:ok, list} -> {:ok, Enum.reverse(list)}
          other -> other
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── the three sides ─────────────────────────────────────────────────────────

  # The bill's own Σ line amounts (the embedded `lines` jsonb — the E2 shape).
  defp billed_cents(bill) do
    bill.lines
    |> Enum.map(&(&1.amount_cents || 0))
    |> Enum.sum()
  end

  # Σ ordered qty × cost over the vendor's POs (R5's ordered side).
  defp ordered_cents(repo, org_id, vendor_id, opts) do
    po_resource = Keyword.fetch!(opts, :po_resource)
    po_line_resource = Keyword.fetch!(opts, :po_line_resource)

    po_table = AshPostgres.DataLayer.Info.table(po_resource)
    pl_table = AshPostgres.DataLayer.Info.table(po_line_resource)

    po_id = col(po_resource, :id)
    po_vendor = col(po_resource, :vendor_id)

    pl_org = col(po_line_resource, :org_id)
    pl_po_fk = entry_fk_source(po_line_resource, po_resource)
    pl_qty = col(po_line_resource, :qty)
    pl_cost = col(po_line_resource, :unit_cost_cents)

    case repo.query(
           """
           SELECT COALESCE(SUM(#{pl_qty} * #{pl_cost}), 0)
           FROM #{pl_table} pl
           JOIN #{po_table} po ON po.#{po_id} = pl.#{pl_po_fk}
           WHERE pl.#{pl_org} = $1 AND po.#{po_vendor} = $2
           """,
           [dump_uuid(org_id), dump_uuid(vendor_id)]
         ) do
      {:ok, %{rows: [[total]]}} -> {:ok, to_i(total)}
      {:error, reason} -> {:error, reason}
    end
  end

  # Σ received qty × the PO lines' frozen costs over the vendor's receipts
  # (R5's received side — ReceiptLine is the materialized fact).
  defp received_cents(repo, org_id, vendor_id, opts) do
    po_resource = Keyword.fetch!(opts, :po_resource)
    po_line_resource = Keyword.fetch!(opts, :po_line_resource)
    receipt_line_resource = Keyword.fetch!(opts, :receipt_line_resource)

    po_table = AshPostgres.DataLayer.Info.table(po_resource)
    pl_table = AshPostgres.DataLayer.Info.table(po_line_resource)
    rl_table = AshPostgres.DataLayer.Info.table(receipt_line_resource)

    po_id = col(po_resource, :id)
    po_vendor = col(po_resource, :vendor_id)

    pl_id = col(po_line_resource, :id)
    pl_po_fk = entry_fk_source(po_line_resource, po_resource)
    pl_cost = col(po_line_resource, :unit_cost_cents)

    rl_org = col(receipt_line_resource, :org_id)
    rl_pl_fk = entry_fk_source(receipt_line_resource, po_line_resource)
    rl_qty = col(receipt_line_resource, :qty)

    case repo.query(
           """
           SELECT COALESCE(SUM(rl.#{rl_qty} * pl.#{pl_cost}), 0)
           FROM #{rl_table} rl
           JOIN #{pl_table} pl ON pl.#{pl_id} = rl.#{rl_pl_fk}
           JOIN #{po_table} po ON po.#{po_id} = pl.#{pl_po_fk}
           WHERE rl.#{rl_org} = $1 AND po.#{po_vendor} = $2
           """,
           [dump_uuid(org_id), dump_uuid(vendor_id)]
         ) do
      {:ok, %{rows: [[total]]}} -> {:ok, to_i(total)}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp entry_fk_source(line_resource, parent_resource) do
    line_resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.type == :belongs_to and &1.destination == parent_resource))
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
