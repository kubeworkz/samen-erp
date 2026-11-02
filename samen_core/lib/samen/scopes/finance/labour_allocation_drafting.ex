defmodule Samen.Scopes.Finance.LabourAllocationDrafting do
  @moduledoc """
  The drafting cascade for a labour allocation (WS-ACCT Unit 10.2;
  ADR-054 D17).

  Runs on `:draft`'s `before_action`: it reads the **approved** timesheets
  overlapping the payroll period through `Samen.Scopes.Finance.LabourDriver`,
  turns those minutes into an exact cent split with
  `Samen.Scopes.Finance.AllocationMath`, and materializes append-only shares
  in the header's transaction. It accepts the declared payroll total and the
  two accounts; it accepts **no** minutes, shares or cents.

  ## What is refused, and why

    * a period that runs backwards;
    * a total that is zero or negative (not a fact);
    * the same source and target account (nothing would move);
    * a period with no approved timesheet minutes — there is no driver, so
      there is nothing to allocate (this is also what an unwired `labour:`
      mount surfaces, as `:timesheets_not_wired`, rather than posting an even
      split of money nobody measured);
    * fewer than two cost objects — a single-programme payroll is a reclass,
      which an ordinary journal entry already posts;
    * a share that would receive zero cents (the amount is too small for the
      basis) — a zero-cent programme is not a fact;
    * a second allocation of the same (period, source account) — the unique
      index is the belt; this pre-read names the existing row.

  ## The declared total

  Actual pay is not minutes × rate (deductions, salaried staff, overtime), so
  the total is the accountant's fact and is stored as given. The allocation
  does not pretend the hours explain the money; it explains the DISTRIBUTION
  of the money, which is exactly what the timesheet dimension records.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias Samen.Scopes.Finance.AllocationMath
  alias Samen.Scopes.Finance.LabourDriver

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      draft(changeset, org_id(changeset), opts)
    end)
  end

  defp draft(changeset, org_id, opts) do
    from = Ash.Changeset.get_attribute(changeset, :period_start)
    to = Ash.Changeset.get_attribute(changeset, :period_end)
    total = Ash.Changeset.get_attribute(changeset, :total_cents)

    with :ok <- require_period(from, to),
         :ok <- require_total(total),
         :ok <- require_different_accounts(changeset),
         {:ok, driver} <- LabourDriver.driver(org_id, from, to, opts),
         :ok <- require_minutes(driver),
         {:ok, computed} <- AllocationMath.allocate(total, as_drivers(driver.shares)),
         :ok <- require_positive(computed),
         :ok <-
           require_unallocated(
             changeset.resource,
             org_id,
             from,
             to,
             Ash.Changeset.get_attribute(changeset, :source_account_id)
           ) do
      changeset
      |> Ash.Changeset.force_change_attribute(:status, :draft)
      |> Ash.Changeset.after_action(fn _changeset, header ->
        materialize(header, org_id, Keyword.fetch!(opts, :share), computed)
      end)
    else
      {:error, message} when is_binary(message) -> error(changeset, message)
      {:error, reason} -> error(changeset, format(reason))
    end
  end

  # ── inputs ─────────────────────────────────────────────────────────────────

  defp require_period(%Date{} = from, %Date{} = to) do
    if Date.compare(to, from) == :lt do
      {:error, "the payroll period ends before it starts"}
    else
      :ok
    end
  end

  defp require_period(_from, _to), do: {:error, "both payroll period dates are required"}

  defp require_total(total) when is_integer(total) and total > 0, do: :ok

  defp require_total(_total) do
    {:error, "the payroll total must be a positive integer number of cents"}
  end

  defp require_different_accounts(changeset) do
    source = Ash.Changeset.get_attribute(changeset, :source_account_id)
    target = Ash.Changeset.get_attribute(changeset, :target_account_id)

    if is_binary(source) and source == target do
      {:error,
       "the source and target accounts are the same — a payroll allocation must move " <>
         "cost out of payroll expense into the account the programmes carry it under"}
    else
      :ok
    end
  end

  # ── driver ─────────────────────────────────────────────────────────────────

  defp require_minutes(%{shares: []}) do
    {:error,
     "no approved timesheet minutes fall in this payroll period — approve the " <>
       "timesheets before allocating payroll (there is no driver to split by)"}
  end

  defp require_minutes(_driver), do: :ok

  # `AllocationMath` speaks `driver`; the labour driver speaks `minutes`. They
  # are the same basis quantity — map explicitly rather than sharing a key name
  # across two contexts.
  defp as_drivers(shares) do
    Enum.map(shares, &%{cost_object_id: &1.cost_object_id, driver: &1.minutes})
  end

  defp require_positive(computed) do
    zeroes = Enum.count(computed, &(&1.allocated_cents <= 0))

    if zeroes == 0 do
      :ok
    else
      {:error,
       "the payroll total is too small to allocate across #{length(computed)} cost " <>
         "objects — #{zeroes} share(s) would be zero cents, which is not a fact " <>
         "(raise the total or merge the programmes)"}
    end
  end

  defp require_unallocated(allocation_mod, org_id, from, to, source_id) do
    existing =
      allocation_mod
      |> Ash.Query.filter(
        org_id == ^org_id and period_start == ^from and period_end == ^to and
          source_account_id == ^source_id and status != :discarded
      )
      |> Ash.read_one(authorize?: false)

    case existing do
      {:ok, nil} ->
        :ok

      {:ok, row} ->
        {:error,
         "this payroll period's cost on that account is already allocated " <>
           "(#{row.status}) — one allocation per period and source account; a " <>
           "correction is a reversing entry, never a second allocation of the same fact"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── persistence ────────────────────────────────────────────────────────────

  defp materialize(header, org_id, share_mod, computed) do
    Enum.reduce_while(computed, {:ok, header}, fn share, {:ok, header} ->
      attrs = %{
        org_id: org_id,
        labour_allocation_id: header.id,
        cost_object_id: share.cost_object_id,
        minutes: share.driver,
        allocated_cents: share.allocated_cents
      }

      case share_mod
           |> Ash.Changeset.for_create(:materialize, attrs, authorize?: false)
           |> Ash.create(authorize?: false) do
        {:ok, _share} -> {:cont, {:ok, header}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # ── errors / plumbing ──────────────────────────────────────────────────────

  defp format(:timesheets_not_wired) do
    "this Finance mount has no Work timesheet modules — configure " <>
      "`labour: [timesheet: ..., timesheet_entry: ...]` to allocate payroll by " <>
      "approved hours"
  end

  defp format(:invalid_period) do
    "the payroll period is invalid — both dates are required and the end cannot " <>
      "fall before the start"
  end

  defp format(:too_few_shares) do
    "the approved timesheets name fewer than two cost objects — a single-programme " <>
      "payroll is a reclass, which an ordinary journal entry already posts"
  end

  defp format(:duplicate_cost_object) do
    "a cost object appears more than once in the labour driver"
  end

  defp format(:invalid_driver) do
    "the labour driver carries a non-positive minutes value — every share must be " <>
      "backed by approved time"
  end

  defp format(:invalid_amount) do
    "the payroll total must be a positive integer number of cents"
  end

  defp format(:allocation_does_not_tie) do
    "the labour allocation's shares do not sum to the payroll total — refused " <>
      "rather than posting a split that loses or invents a cent"
  end

  defp format(reason), do: inspect(reason)

  defp error(changeset, message) do
    Ash.Changeset.add_error(changeset, field: :base, message: message)
  end

  defp org_id(changeset) do
    case Ash.Changeset.get_attribute(changeset, :org_id) do
      %Ash.NotLoaded{} -> persisted_org_id(changeset.data)
      nil -> persisted_org_id(changeset.data)
      value -> value
    end
  end

  defp persisted_org_id(record) do
    case record.org_id do
      %Ash.NotLoaded{} -> Ash.load!(record, [:org_id], authorize?: false).org_id
      value -> value
    end
  end
end
