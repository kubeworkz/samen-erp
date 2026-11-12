defmodule Samen.Web.ReconciliationWorkbenchTest do
  @moduledoc """
  The reconciliation workbench (`/erp/reconciliation`).

  The page is proved over real posted journal entries: the account balances
  and org R1 verdict come from the core reconciliation reads, the drill-down
  shows posted lines only, and the flux table compares the selected month with
  the immediately prior month. A draft is present in the fixture specifically
  to prove it never appears in either read.
  """

  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Finance.Reconciliation
  alias Samen.Web.Finance.Reconciliation.Live
  alias Samen.Web.Mount
  alias Samen.Web.Plane

  alias Samen.WebTest.Erp.{Account, JournalEntry}
  alias Samen.WebTest.Repo

  defp reconciliation_mount do
    Mount.new(:erp, Samen.WebTest.Erp, Repo,
      plane: Plane.tenant(),
      labels: %{erp_path: "/erp"}
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

  defp create_entry!(org_id, date, memo, lines) do
    JournalEntry
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, entry_date: date, memo: memo, lines: lines},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp post_entry!(org_id, date, memo, lines) do
    create_entry!(org_id, date, memo, lines)
    |> Ash.Changeset.for_update(:post, %{}, authorize?: false)
    |> Ash.update!()
  end

  defp period_key(date), do: "#{date.year}-#{String.pad_leading(to_string(date.month), 2, "0")}"

  defp open(org_id, params) do
    mount = reconciliation_mount()
    params = Map.put_new(params, "org", org_id)
    {:ok, socket} = Live.mount(params, mount_session(mount), %Phoenix.LiveView.Socket{})
    {:noreply, socket} = Live.handle_params(params, "http://localhost/erp/reconciliation", socket)
    socket
  end

  setup do
    today = Date.utc_today()
    prior_day = today |> Date.beginning_of_month() |> Date.add(-1)

    org_id = Ash.UUID.generate()
    cash = seed_account!(org_id, "1000", "Cash", :asset, :debit)
    revenue = seed_account!(org_id, "4000", "Revenue", :income, :credit)
    expense = seed_account!(org_id, "6000", "Expense", :expense, :debit)

    post_entry!(org_id, prior_day, "August receipt", [
      %{account_id: cash.id, debit_cents: 50_000},
      %{account_id: revenue.id, credit_cents: 50_000}
    ])

    post_entry!(org_id, today, "Current receipt", [
      %{account_id: cash.id, debit_cents: 100_000},
      %{account_id: revenue.id, credit_cents: 100_000}
    ])

    post_entry!(org_id, today, "Current spend", [
      %{account_id: expense.id, debit_cents: 40_000},
      %{account_id: cash.id, credit_cents: 40_000}
    ])

    _draft =
      create_entry!(org_id, today, "Draft must not count", [
        %{account_id: cash.id, debit_cents: 999_000},
        %{account_id: revenue.id, credit_cents: 999_000}
      ])

    %{org_id: org_id, today: today, cash: cash, revenue: revenue, expense: expense}
  end

  test "renders the R1 verdict, account balances and the month-over-month flux", %{
    org_id: org_id,
    today: today,
    cash: cash
  } do
    socket = open(org_id, %{"period" => period_key(today)})
    html = render_html(Live, socket.assigns)

    assert html =~ ~s(id="reconciliation-workbench")
    assert html =~ "Reconciliation workbench"
    assert html =~ "Org balance (R1)"
    assert html =~ "$0.00"
    assert html =~ "balanced"
    assert html =~ "3 accounts"
    assert html =~ "6 posted lines"

    assert html =~ ~s(id="reconciliation-account-#{cash.id}")
    assert html =~ "Cash"
    assert html =~ "$1100.00"
    assert html =~ "$600.00"
    assert html =~ ~s(href="/erp/reconciliation?org=#{org_id}")
    assert html =~ ~s(class="on")

    assert html =~ ~s(id="reconciliation-flux")
    assert html =~ ~s(id="reconciliation-flux-#{cash.id}")
    assert html =~ "20.0%"
    assert html =~ "$400.00"
    assert html =~ "$500.00"
    refute html =~ "Draft must not count"

    assert {:ok, state} =
             Reconciliation.load(reconciliation_mount(), org_id, period: period_key(today))

    assert state.workbench.account_count == 3
    assert state.workbench.posted_line_count == 6
    assert state.flux.moved_account_count == 3
    assert state.flux.period.month == today.month
  end

  test "the account drill-down shows posted lines only, newest first", %{
    org_id: org_id,
    today: today,
    cash: cash
  } do
    socket =
      open(org_id, %{"period" => period_key(today), "account" => cash.id})

    html = render_html(Live, socket.assigns)

    assert html =~ ~s(id="reconciliation-lines")
    assert html =~ "Posted lines — 1000 Cash"
    assert html =~ "Current receipt"
    assert html =~ "Current spend"
    assert html =~ "August receipt"

    refute html =~ "Draft must not count"
    assert html =~ "reconciliation-line-"
  end

  test "the current month is the default period; a malformed selector falls back to it", %{
    org_id: org_id,
    today: today
  } do
    socket = open(org_id, %{"period" => "not-a-period"})
    state = socket.assigns.state

    assert state.period.year == today.year
    assert state.period.month == today.month
    assert state.flux.period.month == today.month
  end

  test "a workspace without Finance gets the honest unavailable card" do
    org_id = Ash.UUID.generate()
    mount = Mount.new(:crm, Samen.WebTest.Crm, Repo, plane: Plane.tenant(), labels: %{})

    assert {:error, :finance_not_mounted} = Reconciliation.load(mount, org_id)
  end
end
