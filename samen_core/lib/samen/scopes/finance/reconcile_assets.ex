defmodule Samen.Scopes.Finance.ReconcileAssets do
  @moduledoc """
  The independent asset-register audit (WS-ACCT Phase 8; ADR-054 D9): proves
  every posted slice is the schedule's slice, landed on the accounts the
  posting names, and accumulated to the contra account the register reports.

  The read never trusts the run or the cascade. It re-reads the asset contract,
  re-derives the period's slice, follows the ADR-041 anchor to the entry, and
  compares the entry's persisted lines with the two accounts the posting row
  says it paid. Six checks:

    * **amount** — `amount_cents` is `AssetSchedule`'s slice for that period.
      A hand-inserted row carrying a different number is `{:amount, …}`;
    * **term** — the period is inside the asset's life (`{:outside_term, …}`);
    * **disposal** — no slice landed in or after the disposal month
      (`{:after_disposal, …}`);
    * **backing** — the anchored entry exists and is posted
      (`{:unbacked, …}`), is dated the period's last day and carries the
      `asset_posting` anchor (`{:misdated, …}` / `{:misanchored, …}`);
    * **legs** — exactly two lines: debit the posting's `expense_account_id`,
      credit its `contra_account_id`, both for `amount_cents` (`{:legs, …}`);
    * **cap** — Σ posted per asset never exceeds cost − salvage
      (`{:over_amortized, …}`).

  Then org-wide: Σ the register's slices equals Σ (credit − debit) on the
  contra accounts over the anchored entries — the AC's "amortization
  accumulates to the contra account" — and an anchored entry with no posting
  row is `{:orphaned_gl, …}`. A clean register passes; each red path above is
  reachable from hand-crafted rows, which is what keeps the green path from
  being a tautology.
  """

  require Ash.Query

  alias Samen.Scopes.Finance.AssetSchedule

  @source_key "asset_posting"

  @doc """
  The audit for one org.

  Opts (required): `:asset`, `:posting`, `:entry`, `:line`.

  Returns `%{org_id:, ok?:, violations:, assets:, contra:}`; `assets` carries a
  per-asset summary and `contra` the two org-wide numbers.
  """
  def report(org_id, opts) do
    asset_mod = Keyword.fetch!(opts, :asset)
    posting_mod = Keyword.fetch!(opts, :posting)
    entry_mod = Keyword.fetch!(opts, :entry)
    line_mod = Keyword.fetch!(opts, :line)

    assets =
      asset_mod
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.Query.sort(code: :asc)
      |> Ash.read!(authorize?: false)

    postings =
      posting_mod
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.read!(authorize?: false)

    entries =
      entry_mod
      |> Ash.Query.filter(org_id == ^org_id and source_key == @source_key)
      |> Ash.read!(authorize?: false)

    entry_by_source = Map.new(entries, &{&1.source_id, &1})
    entry_ids = Enum.map(entries, & &1.id)
    lines_by_entry = lines_by_entry(line_mod, org_id, entry_ids)

    by_asset = Enum.group_by(postings, & &1.asset_id)
    assets_by_id = Map.new(assets, &{&1.id, &1})

    checks =
      Enum.flat_map(postings, fn posting ->
        check_posting(posting, assets_by_id, entry_by_source, lines_by_entry)
      end)

    cap_checks =
      Enum.flat_map(assets, fn asset ->
        posted = Map.get(by_asset, asset.id, [])
        accumulated = Enum.reduce(posted, 0, &(&1.amount_cents + &2))
        amortizable = AssetSchedule.amortizable(asset)

        if accumulated > amortizable do
          [{:over_amortized, asset.id, accumulated, amortizable}]
        else
          []
        end
      end)

    claimed = MapSet.new(postings, & &1.id)

    orphan_checks =
      entries
      |> Enum.reject(&MapSet.member?(claimed, &1.source_id))
      |> Enum.map(&{:orphaned_gl, &1.id})

    contra = contra_check(postings, entry_by_source, lines_by_entry)

    violations =
      checks ++
        cap_checks ++ orphan_checks ++ if(contra.agrees?, do: [], else: [contra.violation])

    asset_rows =
      Enum.map(assets, fn asset ->
        posted = Map.get(by_asset, asset.id, [])
        accumulated = Enum.reduce(posted, 0, &(&1.amount_cents + &2))
        amortizable = AssetSchedule.amortizable(asset)

        %{
          asset_id: asset.id,
          code: asset.code,
          kind: asset.kind,
          status: asset.status,
          accumulated_cents: accumulated,
          amortizable_cents: amortizable,
          nbv_cents: asset.cost_cents - accumulated,
          fully_amortized?: accumulated >= amortizable,
          ok?: not Enum.any?(violations, &names_asset?(&1, asset.id))
        }
      end)

    %{
      org_id: org_id,
      ok?: violations == [],
      violations: violations,
      assets: asset_rows,
      contra: Map.take(contra, [:posted_cents, :gl_cents, :agrees?])
    }
  end

  # ── per-posting checks ─────────────────────────────────────────────────────

  defp check_posting(posting, assets_by_id, entry_by_source, lines_by_entry) do
    case Map.get(assets_by_id, posting.asset_id) do
      nil ->
        [{:unknown_asset, posting.id, posting.asset_id}]

      asset ->
        schedule_checks(posting, asset) ++
          entry_checks(posting, entry_by_source[posting.id], lines_by_entry)
    end
  end

  defp schedule_checks(posting, asset) do
    violations =
      case AssetSchedule.slice(asset, posting.period_key) do
        {:ok, expected} when expected != posting.amount_cents ->
          [{:amount, posting.id, expected, posting.amount_cents}]

        {:ok, _expected} ->
          []

        :outside_term ->
          [{:outside_term, posting.id, posting.period_key}]

        {:error, :bad_period} ->
          [{:bad_period, posting.id, posting.period_key}]
      end

    violations =
      case AssetSchedule.parse_period(posting.period_key) do
        {:ok, period} ->
          if AssetSchedule.stopped?(asset, period) do
            [{:after_disposal, posting.id, posting.period_key, asset.disposed_on} | violations]
          else
            violations
          end

        :error ->
          violations
      end

    violations
  end

  defp entry_checks(posting, nil, _lines_by_entry) do
    [{:unbacked, posting.id}]
  end

  defp entry_checks(posting, entry, lines_by_entry) do
    violations =
      []
      |> check(entry.status != :posted, {:unanchored, posting.id, entry.status})
      |> check(
        entry.source_key != @source_key,
        {:misanchored, posting.id, entry.source_key}
      )
      |> check(
        not period_end?(posting.period_key, entry.entry_date),
        {:misdated, posting.id, posting.period_key, entry.entry_date}
      )

    lines = Map.get(lines_by_entry, entry.id, [])
    expected = expected_legs(posting)

    actual =
      lines
      |> Enum.map(&{&1.account_id, &1.debit_cents, &1.credit_cents})
      |> Enum.sort()

    if actual == Enum.sort(expected) do
      violations
    else
      [{:legs, posting.id, expected, actual} | violations]
    end
  end

  defp expected_legs(posting) do
    [
      {posting.expense_account_id, posting.amount_cents, 0},
      {posting.contra_account_id, 0, posting.amount_cents}
    ]
  end

  defp period_end?(period_key, date) do
    case AssetSchedule.parse_period(period_key) do
      {:ok, period} -> Date.compare(AssetSchedule.period_end(period), date) == :eq
      :error -> false
    end
  end

  # ── the org-wide contra check ──────────────────────────────────────────────

  defp contra_check(postings, entry_by_source, lines_by_entry) do
    contra_accounts = MapSet.new(postings, & &1.contra_account_id)

    gl_cents =
      postings
      |> Enum.flat_map(fn posting ->
        entry = Map.get(entry_by_source, posting.id)

        if entry do
          Map.get(lines_by_entry, entry.id, [])
          |> Enum.filter(&MapSet.member?(contra_accounts, &1.account_id))
          |> Enum.map(&(&1.credit_cents - &1.debit_cents))
        else
          []
        end
      end)
      |> Enum.sum()

    posted_cents = Enum.reduce(postings, 0, &(&1.amount_cents + &2))

    %{
      posted_cents: posted_cents,
      gl_cents: gl_cents,
      agrees?: posted_cents == gl_cents,
      violation: {:contra_mismatch, posted_cents, gl_cents}
    }
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp lines_by_entry(_line_mod, _org_id, []), do: %{}

  defp lines_by_entry(line_mod, org_id, entry_ids) do
    line_mod
    |> Ash.Query.filter(org_id == ^org_id and entry_id in ^entry_ids)
    |> Ash.read!(authorize?: false)
    |> Enum.group_by(& &1.entry_id)
  end

  # Only the cap violation is tagged by asset id; posting-level violations are
  # listed by posting id in `violations`, where an operator resolves them. The
  # per-asset row is a summary, not a second opinion on them.
  defp names_asset?({:over_amortized, asset_id, _, _}, asset_id), do: true
  defp names_asset?(_violation, _asset_id), do: false

  defp check(violations, false, _violation), do: violations

  defp check(violations, true, violation), do: [violation | violations]
end
