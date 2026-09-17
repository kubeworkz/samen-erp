defmodule Samen.E8ReportsTest do
  @moduledoc """
  WS-ERP E8 — the BI/reports suite (design §6.2 + build-plan E8):

    * b1 Budget/BudgetLine CRUD: Tier-0 config (member RED / admin CONTROL),
      the line-shape guard (negative planned refused, same-account dup
      refused), the in-transaction line materialization (a bad line rolls
      back the WHOLE create — no line-less budgets).
    * b2 budget-vs-actual: the PURE READ (posted activity within the budget's
      year, signed toward the account's normal side; drafts never count;
      planned 0 never divides). Anti-tautology: the same plan over a NOISY
      ledger reads a DIFFERENT actual — the numbers come from the ledger.
    * r9 the rollup registrations: trial-balance / WIP / headcount rollup
      tables materialize through the SHIPPED `Samen.Rollup.refresh/2` (no new
      machinery) and every column is oracle-clean (bounded columns only).
    * x1 cross-tenant portfolio views: the ERP-shaped cross-tenant projection
      rides `Samen.Aggregate.read_all/2` under the token-blind
      `operator_aggregate` actor — a cohort UNDER the k-anon floor renders
      `%Suppressed{}` (the design §6.2 clause: "a department, product line,
      or warehouse cohort under floor renders `%Suppressed{}`"), a cohort AT
      or ABOVE floor releases, and a non-aggregate actor is refused at the
      policy (default-deny, no fallthrough).
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Aggregate
  alias Samen.Aggregate.Suppressed
  alias Samen.Scopes.Finance.BudgetVsActual
  alias SamenCore.Support.FinanceFixture.{Account, Budget, BudgetLine, JournalEntry}
  alias SamenCore.Support.InventoryFixture.{Item, StockLedger, Warehouse}
  alias SamenCore.Support.HrFixture.{Employee, EmploymentEvent}

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()
    {:ok, org: org, scope: tenant_scope(org), admin: admin_scope(org)}
  end

  # ── b1: Budget/BudgetLine CRUD ──────────────────────────────────────────────

  describe "b1 — Budget/BudgetLine (the Tier-0 plan)" do
    test "a member is REFUSED (admin-gated config); an admin creates with lines", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      expense = seed_account(scope, org, "6000", :expense, :debit)

      assert {:error, %Ash.Error.Forbidden{}} =
               Budget
               |> Ash.Changeset.for_create(:create, %{
                 org_id: org,
                 name: "FY2027",
                 period: 2027
               })
               |> Ash.create(scope: scope, authorize?: true)

      assert {:ok, budget} =
               Budget
               |> Ash.Changeset.for_create(:create, %{
                 org_id: org,
                 name: "FY2027",
                 period: 2027,
                 lines: [
                   %{account_id: expense.id, planned_cents: 100_000_00}
                 ]
               })
               |> Ash.create(scope: admin, authorize?: true)

      # The lines materialized in-transaction (the BudgetLinesWriter cascade).
      {:ok, [line]} =
        BudgetLine
        |> Ash.Query.filter(budget_id == ^budget.id)
        |> Ash.read(scope: admin, authorize?: true)

      assert line.planned_cents == 100_000_00
      assert line.account_id == expense.id
    end

    test "a NEGATIVE planned amount is refused; a same-account dup is refused", %{
      org: org,
      admin: admin
    } do
      expense = seed_account(admin, org, "6100", :expense, :debit)

      assert {:error, _} =
               Budget
               |> Ash.Changeset.for_create(:create, %{
                 org_id: org,
                 name: "NEG",
                 period: 2027,
                 lines: [%{account_id: expense.id, planned_cents: -1}]
               })
               |> Ash.create(scope: admin, authorize?: true)

      assert {:ok, _} =
               Budget
               |> Ash.Changeset.for_create(:create, %{
                 org_id: org,
                 name: "DUPBASE",
                 period: 2027,
                 lines: [%{account_id: expense.id, planned_cents: 1_00}]
               })
               |> Ash.create(scope: admin, authorize?: true)

      assert {:error, _} =
               Budget
               |> Ash.Changeset.for_create(:create, %{
                 org_id: org,
                 name: "DUP",
                 period: 2027,
                 lines: [
                   %{account_id: expense.id, planned_cents: 1_00},
                   %{account_id: expense.id, planned_cents: 2_00}
                 ]
               })
               |> Ash.create(scope: admin, authorize?: true)
    end

    test "a bad line rolls back the WHOLE budget create (no line-less budget)", %{
      org: org,
      admin: admin
    } do
      missing_account = Ash.UUID.generate()

      assert {:error, _} =
               Budget
               |> Ash.Changeset.for_create(:create, %{
                 org_id: org,
                 name: "ROLLBACK",
                 period: 2027,
                 lines: [%{account_id: missing_account, planned_cents: 5_00}]
               })
               |> Ash.create(scope: admin, authorize?: true)

      # The header did NOT survive (the create rolled back with its lines).
      assert {:ok, []} =
               Budget
               |> Ash.Query.filter(name == "ROLLBACK")
               |> Ash.read(scope: admin, authorize?: true)
    end
  end

  # ── b2: budget-vs-actual — the pure read ────────────────────────────────────

  describe "b2 — budget-vs-actual (the pure read)" do
    test "planned vs posted actual: expense over plan, income under plan, drafts never count",
         %{org: org, scope: scope, admin: admin} do
      expense = seed_account(scope, org, "6000", :expense, :debit)
      income = seed_account(scope, org, "4000", :income, :credit)
      cash = seed_account(scope, org, "1000", :asset, :debit)

      {:ok, budget} =
        Budget
        |> Ash.Changeset.for_create(:create, %{
          org_id: org,
          name: "FY2026",
          period: 2026,
          lines: [
            %{account_id: expense.id, planned_cents: 80_000_00},
            %{account_id: income.id, planned_cents: 120_000_00}
          ]
        })
        |> Ash.create(scope: admin, authorize?: true)

      # Posted activity IN 2026: expense 90m (over plan), income 100m (under).
      post!(scope, org, ~D[2026-03-15], [
        {cash, 0, 90_000_00},
        {expense, 90_000_00, 0}
      ])

      post!(scope, org, ~D[2026-05-01], [
        {cash, 100_000_00, 0},
        {income, 0, 100_000_00}
      ])

      # A DRAFT in 2026 must never count.
      draft!(scope, org, ~D[2026-06-01], [
        {cash, 0, 5_000_00},
        {expense, 5_000_00, 0}
      ])

      assert {:ok, rows} =
               BudgetVsActual.read(org, budget, @repo,
                 budget_line_resource: BudgetLine,
                 journal_line_resource: SamenCore.Support.FinanceFixture.JournalLine,
                 account_resource: Account
               )

      by_code = Map.new(rows, &{&1.account_code, &1})

      # Expense (debit-normal): actual = Σ debits − Σ credits = +90m → +10m over.
      exp = by_code["6000"]
      assert exp.planned_cents == 80_000_00
      assert exp.actual_cents == 90_000_00
      assert exp.variance_cents == 10_000_00
      assert exp.pct == 12.5

      # Income (credit-normal): actual = Σ credits − Σ debits = +100m → −20m under.
      inc = by_code["4000"]
      assert inc.actual_cents == 100_000_00
      assert inc.variance_cents == -20_000_00
      assert inc.pct == -16.67

      # The draft's 5m never entered ANY row.
      assert exp.actual_cents == 90_000_00
    end

    test "activity OUTSIDE the budget's year does not count; planned 0 never divides", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      expense = seed_account(scope, org, "6200", :expense, :debit)
      cash = seed_account(scope, org, "1000", :asset, :debit)

      {:ok, budget} =
        Budget
        |> Ash.Changeset.for_create(:create, %{
          org_id: org,
          name: "FY2027",
          period: 2027,
          lines: [%{account_id: expense.id, planned_cents: 0}]
        })
        |> Ash.create(scope: admin, authorize?: true)

      # 2026 activity — the 2027 budget must not see it.
      post!(scope, org, ~D[2026-02-02], [
        {cash, 0, 7_000_00},
        {expense, 7_000_00, 0}
      ])

      assert {:ok, [row]} =
               BudgetVsActual.read(org, budget, @repo,
                 budget_line_resource: BudgetLine,
                 journal_line_resource: SamenCore.Support.FinanceFixture.JournalLine,
                 account_resource: Account
               )

      assert row.actual_cents == 0
      assert row.variance_cents == 0
      assert row.pct == nil
    end

    test "ANTI-TAUTOLOGY: the read is a pure function of the LEDGER (a second posting moves the number)",
         %{org: org, scope: scope, admin: admin} do
      expense = seed_account(scope, org, "6300", :expense, :debit)
      cash = seed_account(scope, org, "1000", :asset, :debit)

      {:ok, budget} =
        Budget
        |> Ash.Changeset.for_create(:create, %{
          org_id: org,
          name: "PURE",
          period: 2026,
          lines: [%{account_id: expense.id, planned_cents: 50_000_00}]
        })
        |> Ash.create(scope: admin, authorize?: true)

      opts = [
        budget_line_resource: BudgetLine,
        journal_line_resource: SamenCore.Support.FinanceFixture.JournalLine,
        account_resource: Account
      ]

      assert {:ok, [row0]} = BudgetVsActual.read(org, budget, @repo, opts)
      assert row0.actual_cents == 0

      post!(scope, org, ~D[2026-04-04], [
        {cash, 0, 30_000_00},
        {expense, 30_000_00, 0}
      ])

      assert {:ok, [row1]} = BudgetVsActual.read(org, budget, @repo, opts)
      assert row1.actual_cents == 30_000_00
      assert row1.variance_cents == -20_000_00
    end
  end

  # ── r9: the rollup registrations (TB / WIP / headcount) ─────────────────────

  describe "r9 — the ERP rollups ride the SHIPPED Rollup machinery" do
    test "trial balance / WIP / headcount materialize through Rollup.refresh/2", %{
      org: org,
      scope: scope
    } do
      seed_tb_ledger(scope, org)
      seed_wip_stock(scope, org)
      seed_headcount(scope, org)

      specs = [
        Samen.E8Rollups.trial_balance_spec(),
        Samen.E8Rollups.wip_spec(),
        Samen.E8Rollups.headcount_spec()
      ]

      for spec <- specs do
        assert {:ok, n} = Samen.Rollup.refresh(@repo, spec)
        assert n > 0, "rollup #{spec.name} materialized 0 rows"
      end

      # TB: per-account posted sums (the audit trial balance, credit-normal
      # accounts signed negative).
      {:ok, %{rows: tb_rows}} =
        @repo.query("SELECT ser_account_code, ser_debit_cents, ser_credit_cents, ser_balance_cents
                     FROM ser_trial_balance ORDER BY ser_account_code")

      assert [cash_row] = Enum.filter(tb_rows, fn [code | _] -> code == "1000" end)
      assert ["1000", d, 0, bal] = cash_row
      assert d > 0 and bal == d

      # WIP: per-(org, item, warehouse) on-hand + value from the ledger.
      {:ok, %{rows: [[wip_qty, wip_value]]}} =
        @repo.query("SELECT SUM(spw_on_hand)::bigint, SUM(spw_value_cents)::bigint FROM spw_wip_stock")

      assert wip_qty == 25
      assert wip_value == 250_00

      # Headcount: per-org derived employment facts (the bounded ledger —
      # the PII erasure story: the vault shreds, the headcount survives).
      {:ok, %{rows: [[headcount]]}} =
        @repo.query("SELECT shc_headcount FROM shc_headcount_by_org WHERE shc_org_id = $1", [
          Ecto.UUID.dump!(org)
        ])

      assert headcount == 3
    end

    test "every E8 rollup spec passes the shipped fail-closed validation" do
      for spec <- [
            Samen.E8Rollups.trial_balance_spec(),
            Samen.E8Rollups.wip_spec(),
            Samen.E8Rollups.headcount_spec()
          ] do
        # from_config/1 validates fail-closed (raises on a malformed spec).
        assert %Samen.Rollup.Spec{} = Samen.Rollup.Spec.from_config(spec)
        assert spec.source == :domain
        assert spec.table != nil
      end
    end
  end

  # ── x1: the cross-tenant portfolio view + the k-anon floor ─────────────────

  describe "x1 — cross-tenant views ride operator_aggregate + CohortSpec floors" do
    test "a cohort UNDER the k floor renders %Suppressed{}; AT/above floor releases", %{org: org} do
      seed_portfolio(org, "software", 9, 480_000_00)
      seed_portfolio(org, "one-shop", 1, 12_345_00)

      # The token-blind aggregate actor (operator_aggregate) — the ONLY
      # admissible reader of the cross-tenant plane.
      assert {:ok, rows} = Aggregate.read_all(Samen.E8Aggregate.PortfolioByIndustry)

      by_key = Map.new(rows, &{&1.industry, &1})

      # AT/above floor: releases.
      big = by_key["software"]
      refute match?(%Suppressed{}, big.revenue_cents)
      assert big.revenue_cents == 480_000_00

      # UNDER floor: the design §6.2 clause — renders %Suppressed{}, never the
      # single-tenant's exact revenue.
      small = by_key["one-shop"]
      assert match?(%Suppressed{}, small.revenue_cents)
      assert to_string(small.revenue_cents) == "⊘"
    end

    test "the aggregate plane is DEFAULT-DENY: a tenant actor is refused", %{scope: scope} do
      assert {:error, _} =
               Ash.read(Samen.E8Aggregate.PortfolioByIndustry, actor: scope.actor, authorize?: true)
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

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

  defp seed_account(scope, org, code, kind, side) do
    Account
    |> Ash.Changeset.for_create(:create, %{
      org_id: org,
      code: code,
      name: "Account #{code}",
      kind: kind,
      normal_side: side
    })
    |> Ash.create!(scope: scope, authorize?: true)
  end

  defp post!(scope, org, date, lines) do
    entry =
      JournalEntry
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org,
          entry_date: date,
          lines:
            Enum.map(lines, fn {account, debit, credit} ->
              %{account_id: account.id, debit_cents: debit, credit_cents: credit}
            end)
        },
        scope: scope
      )
      |> Ash.create!()

    entry
    |> Ash.Changeset.for_update(:post, %{}, scope: scope)
    |> Ash.update!()
  end

  defp draft!(scope, org, date, lines) do
    JournalEntry
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        entry_date: date,
        lines:
          Enum.map(lines, fn {account, debit, credit} ->
            %{account_id: account.id, debit_cents: debit, credit_cents: credit}
          end)
      },
      scope: scope
    )
    |> Ash.create!()
  end

  # A tiny balanced TB seed: cash 100m (debit) vs income 100m (credit).
  defp seed_tb_ledger(scope, org) do
    cash = seed_account(scope, org, "1000", :asset, :debit)
    income = seed_account(scope, org, "4000", :income, :credit)

    post!(scope, org, ~D[2026-08-01], [
      {cash, 100_000_00, 0},
      {income, 0, 100_000_00}
    ])
  end

  # WIP seed: one item at one warehouse, +30 then −5 (net 25 on hand,
  # moving-average 1000c/unit → 250_00 value).
  defp seed_wip_stock(scope, org) do
    item =
      Item
      |> Ash.Changeset.for_create(:create, %{
        org_id: org,
        sku: "WIP-1",
        name: "WIP Item",
        kind: :stocked,
        uom: :unit
      })
      |> Ash.create!(scope: scope, authorize?: true)

    wh =
      Warehouse
      |> Ash.Changeset.for_create(:create, %{org_id: org, code: "MAIN", name: "Main"})
      |> Ash.create!(scope: scope, authorize?: true)

    for {kind, qty} <- [receipt: 30, sale: -5] do
      StockLedger
      |> Ash.Changeset.for_create(:record, %{
        org_id: org,
        item_id: item.id,
        warehouse_id: wh.id,
        kind: kind,
        qty: qty,
        unit_cost_cents: 1_000
      })
      |> Ash.create!(scope: scope, authorize?: true)
    end

    {item, wh}
  end

  # Headcount seed: three employees (each born with its :hired ledger row).
  defp seed_headcount(scope, org) do
    for i <- 1..3 do
      Employee
      |> Ash.Changeset.for_create(:create, %{
        org_id: org,
        employee_number: "HC-#{i}",
        hired_at: ~D[2026-01-05],
        full_name: %Samen.Type.FullName{first: "Worker", last: "#{i}"},
        work_emails: [%{label: "work", address: "hc#{i}@example.test"}]
      })
      |> Ash.create!(scope: scope, authorize?: true)
    end

    {:ok, events} =
      EmploymentEvent |> Ash.read(scope: scope, authorize?: true)

    assert length(events) >= 3
  end

  # Portfolio seed (raw SQL — the projection is read-only; rows arrive from a
  # rollup refresh in production).
  defp seed_portfolio(org, industry, tenant_count, revenue) do
    Ecto.Adapters.SQL.query!(
      @repo,
      "INSERT INTO sea_portfolio_by_industry (sea_org_id, sea_industry, sea_tenant_count, sea_revenue_cents) " <>
        "VALUES ($1, $2, $3, $4)",
      [Ecto.UUID.dump!(org), industry, tenant_count, revenue]
    )
  end
end
