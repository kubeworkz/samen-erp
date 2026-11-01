defmodule Samen.Scopes.Finance.ReserveAssessment do
  @moduledoc """
  The obsolescence assessment (WS-ACCT Phase 9; ADR-054 D10): a DERIVED read of
  which stock a policy estimates obsolete, and by how many cents.

  It writes nothing. That is the phase's first acceptance criterion — an
  assessment drafts, it never posts — and it is why this module takes resource
  modules instead of owning state: the same read serves the draft cascade, the
  posting cascade's re-derivation, and an operator's dashboard.

  ## The estimate

  Per `(item, warehouse)` stock level with quantity on hand:

    * **`:age`** — walk the append-only stock ledger as FIFO layers
      (oldest first; an outbound movement consumes the oldest layer) and count
      the quantity still on hand that arrived on or before `as_of − age_months`.
      That quantity, valued at the level's moving average, is the aged cost.
    * **`:item`** — the named items' whole on-hand quantity is the aged cost.

  The write-down is `pct` of the item's **remaining carrying value**, where the
  remaining value is the aged cost minus every write-down **already posted** for
  that item — under this policy or any other. NRV is an estimate applied to what
  is still on the books; without that netting, a second quarterly review would
  propose the same cents again even though the first review already expensed
  them.

  ## The policy's `applies_to`

  For `:age` an empty `applies_to` means every stocked item; a non-empty list
  narrows the policy to those item ids. For `:item` the list is required (the
  shape guard refuses an empty one), because a policy that names no item has no
  basis at all.

  ## What it deliberately does not do

  * It never mutates a stock level, a ledger event, or an item — the read has
    no writes and no side effects.
  * It never treats missing data as zero: an eligible item with no inventory
    account is reported with `inventory_account_id: nil` so the drafting
    cascade can refuse it by SKU. A write-down that cannot name where the credit
    goes is not bookable.
  * It does not model market NRV. The percentage IS the NRV assumption; there
    is no price feed, and inventing one would be the "two truths" failure.
  """

  require Ash.Query

  @doc """
  Assess `policy` for `org_id`.

  Opts (required): `:items`, `:levels`, `:ledger`, `:write_downs`, `:lines`.
  Opts (optional): `:as_of` (defaults to `Date.utc_today/0`).

  Returns `%{policy:, as_of:, cutoff:, candidates:, total_cents:,
  bookable?:, missing_accounts:, prior_cents:}`. A candidate is
  `%{item_id:, sku:, name:, quantity:, cost_cents:, prior_cents:,
  write_down_cents:, inventory_account_id:}`.
  """
  def assess(org_id, policy, opts) do
    items_mod = Keyword.fetch!(opts, :items)
    levels_mod = Keyword.fetch!(opts, :levels)
    ledger_mod = Keyword.fetch!(opts, :ledger)
    write_downs_mod = Keyword.fetch!(opts, :write_downs)
    lines_mod = Keyword.fetch!(opts, :lines)

    as_of = Keyword.get(opts, :as_of) || Date.utc_today()
    cutoff = cutoff_for(policy, as_of)

    items = read_items(items_mod, org_id)
    levels = read_levels(levels_mod, org_id)
    ledger = read_ledger(ledger_mod, org_id, items)
    prior = prior_write_downs(write_downs_mod, lines_mod, org_id)

    levels_by_item = Enum.group_by(levels, & &1.item_id)
    ledger_by_level = Enum.group_by(ledger, &{&1.item_id, &1.warehouse_id})

    candidates =
      items
      |> Enum.flat_map(fn item ->
        item
        |> candidates_for(
          Map.get(levels_by_item, item.id, []),
          ledger_by_level,
          policy,
          cutoff,
          Map.get(prior, item.id, 0)
        )
        |> Enum.reject(fn candidate -> candidate.write_down_cents <= 0 end)
      end)
      |> Enum.sort_by(& &1.sku)

    %{
      org_id: org_id,
      policy: policy,
      as_of: as_of,
      cutoff: cutoff,
      candidates: candidates,
      total_cents: Enum.reduce(candidates, 0, &(&1.write_down_cents + &2)),
      prior_cents: Enum.reduce(prior, 0, fn {_item, cents}, acc -> acc + cents end),
      bookable?: Enum.all?(candidates, &is_binary(&1.inventory_account_id)),
      missing_accounts: for(c <- candidates, is_nil(c.inventory_account_id), do: c.sku)
    }
  end

  @doc """
  The month-end cut: `as_of` shifted back `months`, clamped to the target
  month's last day (a 31st stays a 31st where it exists).
  """
  def cutoff_for(%{basis: :age, age_months: months}, as_of)
      when is_integer(months) and months > 0 do
    shift_months(as_of, -months)
  end

  def cutoff_for(_policy, _as_of), do: nil

  @doc """
  The aged quantity still on hand, as FIFO layers.

  `events` are stock-ledger rows (any order) carrying `qty` (signed) and
  `inserted_at`. An inbound movement pushes a layer dated its ledger timestamp;
  an outbound movement consumes the oldest layers first. The result is the
  remaining quantity whose layer date is on or before `cutoff`, capped at
  `on_hand` (the ledger and the level rollup are reconciled by R3; the cap keeps
  a concurrent reader from reporting more than the level says is there).

  This is public because it is the arithmetic worth pinning directly: a test can
  state layers and a cut without building a database around them.
  """
  def aged_quantity(events, cutoff, on_hand) when is_integer(on_hand) and on_hand > 0 do
    events
    |> Enum.sort_by(& &1.inserted_at)
    |> Enum.reduce([], fn event, layers ->
      cond do
        event.qty > 0 -> layers ++ [{DateTime.to_date(event.inserted_at), event.qty}]
        event.qty < 0 -> consume(layers, -event.qty)
        true -> layers
      end
    end)
    |> Enum.filter(fn {at, _qty} -> Date.compare(at, cutoff) != :gt end)
    |> Enum.reduce(0, fn {_at, qty}, acc -> acc + qty end)
    |> min(on_hand)
  end

  def aged_quantity(_events, _cutoff, _on_hand), do: 0

  # ── per-item rollup ────────────────────────────────────────────────────────

  defp candidates_for(_item, [], _ledger_by_level, _policy, _cutoff, _prior), do: []

  defp candidates_for(item, levels, ledger_by_level, policy, cutoff, prior) do
    {quantity, cost_cents} =
      Enum.reduce(levels, {0, 0}, fn level, {quantity, cost} ->
        aged = aged_for_level(level, policy, cutoff, ledger_by_level)
        {quantity + aged, cost + pro_rata(level.stock_value_cents, aged, level.qty_on_hand)}
      end)

    remaining = max(cost_cents - prior, 0)

    [
      %{
        item_id: item.id,
        sku: item.sku,
        name: item.name,
        quantity: quantity,
        cost_cents: cost_cents,
        prior_cents: prior,
        write_down_cents: apply_pct(remaining, policy.pct),
        inventory_account_id: item.default_inventory_account_id
      }
    ]
  end

  defp aged_for_level(level, %{basis: :item} = policy, _cutoff, _ledger_by_level) do
    if selected?(policy, level.item_id), do: level.qty_on_hand, else: 0
  end

  defp aged_for_level(level, %{basis: :age} = policy, cutoff, ledger_by_level) do
    if selected?(policy, level.item_id) do
      ledger_by_level
      |> Map.get({level.item_id, level.warehouse_id}, [])
      |> aged_quantity(cutoff, level.qty_on_hand)
    else
      0
    end
  end

  defp selected?(%{applies_to: []}, _item_id), do: true
  defp selected?(%{applies_to: ids}, item_id), do: item_id in ids

  # ── reads ──────────────────────────────────────────────────────────────────

  defp read_items(items_mod, org_id) do
    # authz-scope: system assessment — the item master of the org that owns the
    # policy; the caller is the governed draft/post on that policy, and the row
    # carries only ids/skus/costs (no tenant-surface read).
    items_mod
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.Query.sort(sku: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp read_levels(levels_mod, org_id) do
    # authz-scope: system assessment — the org's on-hand levels; derived rollups,
    # read only to value the aged quantity (no mutation, no cross-tenant read).
    levels_mod
    |> Ash.Query.filter(org_id == ^org_id and qty_on_hand > 0)
    |> Ash.read!(authorize?: false)
  end

  defp read_ledger(_ledger_mod, _org_id, []), do: []

  defp read_ledger(ledger_mod, org_id, items) do
    item_ids = Enum.map(items, & &1.id)

    # authz-scope: system assessment — the org's append-only stock history for
    # the items the same org owns; the FIFO walk needs the whole movement tail.
    ledger_mod
    |> Ash.Query.filter(org_id == ^org_id and item_id in ^item_ids)
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp prior_write_downs(write_downs_mod, lines_mod, org_id) do
    # authz-scope: system assessment — the org's POSTED write-down headers, read
    # to net already-expensed value out of the next estimate.
    posted =
      write_downs_mod
      |> Ash.Query.filter(org_id == ^org_id and status == :posted)
      |> Ash.read!(authorize?: false)

    case posted do
      [] ->
        %{}

      rows ->
        ids = Enum.map(rows, & &1.id)

        # authz-scope: system assessment — the lines of THIS org's posted
        # write-downs, by their header ids.
        lines_mod
        |> Ash.Query.filter(org_id == ^org_id and write_down_id in ^ids)
        |> Ash.read!(authorize?: false)
        |> Enum.reduce(%{}, fn line, acc ->
          Map.update(acc, line.item_id, line.write_down_cents, &(&1 + line.write_down_cents))
        end)
    end
  end

  # ── arithmetic ─────────────────────────────────────────────────────────────

  defp pro_rata(_value, 0, _whole), do: 0

  defp pro_rata(value, part, whole) when whole > 0 do
    div(value * part + div(whole, 2), whole)
  end

  # Basis points are whole percentages (1..100), so half-up on cents.
  defp apply_pct(cents, pct) when is_integer(cents) and cents > 0 do
    div(cents * pct + 50, 100)
  end

  defp apply_pct(_cents, _pct), do: 0

  # FIFO consumption: outbound quantity eats the oldest layer first.
  defp consume(layers, 0), do: layers
  defp consume([], _quantity), do: []

  defp consume([{_at, qty} | rest], quantity) when qty <= quantity,
    do: consume(rest, quantity - qty)

  defp consume([{at, qty} | rest], quantity), do: [{at, qty - quantity} | rest]

  defp shift_months(date, months) when is_integer(months) do
    total = date.year * 12 + (date.month - 1) + months
    year = Integer.floor_div(total, 12)
    month = Integer.mod(total, 12) + 1
    day = min(date.day, Date.days_in_month(Date.new!(year, month, 1)))
    Date.new!(year, month, day)
  end
end
