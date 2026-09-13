defmodule Samen.Scopes.Inventory.StockLevelSync do
  @moduledoc """
  The rollup writer (WS-ERP E3; design §3.1): rebuilds the
  `(org, item, warehouse)` `StockLevel` row from the ledger tail IN THE
  SAME TRANSACTION as the event — real-time-at-post (design §9's
  read-your-writes note: the check-at-post is the live ledger sum, the
  rollup serves reads between posts; the freshness is documented, never
  faked).

  Runs on the `StockLedger :record` action's `after_action` (the event has
  landed; the Ecto transaction is still open), and:

    * arms the `samen.stock_sync` belt marker (the level table's trigger
      refuses writes without it — the derived-cache discipline: nothing
      else may write a level row; see the E3 migration), restoring the
      PRIOR value after (the E1/E2 PostingMarker lesson — nested arms),
    * recomputes `qty_on_hand`, `avg_unit_cost_cents`, and
      `stock_value_cents` from the PERSISTED ledger rows (SQL sums — the
      event is already visible inside the transaction),
    * upserts via the `:sync_write` create (upsert on the
      `{org, item, warehouse}` identity), so the row is born or advanced,
      never duplicated.

  `ReconcileStock` recomputes the same quantities INDEPENDENTLY (its own
  SQL over the ledger) — the sync writer and the reconciler share no code
  path, which is what makes R3 a real reconciliation.
  """

  use Ash.Resource.Change

  @guc "samen.stock_sync"

  @doc "The GUC name the E3 migration's level-table trigger checks."
  def guc, do: @guc

  @impl true
  def change(changeset, opts, _context) do
    level_resource = Keyword.fetch!(opts, :level)

    repo = AshPostgres.DataLayer.Info.repo(changeset.resource, :mutate)

    # Capture at change/2 time (the EntryLines discipline — org_id is
    # transformer-injected and reads back NotLoaded on results).
    org_id = resolve_org(changeset)

    Ash.Changeset.after_action(changeset, fn _changeset, ledger_event ->
      sync!(repo, level_resource, org_id, ledger_event)
      {:ok, ledger_event}
    end)
  end

  defp sync!(repo, level_resource, org_id, event) do
    prior = arm!(repo)
    ledger_resource = event.__struct__

    try do
      sums = ledger_sums(repo, ledger_resource, org_id, event.item_id, event.warehouse_id)

      level_resource
      |> Ash.Changeset.for_create(:sync_write, %{
        org_id: org_id,
        item_id: event.item_id,
        warehouse_id: event.warehouse_id,
        qty_on_hand: sums.on_hand,
        avg_unit_cost_cents: sums.avg_unit_cost,
        stock_value_cents: sums.stock_value
      })
      |> Ash.create(authorize?: false)
      |> case do
        {:ok, _level} -> :ok
        {:error, reason} -> raise "StockLevelSync failed: #{inspect(reason)}"
      end
    after
      restore!(repo, prior)
    end
  end

  # The moving average over the VALUED events: Σ(qty*cost) / Σ(|qty|) —
  # computed in SQL, over the persisted rows (the event is already visible
  # inside the transaction). Rows with zero cost do not move the average;
  # a pair with no valued events averages NULL (the level's column is
  # nullable for exactly that state).
  defp ledger_sums(repo, ledger_resource, org_id, item_id, warehouse_id) do
    table = AshPostgres.DataLayer.Info.table(ledger_resource)
    org = col(ledger_resource, :org_id)
    item = col(ledger_resource, :item_id)
    warehouse = col(ledger_resource, :warehouse_id)
    qty = col(ledger_resource, :qty)
    cost = col(ledger_resource, :unit_cost_cents)

    case repo.query!(
           """
           SELECT COALESCE(SUM(#{qty}), 0),
                  CASE WHEN COALESCE(SUM(ABS(#{qty})) FILTER (WHERE #{cost} > 0), 0) = 0
                       THEN NULL
                       ELSE (SUM(#{qty} * #{cost}) FILTER (WHERE #{cost} > 0)
                             / SUM(ABS(#{qty})) FILTER (WHERE #{cost} > 0))::bigint END,
                  COALESCE(SUM(#{qty} * #{cost}), 0)
           FROM #{table}
           WHERE #{org} = $1 AND #{item} = $2 AND #{warehouse} = $3
           """,
           [dump_uuid(org_id), dump_uuid(item_id), dump_uuid(warehouse_id)]
         ).rows do
      [[on_hand, avg, value]] ->
        %{
          on_hand: to_i(on_hand),
          avg_unit_cost: to_i(avg),
          stock_value: to_i(value)
        }
    end
  end

  # ── the belt marker ────────────────────────────────────────────────────────

  defp arm!(nil), do: "off"

  defp arm!(repo) do
    prior =
      case repo.query!("SELECT current_setting('#{@guc}', true)", []).rows do
        [[value]] when is_binary(value) -> value
        _ -> "off"
      end

    repo.query!("SELECT set_config('#{@guc}', 'on', true)", [])
    prior
  end

  defp restore!(nil, _value), do: :ok

  defp restore!(repo, value) when is_binary(value) do
    repo.query!("SELECT set_config('#{@guc}', '#{value}', true)", [])
    :ok
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp resolve_org(changeset) do
    case Ash.Changeset.get_attribute(changeset, :org_id) do
      %Ash.NotLoaded{} ->
        Ash.load!(changeset.data, [:org_id], authorize?: false).org_id

      value ->
        value
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

  defp to_i(nil), do: nil
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
