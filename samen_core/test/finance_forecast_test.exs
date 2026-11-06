defmodule Samen.FinanceForecastTest do
  @moduledoc """
  WS-ACCT Phase 14 (ADR-054 D11) — the rolling forecast, its append-only
  publication rule, scenario weights, runway and forecast accuracy.

  The ledger entries are real posted entries, so the runway/accuracy reads are
  compared against `CashFlow.statement/4` and `ProfitLoss.generate/4`, not
  against hand-figured expected numbers. Each refusal is paired with a positive
  control (the `Samen.RedPath` discipline).
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.{CashFlow, ForecastRead}

  alias SamenCore.Support.FinanceFixture.{
    Account,
    ForecastDriver,
    ForecastVersion,
    JournalEntry,
    JournalLine,
    PostingAccount
  }

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)

    org = Ash.UUID.generate()
    other = Ash.UUID.generate()
    admin = admin_scope(org)
    today = Date.utc_today()
    first = Date.beginning_of_month(today)
    last = Date.end_of_month(today)

    books = books!(admin, org)

    revenue_entry =
      post_entry!(admin, org, today, "Award receipt", [
        %{account_id: books.cash.id, debit_cents: 100_000, credit_cents: 0},
        %{account_id: books.income.id, debit_cents: 0, credit_cents: 100_000}
      ])

    expense_entry =
      post_entry!(admin, org, today, "Research spend", [
        %{account_id: books.expense.id, debit_cents: 40_000, credit_cents: 0},
        %{account_id: books.cash.id, debit_cents: 0, credit_cents: 40_000}
      ])

    %{
      org: org,
      other: other,
      admin: admin,
      today: today,
      first: first,
      last: last,
      books: books,
      revenue_entry: revenue_entry,
      expense_entry: expense_entry
    }
  end

  # ── guards and the append-only promise ────────────────────────────────────

  test "scenario weights must sum to 1.0", %{org: org, admin: admin, first: first, last: last} do
    attrs =
      version_attrs(org, first, last, %{
        scenario_weights: %{base: 0.6, upside: 0.3, downside: 0.2}
      })

    assert {:error, error} =
             ForecastVersion
             |> Ash.Changeset.for_create(:create, attrs, scope: admin)
             |> Ash.create()

    assert Exception.message(error) =~ "sum to 1.0"

    # CONTROL: the same shape with weights that add to one lands.
    version = version!(admin, org, first, last)
    assert version.scenario_weights == %{"base" => 0.5, "upside" => 0.3, "downside" => 0.2}
  end

  test "rolling appends a draft and leaves every published fact untouched", %{
    org: org,
    admin: admin,
    first: first,
    last: last
  } do
    published = version!(admin, org, first, last) |> publish!(admin)
    before = Ash.get!(ForecastVersion, published.id, authorize?: false)
    before_drivers = drivers(org, published.id)

    assert before.status == :published
    assert before.published_at != nil
    assert length(before_drivers) == 12

    rolled =
      ForecastVersion
      |> Ash.Changeset.for_create(:roll, %{org_id: org, source_version_id: published.id},
        scope: admin
      )
      |> Ash.create!()

    assert rolled.id != published.id
    assert rolled.version == 2
    assert rolled.status == :draft
    assert rolled.source_version_id == published.id
    assert rolled.name == published.name
    assert rolled.starts_on == published.starts_on
    assert rolled.ends_on == published.ends_on
    assert rolled.scenario_weights == published.scenario_weights
    assert length(drivers(org, rolled.id)) == length(before_drivers)

    after_roll = Ash.get!(ForecastVersion, published.id, authorize?: false)
    assert after_roll == before
    assert drivers(org, published.id) == before_drivers

    # The published version has no update path and cannot accept a new driver.
    refute Enum.any?(Ash.Resource.Info.actions(ForecastVersion), &(&1.name == :update))

    assert {:error, error} =
             ForecastDriver
             |> Ash.Changeset.for_create(
               :create,
               %{
                 org_id: org,
                 version_id: published.id,
                 driver: :eda_spend,
                 scenario: :base,
                 period_on: first,
                 amount_cents: 1
               },
               scope: admin
             )
             |> Ash.create()

    assert Exception.message(error) =~ "published"

    # CONTROL: a draft still accepts drivers (the guard is not vacuous).
    draft = rolled

    assert {:ok, _} =
             ForecastDriver
             |> Ash.Changeset.for_create(
               :create,
               %{
                 org_id: org,
                 version_id: draft.id,
                 driver: :headcount,
                 scenario: :base,
                 period_on: first,
                 amount_cents: 1
               },
               scope: admin
             )
             |> Ash.create()
  end

  # ── materialized reads ────────────────────────────────────────────────────

  test "the weighted P&L, cash flow and scenarios come from the driver rows", %{
    org: org,
    admin: admin,
    first: first,
    last: last
  } do
    version = version!(admin, org, first, last)

    pnl = ForecastRead.pnl(version, driver: ForecastDriver)

    assert pnl.weights == %{"base" => 0.5, "upside" => 0.3, "downside" => 0.2}
    assert pnl.totals.revenue_cents == 92_000
    assert pnl.totals.cogs_cents == 0
    assert pnl.totals.operating_expense_cents == 30_500
    assert pnl.totals.net_income_cents == 61_500
    assert pnl.totals.cash_in_cents == 10_000
    assert pnl.totals.cash_out_cents == 20_000
    assert pnl.totals.net_cash_cents == -10_000

    cash = ForecastRead.cash_flow(version, finance_opts(org))
    assert cash.mapped?
    assert cash.reconciled?
    assert cash.opening_cents == 0
    assert cash.closing_cents == -10_000
    assert cash.actual_cash_cents == 60_000
    assert cash.cash_account_ids == [books_cash(org)]

    scenarios = ForecastRead.scenarios(version, driver: ForecastDriver)
    assert Enum.map(scenarios.scenarios, & &1.scenario) == [:base, :upside, :downside]
    assert Enum.map(scenarios.scenarios, & &1.revenue_cents) == [90_000, 110_000, 70_000]
    assert scenarios.weighted.revenue_cents == 92_000
  end

  test "runway reconciles to the ledger's :cash accounts", %{
    org: org,
    admin: admin,
    first: first,
    last: last
  } do
    version = version!(admin, org, first, last)
    runway = ForecastRead.runway(version, finance_opts(org))

    actual =
      CashFlow.statement(
        org,
        start_datetime(first),
        end_datetime(last),
        repo: @repo,
        posting_account: PostingAccount,
        line: JournalLine,
        entry: JournalEntry
      )
      |> elem(1)

    assert actual.mapped?
    assert actual.closing_cents == 60_000
    assert runway.cash_account_ids == actual.cash_account_ids
    assert runway.cash_on_hand_cents == actual.closing_cents
    assert runway.avg_monthly_burn_cents == 10_000
    assert runway.runway_months == 6.0
    assert runway.status == :runway
    assert runway.reconciled?
  end

  test "variance-to-forecast and accuracy use the ledger actuals, not a stored copy", %{
    org: org,
    admin: admin,
    first: first,
    last: last
  } do
    version = version!(admin, org, first, last)

    variance = ForecastRead.variance(version, finance_opts(org))
    assert variance.actual.revenue_cents == 100_000
    assert variance.actual.expenses_cents == 40_000
    assert variance.actual.net_income_cents == 60_000
    assert variance.forecast.revenue_cents == 92_000
    assert variance.forecast.operating_expense_cents == 30_500
    assert variance.net_variance_cents == -1_500

    by_line = Map.new(variance.rows, &{&1.line, &1})
    assert by_line.revenue.variance_cents == 8_000
    assert by_line.expenses.variance_cents == 9_500
    assert by_line.net_income.variance_cents == -1_500
    assert by_line.cash_net.variance_cents == 70_000

    _published = publish!(version, admin)

    # A second published version with a different forecast; accuracy compares
    # both to the one ledger actual for the period.
    second =
      version!(admin, org, first, last, %{
        version: 2,
        drivers:
          drivers_for(first, %{
            revenue: 80_000,
            opex: 20_000,
            cash_out: 20_000,
            cash_in: 10_000,
            flat: true
          })
      })
      |> publish!(admin)

    accuracy = ForecastRead.accuracy(org, first, last, finance_opts(org))

    assert accuracy.actual.revenue_cents == 100_000
    assert accuracy.actual.net_income_cents == 60_000
    assert length(accuracy.versions) == 2
    assert Enum.map(accuracy.versions, & &1.version) == [1, 2]
    assert Enum.at(accuracy.versions, 0).error_cents == 1_500
    assert Enum.at(accuracy.versions, 0).accuracy_pct == 97.5
    assert Enum.at(accuracy.versions, 1).error_cents == 0
    assert Enum.at(accuracy.versions, 1).accuracy_pct == 100.0
    assert Enum.any?(accuracy.versions, &(&1.version_id == second.id))
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp admin_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :admin, kind: :tenant, plane: :tenant}
    }
  end

  defp books!(admin, org) do
    cash = account!(admin, org, "1000", :asset, :debit)
    income = account!(admin, org, "4000", :income, :credit)
    expense = account!(admin, org, "6000", :expense, :debit)

    PostingAccount
    |> Ash.Changeset.for_create(:create, %{org_id: org, key: :cash, account_id: cash.id},
      scope: admin
    )
    |> Ash.create!()

    %{cash: cash, income: income, expense: expense}
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

  defp post_entry!(admin, org, date, memo, lines) do
    JournalEntry
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, entry_date: date, memo: memo, lines: lines},
      scope: admin
    )
    |> Ash.create!()
    |> Ash.Changeset.for_update(:post, %{}, scope: admin)
    |> Ash.update!()
  end

  defp version!(admin, org, first, last, overrides \\ %{}) do
    attrs =
      org
      |> version_attrs(first, last, overrides)
      |> Map.put(:drivers, Map.get(overrides, :drivers, drivers_for(first, %{})))

    ForecastVersion
    |> Ash.Changeset.for_create(:create, attrs, scope: admin)
    |> Ash.create!()
  end

  defp version_attrs(org, first, last, overrides) do
    Map.merge(
      %{
        org_id: org,
        name: "FY26",
        version: 1,
        starts_on: first,
        ends_on: last,
        scenario_weights: %{base: 0.5, upside: 0.3, downside: 0.2}
      },
      Map.drop(overrides, [:drivers])
    )
  end

  defp publish!(version, admin) do
    version
    |> Ash.Changeset.for_update(:publish, %{}, scope: admin)
    |> Ash.update!()
  end

  defp drivers_for(date, args) do
    cash_out = Map.get(args, :cash_out, 20_000)
    cash_in = Map.get(args, :cash_in, 10_000)

    scenarios =
      if Map.get(args, :flat, false) do
        revenue = Map.get(args, :revenue, 80_000)
        opex = Map.get(args, :opex, 20_000)
        [base: {revenue, opex}, upside: {revenue, opex}, downside: {revenue, opex}]
      else
        [base: {90_000, 30_000}, upside: {110_000, 35_000}, downside: {70_000, 25_000}]
      end

    for {scenario, {revenue, opex}} <- scenarios,
        row <- [
          %{driver: :slot_price, scenario: scenario, period_on: date, amount_cents: revenue},
          %{driver: :eda_spend, scenario: scenario, period_on: date, amount_cents: opex},
          %{driver: :burn, scenario: scenario, period_on: date, amount_cents: cash_out},
          %{driver: :grant_pipeline, scenario: scenario, period_on: date, amount_cents: cash_in}
        ],
        do: row
  end

  defp drivers(org, version_id) do
    ForecastDriver
    |> Ash.Query.filter(org_id == ^org and version_id == ^version_id)
    |> Ash.read!(authorize?: false)
    |> Enum.sort_by(&{&1.scenario, &1.driver, &1.period_on})
  end

  defp finance_opts(org) do
    [
      org_id: org,
      repo: @repo,
      driver: ForecastDriver,
      version: ForecastVersion,
      account: Account,
      line: JournalLine,
      entry: JournalEntry,
      posting_account: PostingAccount
    ]
  end

  defp start_datetime(date), do: DateTime.new!(date, ~T[00:00:00], "Etc/UTC")
  defp end_datetime(date), do: DateTime.new!(date, ~T[23:59:59], "Etc/UTC")

  defp books_cash(org) do
    PostingAccount
    |> Ash.Query.filter(org_id == ^org and key == :cash)
    |> Ash.read_one!(authorize?: false)
    |> Map.fetch!(:account_id)
  end
end
