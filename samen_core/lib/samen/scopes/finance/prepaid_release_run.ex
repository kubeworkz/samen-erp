defmodule Samen.Scopes.Finance.PrepaidReleaseRun do
  @moduledoc """
  The prepaid release RUN (WS-ACCT prepaid expense slice): for one fiscal month,
  post every active prepaid schedule's derived slice through the ordinary
  governed `:release` action.

  ## Exactly once

    * the run's `already_released?/3` read makes a repeated sweep a clean no-op;
    * the release table's unique index on `{org, schedule, period}` is the belt
      for a racing or regressed caller.

  A period outside the term posts nothing. The run never backfills a missed
  month: a skipped period stays visible as `remaining` in `PrepaidRegister`.

  ## Host seam

      config :samen_core, Samen.Scopes.Finance.PrepaidReleaseRun,
        modules: [
          schedule: Samenerp.Erp.PrepaidSchedule,
          release: Samenerp.Erp.PrepaidRelease,
          entry: Samenerp.Erp.JournalEntry,
          account: Samenerp.Erp.Account
        ]

  An unconfigured host is a NO-OP that names itself (`:not_configured`), not a
  silent success.
  """

  require Ash.Query

  alias Samen.Scopes.Finance.PrepaidSchedule

  @config_key __MODULE__

  @doc "The host's wired prepaid modules, or nil when the host has not wired them."
  def modules do
    case :samen_core |> Application.get_env(@config_key, []) |> Keyword.get(:modules) do
      nil -> nil
      modules -> Map.new(modules)
    end
  end

  @doc """
  Run the prepaid sweep for one month. Returns
  `{:ok, %{period: "YYYY-MM", posted: [...], skipped: [{schedule_id, reason}]}}`,
  or `{:error, {:prepaid_release_failed, [...]}}` naming every schedule whose
  release refused.
  """
  def run(opts \\ []) do
    period =
      Keyword.get_lazy(opts, :period, fn -> PrepaidSchedule.previous_month(Date.utc_today()) end)

    key = PrepaidSchedule.period_key(period)

    case modules() do
      nil ->
        {:ok, %{period: key, posted: [], skipped: [], state: :not_configured}}

      mods ->
        sweep(mods, period, key)
    end
  end

  defp sweep(mods, period, key) do
    schedules =
      mods.schedule
      |> Ash.Query.ensure_selected([:org_id])
      |> Ash.Query.load(:released_cents)
      |> Ash.Query.sort(start_on: :asc)
      # authz-scope: system sweep — every org's due slice is considered, and
      # each release's own governed action decides whether it may land.
      |> Ash.read!(authorize?: false)

    results =
      Enum.map(schedules, fn schedule ->
        case plan(schedule, period, key, mods) do
          {:post, amount} -> post(mods, schedule, key, period, amount)
          {:skip, reason} -> {:skip, {schedule.id, reason}}
        end
      end)

    posted = for {:posted, id} <- results, do: id
    skipped = for {:skip, entry} <- results, do: entry
    failed = for {:error, failure} <- results, do: failure

    if failed == [] do
      {:ok, %{period: key, posted: posted, skipped: skipped}}
    else
      {:error, {:prepaid_release_failed, failed}}
    end
  end

  defp plan(schedule, period, key, mods) do
    released = schedule.released_cents || 0
    remaining = schedule.total_cents - released

    cond do
      remaining <= 0 ->
        {:skip, :fully_released}

      not PrepaidSchedule.in_term?(schedule, period) ->
        {:skip, :outside_term}

      true ->
        amount = min(PrepaidSchedule.slice_amount(schedule, period), remaining)

        cond do
          amount <= 0 ->
            {:skip, :nothing_due}

          already_released?(mods.release, schedule, key) ->
            {:skip, :already_released}

          true ->
            {:post, amount}
        end
    end
  end

  defp post(mods, schedule, key, period, amount) do
    mods.release
    |> Ash.Changeset.for_create(
      :release,
      %{
        org_id: schedule.org_id,
        schedule_id: schedule.id,
        period_key: key,
        amount_cents: amount,
        released_on: PrepaidSchedule.period_end(period)
      },
      authorize?: false
    )
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, release} -> {:posted, release.id}
      {:error, reason} -> {:error, {schedule.id, reason}}
    end
  end

  defp already_released?(release_mod, schedule, key) do
    release_mod
    |> Ash.Query.filter(
      org_id == ^schedule.org_id and schedule_id == ^schedule.id and period_key == ^key
    )
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> false
      {:ok, _row} -> true
      {:error, _reason} -> false
    end
  end
end
