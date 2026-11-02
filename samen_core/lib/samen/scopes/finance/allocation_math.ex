defmodule Samen.Scopes.Finance.AllocationMath do
  @moduledoc """
  The allocation step's arithmetic (WS-ACCT Phase 10; ADR-054 decision 11):
  split ONE cent amount across N cost objects by a declared basis driver, with
  the shares summing to the amount **exactly**.

  ## Why largest remainder, not `round/1` per share

  Rounding each share independently can lose or invent cents: 1 000 000.01
  split three ways rounds to three shares that sum to 1 000 000.02, and a
  3-cent invoice split 40/40/20 rounds to 1/1/1 and invents a cent. A lost cent
  is a ledger that does not tie to the vendor's invoice; an invented cent is
  cost a programme never incurred. This is the phase's red path.

  So every share first takes the floor of its exact proportion
  (`amount * driver / total_driver`, integer division), and the leftover cents
  (`0 ≤ leftover < N`) go one each to the shares with the largest fractional
  remainders. Ties go to the larger driver, then to the cost-object id, so the
  same inputs always produce the same split.

  ## The driver is a basis quantity, never money

  Die-area units, wafers, effort hours — only the proportions matter. A zero or
  negative driver is refused: a cost object with no share of the basis has no
  business absorbing cost, and an all-zero basis is a division by zero dressed
  as an allocation. Fewer than two targets is refused too — a one-target
  "allocation" is a reclass, which the ordinary journal entry already does.

  The `basis` recorded on the allocation is the DECLARED unit (an audit label);
  this module cannot verify that a driver really is square microns, and says so
  rather than pretending.
  """

  @type share :: %{
          required(:cost_object_id) => String.t(),
          required(:driver) => pos_integer()
        }

  @doc """
  Allocate `amount_cents` across `shares` (each `%{cost_object_id, driver}`).

  Returns `{:ok, shares}` with an `:allocated_cents` added to every entry, in
  the input order, or `{:error, reason}` where reason is `:invalid_amount`,
  `:too_few_shares`, `:duplicate_cost_object` or `:invalid_driver`.
  """
  @spec allocate(integer(), [map()]) :: {:ok, [map()]} | {:error, atom()}
  def allocate(amount_cents, shares)
      when is_integer(amount_cents) and amount_cents > 0 and is_list(shares) do
    with :ok <- require_two_targets(shares),
         :ok <- require_distinct(shares),
         normalized = Enum.map(shares, &normalize/1),
         :ok <- require_shape(normalized) do
      total_driver = Enum.reduce(normalized, 0, fn share, acc -> acc + share.driver end)

      bases =
        Enum.map(normalized, fn share ->
          div(amount_cents * share.driver, total_driver)
        end)

      leftover = amount_cents - Enum.sum(bases)

      # Rank by the fractional remainder, then the larger driver, then the id —
      # deterministic, and never sensitive to the caller's list order.
      order =
        normalized
        |> Enum.with_index()
        |> Enum.map(fn {share, index} ->
          remainder = rem(amount_cents * share.driver, total_driver)
          {index, {-remainder, -share.driver, share.cost_object_id}}
        end)
        |> Enum.sort_by(fn {_index, rank} -> rank end)
        |> Enum.map(fn {index, _rank} -> index end)
        |> Enum.take(leftover)

      boosted = MapSet.new(order)

      allocated =
        normalized
        |> Enum.with_index()
        |> Enum.map(fn {share, index} ->
          extra = if MapSet.member?(boosted, index), do: 1, else: 0

          %{
            cost_object_id: share.cost_object_id,
            driver: share.driver,
            allocated_cents: Enum.at(bases, index) + extra
          }
        end)

      # The whole point of the module. If this ever fails, the arithmetic is
      # wrong and no caller should receive the split.
      if Enum.reduce(allocated, 0, &(&1.allocated_cents + &2)) == amount_cents do
        {:ok, allocated}
      else
        {:error, :allocation_does_not_tie}
      end
    end
  end

  def allocate(_amount_cents, _shares), do: {:error, :invalid_amount}

  # ── guards ─────────────────────────────────────────────────────────────────

  defp require_two_targets(shares) when length(shares) >= 2, do: :ok
  defp require_two_targets(_shares), do: {:error, :too_few_shares}

  defp require_distinct(shares) do
    ids = Enum.map(shares, &Map.get(&1, :cost_object_id) || Map.get(&1, "cost_object_id"))

    if length(Enum.uniq(ids)) == length(ids) do
      :ok
    else
      {:error, :duplicate_cost_object}
    end
  end

  defp require_shape(shares) do
    if Enum.all?(shares, fn share ->
         is_binary(share.cost_object_id) and share.cost_object_id != "" and
           is_integer(share.driver) and share.driver > 0
       end) do
      :ok
    else
      {:error, :invalid_driver}
    end
  end

  defp normalize(share) do
    %{
      cost_object_id: Map.get(share, :cost_object_id) || Map.get(share, "cost_object_id"),
      driver: Map.get(share, :driver) || Map.get(share, "driver")
    }
  end
end
