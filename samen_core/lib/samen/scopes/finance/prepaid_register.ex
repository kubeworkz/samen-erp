defmodule Samen.Scopes.Finance.PrepaidRegister do
  @moduledoc """
  The derived prepaid register (WS-ACCT prepaid expense slice): every schedule,
  its contract, the releases that actually posted, and the remaining prepaid
  balance that follows from the two.

  Nothing here is stored except the `PrepaidSchedule` row and its
  `PrepaidRelease` facts. The schedule is re-derived
  (`PrepaidSchedule.slices/1`), released is Σ the releases, and remaining is
  `total − released`. There is no stored balance to drift.

  Per schedule the read answers:

    * `schedule` — every month of the term, with `released?` and the release id;
    * `released_cents` — Σ posted releases;
    * `remaining_cents` — total − released;
    * `next_open_period` — the first unreleased month, or nil when complete;
    * `fully_released?` — released has reached the contract total;
    * the account pair every release uses, and the optional cost-object
      dimension.

  `for_org/2` takes the host's `:schedule` and `:release` resources so the same
  read serves the kernel fixture, the web mount and the host.
  """

  require Ash.Query

  alias Samen.Scopes.Finance.PrepaidSchedule

  @doc """
  The register for one org.

  Opts (required): `:schedule`, `:release`.

  Returns `%{org_id:, schedules: [...], totals: %{...}}`; a bare org yields
  empty lists and zero totals, not an error.
  """
  def for_org(org_id, opts) do
    schedule_mod = Keyword.fetch!(opts, :schedule)
    release_mod = Keyword.fetch!(opts, :release)

    schedules =
      schedule_mod
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.Query.sort(code: :asc)
      |> Ash.read!(authorize?: false)

    releases =
      release_mod
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.read!(authorize?: false)

    by_schedule = Enum.group_by(releases, & &1.schedule_id)

    rows =
      Enum.map(schedules, fn schedule ->
        row(schedule, Map.get(by_schedule, schedule.id, []))
      end)

    %{
      org_id: org_id,
      schedules: rows,
      totals: totals(rows, length(releases))
    }
  end

  defp row(schedule, releases) do
    slices = PrepaidSchedule.slices(schedule)
    by_key = Map.new(releases, &{&1.period_key, &1})
    released = Enum.reduce(releases, 0, &(&1.amount_cents + &2))
    remaining = max(schedule.total_cents - released, 0)

    months =
      Enum.map(slices, fn slice ->
        release = Map.get(by_key, slice.period_key)

        slice
        |> Map.put(:released?, not is_nil(release))
        |> Map.put(:release_id, release && release.id)
      end)

    next_open = Enum.find(months, fn slice -> not slice.released? end)

    %{
      prepaid_schedule: schedule,
      code: schedule.code,
      name: schedule.name,
      total_cents: schedule.total_cents,
      start_on: schedule.start_on,
      months: schedule.months,
      prepaid_account_id: schedule.prepaid_account_id,
      expense_account_id: schedule.expense_account_id,
      cost_object_id: schedule.cost_object_id,
      dimension_key: schedule.dimension_key,
      released_cents: released,
      remaining_cents: remaining,
      fully_released?: remaining == 0,
      next_open_period: next_open && next_open.period_key,
      released_months: map_size(by_key),
      schedule: months
    }
  end

  defp totals(rows, release_count) do
    %{
      schedules: length(rows),
      releases: release_count,
      total_cents: Enum.sum(Enum.map(rows, & &1.total_cents)),
      released_cents: Enum.sum(Enum.map(rows, & &1.released_cents)),
      remaining_cents: Enum.sum(Enum.map(rows, & &1.remaining_cents))
    }
  end
end
