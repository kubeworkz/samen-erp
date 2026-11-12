defmodule Samen.FinanceCrossOrgReadGuardsTest do
  @moduledoc """
  Cross-org regression coverage for Finance reads whose SQL joins journal lines
  to their entries.

  Every fixture below forces a line in at the exact line/entry boundary: either
  the line's `org_id` disagrees with its entry, or the entry belongs to another
  org. The read must ignore the row. These are load-bearing tests: without the
  same-org predicate the foreign amount enters the asserted total, so the test
  fails instead of silently accepting a tenant leak.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.{
    BalanceSheet,
    BudgetVsActual,
    DimensionReconcile,
    GrantCompliance,
    IncurredCost,
    ProfitLoss,
    RecognitionRun,
    ReconcilePayments,
    ReconcileRecognition
  }

  alias SamenCore.Support.FinanceFixture.{
    Account,
    Budget,
    BudgetLine,
    CostObject,
    Grant,
    GrantClaim,
    JournalEntry,
    JournalLine,
    PostingAccount,
    RevenueRecognition,
    RevenueSchedule
  }

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)

    org = Ash.UUID.generate()
    foreign = Ash.UUID.generate()

    %{
      org: org,
      foreign: foreign,
      scope: tenant_scope(org),
      admin: admin_scope(org),
      foreign_scope: tenant_scope(foreign)
    }
  end

  describe "DimensionReconcile" do
    test "a local line pointing at a foreign posted entry cannot move a cost object", %{
      org: org,
      foreign: foreign,
      scope: scope,
      admin: admin,
      foreign_scope: foreign_scope
    } do
      project = cost_object!(admin, org, "CX-PROJECT", :project)
      wip = account!(scope, org, "1200", :asset, :debit)
      cash = account!(scope, org, "1000", :asset, :debit)
      refs = %{"project" => project.id}

      # The local control: the project's two legs net to zero.
      _local_entry =
        post_entry!(scope, org, ~D[2026-10-15], [
          %{account_id: wip.id, debit_cents: 500, credit_cents: 0, dimension_refs: refs},
          %{account_id: cash.id, debit_cents: 0, credit_cents: 500, dimension_refs: refs}
        ])

      foreign_cash = account!(foreign_scope, foreign, "1000", :asset, :debit)
      foreign_income = account!(foreign_scope, foreign, "4000", :income, :credit)

      foreign_entry =
        post_entry!(foreign_scope, foreign, ~D[2026-10-16], [
          %{account_id: foreign_cash.id, debit_cents: 777_000, credit_cents: 0},
          %{account_id: foreign_income.id, debit_cents: 0, credit_cents: 777_000}
        ])

      # The line is local and carries the local project dimension, but its entry
      # is foreign. The old id-only join would count it as local activity.
      raw_line!(org, foreign_entry.id, wip.id, 777_000, 0, dimension_refs: refs)

      assert {:ok, [row]} =
               DimensionReconcile.balances(org, @repo, line_resource: JournalLine)

      assert row.cost_object_id == project.id
      assert row.debit_cents == 500
      assert row.credit_cents == 500
      assert row.balance_cents == 0
      assert {:ok, true} = DimensionReconcile.balanced?(org, @repo, line_resource: JournalLine)
    end
  end

  describe "BudgetVsActual" do
    test "a local budget line backed by a foreign posted entry reads zero actual", %{
      org: org,
      foreign: foreign,
      scope: scope,
      admin: admin,
      foreign_scope: foreign_scope
    } do
      expense = account!(scope, org, "6000", :expense, :debit)
      year = 2026

      budget =
        Budget
        |> Ash.Changeset.for_create(:create, %{
          org_id: org,
          name: "CX-BUDGET",
          period: year,
          lines: [%{account_id: expense.id, planned_cents: 100_000}]
        })
        |> Ash.create!(scope: admin)

      foreign_expense = account!(foreign_scope, foreign, "6000", :expense, :debit)
      foreign_cash = account!(foreign_scope, foreign, "1000", :asset, :debit)

      foreign_entry =
        post_entry!(foreign_scope, foreign, ~D[2026-03-15], [
          %{account_id: foreign_expense.id, debit_cents: 777_000, credit_cents: 0},
          %{account_id: foreign_cash.id, debit_cents: 0, credit_cents: 777_000}
        ])

      # The line belongs to the local org and points at its local expense
      # account; only the entry is foreign. An id-only entry join would count
      # the 777,000 as local actual.
      raw_line!(org, foreign_entry.id, expense.id, 777_000, 0)

      assert {:ok, [row]} =
               BudgetVsActual.read(org, budget, @repo,
                 budget_line_resource: BudgetLine,
                 journal_line_resource: JournalLine,
                 account_resource: Account
               )

      assert row.account_code == "6000"
      assert row.actual_cents == 0
      assert row.variance_cents == -100_000
    end
  end

  describe "grants and incurred cost" do
    test "foreign-owned fund lines do not enter GrantCompliance or IncurredCost", %{
      org: org,
      foreign: foreign,
      scope: scope,
      admin: admin
    } do
      cash = account!(scope, org, "1000", :asset, :debit)
      income = account!(scope, org, "4000", :income, :credit)
      expense = account!(scope, org, "5000", :expense, :debit)
      fund = cost_object!(admin, org, "CX-FUND", :fund)
      grant = grant!(admin, org, fund)

      # A local posted entry gives both reads a valid local row to start from.
      local_entry =
        post_entry!(scope, org, ~D[2026-01-15], [
          %{account_id: cash.id, debit_cents: 10_000, credit_cents: 0},
          %{account_id: income.id, debit_cents: 0, credit_cents: 10_000}
        ])

      # Both lines are on the local entry and the local accounts, but their own
      # org is foreign. GrantCompliance filters only the entry org and
      # IncurredCost filters only the entry org, so the same-org line join is
      # the guard that keeps these 777k/888k amounts out.
      refs = %{"fund" => fund.id}
      raw_line!(foreign, local_entry.id, income.id, 0, 777_000, dimension_refs: refs)
      raw_line!(foreign, local_entry.id, expense.id, 888_000, 0, dimension_refs: refs)

      assert {:ok, 0} =
               IncurredCost.for_period(org, {2026, 1}, fund.id, @repo,
                 entry_resource: JournalEntry,
                 line_resource: JournalLine,
                 account_resource: Account
               )

      statement =
        GrantCompliance.statement(grant, @repo,
          entry: JournalEntry,
          line: JournalLine,
          account: Account,
          recognition: RevenueRecognition,
          claim: GrantClaim,
          posting_account: PostingAccount
        )

      assert statement.fund_income_cents == 0
      assert statement.incurred_cents == 0
      assert statement.recognized_cents == 0
      assert statement.issues == []
      assert statement.balanced?
    end
  end

  describe "ReconcilePayments" do
    test "a foreign-owned line on a local payment entry does not inflate posted cash", %{
      org: org,
      foreign: foreign,
      scope: scope
    } do
      cash = account!(scope, org, "1000", :asset, :debit)
      ar = account!(scope, org, "1200", :asset, :debit)

      local_entry =
        post_entry!(
          scope,
          org,
          ~D[2026-09-05],
          [
            %{account_id: cash.id, debit_cents: 10_000, credit_cents: 0},
            %{account_id: ar.id, debit_cents: 0, credit_cents: 10_000}
          ],
          %{
            source_key: "billing_payment",
            source_id: Ash.UUID.generate(),
            memo: "local payment"
          }
        )

      # The old read filtered only `entry.org_id`; this line is foreign-owned but
      # points at the local posted entry and local cash account.
      raw_line!(foreign, local_entry.id, cash.id, 777_000, 0)

      assert {:ok, 10_000} =
               ReconcilePayments.posted_cash_total(org, @repo,
                 entry_resource: JournalEntry,
                 line_resource: JournalLine
               )
    end
  end

  describe "ReconcileRecognition" do
    test "a foreign-owned line on a local recognition entry cannot inflate released revenue", %{
      org: org,
      foreign: foreign,
      scope: scope,
      admin: admin
    } do
      prev = Application.get_env(:samen_core, RecognitionRun)

      Application.put_env(:samen_core, RecognitionRun,
        modules: [
          schedule: RevenueSchedule,
          recognition: RevenueRecognition,
          entry: JournalEntry,
          line: JournalLine,
          account: Account
        ]
      )

      on_exit(fn ->
        if prev do
          Application.put_env(:samen_core, RecognitionRun, prev)
        else
          Application.delete_env(:samen_core, RecognitionRun)
        end
      end)

      income = account!(scope, org, "4000", :income, :credit)
      deferred = account!(scope, org, "2200", :liability, :credit)
      posting_account!(admin, org, :income, income)
      posting_account!(admin, org, :deferred_revenue, deferred)

      schedule =
        RevenueSchedule
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: org,
            start_on: ~D[2026-01-01],
            months: 12,
            total_cents: 12_000,
            method: :straight_line
          },
          scope: admin
        )
        |> Ash.create!()

      assert {:ok, %{posted: [_]}} = RecognitionRun.run(period: {2026, 1})

      recognition =
        RevenueRecognition
        |> Ash.Query.filter(schedule_id == ^schedule.id and period_key == "2026-01")
        |> Ash.read_one!(scope: scope)

      entry =
        JournalEntry
        |> Ash.Query.filter(source_key == "revenue_recognition" and source_id == ^recognition.id)
        |> Ash.read_one!(authorize?: false)

      # The recognition entry is local and posted. The raw line is owned by
      # another org but targets the local deferred account; the old read had no
      # `line.org_id = schedule.org_id` predicate and would count all 777,000
      # as released revenue.
      raw_line!(foreign, entry.id, deferred.id, 777_000, 0)

      opts = [
        schedule_resource: RevenueSchedule,
        recognition_resource: RevenueRecognition,
        entry_resource: JournalEntry,
        line_resource: JournalLine,
        posting_account_resource: PostingAccount
      ]

      assert {:ok, [state]} = ReconcileRecognition.schedule_states(org, @repo, opts)
      assert state.schedule_id == schedule.id
      assert state.recognized_cents == 1_000
      assert state.released_cents == 1_000
      assert state.remaining_cents == 11_000
      assert state.reconciled?
      assert {:ok, true} = ReconcileRecognition.reconciled?(org, @repo, opts)
    end
  end

  describe "BalanceSheet and ProfitLoss" do
    test "foreign lines and foreign entries stay out of the statements", %{
      org: org,
      foreign: foreign,
      scope: scope,
      foreign_scope: foreign_scope
    } do
      cash = account!(scope, org, "1000", :asset, :debit)
      income = account!(scope, org, "4000", :income, :credit)
      expense = account!(scope, org, "6000", :expense, :debit)

      today = Date.utc_today()
      period_from = DateTime.new!(Date.new!(today.year, 1, 1), ~T[00:00:00], "Etc/UTC")
      as_of = DateTime.new!(today, ~T[23:59:59], "Etc/UTC")

      local_entry =
        post_entry!(scope, org, today, [
          %{account_id: cash.id, debit_cents: 10_000, credit_cents: 0},
          %{account_id: income.id, debit_cents: 0, credit_cents: 10_000}
        ])

      foreign_expense = account!(foreign_scope, foreign, "6000", :expense, :debit)
      foreign_cash = account!(foreign_scope, foreign, "1000", :asset, :debit)

      foreign_entry =
        post_entry!(foreign_scope, foreign, today, [
          %{account_id: foreign_expense.id, debit_cents: 777_000, credit_cents: 0},
          %{account_id: foreign_cash.id, debit_cents: 0, credit_cents: 777_000}
        ])

      # Direction 1: a local line pointed at a foreign posted entry. Without the
      # entry-org predicate in the `IN (SELECT ...)` subquery, this expense
      # enters net income.
      raw_line!(org, foreign_entry.id, expense.id, 777_000, 0)

      # Direction 2: a foreign-owned line pointed at the local posted entry.
      # Without the line-org predicate, this expense enters both statements.
      raw_line!(foreign, local_entry.id, expense.id, 888_000, 0)

      balance_sheet =
        BalanceSheet.generate(org, as_of,
          repo: @repo,
          account_resource: Account,
          line_resource: JournalLine,
          entry_resource: JournalEntry
        )
        |> elem(1)

      assert Enum.find(balance_sheet.assets, &(&1.code == "1000")).balance == 10_000
      assert balance_sheet.net_income == 10_000
      assert balance_sheet.total_assets == 10_000
      assert balance_sheet.total_equity == 10_000
      assert balance_sheet.balanced

      profit_loss =
        ProfitLoss.generate(org, period_from, as_of,
          repo: @repo,
          account_resource: Account,
          line_resource: JournalLine,
          entry_resource: JournalEntry
        )
        |> elem(1)

      assert Enum.find(profit_loss.revenue, &(&1.code == "4000")).balance == -10_000
      assert Enum.find(profit_loss.expenses, &(&1.code == "6000")).balance == 0
      assert profit_loss.total_revenue == 10_000
      assert profit_loss.total_expenses == 0
      assert profit_loss.net_income == 10_000
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp tenant_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, kind: :tenant, plane: :tenant}
    }
  end

  defp admin_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "a:#{org_id}", org_id: org_id, role: :admin, kind: :tenant, plane: :tenant}
    }
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

  defp cost_object!(admin, org, code, kind) do
    CostObject
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, code: code, name: "Cost object #{code}", kind: kind},
      scope: admin
    )
    |> Ash.create!()
  end

  defp posting_account!(admin, org, key, account) do
    PostingAccount
    |> Ash.Changeset.for_create(:create, %{org_id: org, key: key, account_id: account.id},
      scope: admin
    )
    |> Ash.create!()
  end

  defp grant!(admin, org, fund) do
    Grant
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        funder: "NSERC",
        program: "Alliance",
        award_ref: "CX-#{System.unique_integer([:positive])}",
        award_cents: 120_000,
        period_start: ~D[2026-01-01],
        period_end: ~D[2026-12-31],
        fund_cost_object_id: fund.id
      },
      scope: admin
    )
    |> Ash.create!()
  end

  defp post_entry!(scope, org, date, lines, extra \\ %{}) do
    attrs =
      Map.merge(
        %{org_id: org, entry_date: date, memo: "cross-org fixture", lines: lines},
        extra
      )

    JournalEntry
    |> Ash.Changeset.for_create(:create, attrs, scope: scope)
    |> Ash.create!()
    |> Ash.Changeset.for_update(:post, %{}, scope: scope)
    |> Ash.update!()
  end

  # Insert a line below Ash at the exact compromised shape. The posted-entry
  # trigger requires the PostGuard marker, so arm it for the insert and clear it
  # immediately afterward.
  defp raw_line!(org_id, entry_id, account_id, debit, credit, opts \\ []) do
    @repo.query!("SELECT set_config('samen.finance_posting', 'on', true)", [])

    try do
      @repo.query!(
        """
        INSERT INTO sjl_journal_line
          (sjl_org_id, sjl_entry_id, sjl_account_id, sjl_debit_cents, sjl_credit_cents,
           sjl_memo, sjl_dimension_refs, sjl_inserted_at, sjl_updated_at)
        VALUES ($1, $2, $3, $4, $5, $6, $7::jsonb, now(), now())
        """,
        [
          dump_uuid(org_id),
          dump_uuid(entry_id),
          dump_uuid(account_id),
          debit,
          credit,
          "raw cross-org line",
          Keyword.get(opts, :dimension_refs, %{})
        ]
      )
    after
      @repo.query!("SELECT set_config('samen.finance_posting', 'off', true)", [])
    end
  end

  defp dump_uuid(value), do: Ecto.UUID.dump!(value)
end
