defmodule Samen.FinanceReconciliationWorkbenchTest do
  @moduledoc """
  The reconciliation workbench and flux reads (WS-ACCT follow-on).

  Both reads are proved over REAL posted journal entries in the Finance
  fixture: drafts must not move a balance, the workbench's account balances
  must agree with `Reconcile.account_balance/3`, a selected account's lines
  must be posted lines only, and flux must compare the requested month with
  the immediately prior month without leaking another org's rows.
  """

  use ExUnit.Case, async: false

  alias Samen.Scopes.Finance.{FluxRead, Reconcile, ReconciliationWorkbench}
  alias SamenCore.Support.FinanceFixture.{Account, JournalEntry, JournalLine}

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()
    {:ok, org: org, scope: tenant_scope(org)}
  end

  defp tenant_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, kind: :tenant, plane: :tenant}
    }
  end

  defp account!(scope, org, code, name, kind, side) do
    Account
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        code: code,
        name: name,
        kind: kind,
        normal_side: side,
        currency: "CAD"
      },
      scope: scope
    )
    |> Ash.create!()
  end

  defp entry!(scope, org, date, memo, lines) do
    JournalEntry
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, entry_date: date, memo: memo, lines: lines},
      scope: scope
    )
    |> Ash.create!()
  end

  defp posted_entry!(scope, org, date, memo, lines) do
    entry = entry!(scope, org, date, memo, lines)

    entry
    |> Ash.Changeset.for_update(:post, %{}, scope: scope)
    |> Ash.update!()
  end

  defp read_opts do
    [
      repo: @repo,
      account_resource: Account,
      line_resource: JournalLine,
      entry_resource: JournalEntry
    ]
  end

  # Insert a line that the governed API would refuse: a line whose own org_id
  # disagrees with its entry's (or its account's) org. The posted-entry trigger
  # correctly refuses a line insert without the PostGuard marker, so the test
  # arms that marker for the one statement and clears it again — this models
  # compromised/raw data the read-side join must fail closed on.
  defp raw_line!(org_id, entry, account, debit_cents, memo) do
    @repo.query!("SELECT set_config('samen.finance_posting', 'on', true)", [])

    try do
      @repo.query!(
        """
        INSERT INTO sjl_journal_line
          (sjl_org_id, sjl_entry_id, sjl_account_id, sjl_debit_cents, sjl_credit_cents,
           sjl_memo, sjl_inserted_at, sjl_updated_at)
        VALUES ($1, $2, $3, $4, 0, $5, now(), now())
        """,
        [
          dump_uuid(org_id),
          dump_uuid(entry.id),
          dump_uuid(account.id),
          debit_cents,
          memo
        ]
      )
    after
      @repo.query!("SELECT set_config('samen.finance_posting', 'off', true)", [])
    end
  end

  defp dump_uuid(value), do: Ecto.UUID.dump!(value)

  describe "ReconciliationWorkbench.report/2" do
    test "reads posted account balances and the independent R1 verdict", %{org: org, scope: scope} do
      cash = account!(scope, org, "1000", "Cash", :asset, :debit)
      revenue = account!(scope, org, "4000", "Revenue", :income, :credit)
      expense = account!(scope, org, "6000", "Expense", :expense, :debit)

      posted_entry!(scope, org, ~D[2026-09-10], "receipt", [
        %{account_id: cash.id, debit_cents: 100_000},
        %{account_id: revenue.id, credit_cents: 100_000}
      ])

      posted_entry!(scope, org, ~D[2026-09-15], "spend", [
        %{account_id: expense.id, debit_cents: 40_000},
        %{account_id: cash.id, credit_cents: 40_000}
      ])

      # A draft is a staged intention, not a fact: it must move neither the
      # account balance nor the posted-line count.
      _draft =
        entry!(scope, org, ~D[2026-09-20], "draft", [
          %{account_id: cash.id, debit_cents: 999_000},
          %{account_id: revenue.id, credit_cents: 999_000}
        ])

      assert {:ok, report} = ReconciliationWorkbench.report(org, read_opts())
      assert report.balanced?
      assert report.org_balance_cents == 0
      assert report.account_count == 3
      assert report.posted_line_count == 4

      rows = Map.new(report.accounts, &{&1.code, &1})
      assert rows["1000"].debit_cents == 100_000
      assert rows["1000"].credit_cents == 40_000
      assert rows["1000"].balance_cents == 60_000
      assert rows["1000"].posted_line_count == 2
      assert rows["4000"].balance_cents == -100_000
      assert rows["6000"].balance_cents == 40_000

      # The workbench's per-account balance is the same number the kernel
      # reconciliation read returns for that account.
      assert {:ok, 60_000} =
               Reconcile.account_balance(cash.id, @repo, line_resource: JournalLine)

      foreign_org = Ash.UUID.generate()
      assert {:ok, foreign} = ReconciliationWorkbench.report(foreign_org, read_opts())
      assert foreign.accounts == []
      assert foreign.org_balance_cents == 0
    end

    test "a selected account's lines are posted-only and newest first", %{org: org, scope: scope} do
      cash = account!(scope, org, "1000", "Cash", :asset, :debit)
      revenue = account!(scope, org, "4000", "Revenue", :income, :credit)

      posted_entry!(scope, org, ~D[2026-09-10], "older", [
        %{account_id: cash.id, debit_cents: 10_000},
        %{account_id: revenue.id, credit_cents: 10_000}
      ])

      posted_entry!(scope, org, ~D[2026-09-20], "newer", [
        %{account_id: cash.id, debit_cents: 25_000},
        %{account_id: revenue.id, credit_cents: 25_000}
      ])

      _draft =
        entry!(scope, org, ~D[2026-09-25], "draft", [
          %{account_id: cash.id, debit_cents: 999_000},
          %{account_id: revenue.id, credit_cents: 999_000}
        ])

      assert {:ok, lines} = ReconciliationWorkbench.lines(org, cash.id, read_opts())
      assert Enum.map(lines, & &1.entry_memo) == ["newer", "older"]
      assert Enum.all?(lines, &(&1.debit_cents > 0 and &1.credit_cents == 0))

      # A foreign account id is an empty read, never another org's rows.
      assert {:ok, []} =
               ReconciliationWorkbench.lines(Ash.UUID.generate(), cash.id, read_opts())
    end
  end

  describe "cross-org join guards" do
    test "report and flux ignore a line whose entry is local but whose own org is foreign",
         %{org: org, scope: scope} do
      cash = account!(scope, org, "1000", "Cash", :asset, :debit)
      revenue = account!(scope, org, "4000", "Revenue", :income, :credit)
      victim = account!(scope, org, "2000", "Victim", :asset, :debit)

      entry =
        posted_entry!(scope, org, ~D[2026-09-10], "local entry", [
          %{account_id: cash.id, debit_cents: 10_000},
          %{account_id: revenue.id, credit_cents: 10_000}
        ])

      # The entry and account are local; only the line's own org_id is foreign.
      # A join keyed only on the entry id would let this row contaminate the
      # local org's account balance and flux.
      raw_line!(Ash.UUID.generate(), entry, victim, 777_000, "foreign-owned line")

      assert {:ok, report} = ReconciliationWorkbench.report(org, read_opts())
      assert report.balanced?
      assert report.org_balance_cents == 0
      assert report.posted_line_count == 2

      rows = Map.new(report.accounts, &{&1.code, &1})
      assert rows["2000"].balance_cents == 0
      assert rows["2000"].posted_line_count == 0
      assert {:ok, 0} = Reconcile.account_balance(victim.id, @repo, line_resource: JournalLine)

      assert {:ok, flux} = FluxRead.report(org, 2026, 9, read_opts())
      refute Enum.any?(flux.rows, &(&1.code == "2000"))
    end

    test "the drill-down and R1 ignore a local line whose entry belongs to another org",
         %{org: org, scope: scope} do
      local = account!(scope, org, "3000", "Local", :asset, :debit)

      foreign_org = Ash.UUID.generate()
      foreign_scope = tenant_scope(foreign_org)
      foreign_cash = account!(foreign_scope, foreign_org, "1000", "Foreign Cash", :asset, :debit)

      foreign_revenue =
        account!(foreign_scope, foreign_org, "4000", "Foreign Revenue", :income, :credit)

      foreign_entry =
        posted_entry!(foreign_scope, foreign_org, ~D[2026-09-12], "foreign secret", [
          %{account_id: foreign_cash.id, debit_cents: 5_000},
          %{account_id: foreign_revenue.id, credit_cents: 5_000}
        ])

      # The line is local, but it points at a foreign entry. The drill-down join
      # must not disclose that entry's memo/date, and R1 must not count the row.
      raw_line!(org, foreign_entry, local, 42_000, "leaked line")

      assert {:ok, []} = ReconciliationWorkbench.lines(org, local.id, read_opts())
      assert {:ok, 0} = Reconcile.account_balance(local.id, @repo, line_resource: JournalLine)

      assert {:ok, report} = ReconciliationWorkbench.report(org, read_opts())
      assert report.balanced?
      assert report.org_balance_cents == 0

      rows = Map.new(report.accounts, &{&1.code, &1})
      assert rows["3000"].balance_cents == 0
      assert report.posted_line_count == 0

      assert {:ok, flux} = FluxRead.report(org, 2026, 9, read_opts())
      assert flux.rows == []
    end
  end

  describe "FluxRead.report/4" do
    test "compares the requested month with the prior month and excludes drafts and other periods",
         %{org: org, scope: scope} do
      cash = account!(scope, org, "1000", "Cash", :asset, :debit)
      revenue = account!(scope, org, "4000", "Revenue", :income, :credit)
      expense = account!(scope, org, "6000", "Expense", :expense, :debit)
      _quiet = account!(scope, org, "9000", "Quiet", :asset, :debit)

      posted_entry!(scope, org, ~D[2026-08-10], "August receipt", [
        %{account_id: cash.id, debit_cents: 50_000},
        %{account_id: revenue.id, credit_cents: 50_000}
      ])

      posted_entry!(scope, org, ~D[2026-09-05], "September receipt", [
        %{account_id: cash.id, debit_cents: 100_000},
        %{account_id: revenue.id, credit_cents: 100_000}
      ])

      posted_entry!(scope, org, ~D[2026-09-20], "September spend", [
        %{account_id: expense.id, debit_cents: 40_000},
        %{account_id: cash.id, credit_cents: 40_000}
      ])

      # Neither a draft in the current month nor a posted entry from the next
      # month belongs in September's flux.
      _draft =
        entry!(scope, org, ~D[2026-09-25], "draft", [
          %{account_id: cash.id, debit_cents: 999_000},
          %{account_id: revenue.id, credit_cents: 999_000}
        ])

      posted_entry!(scope, org, ~D[2026-10-01], "October receipt", [
        %{account_id: cash.id, debit_cents: 70_000},
        %{account_id: revenue.id, credit_cents: 70_000}
      ])

      assert {:ok, report} = FluxRead.report(org, 2026, 9, read_opts())
      assert report.period.year == 2026
      assert report.period.month == 9
      assert report.prior_period.year == 2026
      assert report.prior_period.month == 8
      assert report.moved_account_count == 3

      rows = Map.new(report.rows, &{&1.code, &1})

      assert rows["1000"].current_net_cents == 60_000
      assert rows["1000"].prior_net_cents == 50_000
      assert rows["1000"].delta_cents == 10_000
      assert rows["1000"].delta_pct == 20.0
      assert rows["1000"].direction == :up

      assert rows["4000"].current_net_cents == -100_000
      assert rows["4000"].prior_net_cents == -50_000
      assert rows["4000"].delta_cents == -50_000
      assert rows["4000"].delta_pct == -100.0
      assert rows["4000"].direction == :down

      assert rows["6000"].current_net_cents == 40_000
      assert rows["6000"].prior_net_cents == 0
      assert rows["6000"].delta_pct == nil

      refute Map.has_key?(rows, "9000")
      assert Enum.map(report.rows, & &1.code) == ["4000", "6000", "1000"]
      assert {:error, :bad_period} = FluxRead.report(org, 2026, 13, read_opts())
    end
  end
end
