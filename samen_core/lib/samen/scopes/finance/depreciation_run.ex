defmodule Samen.Scopes.Finance.DepreciationRun do
  @moduledoc """
  The monthly depreciation RUN (WS-ACCT Phase 8; ADR-054 D9): for one fiscal
  month, post every due asset's slice — through the ordinary governed
  `:depreciate` action, which posts the expense/contra entry in the same
  transaction.

  ## What "due" means

  An asset's slice posts when the period is inside its term, the asset has not
  been disposed in or before that month, and no posting exists for
  `{asset, period}`. Anything else is reported and skipped:

    * `:under_construction` — a CIP asset has not been placed in service, so it
      has no schedule at all;
    * `:not_in_service` — the row has no schedule start (a malformed/legacy CIP);
    * `:not_yet_acquired` / `:not_yet_in_service` — the period precedes the
      acquisition or the in-service month;
    * `:fully_depreciated` — the life has run out (the schedule has no slice);
    * `:disposed` — the asset was retired in this month or an earlier one, so
      the schedule stopped (the months already posted remain);
    * `:already_posted` — the exactly-once read saw the period's fact.

  A skip is a verdict, not a failure. The run returns
  `{:ok, %{period: "YYYY-MM", posted: [ids], skipped: [{asset_id, reason}]}}`.

  ## Exactly once, in two layers

  * **The read (`already_posted?/3`)** makes a repeated sweep a clean no-op:
    the second run sees the period's row and skips it. This is what the cron
    relies on when a retry fires twice, and it is the contract the suite pins.
  * **The table's unique index on `{org, asset, period}`** is the belt. If the
    read is ever dropped by a regression, the database still refuses the
    duplicate row — the sweep then fails loudly (and retries into the
    dead-letter bucket) rather than double-depreciating a period.

  The split matters: the belt alone would make a retry a hard error; the read
  makes the normal case silent. Neither can produce two slices for one period,
  which is the exactly-once leg the phase's acceptance criterion names.

  ## What it refuses to do

  * It does not backfill missed months. A period that was never run stays
    unposted and is visible as the register's gap — an honest omission, not a
    silent catch-up dated into a month nobody reviewed (the P2 carry).
  * It does not amortize past the life or past a disposal.
  * A posting that cannot land (unmapped account, closed period) is REPORTED —
    the run returns `{:error, {:depreciation_failed, failures}}` so the worker
    retries and dead-letters, rather than counting a skipped asset as done.
    Each asset posts in its own transaction, so one misconfigured asset does
    not prevent the others' independent facts from landing; the failures are
    named and the run is not reported as a success.

  ## Disposal is an action, not a run side effect

  `AssetDisposal` posts the proceeds/accumulated/cost/gain-loss entry when a
  human disposes of the asset. The run only stops scheduling from the disposal
  month; it never invents proceeds or a catch-up write-off. Keeping the
  scheduled job to what the contract already determined is the same posture as
  the accrual reversal and the recognition run.

  ## The host seam

      config :samen_core, Samen.Scopes.Finance.DepreciationRun,
        modules: [
          asset: Samenerp.Erp.Asset,
          posting: Samenerp.Erp.AssetPosting,
          entry: Samenerp.Erp.JournalEntry,
          line: Samenerp.Erp.JournalLine,
          account: Samenerp.Erp.Account
        ]

  An unconfigured host is a NO-OP that names itself (`:not_configured`), not a
  silent success: there are no books to depreciate into.

  ## Testability

  `run/1` takes `period: {year, month}` so a suite states its own month instead
  of waiting for the calendar.
  """

  require Ash.Query

  alias Samen.Scopes.Finance.AssetSchedule

  @config_key __MODULE__

  @doc "The host's wired finance modules, or nil when the host has not wired them."
  def modules do
    case :samen_core |> Application.get_env(@config_key, []) |> Keyword.get(:modules) do
      nil -> nil
      modules -> Map.new(modules)
    end
  end

  @doc """
  Run the depreciation sweep for one month. Returns
  `{:ok, %{period: "YYYY-MM", posted: [ids], skipped: [{asset_id, reason}]}}`, or
  `{:error, {:depreciation_failed, [{asset_id, reason}]}}` naming every asset
  whose posting refused.
  """
  def run(opts \\ []) do
    period = Keyword.get_lazy(opts, :period, fn -> previous_month(Date.utc_today()) end)
    key = AssetSchedule.period_key(period)

    case modules() do
      nil ->
        {:ok, %{period: key, posted: [], skipped: [], state: :not_configured}}

      mods ->
        sweep(mods, period, key)
    end
  end

  @doc "The cron's default: the month before the wall clock."
  defdelegate previous_month(date), to: AssetSchedule

  defp sweep(mods, period, key) do
    assets =
      mods.asset
      |> Ash.Query.ensure_selected([:org_id])
      |> Ash.Query.sort(acquired_on: :asc, code: :asc)
      # authz-scope: system sweep — the run depreciates EVERY org's due slice,
      # and each row's own governed `:depreciate` action (OrgScope, PeriodGuard,
      # PostBalance on the asset's org) decides whether it may land. Pinning
      # this read to one org would leave every other tenant's month unposted.
      |> Ash.read!(authorize?: false)

    results =
      Enum.map(assets, fn asset ->
        case plan(asset, period, key) do
          {:post, amount} -> post(mods, asset, key, period, amount)
          {:skip, reason} -> {:skip, {asset.id, reason}}
          {:error, reason} -> {:error, {asset.id, reason}}
        end
      end)

    posted = for {:posted, id} <- results, do: id
    skipped = for {:skip, entry} <- results, do: entry
    failed = for {:error, failure} <- results, do: failure

    if failed == [] do
      {:ok, %{period: key, posted: posted, skipped: skipped}}
    else
      {:error, {:depreciation_failed, failed}}
    end
  end

  # ── the plan ───────────────────────────────────────────────────────────────

  defp plan(asset, period, key) do
    cond do
      asset.status == :under_construction ->
        {:skip, :under_construction}

      is_nil(AssetSchedule.start_on(asset)) ->
        {:skip, :not_in_service}

      not AssetSchedule.in_term?(asset, period) ->
        reason =
          cond do
            not AssetSchedule.before_start?(asset, period) -> :fully_depreciated
            not is_nil(asset.in_service_on) -> :not_yet_in_service
            true -> :not_yet_acquired
          end

        {:skip, reason}

      AssetSchedule.stopped?(asset, period) ->
        {:skip, :disposed}

      true ->
        {:post, AssetSchedule.slice_amount(asset, period)}
    end
  rescue
    # A malformed asset row (life <= 0) cannot be planned; report it rather
    # than crashing the whole sweep.
    _ -> {:error, {:unplannable, key}}
  end

  # ── posting ────────────────────────────────────────────────────────────────

  defp post(mods, asset, key, period, amount) do
    if already_posted?(mods.posting, asset, key) do
      {:skip, {asset.id, :already_posted}}
    else
      mods.posting
      |> Ash.Changeset.for_create(
        :depreciate,
        %{
          org_id: asset.org_id,
          asset_id: asset.id,
          period_key: key,
          amount_cents: amount,
          depreciated_on: AssetSchedule.period_end(period)
        },
        authorize?: false
      )
      |> Ash.create(authorize?: false)
      |> case do
        {:ok, posting} -> {:posted, posting.id}
        {:error, reason} -> {:error, {asset.id, reason}}
      end
    end
  end

  # Org-pinned and period-pinned: this is the no-op read that makes a repeated
  # sweep silent (the unique index behind it is the belt).
  defp already_posted?(posting_mod, asset, key) do
    posting_mod
    |> Ash.Query.filter(org_id == ^asset.org_id and asset_id == ^asset.id and period_key == ^key)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> false
      {:ok, _row} -> true
      {:error, _reason} -> false
    end
  end
end
