defmodule Samen.Scopes.Inventory.GoodsPosting do
  @moduledoc """
  THE ONE-TRANSACTION CHOKEPOINT (WS-ERP E4; design §3.2): on
  `GoodsReceipt :receive`, per receipt line — a `StockLedger :receipt` event
  (qty in, cost = the PO line's cost, anchored `source_key: "goods_receipt"`)
  — plus the inventory-asset + AP-clearing `JournalEntry` (anchored the same)
  and the materialized `ReceiptLine` rows, and the receipt's own flip to
  `:posted`, and the PO's progression to `:received` — ALL inside the
  action's single transaction: stock and GL commit or roll back TOGETHER.
  A receipt that posted stock but not the journal (or vice versa) is
  structurally impossible (and R3-full + R5 read the two sides
  independently — `ReconcileProcurement` / `ThreeWayMatch` — so even a
  future bypass DIVERGES).

  Ordering inside the transaction (why it is safe):

    * the `:receive` action carries `Samen.Scopes.Finance.PostingMarker`
      BEFORE this change, so the belt marker (`samen.finance_posting`) is
      armed for the receipt's own flip and the PO's `:received` stamp;
    * each `StockLedger :record` create runs its own resource-wide changes
      (`NegativeStock` — a no-op for positive receipts — and
      `StockLevelSync`, which arms/restores ITS belt marker per write);
    * the GL entry is born through the same governed factory the reversal
      cascade uses (`:create_reversal`, POSTED — the receipt IS the posting
      act) with R1 running resource-wide: the two-sided construction
      balances by construction.

  The inventory-asset side resolves per line from the PO line's ITEM's
  `default_inventory_account_id` — the E3 Finance seam, exactly as designed
  ("an unlinked item simply never posts"): an item without the link refuses
  the WHOLE receipt fail-honest (a partial posting is not a posting). The
  AP-clearing side resolves from the org's `PostingAccount` rows (the E2
  map). Over-receipt (cumulative received > ordered, over the materialized
  `ReceiptLine` facts) is refused; the receipt flip is exactly-once.

  Every refusal is fail-honest with a distinct formatted reason.
  """

  use Ash.Resource.Change

  @source_key "goods_receipt"

  @impl true
  def change(changeset, opts, _context) do
    # Capture at change/2 time (the EntryLines posture — on action results
    # org_id reads back NotLoaded).
    org_id = resolve_org(changeset)

    Ash.Changeset.before_action(changeset, fn changeset ->
      do_receive(changeset, org_id, opts)
    end)
  end

  defp do_receive(changeset, org_id, opts) do
    po_line_resource = Keyword.fetch!(opts, :po_line)
    receipt_line_resource = Keyword.fetch!(opts, :receipt_line)
    ledger_resource = Keyword.fetch!(opts, :ledger)
    entry_resource = Keyword.fetch!(opts, :entry)
    pa_resource = Keyword.fetch!(opts, :posting_account)

    receipt = changeset.data

    with :ok <- refuse_posted(receipt),
         {:ok, lines} <- lines_of(changeset),
         {:ok, po} <- fetch_po(po_line_resource, org_id, receipt.purchase_order_id),
         :ok <- refuse_not_receivable(po),
         {:ok, expanded} <- expand_lines(po_line_resource, org_id, lines),
         :ok <- refuse_over_receipt(receipt_line_resource, expanded),
         {:ok, ap_clearing} <- posting_account(pa_resource, org_id, :ap_clearing),
         {:ok, valued} <- value_lines(po_line_resource, expanded) do
      # ── 1. the receipt-line facts (R5's received side, written FIRST so
      # the over-receipt floor is durable even mid-transaction) ────────────
      with {:ok, _} <- write_receipt_lines(receipt_line_resource, org_id, receipt, valued),
           # ── 2. the ledger events (stock side) ───────────────────────────
           {:ok, _} <- write_stock_events(ledger_resource, org_id, receipt, valued),
           # ── 3. the GL entry (the chokepoint's other half) ───────────────
           {:ok, entry} <- write_entry(entry_resource, org_id, receipt, ap_clearing, valued) do
        # ── 4. the receipt's own flip + the PO's progression ──────────────
        changeset
        |> Ash.Changeset.force_change_attribute(:status, :posted)
        |> Ash.Changeset.force_change_attribute(:posted_entry_id, entry.id)
        |> Ash.Changeset.force_change_attribute(:received_at, now())
        |> stamp_po(po)
      else
        {:error, reason} ->
          Ash.Changeset.add_error(changeset,
            field: :base,
            message: "the goods receipt failed to land: #{format(reason)}"
          )
      end
    else
      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :base,
          message: "the goods receipt cannot be received: #{format(reason)}"
        )
    end
  end

  # ── the write steps (any failure rolls the WHOLE transaction back) ──────────

  defp write_receipt_lines(receipt_line_resource, org_id, receipt, valued) do
    Enum.reduce_while(valued, {:ok, []}, fn %{po_line: po_line, qty: qty}, {:ok, acc} ->
      case receipt_line_resource
           |> Ash.Changeset.for_create(:create, %{
             org_id: org_id,
             goods_receipt_id: receipt.id,
             po_line_id: po_line.id,
             qty: qty,
             unit_cost_cents: po_line.unit_cost_cents
           })
           |> Ash.create(authorize?: false) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        {:error, reason} -> {:halt, {:error, {:receipt_line_failed, reason}}}
      end
    end)
  end

  defp write_stock_events(ledger_resource, org_id, receipt, valued) do
    Enum.reduce_while(valued, {:ok, []}, fn %{po_line: po_line, qty: qty}, {:ok, acc} ->
      case ledger_resource
           |> Ash.Changeset.for_create(:record, %{
             org_id: org_id,
             item_id: po_line.item_id,
             warehouse_id: receipt.warehouse_id,
             kind: :receipt,
             qty: qty,
             unit_cost_cents: po_line.unit_cost_cents,
             source_key: @source_key,
             source_id: receipt.id
           })
           |> Ash.create(authorize?: false) do
        {:ok, event} -> {:cont, {:ok, [event | acc]}}
        {:error, reason} -> {:halt, {:error, {:stock_event_failed, reason}}}
      end
    end)
  end

  defp write_entry(entry_resource, org_id, receipt, ap_clearing, valued) do
    value = received_value(valued)

    entry_lines =
      (Enum.map(valued, fn %{account_id: account_id, qty: qty, unit_cost: unit_cost} ->
         %{account_id: account_id, debit_cents: qty * unit_cost, credit_cents: 0}
       end) ++
         [
           %{account_id: ap_clearing.account_id, debit_cents: 0, credit_cents: value}
         ])
      |> Enum.reject(&(&1.debit_cents == 0 and &1.credit_cents == 0))

    entry_attrs = %{
      org_id: org_id,
      entry_date: receipt.received_date,
      memo: "Goods receipt #{receipt.number}" <> memo_suffix(receipt.memo),
      source_key: @source_key,
      source_id: receipt.id,
      lines: entry_lines
    }

    # The posted-born internal factory (the reversal cascade's shape): R1's
    # UnbalancedEntry + EntryLines run resource-wide, so the entry lands
    # POSTED — the receipt IS the posting act; a draft would hide the asset
    # from the GL and from every reconciliation sum.
    case entry_resource
         |> Ash.Changeset.for_create(:create_reversal, entry_attrs, authorize?: false)
         |> Ash.create(authorize?: false) do
      {:ok, entry} -> {:ok, entry}
      {:error, reason} -> {:error, {:entry_failed, reason}}
    end
  end

  # The PO's progression: approved/sent → received (first receipt), through
  # the dedicated internal transition (NOT :update — PoLinesWriter owns draft
  # edits only). The belt trigger admits an →:received transition ONLY under
  # the posting marker (armed by the :receive action) — the stamp is
  # exactly-once with the chokepoint.
  defp stamp_po(changeset, po) when po.status in [:approved, :sent] do
    case po
         |> Ash.Changeset.for_update(:mark_received, %{}, authorize?: false)
         |> Ash.Changeset.force_change_attribute(:status, :received)
         |> Ash.update(authorize?: false) do
      {:ok, _po} -> changeset
      {:error, reason} -> raise "the PO could not progress to :received: #{inspect(reason)}"
    end
  end

  defp stamp_po(changeset, _po), do: changeset

  # ── reads + refusals ────────────────────────────────────────────────────────

  defp refuse_posted(receipt) do
    case receipt.status do
      :draft -> :ok
      other -> {:error, {:already_posted, other}}
    end
  end

  defp lines_of(changeset) do
    case Ash.Changeset.get_argument(changeset, :lines) do
      lines when is_list(lines) and lines != [] -> {:ok, lines}
      _ -> {:error, :no_lines}
    end
  end

  defp fetch_po(po_line_resource, org_id, po_id) do
    # The org pin happens at the QUERY layer: fixture records do not select
    # org_id into their structs (a NotLoaded field), so a struct-pattern pin
    # can never match. A filtered read DOES constrain on the org column.
    require Ash.Query

    po_line_resource
    |> po_resource()
    |> Ash.Query.filter(org_id == ^org_id and id == ^po_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %{} = po} -> {:ok, po}
      {:ok, nil} -> {:error, :po_not_found}
      {:error, reason} -> {:error, {:po_read_failed, reason}}
    end
  end

  defp refuse_not_receivable(po) do
    if po.status in [:approved, :sent, :received] do
      :ok
    else
      {:error, {:po_not_receivable, po.status}}
    end
  end

  # Expand the receipt's `lines` argument into %{po_line, qty} pairs. A
  # po_line from another org (or a nonexistent one) is a data error — the
  # SameOrgFk posture, checked here because the argument is a bare uuid.
  defp expand_lines(po_line_resource, org_id, lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      qty = Map.get(line, :qty) || Map.get(line, "qty")
      po_line_id = Map.get(line, :po_line_id) || Map.get(line, "po_line_id")

      cond do
        not is_integer(qty) or qty <= 0 ->
          {:halt, {:error, {:bad_qty, qty}}}

        is_nil(po_line_id) ->
          {:halt, {:error, :missing_po_line}}

        true ->
          # Same-org pin at the query layer (see fetch_po — fixture records
          # carry org_id as a NotLoaded field; only a filtered read
          # constrains on it).
          require Ash.Query

          case po_line_resource
               |> Ash.Query.filter(org_id == ^org_id and id == ^po_line_id)
               |> Ash.read_one(authorize?: false) do
            {:ok, %{} = po_line} ->
              {:cont, {:ok, acc ++ [%{po_line: po_line, qty: qty}]}}

            {:ok, nil} ->
              {:halt, {:error, {:po_line_not_found, po_line_id}}}

            {:error, reason} ->
              {:halt, {:error, {:po_line_read_failed, reason}}}
          end
      end
    end)
  end

  # Cumulative received facts per po_line (over the ReceiptLine rows): the
  # intake floor is received + qty <= ordered — over-receipt refused.
  defp refuse_over_receipt(receipt_line_resource, expanded) do
    Enum.reduce_while(expanded, :ok, fn %{po_line: po_line, qty: qty}, :ok ->
      received = received_so_far(receipt_line_resource, po_line.id)

      if received + qty > po_line.qty do
        {:halt, {:error, {:over_receipt, po_line.id, received, qty, po_line.qty}}}
      else
        {:cont, :ok}
      end
    end)
  end

  # Resolve each line's inventory-asset account off the PO line's ITEM (the
  # E3 Finance seam): an unlinked item refuses the WHOLE receipt.
  defp value_lines(po_line_resource, expanded) do
    item_resource = item_resource(po_line_resource)

    Enum.reduce_while(expanded, {:ok, []}, fn %{po_line: po_line, qty: qty}, {:ok, acc} ->
      require Ash.Query

      item =
        item_resource
        |> Ash.Query.filter(id == ^po_line.item_id)
        |> Ash.read_one!(authorize?: false)

      case item.default_inventory_account_id do
        nil ->
          {:halt, {:error, {:unlinked_item, item.id}}}

        account_id ->
          {:cont,
           {:ok,
            acc ++
              [%{
                po_line: po_line,
                qty: qty,
                account_id: account_id,
                unit_cost: po_line.unit_cost_cents
              }]}}
      end
    end)
  end

  defp received_value(valued),
    do: Enum.sum(Enum.map(valued, fn %{qty: qty, unit_cost: unit_cost} -> qty * unit_cost end))

  defp posting_account(pa_resource, org_id, key) do
    require Ash.Query

    case pa_resource
         |> Ash.Query.filter(org_id == ^org_id and key == ^key)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, {:unmapped_posting_account, key}}
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, reason}
    end
  end

  defp received_so_far(receipt_line_resource, po_line_id) do
    table = AshPostgres.DataLayer.Info.table(receipt_line_resource)
    repo = AshPostgres.DataLayer.Info.repo(receipt_line_resource, :mutate)
    line_fk = attr_source(receipt_line_resource, :po_line_id)
    qty_col = attr_source(receipt_line_resource, :qty)

    case repo.query(
           "SELECT COALESCE(SUM(#{qty_col}), 0) FROM #{table} WHERE #{line_fk} = $1",
           [dump_uuid(po_line_id)]
         ) do
      {:ok, %{rows: [[total]]}} -> to_i(total)
      {:error, reason} -> raise "the received-sum read failed: #{inspect(reason)}"
    end
  end

  # ── resource resolution (compile-free — off the relationships) ──────────────

  defp po_resource(po_line_resource) do
    po_line_resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.type == :belongs_to and &1.name == :purchase_order))
    |> case do
      nil -> raise "PoLine has no purchase_order relationship"
      rel -> rel.destination
    end
  end

  defp item_resource(po_line_resource) do
    po_line_resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.type == :belongs_to and &1.name == :item))
    |> case do
      nil -> raise "PoLine has no item relationship"
      rel -> rel.destination
    end
  end

  # ── formatting ──────────────────────────────────────────────────────────────

  defp format({:already_posted, status}),
    do: "the receipt is #{inspect(status)} — a receipt posts exactly once"

  defp format(:no_lines), do: "the receipt carries no lines"
  defp format(:po_not_found), do: "the receipt's PO does not exist in this org"

  defp format({:po_not_receivable, status}),
    do: "the PO is #{inspect(status)} — only an approved/sent/received PO can be received"

  defp format({:bad_qty, qty}),
    do: "every receipt line qty must be a positive integer — got: #{inspect(qty)}"

  defp format(:missing_po_line), do: "every receipt line must name its po_line_id"

  defp format({:po_line_not_found, id}),
    do: "receipt line names a po_line that does not exist in this org: #{inspect(id)}"

  defp format({:over_receipt, po_line_id, received, qty, ordered}),
    do: "over-receipt refused: po_line #{inspect(po_line_id)} has #{received} received and " <>
          "#{qty} more were demanded against an order of #{ordered} — receiving more than " <>
          "was ordered is a data error (the P2 tolerance carry may relax this per host)"

  defp format({:unlinked_item, item_id}),
    do: "item #{inspect(item_id)} has no default_inventory_account_id — an unlinked item " <>
          "never posts (set the item's Finance seam first; a partial posting is not a posting)"

  defp format({:unmapped_posting_account, key}),
    do: "no PostingAccount row maps `#{key}` for this org (fail-honest — accounts are a " <>
          "host decision; seed the org's posting accounts first)"

  defp format({:po_read_failed, reason}), do: "the receipt's PO read failed: #{inspect(reason)}"

  defp format({:po_line_read_failed, reason}),
    do: "a receipt line's PO line read failed: #{inspect(reason)}"

  defp format({:receipt_line_failed, reason}),
    do: "the receipt's line fact failed to land: #{inspect(reason)}"

  defp format({:stock_event_failed, reason}),
    do: "the goods receipt's stock event failed: #{inspect(reason)}"

  defp format({:entry_failed, reason}),
    do: "the goods receipt's journal entry failed to land: #{inspect(reason)}"

  defp format(reason), do: inspect(reason)

  # ── plumbing ────────────────────────────────────────────────────────────────

  defp resolve_org(changeset) do
    # :receive is accept([]) — the pending attributes carry NO org_id, and
    # even when the attribute IS pending, the RECORD's org_id reads NotLoaded
    # on a struct the caller holds. One honest route: re-fetch by id and take
    # the org column off the row (a query-level read, not a struct load).
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
          other -> raise "the receipt's org could not be resolved: #{inspect(other)}"
        end
    end
  end

  defp attr_source(resource, name) do
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

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp memo_suffix(nil), do: ""
  defp memo_suffix(""), do: ""
  defp memo_suffix(memo), do: " — " <> memo
end
