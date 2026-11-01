defmodule Samen.Scopes.Finance.ReconcileVariance do
  @moduledoc """
  **R8 — standard ↔ actual** (WS-ACCT Phase 7; ADR-054 D4): the independent read
  that proves every posted variance ties to its standard card, lands on the
  accounts its row names, and sums to the variance-account movement in the GL.

  The read never trusts the engine's arithmetic or the posting cascade's
  resolution: it re-reads the rows, the card, the entry and the GL lines, and
  reports what disagrees. Four checks per variance row:

    * **arithmetic** — `amount_cents == actual_amount_cents − standard_amount_cents`;
    * **card** — the row's `standard_id` is the card IN FORCE for its period
      (`StandardCard.in_force/4`), not merely a card that exists. A revised
      standard that retroactively repriced a period shows up here as
      `{:off_card, …}`;
    * **tie** — re-running `VarianceMath.amount/3` over the named card's lines
      and the row's recorded `inputs` reproduces the stored actual and standard
      amounts. A posting computed from a different card, or from inputs the
      card does not carry, is `{:untied, …}`;
    * **legs** — the anchored entry has exactly two lines: the row's variance
      account and its disposition account, with the direction the sign
      demands. The disposition account must be the org's mapping for the
      type's table entry, so a row that names one account and posts another —
      or names a disposition the type's row does not give it — is
      `{:misdisposed, …}`.

  Then, per variance account, it compares **Σ rows** with **Σ (credit − debit)**
  over those same entries' variance-account lines: the invariant's headline
  number. An anchored entry with no row is `{:orphaned_gl, …}`.

  ## Why the read exists separately from the engine

  A variance that the engine computed and the engine checked is one opinion.
  R8's green path is the ordinary run; its red path is a hand-inserted row,
  a repointed account and an orphaned entry, each of which must be DETECTED
  (the anti-tautology discipline). Without this read, "the variances are tied"
  would be a claim about the engine rather than about the ledger.
  """

  require Ash.Query

  @doc """
  The R8 report for `{org, "YYYY-MM"}`.

  Opts (required): `:variance`, `:standard`, `:standard_line`, `:entry`,
  `:line`, `:posting_account`.

  Returns `%{period_key:, ok?:, violations:, families:, variances:}`; a
  malformed period key is reported as `{:bad_period, key}` rather than raised.
  """
  def report(org_id, period_key, opts) do
    variance_mod = Keyword.fetch!(opts, :variance)
    standard_mod = Keyword.fetch!(opts, :standard)

    with {:ok, period_end} <- Samen.Scopes.Finance.StandardCard.period_end(period_key) do
      rows = read_rows(variance_mod, org_id, period_key)

      ctx = %{
        org_id: org_id,
        period_key: period_key,
        period_end: period_end,
        standard: standard_mod,
        standard_line: Keyword.fetch!(opts, :standard_line),
        entry: Keyword.fetch!(opts, :entry),
        line: Keyword.fetch!(opts, :line),
        posting_account: Keyword.fetch!(opts, :posting_account)
      }

      {violations, families, details} =
        Enum.reduce(rows, {[], %{}, []}, fn row, {violations, families, details} ->
          {row_violations, gl_cents} = check_row(row, ctx)

          families =
            Map.update(
              families,
              row.variance_account_id,
              %{rows_cents: row.amount_cents, gl_cents: gl_cents},
              fn family ->
                %{
                  rows_cents: family.rows_cents + row.amount_cents,
                  gl_cents: family.gl_cents + gl_cents
                }
              end
            )

          detail = %{
            id: row.id,
            type: row.type,
            amount_cents: row.amount_cents,
            disposition: row.disposition,
            variance_account_id: row.variance_account_id,
            disposition_account_id: row.disposition_account_id,
            entry_id: row.entry_id,
            ok?: row_violations == []
          }

          {violations ++ row_violations, families, [detail | details]}
        end)

      family_violations =
        families
        |> Enum.sort_by(fn {account_id, _} -> account_id end)
        |> Enum.flat_map(fn {account_id, family} ->
          if family.rows_cents == family.gl_cents do
            []
          else
            [{:variance_gl_mismatch, account_id, family.rows_cents, family.gl_cents}]
          end
        end)

      orphan_violations = check_orphans(rows, ctx)

      violations = violations ++ family_violations ++ orphan_violations

      %{
        period_key: period_key,
        ok?: violations == [],
        violations: violations,
        families:
          families
          |> Enum.sort_by(fn {account_id, _} -> account_id end)
          |> Enum.map(fn {account_id, family} ->
            Map.merge(family, %{
              variance_account_id: account_id,
              agrees?: family.rows_cents == family.gl_cents
            })
          end),
        variances: Enum.reverse(details)
      }
    else
      {:error, :bad_period} ->
        %{
          period_key: period_key,
          ok?: false,
          violations: [{:bad_period, period_key}],
          families: [],
          variances: []
        }
    end
  end

  # ── per-row checks ─────────────────────────────────────────────────────────

  defp check_row(row, ctx) do
    {violations, gl_cents} =
      cond do
        # A measured zero posts nothing by design: the row is the run's marker,
        # not a posting. Anything else with no entry is an unbacked claim.
        row.amount_cents == 0 and is_nil(row.entry_id) -> {[], 0}
        row.amount_cents == 0 -> {[{:zero_variance_posted, row.id}], 0}
        is_nil(row.entry_id) -> {[{:unbacked, row.id}], 0}
        true -> check_entry(row, row.entry_id, ctx)
      end

    violations =
      violations ++
        arithmetic_violations(row) ++
        card_violations(row, ctx) ++
        tie_violations(row, ctx)

    {violations, gl_cents}
  end

  defp arithmetic_violations(row) do
    if row.amount_cents == row.actual_amount_cents - row.standard_amount_cents do
      []
    else
      [
        {:arithmetic, row.id, row.amount_cents, row.actual_amount_cents,
         row.standard_amount_cents}
      ]
    end
  end

  defp card_violations(row, ctx) do
    case Samen.Scopes.Finance.StandardCard.in_force(
           ctx.standard,
           row.org_id,
           row.cost_object_id,
           ctx.period_end
         ) do
      {:ok, nil} ->
        [{:off_card, row.id, row.standard_id, nil}]

      {:ok, in_force} ->
        if in_force.id == row.standard_id do
          []
        else
          [{:off_card, row.id, row.standard_id, in_force.id}]
        end

      {:error, reason} ->
        [{:card_unreadable, row.id, reason}]
    end
  end

  defp tie_violations(row, ctx) do
    with {:ok, standard} <- read_one(ctx.standard, row.org_id, row.standard_id),
         false <- is_nil(standard),
         {:ok, lines} <- read_standard_lines(ctx.standard_line, row.org_id, row.standard_id) do
      case Samen.Scopes.Finance.VarianceMath.recompute(row.type, lines, row.inputs) do
        {:ok, {actual, standard_cents}} ->
          if actual == row.actual_amount_cents and standard_cents == row.standard_amount_cents do
            []
          else
            [
              {:untied, row.id, {row.actual_amount_cents, row.standard_amount_cents},
               {actual, standard_cents}}
            ]
          end

        {:error, reason} ->
          [{:untied, row.id, reason}]
      end
    else
      true -> [{:untied, row.id, :missing_standard}]
      {:error, reason} -> [{:untied, row.id, reason}]
    end
  end

  defp read_standard_lines(standard_line_mod, org_id, standard_id) do
    require Ash.Query

    {:ok,
     standard_line_mod
     |> Ash.Query.filter(org_id == ^org_id and standard_id == ^standard_id)
     |> Ash.read!(authorize?: false)}
  end

  defp check_entry(row, entry_id, ctx) do
    lines = read_entry_lines(ctx.line, row.org_id, entry_id)

    gl_cents =
      lines
      |> Enum.filter(&(&1.account_id == row.variance_account_id))
      |> Enum.reduce(0, fn line, acc -> acc + line.credit_cents - line.debit_cents end)

    violations =
      case posting_account(ctx.posting_account, row.org_id, type_meaning(row.type)) do
        {:ok, nil} ->
          [{:unmapped_disposition_account, row.id, type_meaning(row.type)}]

        {:ok, expected} ->
          disposition_violations(row, expected, lines)

        {:error, reason} ->
          [{:disposition_unreadable, row.id, reason}]
      end

    {violations, gl_cents}
  end

  defp type_meaning(type),
    do: Samen.Scopes.Finance.VarianceDisposition.account_meaning(type)

  defp disposition_violations(row, expected, lines) do
    expected_disposition = Samen.Scopes.Finance.VarianceDisposition.disposition(row.type)

    disposition_ok =
      row.disposition == expected_disposition and
        row.disposition_account_id == expected.account_id

    legs = expected_legs(row)

    legs_ok =
      length(lines) == 2 and
        MapSet.new(Enum.map(lines, &{&1.account_id, &1.debit_cents, &1.credit_cents})) ==
          MapSet.new(legs)

    violations =
      if disposition_ok,
        do: [],
        else: [
          {:misdisposed, row.id, expected_disposition, expected.account_id, row.disposition,
           row.disposition_account_id}
        ]

    if legs_ok do
      violations
    else
      [
        {:legs, row.id, legs, Enum.map(lines, &{&1.account_id, &1.debit_cents, &1.credit_cents})}
        | violations
      ]
    end
  end

  defp expected_legs(row) do
    amount = row.amount_cents

    if amount > 0 do
      [
        {row.variance_account_id, 0, amount},
        {row.disposition_account_id, amount, 0}
      ]
    else
      [
        {row.variance_account_id, -amount, 0},
        {row.disposition_account_id, 0, -amount}
      ]
    end
  end

  defp check_orphans(rows, ctx) do
    require Ash.Query

    claimed = MapSet.new(rows, & &1.entry_id)

    from_date = Date.new!(year(ctx.period_key), month(ctx.period_key), 1)

    ctx.entry
    |> Ash.Query.filter(
      org_id == ^ctx.org_id and source_key == "cost_variance" and
        entry_date >= ^from_date and entry_date <= ^ctx.period_end
    )
    |> Ash.read!(authorize?: false)
    |> Enum.reject(&MapSet.member?(claimed, &1.id))
    |> Enum.map(&{:orphaned_gl, &1.id})
  end

  ## ── small reads ───────────────────────────────────────────────────────────

  defp read_rows(variance_mod, org_id, period_key) do
    require Ash.Query

    variance_mod
    |> Ash.Query.filter(org_id == ^org_id and period_key == ^period_key)
    |> Ash.Query.ensure_selected([:org_id])
    |> Ash.Query.sort(inserted_at: :asc)
    |> Ash.read!(authorize?: false)
  end

  defp read_entry_lines(line_mod, org_id, entry_id) do
    require Ash.Query

    line_mod
    |> Ash.Query.filter(org_id == ^org_id and entry_id == ^entry_id)
    |> Ash.read!(authorize?: false)
  end

  defp posting_account(pa_mod, org_id, key) do
    require Ash.Query

    pa_mod
    |> Ash.Query.filter(org_id == ^org_id and key == ^key)
    |> Ash.read_one(authorize?: false)
  end

  defp read_one(mod, org_id, id) do
    require Ash.Query

    mod
    |> Ash.Query.filter(org_id == ^org_id and id == ^id)
    |> Ash.read_one(authorize?: false)
  end

  defp year(period_key), do: period_key |> String.split("-") |> Enum.at(0) |> String.to_integer()
  defp month(period_key), do: period_key |> String.split("-") |> Enum.at(1) |> String.to_integer()
end
