defmodule Samen.PayrollSettlementTest do
  @moduledoc """
  Payroll settlement and tie-out: the batch drafts ordinary entries, posts them
  through the journal's own gate, refuses a register that is not posted, and
  the tie-out report tells the truth when the bank link is absent or the
  settlement amount drifts.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.PayrollTieOut

  alias SamenCore.Support.FinanceFixture.{
    Account,
    JournalEntry,
    PayrollImport,
    PayrollSettlement
  }

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()
    admin = admin_scope(org)
    member = member_scope(org)
    expense = account!(admin, org, "6000", :expense, :debit)
    payable = account!(admin, org, "2100", :liability, :credit)
    tax = account!(admin, org, "2200", :liability, :credit)
    cash = account!(admin, org, "1010", :asset, :debit)

    {:ok,
     org: org,
     admin: admin,
     member: member,
     expense: expense,
     payable: payable,
     tax: tax,
     cash: cash}
  end

  describe "preparing a settlement" do
    test "drafts one entry per register liability and stores the batch", %{
      org: org,
      admin: admin,
      expense: expense,
      payable: payable,
      tax: tax,
      cash: cash
    } do
      entry = payroll_entry!(admin, org, expense, payable, tax, :posted)
      import = import!(admin, org, entry, 500_000)

      report = report!(org, import.id)
      assert report.status == :unsettled
      assert report.exceptions == [:settlement_not_prepared]

      settlement = prepare!(admin, org, import, cash, ~D[2026-10-05], "October net pay and tax")

      assert settlement.status == :draft
      assert settlement.total_cents == 500_000
      assert settlement.payment_count == 2
      assert settlement.prepared_by == admin.actor.id
      assert settlement.reference == "October net pay and tax"
      assert length(settlement.entry_ids) == 2

      entries = entries!(settlement.entry_ids)

      assert Enum.all?(entries, &(&1.status == :draft))
      assert Enum.all?(entries, &(&1.source_key == "payroll_settlement"))
      assert Enum.all?(entries, &(&1.source_id == settlement.id))

      assert Enum.sort(Enum.map(entries, &liability_debit/1)) == [200_000, 300_000]
      assert Enum.all?(entries, &(cash_credit(&1, cash.id) > 0))

      report = report!(org, import.id)
      assert report.status == :unposted
      assert report.totals.register_liability_cents == 500_000
      assert report.totals.settlement_cents == 500_000
      assert report.totals.cash_cents == 500_000
      assert report.totals.matched_cents == 0
      assert Enum.map(report.liabilities, & &1.code) == ["2100", "2200"]
      assert report.exceptions == [:settlement_not_posted]
    end

    test "refuses a register whose entry is still draft", %{
      org: org,
      admin: admin,
      expense: expense,
      payable: payable,
      tax: tax,
      cash: cash
    } do
      entry = payroll_entry!(admin, org, expense, payable, tax, :draft)
      import = import!(admin, org, entry, 500_000)

      assert {:error, error} = prepare(admin, org, import, cash, ~D[2026-10-05])
      assert inspect(error) =~ "must be posted before settlement"
      assert Ash.read!(PayrollSettlement, authorize?: false) == []
    end

    test "refuses a non-asset cash account", %{
      org: org,
      admin: admin,
      expense: expense,
      payable: payable,
      tax: tax
    } do
      entry = payroll_entry!(admin, org, expense, payable, tax, :posted)
      import = import!(admin, org, entry, 500_000)

      assert {:error, error} = prepare(admin, org, import, payable, ~D[2026-10-05])
      assert inspect(error) =~ "must be an asset account"
    end

    test "refuses a second batch for the same register", %{
      org: org,
      admin: admin,
      expense: expense,
      payable: payable,
      tax: tax,
      cash: cash
    } do
      entry = payroll_entry!(admin, org, expense, payable, tax, :posted)
      import = import!(admin, org, entry, 500_000)

      _settlement = prepare!(admin, org, import, cash, ~D[2026-10-05])

      assert {:error, _} = prepare(admin, org, import, cash, ~D[2026-10-06])

      # The losing prepare's draft entries must roll back with its failed
      # settlement insert; there is no orphan batch.
      settlement_entries =
        JournalEntry
        |> Ash.Query.filter(source_key == "payroll_settlement")
        |> Ash.read!(authorize?: false)

      assert length(settlement_entries) == 2
    end

    test "is an admin action and is org-scoped", %{
      org: org,
      admin: admin,
      member: member,
      expense: expense,
      payable: payable,
      tax: tax,
      cash: cash
    } do
      entry = payroll_entry!(admin, org, expense, payable, tax, :posted)
      import = import!(admin, org, entry, 500_000)

      assert {:error, %Ash.Error.Forbidden{}} = prepare(member, org, import, cash, ~D[2026-10-05])

      foreign_org = Ash.UUID.generate()
      foreign = admin_scope(foreign_org)

      assert {:error, _} = prepare(foreign, foreign_org, import, cash, ~D[2026-10-05])
    end
  end

  describe "posting a settlement" do
    test "posts every drafted entry through the journal and becomes posted", %{
      org: org,
      admin: admin,
      expense: expense,
      payable: payable,
      tax: tax,
      cash: cash
    } do
      entry = payroll_entry!(admin, org, expense, payable, tax, :posted)
      import = import!(admin, org, entry, 500_000)
      settlement = prepare!(admin, org, import, cash, ~D[2026-10-05])

      posted = post!(settlement, admin)

      assert posted.status == :posted
      assert posted.posted_by == admin.actor.id
      assert posted.posted_at != nil
      assert Enum.all?(entries!(posted.entry_ids), &(&1.status == :posted))

      report = report!(org, import.id)

      assert report.status == :unreconciled
      assert report.totals.matched_cents == 0

      assert report.exceptions == [
               :bank_match_missing,
               {:bank_match_missing, "2100"},
               {:bank_match_missing, "2200"}
             ]
    end

    test "refuses a member post", %{
      org: org,
      admin: admin,
      member: member,
      expense: expense,
      payable: payable,
      tax: tax,
      cash: cash
    } do
      entry = payroll_entry!(admin, org, expense, payable, tax, :posted)
      import = import!(admin, org, entry, 500_000)
      settlement = prepare!(admin, org, import, cash, ~D[2026-10-05])

      assert {:error, %Ash.Error.Forbidden{}} = post(settlement, member)
      assert Ash.get!(PayrollSettlement, settlement.id, authorize?: false).status == :draft
    end

    test "refuses to post a draft whose liability and cash amounts drifted", %{
      org: org,
      admin: admin,
      expense: expense,
      payable: payable,
      tax: tax,
      cash: cash
    } do
      entry = payroll_entry!(admin, org, expense, payable, tax, :posted)
      import = import!(admin, org, entry, 500_000)
      settlement = prepare!(admin, org, import, cash, ~D[2026-10-05])

      [first | _] = entries!(settlement.entry_ids)
      liability_id = liability_account_id(first)

      first
      |> Ash.Changeset.for_update(
        :update,
        %{
          lines: [
            %{account_id: liability_id, debit_cents: 290_000},
            %{account_id: cash.id, credit_cents: 290_000}
          ]
        },
        scope: admin
      )
      |> Ash.update!()

      assert {:error, error} = post(settlement, admin)
      assert inspect(error) =~ "stored batch total"

      assert Ash.get!(PayrollSettlement, settlement.id, authorize?: false).status == :draft
      assert Enum.all?(entries!(settlement.entry_ids), &(&1.status == :draft))
      assert report!(org, import.id).status == :unposted
    end

    test "refuses to post when a draft credits a different asset account", %{
      org: org,
      admin: admin,
      expense: expense,
      payable: payable,
      tax: tax,
      cash: cash
    } do
      other_cash = account!(admin, org, "1020", :asset, :debit)
      entry = payroll_entry!(admin, org, expense, payable, tax, :posted)
      import = import!(admin, org, entry, 500_000)
      settlement = prepare!(admin, org, import, cash, ~D[2026-10-05])

      [first | _] = entries!(settlement.entry_ids)
      liability_id = liability_account_id(first)
      amount = liability_debit(first)

      first
      |> Ash.Changeset.for_update(
        :update,
        %{
          lines: [
            %{account_id: liability_id, debit_cents: amount},
            %{account_id: other_cash.id, credit_cents: amount}
          ]
        },
        scope: admin
      )
      |> Ash.update!()

      assert {:error, error} = post(settlement, admin)

      assert inspect(error) =~
               "credit #{500_000 - amount} cents to the settlement cash account"

      assert Ash.get!(PayrollSettlement, settlement.id, authorize?: false).status == :draft
      assert Enum.all?(entries!(settlement.entry_ids), &(&1.status == :draft))
    end
  end

  describe "the tie-out report" do
    test "does not expose another org's payroll", %{
      org: org,
      admin: admin,
      expense: expense,
      payable: payable,
      tax: tax
    } do
      entry = payroll_entry!(admin, org, expense, payable, tax, :posted)
      import = import!(admin, org, entry, 500_000)
      foreign_org = Ash.UUID.generate()

      assert {:error, :not_found} = report(foreign_org, import.id)
      assert report!(org, import.id).status == :unsettled
    end

    test "a voided register entry is reported as voided", %{
      org: org,
      admin: admin,
      expense: expense,
      payable: payable,
      tax: tax
    } do
      entry = payroll_entry!(admin, org, expense, payable, tax, :void)
      import = import!(admin, org, entry, 500_000)

      report = report!(org, import.id)

      assert report.status == :voided
      assert :voided_payroll_entry in report.exceptions
    end
  end

  defp payroll_entry!(scope, org, expense, payable, tax, status) do
    entry =
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

    case status do
      :draft ->
        entry

      :posted ->
        entry
        |> Ash.Changeset.for_update(:post, %{}, scope: scope)
        |> Ash.update!()

      :void ->
        entry
        |> Ash.Changeset.for_update(:post, %{}, scope: scope)
        |> Ash.update!()
        |> Ash.Changeset.for_update(:void, %{}, scope: scope)
        |> Ash.update!()
    end
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

  defp prepare(scope, org, import, cash, date, reference \\ nil) do
    PayrollSettlement
    |> Ash.Changeset.for_create(
      :prepare,
      %{
        org_id: org,
        payroll_import_id: import.id,
        cash_account_id: cash.id,
        settlement_date: date,
        reference: reference
      },
      scope: scope
    )
    |> Ash.create()
  end

  defp prepare!(scope, org, import, cash, date, reference \\ nil) do
    case prepare(scope, org, import, cash, date, reference) do
      {:ok, settlement} -> settlement
      {:error, error} -> flunk("settlement prepare failed: #{inspect(error)}")
    end
  end

  defp post(settlement, scope) do
    settlement
    |> Ash.Changeset.for_update(:post, %{}, scope: scope)
    |> Ash.update()
  end

  defp post!(settlement, scope) do
    case post(settlement, scope) do
      {:ok, posted} -> posted
      {:error, error} -> flunk("settlement post failed: #{inspect(error)}")
    end
  end

  defp entries!(ids) do
    JournalEntry
    |> Ash.Query.filter(id in ^ids)
    |> Ash.Query.load(lines: :account)
    |> Ash.read!(authorize?: false)
  end

  defp report(org, import_id) do
    PayrollTieOut.report(org, import_id,
      import_module: PayrollImport,
      settlement_module: PayrollSettlement,
      entry_module: JournalEntry
    )
  end

  defp report!(org, import_id) do
    case report(org, import_id) do
      {:ok, report} -> report
      {:error, error} -> flunk("tie-out failed: #{inspect(error)}")
    end
  end

  defp liability_debit(entry) do
    entry.lines
    |> Enum.filter(&(&1.account.kind == :liability))
    |> Enum.map(& &1.debit_cents)
    |> Enum.sum()
  end

  defp liability_account_id(entry) do
    entry.lines
    |> Enum.find(&(&1.account.kind == :liability))
    |> Map.fetch!(:account_id)
  end

  defp cash_credit(entry, cash_id) do
    entry.lines
    |> Enum.filter(&(&1.account_id == cash_id))
    |> Enum.map(& &1.credit_cents)
    |> Enum.sum()
  end

  defp account!(scope, org, code, kind, side) do
    Account
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, code: code, name: "Account #{code}", kind: kind, normal_side: side},
      scope: scope
    )
    |> Ash.create!()
  end

  defp admin_scope(org) do
    %Samen.Scope{
      actor: %{id: "u:#{org}", org_id: org, role: :admin, kind: :tenant, plane: :tenant}
    }
  end

  defp member_scope(org) do
    %Samen.Scope{
      actor: %{id: "member:#{org}", org_id: org, role: :member, kind: :tenant, plane: :tenant}
    }
  end
end
