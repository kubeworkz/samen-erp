defmodule Samen.FinanceStatementsTest do
  @moduledoc """
  The period statements added over the WS-ACCT ledger: the equity roll-forward,
  the cost-object segment P&L, and the indirect cash-flow classification.

  The fixtures are real posted entries, and every total is compared with the
  existing `BalanceSheet`/`ProfitLoss` reads where the statements claim to tie.
  """

  use ExUnit.Case, async: false

  alias Samen.Scopes.Finance.{
    BalanceSheet,
    CashFlow,
    EquityStatement,
    ProfitLoss,
    SegmentReport
  }

  alias SamenCore.Support.FinanceFixture.{
    Account,
    CostObject,
    JournalEntry,
    JournalLine,
    PostingAccount
  }

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)

    org = Ash.UUID.generate()
    admin = admin_scope(org)
    project_a = cost_object!(admin, org, "PROJECT-A", :project)
    project_b = cost_object!(admin, org, "PROJECT-B", :project)

    accounts = %{
      cash: account!(admin, org, "1000", :asset, :debit),
      ar: account!(admin, org, "1100", :asset, :debit),
      inventory: account!(admin, org, "1400", :asset, :debit),
      equipment: account!(admin, org, "1500", :asset, :debit),
      accumulated: account!(admin, org, "1510", :asset, :credit),
      ap: account!(admin, org, "2000", :liability, :credit),
      equity: account!(admin, org, "3000", :equity, :credit),
      revenue: account!(admin, org, "4000", :income, :credit),
      cogs: account!(admin, org, "5000", :expense, :debit),
      depreciation: account!(admin, org, "6030", :expense, :debit),
      disposal_gain: account!(admin, org, "7920", :income, :credit)
    }

    posting_keys!(admin, org, accounts)

    # Opening balances: owner capital and a prior-period receivable.
    post!(admin, org, ~D[2026-01-02], "Owner contribution", [
      %{account_id: accounts.cash.id, debit_cents: 1_000_000, credit_cents: 0},
      %{account_id: accounts.equity.id, debit_cents: 0, credit_cents: 1_000_000}
    ])

    post!(admin, org, ~D[2026-01-20], "Prior-period credit sale", [
      %{account_id: accounts.ar.id, debit_cents: 500_000, credit_cents: 0},
      %{account_id: accounts.revenue.id, debit_cents: 0, credit_cents: 500_000}
    ])

    dims_a = %{"project" => project_a.id}
    dims_b = %{"project" => project_b.id}

    # Current-period operating activity.
    post_dims!(admin, org, ~D[2026-02-02], "Cash sale", dims_a, [
      %{account_id: accounts.cash.id, debit_cents: 300_000, credit_cents: 0},
      %{account_id: accounts.revenue.id, debit_cents: 0, credit_cents: 300_000}
    ])

    post_dims!(admin, org, ~D[2026-02-03], "Credit sale", dims_a, [
      %{account_id: accounts.ar.id, debit_cents: 200_000, credit_cents: 0},
      %{account_id: accounts.revenue.id, debit_cents: 0, credit_cents: 200_000}
    ])

    post_dims!(admin, org, ~D[2026-02-04], "Collection", dims_a, [
      %{account_id: accounts.cash.id, debit_cents: 150_000, credit_cents: 0},
      %{account_id: accounts.ar.id, debit_cents: 0, credit_cents: 150_000}
    ])

    post!(admin, org, ~D[2026-02-05], "Inventory purchase", [
      %{account_id: accounts.inventory.id, debit_cents: 100_000, credit_cents: 0},
      %{account_id: accounts.cash.id, debit_cents: 0, credit_cents: 100_000}
    ])

    post_dims!(admin, org, ~D[2026-02-06], "Cost of goods sold", dims_b, [
      %{account_id: accounts.cogs.id, debit_cents: 80_000, credit_cents: 0},
      %{account_id: accounts.inventory.id, debit_cents: 0, credit_cents: 80_000}
    ])

    post!(admin, org, ~D[2026-02-07], "Unallocated AP bill", [
      %{account_id: accounts.cogs.id, debit_cents: 50_000, credit_cents: 0},
      %{account_id: accounts.ap.id, debit_cents: 0, credit_cents: 50_000}
    ])

    post!(admin, org, ~D[2026-02-08], "AP payment", [
      %{account_id: accounts.ap.id, debit_cents: 30_000, credit_cents: 0},
      %{account_id: accounts.cash.id, debit_cents: 0, credit_cents: 30_000}
    ])

    # Investing and financing activity.
    post_dims!(admin, org, ~D[2026-02-09], "Equipment purchase", dims_b, [
      %{account_id: accounts.equipment.id, debit_cents: 400_000, credit_cents: 0},
      %{account_id: accounts.cash.id, debit_cents: 0, credit_cents: 400_000}
    ])

    post_dims!(admin, org, ~D[2026-02-10], "Depreciation", dims_b, [
      %{account_id: accounts.depreciation.id, debit_cents: 20_000, credit_cents: 0},
      %{account_id: accounts.accumulated.id, debit_cents: 0, credit_cents: 20_000}
    ])

    post_dims!(admin, org, ~D[2026-02-11], "Equipment disposal", dims_b, [
      %{account_id: accounts.cash.id, debit_cents: 50_000, credit_cents: 0},
      %{account_id: accounts.accumulated.id, debit_cents: 10_000, credit_cents: 0},
      %{account_id: accounts.equipment.id, debit_cents: 0, credit_cents: 55_000},
      %{account_id: accounts.disposal_gain.id, debit_cents: 0, credit_cents: 5_000}
    ])

    post!(admin, org, ~D[2026-02-12], "Owner distribution", [
      %{account_id: accounts.equity.id, debit_cents: 25_000, credit_cents: 0},
      %{account_id: accounts.cash.id, debit_cents: 0, credit_cents: 25_000}
    ])

    %{
      org: org,
      admin: admin,
      accounts: accounts,
      project_a: project_a,
      project_b: project_b,
      from_date: datetime(~D[2026-02-01]),
      to_date: datetime(~D[2026-02-28])
    }
  end

  test "the equity statement rolls opening equity to closing equity", ctx do
    assert {:ok, statement} =
             EquityStatement.generate(ctx.org, ctx.from_date, ctx.to_date, statement_opts())

    assert statement.opening_total_cents == 1_500_000
    assert statement.net_income_cents == 355_000
    assert statement.other_changes_cents == -25_000
    assert statement.closing_total_cents == 1_830_000
    assert statement.articulated?

    [equity] = Enum.filter(statement.rows, &(&1.code == "3000"))
    assert equity.opening_cents == 1_000_000
    assert equity.debit_cents == 25_000
    assert equity.credit_cents == 0
    assert equity.change_cents == -25_000
    assert equity.closing_cents == 975_000

    assert statement.unclosed_earnings.opening_cents == 500_000
    assert statement.unclosed_earnings.net_income_cents == 355_000
    assert statement.unclosed_earnings.closing_cents == 855_000

    assert {:ok, balance_sheet} =
             BalanceSheet.generate(ctx.org, ctx.to_date, balance_opts())

    assert statement.closing_total_cents == balance_sheet.total_equity
  end

  test "the segment report ties every period P&L line to a cost object or unallocated", ctx do
    assert {:ok, report} =
             SegmentReport.report(
               ctx.org,
               ctx.from_date,
               ctx.to_date,
               statement_opts() ++
                 [
                   dimension_key: "project",
                   cost_object: CostObject,
                   scope: ctx.admin
                 ]
             )

    assert report.dimension_key == "project"
    assert report.totals.revenue_cents == 505_000
    assert report.totals.expense_cents == 150_000
    assert report.totals.net_cents == 355_000

    by_code = Map.new(report.allocated, &{&1.code, &1})
    assert by_code["PROJECT-A"].revenue_cents == 500_000
    assert by_code["PROJECT-A"].expense_cents == 0
    assert by_code["PROJECT-A"].net_cents == 500_000

    assert by_code["PROJECT-B"].revenue_cents == 5_000
    assert by_code["PROJECT-B"].expense_cents == 100_000
    assert by_code["PROJECT-B"].net_cents == -95_000

    assert report.unallocated.revenue_cents == 0
    assert report.unallocated.expense_cents == 50_000
    assert report.unallocated.net_cents == -50_000

    assert {:ok, profit_loss} =
             ProfitLoss.generate(ctx.org, ctx.from_date, ctx.to_date, profit_loss_opts())

    assert report.totals.revenue_cents == profit_loss.total_revenue
    assert report.totals.expense_cents == profit_loss.total_expenses
    assert report.totals.net_cents == profit_loss.net_income

    assert {:error, {:unknown_dimension, "customer"}} =
             SegmentReport.report(
               ctx.org,
               ctx.from_date,
               ctx.to_date,
               statement_opts() ++ [dimension_key: "customer"]
             )
  end

  test "the indirect cash flow reconciles operating, investing and financing", ctx do
    assert {:ok, cash_flow} =
             CashFlow.statement(ctx.org, ctx.from_date, ctx.to_date,
               repo: @repo,
               posting_account: PostingAccount,
               line: JournalLine,
               entry: JournalEntry
             )

    assert cash_flow.method == :indirect
    assert cash_flow.mapped?
    assert cash_flow.reconciled?
    assert cash_flow.sections_reconciled?
    assert cash_flow.opening_cents == 1_000_000
    assert cash_flow.inflows_cents == 500_000
    assert cash_flow.outflows_cents == 555_000
    assert cash_flow.net_cents == -55_000
    assert cash_flow.closing_cents == 945_000

    assert cash_flow.operating.net_income_cents == 355_000
    assert cash_flow.operating.net_cents == 320_000
    assert cash_flow.operating.cash_cents == 320_000
    assert cash_flow.operating.reconciled?
    assert cash_flow.investing.net_cents == -350_000
    assert cash_flow.financing.net_cents == -25_000

    adjustments = Map.new(cash_flow.operating.adjustments, &{&1.code, &1})
    assert adjustments["7920"].amount_cents == -5_000
    assert adjustments["7920"].category == :reclassification
    assert adjustments["1510"].amount_cents == 20_000
    assert adjustments["1510"].category == :non_cash

    working_capital = Map.new(cash_flow.operating.working_capital, &{&1.code, &1})
    assert working_capital["1100"].amount_cents == -50_000
    assert working_capital["1400"].amount_cents == -20_000
    assert working_capital["2000"].amount_cents == 20_000

    assert Enum.any?(cash_flow.investing.rows, &(&1.code == "1500"))
    assert Enum.any?(cash_flow.financing.rows, &(&1.code == "3000"))
  end

  defp statement_opts do
    [
      repo: @repo,
      account_resource: Account,
      line_resource: JournalLine,
      entry_resource: JournalEntry
    ]
  end

  defp balance_opts do
    [
      repo: @repo,
      account_resource: Account,
      line_resource: JournalLine,
      entry_resource: JournalEntry
    ]
  end

  defp profit_loss_opts, do: statement_opts()

  defp admin_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :admin, kind: :tenant, plane: :tenant}
    }
  end

  defp account!(admin, org, code, kind, side) do
    Account
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, code: code, name: "Account #{code}", kind: kind, normal_side: side},
      scope: admin
    )
    |> Ash.create!()
  end

  defp cost_object!(admin, org, code, kind) do
    CostObject
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, code: code, name: "Cost object #{code}", kind: kind},
      scope: admin
    )
    |> Ash.create!()
  end

  defp posting_keys!(admin, org, accounts) do
    for {key, account} <- [
          cash: accounts.cash,
          ar_clearing: accounts.ar,
          ap_clearing: accounts.ap,
          asset_cost_equipment: accounts.equipment,
          accumulated_depreciation: accounts.accumulated,
          depreciation_expense: accounts.depreciation,
          disposal_gain_loss: accounts.disposal_gain
        ] do
      PostingAccount
      |> Ash.Changeset.for_create(:create, %{org_id: org, key: key, account_id: account.id},
        scope: admin
      )
      |> Ash.create!()
    end
  end

  defp post_dims!(admin, org, date, memo, dims, lines) do
    lines = Enum.map(lines, &Map.put(&1, :dimension_refs, dims))
    post!(admin, org, date, memo, lines)
  end

  defp post!(admin, org, date, memo, lines) do
    entry =
      JournalEntry
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org, entry_date: date, memo: memo, lines: lines},
        scope: admin
      )
      |> Ash.create!()
      |> Ash.Changeset.for_update(:post, %{}, scope: admin)
      |> Ash.update!()

    stamp_posted_at!(entry, date)
    entry
  end

  # The report axis is the entry's POSTED_AT, not its document date. Pin it so
  # the prior-period opening and current-period legs are deterministic; the
  # PostGuard marker is the sanctioned raw-update route for a posted fact.
  defp stamp_posted_at!(entry, date) do
    posted_at = DateTime.new!(date, ~T[12:00:00], "Etc/UTC") |> DateTime.to_naive()
    @repo.query!("SELECT set_config('samen.finance_posting', 'on', true)", [])

    @repo.query!(
      "UPDATE sje_journal_entry SET sje_posted_at = $2 WHERE sje_id = $1",
      [Ecto.UUID.dump!(entry.id), posted_at]
    )

    @repo.query!("SELECT set_config('samen.finance_posting', 'off', true)", [])
  end

  defp datetime(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
end
