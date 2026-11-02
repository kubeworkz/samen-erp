defmodule Samen.Scopes.Finance.LabourDriver do
  @moduledoc """
  The **labour driver** for payroll cost allocation (WS-ACCT Unit 10.2;
  ADR-054 D17): approved timesheet minutes per cost object, for one payroll
  period.

  ## Only approved sheets count

  A timesheet is read only when its status is `:approved`, and only entries
  dated inside the payroll period are counted. A submitted-but-unapproved
  sheet, a draft, or an entry dated outside the window contributes ZERO
  minutes — unapproved time is not a labour fact, and the driver is the one
  place that decides it.

  ## A sheet overlaps, an entry lands

  The sheet scan is an overlap: a monthly capture that starts before the pay
  period and ends inside it is included, and its entries are then filtered by
  `worked_on` to the pay period. The entry is the unit of time; the sheet is
  only the approval envelope.

  ## The driver is minutes, never money

  Rates live in payroll, not here. The driver returns minutes per cost object
  and the total; `Samen.Scopes.Finance.AllocationMath` turns those proportions
  into cents on the declared payroll total. A cost object with zero approved
  minutes simply does not appear — it has no share of the basis and absorbs no
  cost.

  ## No PII

  Reads return cost-object ids, minutes and dates; `employee_id` is never
  selected. The lookup is org-scoped and `authorize?: false` because it is a
  system derivation inside the accountant's action, not a user read: the action
  itself is policy-gated and the caller cannot choose the org.
  """

  require Ash.Query

  @doc """
  Derive the labour driver for `org_id` over `[from, to]`.

  Options: `timesheet` (Work.Timesheet module) and `timesheet_entry`
  (Work.TimesheetEntry module). Both must be configured by the Finance mount
  (`labour: [timesheet: ..., timesheet_entry: ...]`); otherwise the draft and
  post actions refuse with `:timesheets_not_wired`.

  Returns `{:ok, %{shares: [%{cost_object_id, minutes}], total_minutes: n,
  timesheets: n}}` or `{:error, reason}` where reason is
  `:timesheets_not_wired` or `:invalid_period`.
  """
  @spec driver(String.t(), Date.t(), Date.t(), keyword()) ::
          {:ok, %{shares: [map()], total_minutes: non_neg_integer(), timesheets: non_neg_integer()}}
          | {:error, atom()}
  def driver(org_id, %Date{} = from, %Date{} = to, opts) do
    timesheet_mod = Keyword.get(opts, :timesheet)
    entry_mod = Keyword.get(opts, :timesheet_entry)

    cond do
      is_nil(timesheet_mod) or is_nil(entry_mod) ->
        {:error, :timesheets_not_wired}

      Date.compare(to, from) == :lt ->
        {:error, :invalid_period}

      true ->
        approved = approved_sheets(timesheet_mod, org_id, from, to)
        entries = entries_in(entry_mod, org_id, approved, from, to)
        shares = shares(entries)

        {:ok,
         %{
           shares: shares,
           total_minutes: Enum.reduce(shares, 0, &(&1.minutes + &2)),
           timesheets: length(approved)
         }}
    end
  end

  def driver(_org_id, _from, _to, _opts), do: {:error, :invalid_period}

  # The approval envelope: approved sheets whose window overlaps the pay period.
  defp approved_sheets(timesheet_mod, org_id, from, to) do
    timesheet_mod
    |> Ash.Query.filter(
      org_id == ^org_id and status == :approved and
        period_start <= ^to and period_end >= ^from
    )
    |> Ash.Query.select([:id, :period_start, :period_end])
    |> Ash.read!(authorize?: false)
  end

  # The time itself: entries inside the pay period, from those approved sheets.
  defp entries_in(_entry_mod, _org_id, [], _from, _to), do: []

  defp entries_in(entry_mod, org_id, approved, from, to) do
    ids = Enum.map(approved, & &1.id)

    entry_mod
    |> Ash.Query.filter(
      org_id == ^org_id and worked_on >= ^from and worked_on <= ^to and
        timesheet_id in ^ids
    )
    |> Ash.Query.select([:cost_object_id, :minutes])
    |> Ash.read!(authorize?: false)
  end

  defp shares(entries) do
    entries
    |> Enum.group_by(& &1.cost_object_id)
    |> Enum.map(fn {cost_object_id, rows} ->
      %{
        cost_object_id: cost_object_id,
        minutes: Enum.reduce(rows, 0, &(&1.minutes + &2))
      }
    end)
    |> Enum.sort_by(& &1.cost_object_id)
  end
end
