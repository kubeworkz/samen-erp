defmodule Samenerp.PayrollSettlementTest do
  @moduledoc """
  Payroll settlement -> bank reconciliation on the REAL host schema.

  The register creates payroll payable and tax liabilities; the settlement
  drafts and posts one cash movement per liability; `Banking.Match` then links
  each posted settlement entry to a statement line. The tie-out must stay
  unreconciled until every cash movement is matched, then go reconciled.
  """

  use Samenerp.DataCase, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.PayrollTieOut
  alias Samen.Web.Finance.CloseDashboard
  alias Samen.Web.Finance.CloseDashboard.Live, as: CloseBoardLive
  alias Samen.Web.Mount
  alias Samenerp.Banking
  alias Samenerp.Erp.{Account, FiscalPeriod, JournalEntry, PayrollImport, PayrollSettlement}

  setup do
    org = Ecto.UUID.generate()

    scope = %Samen.Scope{
      actor: %{id: "u:#{org}", org_id: org, role: :admin, kind: :tenant, plane: :tenant}
    }

    expense = account!(org, "6000", :expense, :debit)
    payable = account!(org, "2100", :liability, :credit)
    tax = account!(org, "2200", :liability, :credit)
    cash = account!(org, "1010", :asset, :debit)
    bank = bank_account!(org, cash.id)

    {:ok,
     org: org, scope: scope, expense: expense, payable: payable, tax: tax, cash: cash, bank: bank}
  end

  test "the tie-out reconciles only after every cash movement is bank-matched", %{
    org: org,
    scope: scope,
    expense: expense,
    payable: payable,
    tax: tax,
    cash: cash,
    bank: bank
  } do
    entry = payroll_entry!(scope, org, expense, payable, tax)
    import = import!(scope, org, entry, 500_000)
    settlement = prepare!(scope, org, import, cash)
    posted = post!(settlement, scope)

    entries = settlement_entries!(posted.entry_ids)

    assert report!(org, import.id).status == :unreconciled

    [first | rest] = entries

    first_line = statement_line!(org, bank.id, -cash_credit(first, cash.id))
    assert {:ok, _match} = match(scope, first_line, first)

    report = report!(org, import.id)
    assert report.status == :unreconciled
    assert report.totals.matched_cents in [200_000, 300_000]

    second = hd(rest)
    second_line = statement_line!(org, bank.id, -cash_credit(second, cash.id))
    assert {:ok, _match} = match(scope, second_line, second)

    report = report!(org, import.id)

    assert report.status == :reconciled
    assert report.reconciled?
    assert report.totals.register_liability_cents == 500_000
    assert report.totals.settlement_cents == 500_000
    assert report.totals.cash_cents == 500_000
    assert report.totals.matched_cents == 500_000
    assert report.totals.variance_cents == 0
    assert report.totals.bank_variance_cents == 0
    assert Enum.all?(report.liabilities, & &1.accepted?)
    assert Enum.all?(report.liabilities, &(length(&1.bank_matches) == 1))
    assert report.exceptions == []
  end

  test "the close board renders a reconciled settlement after every bank match", %{
    org: org,
    scope: scope,
    expense: expense,
    payable: payable,
    tax: tax,
    cash: cash,
    bank: bank
  } do
    _period = period!(scope, org, 2026, 9)
    entry = payroll_entry!(scope, org, expense, payable, tax)
    import = import!(scope, org, entry, 500_000)
    settlement = prepare!(scope, org, import, cash)
    posted = post!(settlement, scope)

    entries = settlement_entries!(posted.entry_ids)

    Enum.each(entries, fn entry ->
      line = statement_line!(org, bank.id, -cash_credit(entry, cash.id))
      assert {:ok, _match} = match(scope, line, entry)
    end)

    mount = close_mount()

    assert {:ok, state} = CloseDashboard.load(mount, org)
    assert [row] = state.settlements.rows
    assert row.status == :reconciled
    assert row.tie_out.status == :reconciled
    assert row.tie_out.bank_wired?
    assert row.tie_out.exceptions == []
    assert row.tie_out.totals.matched_cents == 500_000
    assert row.cash_account.id == cash.id

    html = close_html!(mount, org)

    assert html =~ ~s(id="close-payroll-settlement-#{import.id}")
    assert html =~ ~s(id="close-payroll-settlement-status-#{import.id}" data-status="reconciled")
    assert html =~ ~s(id="close-payroll-tie-out-#{import.id}" data-status="reconciled")
    assert html =~ "$5000.00"
    refute html =~ "Bank matching is not wired on this host."
  end

  test "a bank match within the amount tolerance is still a tie-out mismatch", %{
    org: org,
    scope: scope,
    expense: expense,
    payable: payable,
    tax: tax,
    cash: cash,
    bank: bank
  } do
    entry = payroll_entry!(scope, org, expense, payable, tax)
    import = import!(scope, org, entry, 500_000)
    settlement = prepare!(scope, org, import, cash)
    posted = post!(settlement, scope)
    [first, second] = settlement_entries!(posted.entry_ids)

    first_line = statement_line!(org, bank.id, -cash_credit(first, cash.id))
    assert {:ok, _match} = match(scope, first_line, first)

    # Banking.Match permits a one-cent currency-rounding tolerance; the tie-out
    # must still expose the unmatched cent rather than calling it reconciled.
    second_line = statement_line!(org, bank.id, -(cash_credit(second, cash.id) + 1))
    assert {:ok, _match} = match(scope, second_line, second)

    report = report!(org, import.id)

    assert report.status == :mismatch
    refute report.reconciled?
    assert report.totals.bank_variance_cents == -1
    assert Enum.any?(report.exceptions, &match?({:bank_match_amount_mismatch, _, _}, &1))
  end

  defp period!(scope, org, year, month) do
    FiscalPeriod
    |> Ash.Changeset.for_create(:create, %{org_id: org, year: year, month: month}, scope: scope)
    |> Ash.create!()
  end

  defp close_mount do
    Mount.new(:erp, Samenerp.Erp, Samenerp.Repo,
      labels: %{
        close_path: "/close",
        erp_path: "/erp",
        banking_namespace: Samenerp.Banking
      }
    )
  end

  defp close_html!(mount, org) do
    params = %{"org" => org}
    session = %{"samen_mount" => Mount.to_session(mount)}

    {:ok, socket} = CloseBoardLive.mount(params, session, %Phoenix.LiveView.Socket{})

    {:noreply, socket} =
      CloseBoardLive.handle_params(params, "http://localhost/close", socket)

    socket.assigns
    |> Map.put(:__changed__, %{})
    |> CloseBoardLive.render()
    |> Phoenix.HTML.Safe.to_iodata()
    |> IO.iodata_to_binary()
  end

  defp payroll_entry!(scope, org, expense, payable, tax) do
    JournalEntry
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        entry_date: ~D[2026-09-30],
        memo: "Payroll register",
        lines: [
          %{account_id: expense.id, debit_cents: 500_000},
          %{account_id: payable.id, credit_cents: 300_000},
          %{account_id: tax.id, credit_cents: 200_000}
        ]
      },
      scope: scope
    )
    |> Ash.create!()
    |> Ash.Changeset.for_update(:post, %{}, scope: scope)
    |> Ash.update!()
  end

  defp import!(scope, org, entry, total_cents) do
    PayrollImport
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        provider: "acme_payroll",
        external_id: "run-#{Ash.UUID.generate()}",
        line_set_hash: String.duplicate("a", 64),
        total_cents: total_cents,
        entry_date: entry.entry_date,
        imported_at: DateTime.utc_now() |> DateTime.truncate(:second),
        imported_by: "u:payroll-importer",
        status: :imported,
        entry_id: entry.id
      },
      scope: scope
    )
    |> Ash.create!()
  end

  defp prepare!(scope, org, import, cash) do
    PayrollSettlement
    |> Ash.Changeset.for_create(
      :prepare,
      %{
        org_id: org,
        payroll_import_id: import.id,
        cash_account_id: cash.id,
        settlement_date: ~D[2026-10-05],
        reference: "October payroll clearance"
      },
      scope: scope
    )
    |> Ash.create!()
  end

  defp post!(settlement, scope) do
    settlement
    |> Ash.Changeset.for_update(:post, %{}, scope: scope)
    |> Ash.update!()
  end

  defp settlement_entries!(ids) do
    JournalEntry
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.load(lines: :account)
    |> Ash.read!(authorize?: false)
  end

  defp report!(org, import_id) do
    PayrollTieOut.report(org, import_id,
      import_module: PayrollImport,
      settlement_module: PayrollSettlement,
      entry_module: JournalEntry,
      match_module: Banking.Match
    )
    |> case do
      {:ok, report} -> report
      {:error, error} -> flunk("tie-out failed: #{inspect(error)}")
    end
  end

  defp match(scope, line_id, entry) do
    Banking.Match
    |> Ash.Changeset.for_create(
      :create_match,
      %{
        statement_line_id: line_id,
        entry_id: entry.id,
        org_id: scope.actor.org_id
      },
      scope: scope
    )
    |> Ash.create()
  end

  defp statement_line!(org, bank_account_id, amount_cents) do
    %{rows: [[id]]} =
      Samenerp.Repo.query!(
        """
        INSERT INTO bkl_statement_line
          (bkl_bank_account_id, bkl_posted_at, bkl_amount_cents, bkl_description,
           bkl_import_hash, bkl_id, bkl_org_id, bkl_inserted_at, bkl_updated_at)
        VALUES ($1, $2, $3, $4, $5, gen_random_uuid(), $6, NOW(), NOW())
        RETURNING bkl_id
        """,
        [
          Ecto.UUID.dump!(bank_account_id),
          DateTime.utc_now() |> DateTime.truncate(:second),
          amount_cents,
          "PAYROLL CLEARANCE",
          "payroll-settlement-#{System.unique_integer([:positive])}",
          Ecto.UUID.dump!(org)
        ]
      )

    Ecto.UUID.load!(id)
  end

  defp cash_credit(entry, cash_id) do
    entry.lines
    |> Enum.filter(&(&1.account_id == cash_id))
    |> Enum.map(& &1.credit_cents)
    |> Enum.sum()
  end

  defp account!(org, code, kind, side) do
    Account
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, code: code, name: "Account #{code}", kind: kind, normal_side: side},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp bank_account!(org, cash_id) do
    Banking.BankAccount
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, name: "Payroll Bank", account_id: cash_id},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end
end
