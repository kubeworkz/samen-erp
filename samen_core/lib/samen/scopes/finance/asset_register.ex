defmodule Samen.Scopes.Finance.AssetRegister do
  @moduledoc """
  The derived asset-register read (WS-ACCT Phase 8; ADR-054 D9): every asset,
  its contractual schedule, what has actually posted, and the net book value
  that follows from the two.

  Nothing here is stored except the `Asset` row and its `AssetPosting` facts.
  The schedule is re-derived (`AssetSchedule.slices/1`), accumulated is Σ the
  postings, and net book value is `cost − accumulated`. That is the whole
  register — there is no second balance to drift, and a reviewer can rebuild
  every number from the contract plus the posted slices.

  ## What the rows answer

  Per asset:

    * `schedule` — every month of the term, with `posted?` and `stopped?`
      (a disposal stops the future months without deleting the past ones);
    * `accumulated_cents` — Σ posted slices (the contra account's movement);
    * `nbv_cents` — cost − accumulated;
    * `remaining_cents` — amortizable − accumulated, never negative on a
      healthy register;
    * `fully_amortized?` — accumulated has reached cost − salvage;
    * `last_posted_period` / `next_open_period` — where the schedule stands.

  `for_org/2` takes the host's `:asset` and `:posting` resources so the same
  read serves the kernel fixture, the web mount and the host.
  """

  require Ash.Query

  alias Samen.Scopes.Finance.AssetSchedule

  @doc """
  The register for one org.

  Opts (required): `:asset`, `:posting`.

  Returns `%{org_id:, assets: [...], totals: %{...}}`; a bare org yields empty
  lists and zero totals, not an error.
  """
  def for_org(org_id, opts) do
    asset_mod = Keyword.fetch!(opts, :asset)
    posting_mod = Keyword.fetch!(opts, :posting)

    assets =
      asset_mod
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.Query.sort(code: :asc)
      |> Ash.read!(authorize?: false)

    postings =
      posting_mod
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.read!(authorize?: false)

    by_asset = Enum.group_by(postings, & &1.asset_id)

    rows =
      Enum.map(assets, fn asset ->
        row(asset, Map.get(by_asset, asset.id, []))
      end)

    %{
      org_id: org_id,
      assets: rows,
      totals: totals(rows, length(postings))
    }
  end

  defp row(asset, postings) do
    schedule = AssetSchedule.slices(asset)
    posted_by_key = Map.new(postings, &{&1.period_key, &1})

    months =
      Enum.map(schedule, fn slice ->
        posted = Map.get(posted_by_key, slice.period_key)

        slice
        |> Map.put(:posted?, not is_nil(posted))
        |> Map.put(:posting_id, posted && posted.id)
        |> Map.put(:stopped?, AssetSchedule.stopped?(asset, slice.period))
      end)

    accumulated = Enum.reduce(postings, 0, &(&1.amount_cents + &2))
    amortizable = AssetSchedule.amortizable(asset)

    posted_keys = MapSet.new(postings, & &1.period_key)

    next_open =
      months
      |> Enum.find(fn month -> not MapSet.member?(posted_keys, month.period_key) end)

    %{
      asset: asset,
      code: asset.code,
      name: asset.name,
      kind: asset.kind,
      status: asset.status,
      disposed_on: asset.disposed_on,
      cost_cents: asset.cost_cents,
      salvage_cents: asset.salvage_cents,
      amortizable_cents: amortizable,
      accumulated_cents: accumulated,
      remaining_cents: amortizable - accumulated,
      nbv_cents: asset.cost_cents - accumulated,
      fully_amortized?: accumulated >= amortizable,
      monthly_cents: first_slice(schedule),
      posted_months: map_size(posted_by_key),
      last_posted_period: last_key(schedule, posted_keys),
      next_open_period: next_open && next_open.period_key,
      schedule: months
    }
  end

  defp first_slice([slice | _]), do: slice.amount_cents
  defp first_slice([]), do: 0

  defp last_key(schedule, posted_keys) do
    schedule
    |> Enum.filter(&MapSet.member?(posted_keys, &1.period_key))
    |> List.last()
    |> case do
      nil -> nil
      slice -> slice.period_key
    end
  end

  defp totals(rows, posting_count) do
    %{
      assets: length(rows),
      postings: posting_count,
      cost_cents: Enum.sum(Enum.map(rows, & &1.cost_cents)),
      salvage_cents: Enum.sum(Enum.map(rows, & &1.salvage_cents)),
      amortizable_cents: Enum.sum(Enum.map(rows, & &1.amortizable_cents)),
      accumulated_cents: Enum.sum(Enum.map(rows, & &1.accumulated_cents)),
      nbv_cents: Enum.sum(Enum.map(rows, & &1.nbv_cents))
    }
  end
end
