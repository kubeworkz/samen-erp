defmodule Samen.Scopes.Finance.VarianceReport do
  @moduledoc """
  The period's variance report (WS-ACCT Phase 7; ADR-054 D4) — every one of the
  manual's seven classes, per cost object, with where each one was disposed.

  A pure read over the posted `CostVariance` rows: no posting, no recompute of
  the ledger. The numbers ARE the facts the period recorded, which is what
  makes this the report an accountant reads and R8 the audit that checks it.

  ## Labour is labelled, per the ADR's binding proviso

  Until the timesheet driver lands (ADR-054 §5, Phase 10), the labour
  rate/efficiency figures here rest on a **declared** actual — a ratio the
  caller supplies, not hours a timesheet proves. The report carries
  `labour_basis: :declared_pending_driver` so no surface can present one as a
  fact; Phase 10 flips it to `:timesheet` when the driver exists.
  """

  require Ash.Query

  @doc """
  The report for `{org, "YYYY-MM"}`.

  Opts (required): `:variance`.

  Returns `%{period_key:, rows:, totals:, labour_basis:}` where each row is
  `%{type, cost_object_id, actual_cents, standard_cents, variance_cents,
  favourability, disposition, variance_account_id, disposition_account_id,
  standard_id, entry_id}`.
  """
  def for_period(org_id, period_key, opts) do
    variance_mod = Keyword.fetch!(opts, :variance)

    rows = read_rows(variance_mod, org_id, period_key)

    details = Enum.map(rows, &detail/1)

    %{
      period_key: period_key,
      rows: details,
      totals: %{
        by_type: totals_by_type(details),
        net_cents: Enum.reduce(details, 0, &(&1.variance_cents + &2))
      },
      labour_basis: :declared_pending_driver
    }
  end

  defp detail(row) do
    %{
      type: row.type,
      cost_object_id: row.cost_object_id,
      standard_id: row.standard_id,
      actual_cents: row.actual_amount_cents,
      standard_cents: row.standard_amount_cents,
      variance_cents: row.amount_cents,
      favourability: if(row.amount_cents > 0, do: :unfavourable, else: :favourable),
      disposition: row.disposition,
      variance_account_id: row.variance_account_id,
      disposition_account_id: row.disposition_account_id,
      entry_id: row.entry_id
    }
  end

  defp totals_by_type(rows) do
    Enum.reduce(rows, %{}, fn row, acc ->
      Map.update(acc, row.type, row.variance_cents, &(&1 + row.variance_cents))
    end)
  end

  defp read_rows(variance_mod, org_id, period_key) do
    variance_mod
    |> Ash.Query.filter(org_id == ^org_id and period_key == ^period_key)
    |> Ash.Query.sort(type: :asc)
    |> Ash.read!(authorize?: false)
  end
end
