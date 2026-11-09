defmodule Samen.Scopes.Finance.ApDuplicates do
  @moduledoc """
  The duplicate rule — "these two bills are the same document": same vendor,
  same line total, same bill date. Invoice capture uses this module directly;
  the AP payment run applies the identical rule in `ApPaymentRun.duplicates/1`,
  and both share `total/1` for the amount, so a bill's total cannot drift
  between the two paths.

  Two bills are duplicates when they share the vendor, the line total and the
  bill date — the shape a re-keyed invoice takes when only the vendor's number
  differs (`{org, number}` is already unique at the database, so an identical
  number cannot be stored twice). An identical number is a separate, harder
  check: `ApInvoiceCapture` refuses on `{org, number}` before it ever asks this
  module, because a number collision is a duplicate regardless of vendor.

  Detection is over the bills the caller supplies; the caller decides which
  population that is (the approved list, one payment batch, or the org's bills
  sharing a vendor and date).
  """

  @doc """
  Group the supplied bills by `{vendor_id, line total, bill_date}` and return
  only the groups with more than one bill, sorted by number inside each group.

  Bills without a vendor are ignored (they cannot be attributed), and a single
  bill never produces a group.
  """
  @spec groups([map()]) :: [%{key: tuple(), bills: [map()]}]
  def groups(bills) when is_list(bills) do
    bills
    |> Enum.reject(&(Map.get(&1, :vendor_id) in [nil, ""]))
    |> Enum.group_by(&key/1)
    |> Enum.filter(fn {_key, group} -> length(group) > 1 end)
    |> Enum.map(fn {key, group} ->
      %{key: key, bills: Enum.sort_by(group, &to_string(Map.get(&1, :number)))}
    end)
    |> Enum.sort_by(fn %{key: {vendor, total, date}} -> {to_string(date), vendor, total} end)
  end

  @doc "The identity this module compares: vendor, line total and bill date."
  @spec key(map()) :: {term(), integer(), term()}
  def key(bill) do
    {Map.get(bill, :vendor_id), total(bill), Map.get(bill, :bill_date)}
  end

  @doc "The bill's amount: the sum of its embedded lines."
  @spec total(map()) :: integer()
  def total(bill) do
    bill
    |> Map.get(:lines)
    |> List.wrap()
    |> Enum.reduce(0, fn line, sum ->
      sum + (Map.get(line, :amount_cents) || Map.get(line, "amount_cents") || 0)
    end)
  end

  @doc """
  The bills in `bills` that collide with `candidate` under `key/1`.

  Used at capture time: the candidate is a parsed invoice draft (vendor, total,
  bill date) and the bills are the org's rows for that vendor and date.
  """
  @spec candidate_matches([map()], map()) :: [map()]
  def candidate_matches(bills, candidate) when is_list(bills) do
    identity = key(candidate)
    Enum.filter(bills, &(key(&1) == identity))
  end
end
