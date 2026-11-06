defmodule Samen.Web.BoardPackTest do
  @moduledoc """
  WS-ACCT Phase 13 — the board reporting package.

  The page is proved over REAL posted journal entries: the exec snapshot,
  condensed statements and cash flow must equal the same `ProfitLoss`,
  `BalanceSheet` and `CashFlow` reads called directly. That is the phase's
  traceability claim — no number is hand-figured by the view.

  The remaining legs prove the bounded CSV egress, the absence of PII
  columns, and the two honest empty states: an unmapped `:cash` posting
  account and a workspace with no fiscal period.
  """

  use Samen.WebTest.DataCase, async: false

  alias Samen.Scopes.Finance.{BalanceSheet, CashFlow, ForecastRead, ProfitLoss}
  alias Samen.Web.Finance.BoardPack
  alias Samen.Web.Finance.BoardPack.Live
  alias Samen.Web.Mount
  alias Samen.Web.Plane

  alias Samen.WebTest.Erp.{
    Account,
    FiscalPeriod,
    ForecastDriver,
    ForecastVersion,
    JournalEntry,
    JournalLine,
    PostingAccount
  }

  alias Samen.WebTest.Repo

  defp admin_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :admin, kind: :tenant, plane: :tenant}
    }
  end

  defp board_mount do
    Mount.new(:erp, Samen.WebTest.Erp, Repo,
      plane: Plane.tenant(),
      labels: %{
        board_path: "/board",
        erp_path: "/erp",
        work_namespace: Samen.WebTest.Work
      }
    )
  end

  defp seed_account!(org_id, code, name, kind, side) do
    Account
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        code: code,
        name: name,
        kind: kind,
        normal_side: side,
        currency: "CAD"
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp seed_posting_account!(org_id, key, account) do
    PostingAccount
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, key: key, account_id: account.id},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp seed_period!(org_id, year, month) do
    FiscalPeriod
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, year: year, month: month},
      scope: admin_scope(org_id)
    )
    |> Ash.create!()
  end

  defp post_entry!(org_id, date, memo, lines) do
    JournalEntry
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, entry_date: date, memo: memo, lines: lines},
      authorize?: false
    )
    |> Ash.create!()
    |> Ash.Changeset.for_update(:post, %{}, authorize?: false)
    |> Ash.update!()
  end

  defp seed_month! do
    today = Date.utc_today()
    org_id = Ash.UUID.generate()
    cash = seed_account!(org_id, "1000", "Cash", :asset, :debit)
    income = seed_account!(org_id, "4000", "Grant revenue", :income, :credit)
    expense = seed_account!(org_id, "6000", "Research expense", :expense, :debit)

    seed_posting_account!(org_id, :cash, cash)
    seed_period!(org_id, today.year, today.month)

    post_entry!(org_id, today, "Award receipt", [
      %{account_id: cash.id, debit_cents: 100_000, credit_cents: 0},
      %{account_id: income.id, debit_cents: 0, credit_cents: 100_000}
    ])

    post_entry!(org_id, today, "Research spend", [
      %{account_id: expense.id, debit_cents: 40_000, credit_cents: 0},
      %{account_id: cash.id, debit_cents: 0, credit_cents: 40_000}
    ])

    %{org_id: org_id, today: today, cash: cash, income: income, expense: expense}
  end

  defp seed_forecast!(org_id, today, opts \\ []) do
    first = Date.beginning_of_month(today)
    name = Keyword.get(opts, :name, "Board base")
    number = Keyword.get(opts, :version, 1)
    burn = Keyword.get(opts, :burn, 20_000)
    grant = Keyword.get(opts, :grant, 10_000)

    version =
      ForecastVersion
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          name: name,
          version: number,
          starts_on: first,
          ends_on: Date.end_of_month(first),
          scenario_weights: %{base: 1.0, upside: 0.0, downside: 0.0},
          drivers: [
            %{driver: :burn, scenario: :base, period_on: first, amount_cents: burn},
            %{driver: :grant_pipeline, scenario: :base, period_on: first, amount_cents: grant}
          ]
        },
        scope: admin_scope(org_id)
      )
      |> Ash.create!()

    version
    |> Ash.Changeset.for_update(:publish, %{}, scope: admin_scope(org_id))
    |> Ash.update!()
  end

  defp finance_opts(org_id) do
    [
      org_id: org_id,
      driver: ForecastDriver,
      repo: Repo,
      posting_account: PostingAccount,
      line: JournalLine,
      entry: JournalEntry
    ]
  end

  defp open(org_id) do
    mount = board_mount()
    params = %{"org" => org_id}
    {:ok, socket} = Live.mount(params, mount_session(mount), %Phoenix.LiveView.Socket{})
    {:noreply, socket} = Live.handle_params(params, "http://localhost/board", socket)
    socket
  end

  test "renders the package and every figure ties to the same ledger reads" do
    %{org_id: org_id, today: today} = seed_month!()
    socket = open(org_id)
    html = render_html(Live, socket.assigns)

    assert html =~ ~s(id="board-pack")
    assert html =~ "Board pack"
    assert html =~ Calendar.strftime(Date.new!(today.year, today.month, 1), "%B %Y")
    assert html =~ "Exec snapshot"
    assert html =~ "Condensed statements"
    assert html =~ "KPI &amp; variance bridge" or html =~ "KPI & variance bridge"
    assert html =~ "$1000.00"
    assert html =~ "$400.00"
    assert html =~ "$600.00"
    assert html =~ "Cash flow"
    assert html =~ "Opening cash"
    assert html =~ "Closing cash"
    assert html =~ ~s(id="board-light-statements")
    assert html =~ ~s(id="board-light-cash")
    assert html =~ "Trace"
    assert html =~ "ProfitLoss.generate/4"
    assert html =~ "CashFlow.statement/4"
    assert html =~ "No variance rows are recorded for this period."
    assert html =~ "No published forecast version covers this period"
    assert html =~ ~s(href="/board?org=#{org_id}" class="on")

    assert Samen.Web.Erp.report_surfaces() == [:board]
    assert Samen.Web.Erp.report_surface("board") == :board
    refute Samen.Web.Erp.report_surface("bogus")
    assert Samen.Web.Erp.report_label(:board) == "Board pack"

    # No PII column or value is part of the package.
    refute html =~ "employee_id"
    refute html =~ "full_name"
    refute html =~ "email"
    refute html =~ "phone"

    {:ok, state} = BoardPack.load(board_mount(), org_id)

    first = Date.new!(today.year, today.month, 1)
    last = Date.end_of_month(first)
    from_date = DateTime.new!(first, ~T[00:00:00], "Etc/UTC")
    to_date = DateTime.new!(last, ~T[23:59:59], "Etc/UTC")

    statement_opts = [
      repo: Repo,
      account_resource: Account,
      line_resource: JournalLine,
      entry_resource: JournalEntry
    ]

    {:ok, profit_loss} = ProfitLoss.generate(org_id, from_date, to_date, statement_opts)
    {:ok, balance_sheet} = BalanceSheet.generate(org_id, to_date, statement_opts)

    {:ok, cash_flow} =
      CashFlow.statement(org_id, from_date, to_date,
        repo: Repo,
        posting_account: PostingAccount,
        line: JournalLine,
        entry: JournalEntry
      )

    assert state.report.statements.profit_loss == profit_loss
    assert state.report.statements.balance_sheet == balance_sheet
    assert state.report.statements.cash_flow == cash_flow

    assert state.report.exec.revenue_cents == 100_000
    assert state.report.exec.expenses_cents == 40_000
    assert state.report.exec.net_income_cents == 60_000
    assert state.report.exec.cash_cents == 60_000
    assert state.report.exec.balanced?
    assert state.report.statements.cash_flow.reconciled?
    assert state.report.kpis.operating_margin_pct == 60.0

    csv = BoardPack.csv(state.report)
    assert csv =~ "section,label,value,unit,source"
    assert csv =~ "exec,Revenue,100000,cents,ProfitLoss.generate/4"
    assert csv =~ "cash_flow,Closing cash,60000,cents,CashFlow.statement/4"
    assert csv =~ "variance_bridge,Labour basis,declared_pending_driver,text"
    assert csv =~ "runway,Status,no_published_forecast,text"
  end

  test "quotes the latest published forecast through ForecastRead.runway/2" do
    %{org_id: org_id, today: today} = seed_month!()
    _older = seed_forecast!(org_id, today, name: "Older", version: 1, burn: 50_000)
    latest = seed_forecast!(org_id, today, name: "Latest", version: 2, burn: 20_000)

    socket = open(org_id)
    html = render_html(Live, socket.assigns)

    assert html =~ ~s(id="board-runway")
    assert html =~ "Runway"
    assert html =~ "Latest · v2"
    assert html =~ "6.0 months"
    assert html =~ "$100.00"

    {:ok, state} = BoardPack.load(board_mount(), org_id)
    expected = ForecastRead.runway(latest, finance_opts(org_id))

    assert state.report.runway.version_id == latest.id
    assert state.report.runway.status == :runway
    assert state.report.runway.cash_on_hand_cents == expected.cash_on_hand_cents
    assert state.report.runway.avg_monthly_burn_cents == expected.avg_monthly_burn_cents
    assert state.report.runway.runway_months == expected.runway_months
    assert state.report.runway.reconciled?
    assert Enum.any?(state.report.sources, &(&1.section == "Runway"))

    csv = BoardPack.csv(state.report)
    assert csv =~ "runway,Status,runway,text"
    assert csv =~ "runway,Cash on hand,60000,cents"
    assert csv =~ "runway,Average monthly burn,10000,cents"
    assert csv =~ "runway,Runway,6.0,months"
    assert csv =~ "runway,Mapped,true,boolean"
    assert csv =~ "runway,Reconciled,true,boolean"
  end

  test "an unmapped :cash account is an honest empty cash statement" do
    today = Date.utc_today()
    org_id = Ash.UUID.generate()
    cash = seed_account!(org_id, "1000", "Cash", :asset, :debit)
    income = seed_account!(org_id, "4000", "Grant revenue", :income, :credit)
    seed_period!(org_id, today.year, today.month)
    seed_forecast!(org_id, today)

    post_entry!(org_id, today, "Award receipt", [
      %{account_id: cash.id, debit_cents: 100_000, credit_cents: 0},
      %{account_id: income.id, debit_cents: 0, credit_cents: 100_000}
    ])

    socket = open(org_id)
    html = render_html(Live, socket.assigns)

    assert html =~ "No"
    assert html =~ "posting account is mapped"
    assert html =~ "cash movement is unavailable"
    assert html =~ "No :cash posting account is mapped, so no runway is quoted."

    {:ok, state} = BoardPack.load(board_mount(), org_id)
    refute state.report.statements.cash_flow.mapped?
    assert state.report.statements.cash_flow.closing_cents == 0
    assert state.report.exec.cash_cents == 0
    assert state.report.runway.status == :unmapped
    refute state.report.runway.mapped?

    csv = BoardPack.csv(state.report)
    assert csv =~ "cash_flow,Closing cash,0,cents,CashFlow.statement/4"
    assert csv =~ "runway,Status,unmapped,text"
  end

  test "a workspace with no fiscal period renders the honest empty state" do
    org_id = Ash.UUID.generate()
    socket = open(org_id)
    html = render_html(Live, socket.assigns)

    assert html =~ "No fiscal period is declared on this workspace."
    refute html =~ ~s(id="board-exec")
  end
end
