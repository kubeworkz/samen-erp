defmodule Samen.FinanceGrantsTest do
  @moduledoc """
  WS-ACCT Phase 11 (ADR-054 D8, R11) — grants and restricted funds, mounted via
  `test/support/finance_fixture.ex`.

  Every refusal is paired with a positive control (`Samen.RedPath` discipline):

    * the grant document's shape guards (period, award floor, same-org fund of
      kind `:fund`) refuse before a row exists;
    * `:receive_award` posts Dr cash / Cr `grant_deferred`, BOTH lines
      dimensioned to the fund, and a second receipt is refused;
    * `:open_recognition` creates the `:cost_incurred` schedule once, with
      `deferred_key: :grant_deferred` and the fund as its cost object;
    * the recognition never runs ahead of incurred allowable cost (a period
      with no cost recognizes ZERO), and each recognition entry carries the
      fund dimension;
    * R11 is derived, not stored: recognized == fund income, approved claims
      == recognized, recognized <= incurred; a submitted claim does not count,
      and a raw recognition row with no GL leg is DETECTED (the anti-tautology
      leg);
    * the personnel report resolves the opaque HR id on the caller's plane —
      tenant clear, operator `••••` — and never leaks a `vt_*` token.
  """

  use ExUnit.Case, async: false
  use Samen.MaskingCase

  require Ash.Query

  alias Samen.Scopes.Finance.{
    GrantAwardPosting,
    GrantCompliance,
    GrantReconcile,
    RecognitionRun
  }

  alias SamenCore.Support.FinanceFixture.{
    Account,
    Budget,
    CostObject,
    FiscalPeriod,
    Grant,
    GrantClaim,
    GrantMilestone,
    GrantOpportunity,
    GrantPersonnel,
    JournalEntry,
    JournalLine,
    PostingAccount,
    RevenueRecognition,
    RevenueSchedule
  }

  alias SamenCore.Support.HrFixture.Employee

  @repo SamenCore.TestRepo
  @plain_first "Grant"
  @plain_last "Person"

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()
    other = Ash.UUID.generate()

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

    %{
      org: org,
      other: other,
      admin: admin_scope(org),
      tenant: tenant_scope(org),
      other_admin: admin_scope(other)
    }
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp tenant_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, kind: :tenant, plane: :tenant}
    }
  end

  defp admin_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :admin, kind: :tenant, plane: :tenant}
    }
  end

  defp operator_scope, do: %Samen.Scope{actor: plane_actor(:operator)}

  defp new_account(scope, org, code, kind, side) do
    Account
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, code: code, name: "Account #{code}", kind: kind, normal_side: side},
      scope: scope
    )
    |> Ash.create!()
  end

  defp new_posting_account(admin, org, key, account) do
    PostingAccount
    |> Ash.Changeset.for_create(:create, %{org_id: org, key: key, account_id: account.id},
      scope: admin
    )
    |> Ash.create!()
  end

  defp new_cost_object!(admin, org, code, kind \\ :fund) do
    CostObject
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, code: code, name: "Cost object #{code}", kind: kind},
      scope: admin
    )
    |> Ash.create!()
  end

  defp books!(admin, org) do
    cash = new_account(admin, org, "1000", :asset, :debit)
    deferred = new_account(admin, org, "2210", :liability, :credit)
    income = new_account(admin, org, "4000", :income, :credit)
    expense = new_account(admin, org, "5000", :expense, :debit)
    liability = new_account(admin, org, "2100", :liability, :credit)

    new_posting_account(admin, org, :cash, cash)
    new_posting_account(admin, org, :grant_deferred, deferred)
    new_posting_account(admin, org, :income, income)

    %{
      cash: cash,
      deferred: deferred,
      income: income,
      expense: expense,
      liability: liability
    }
  end

  defp grant_attrs(org, fund, attrs) do
    Map.merge(
      %{
        org_id: org,
        funder: "NSERC",
        program: "Alliance",
        award_ref: "GR-#{System.unique_integer([:positive])}",
        award_cents: 120_000,
        period_start: ~D[2026-01-01],
        period_end: ~D[2026-12-31],
        fund_cost_object_id: fund.id
      },
      attrs
    )
  end

  defp create_grant(admin, org, fund, attrs \\ %{}) do
    Grant
    |> Ash.Changeset.for_create(:create, grant_attrs(org, fund, attrs), scope: admin)
    |> Ash.create()
  end

  defp new_grant!(admin, org, fund, attrs \\ %{}) do
    Grant
    |> Ash.Changeset.for_create(:create, grant_attrs(org, fund, attrs), scope: admin)
    |> Ash.create!()
  end

  defp receive!(grant, admin) do
    grant
    |> Ash.Changeset.for_update(:receive_award, %{}, scope: admin)
    |> Ash.update!()
  end

  defp open!(grant, admin) do
    grant
    |> Ash.Changeset.for_update(:open_recognition, %{}, scope: admin)
    |> Ash.update!()
  end

  defp expense_entry!(admin, org, books, fund, cents, date \\ ~D[2026-01-15]) do
    entry =
      JournalEntry
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org,
          entry_date: date,
          memo: "allowable grant cost",
          lines: [
            %{
              account_id: books.expense.id,
              debit_cents: cents,
              dimension_refs: %{"fund" => fund.id}
            },
            %{
              account_id: books.liability.id,
              credit_cents: cents,
              dimension_refs: %{"fund" => fund.id}
            }
          ]
        },
        scope: admin
      )
      |> Ash.create!()

    entry
    |> Ash.Changeset.for_update(:post, %{}, scope: admin)
    |> Ash.update!()
  end

  defp recognitions(org, scope) do
    RevenueRecognition
    |> Ash.Query.filter(org_id == ^org)
    |> Ash.read!(scope: scope)
  end

  defp submit_claim!(tenant, org, grant, cents) do
    GrantClaim
    |> Ash.Changeset.for_create(
      :submit,
      %{org_id: org, grant_id: grant.id, claimed_on: ~D[2026-01-20], amount_cents: cents},
      scope: tenant
    )
    |> Ash.create!()
  end

  defp approve_claim!(claim, admin) do
    claim
    |> Ash.Changeset.for_update(:approve, %{}, scope: admin)
    |> Ash.update!()
  end

  defp statement_opts do
    [
      entry: JournalEntry,
      line: JournalLine,
      account: Account,
      recognition: RevenueRecognition,
      claim: GrantClaim,
      posting_account: PostingAccount
    ]
  end

  defp reconcile_opts, do: [grant: Grant] ++ statement_opts()

  defp personnel_opts do
    [
      rows: GrantPersonnel,
      personnel: [resource: Employee, name_attribute: :full_name],
      repo: @repo
    ]
  end

  defp line_on(lines, account) do
    Enum.find(lines, &(&1.account_id == account.id)) ||
      flunk("no line on account #{account.code}")
  end

  # ── shape guards ──────────────────────────────────────────────────────────

  describe "the grant document is guarded before it exists" do
    test "an inverted period is refused", %{org: org, admin: admin} do
      fund = new_cost_object!(admin, org, "FUND-INV")

      assert {:error, error} =
               create_grant(admin, org, fund, %{
                 period_start: ~D[2026-12-01],
                 period_end: ~D[2026-01-01]
               })

      assert Exception.message(error) =~ "period_end must not be before period_start"
    end

    test "an award that cannot fund one cent per month is refused", %{org: org, admin: admin} do
      fund = new_cost_object!(admin, org, "FUND-FLOOR")

      assert {:error, error} = create_grant(admin, org, fund, %{award_cents: 5})
      assert Exception.message(error) =~ "at least the term in months"
    end

    test "the fund must be a same-org CostObject of kind :fund", %{org: org, admin: admin} do
      project = new_cost_object!(admin, org, "PROJ-1", :project)

      assert {:error, error} = create_grant(admin, org, project)
      assert Exception.message(error) =~ "CostObject of kind :fund"

      foreign = new_cost_object!(admin, org, "FUND-OTHER", :fund)

      assert {:error, _} =
               create_grant(admin, Ash.UUID.generate(), foreign)
    end

    test "a budget is reused, never re-declared", %{org: org, admin: admin} do
      fund = new_cost_object!(admin, org, "FUND-BUDGET")

      budget =
        Budget
        |> Ash.Changeset.for_create(:create, %{org_id: org, name: "Grant plan", period: 2026},
          scope: admin
        )
        |> Ash.create!()

      grant = new_grant!(admin, org, fund, %{budget_id: budget.id})
      assert grant.budget_id == budget.id
    end
  end

  # ── the restricted receipt ────────────────────────────────────────────────

  describe "the award receipt" do
    test "posts Dr cash / Cr grant_deferred, both dimensioned to the fund, once", %{
      org: org,
      admin: admin
    } do
      books = books!(admin, org)
      fund = new_cost_object!(admin, org, "FUND-RECEIPT")
      grant = new_grant!(admin, org, fund)

      received = receive!(grant, admin)

      assert received.status == :active
      assert received.received_on == Date.utc_today()

      entry =
        JournalEntry
        |> Ash.Query.filter(
          source_key == ^GrantAwardPosting.source_key() and source_id == ^grant.id
        )
        |> Ash.read_one!(scope: admin)

      assert entry.status == :posted
      lines = entry |> Ash.load!(:lines, authorize?: false) |> Map.fetch!(:lines)

      assert line_on(lines, books.cash).debit_cents == 120_000
      assert line_on(lines, books.deferred).credit_cents == 120_000
      assert line_on(lines, books.cash).dimension_refs == %{"fund" => fund.id}
      assert line_on(lines, books.deferred).dimension_refs == %{"fund" => fund.id}

      assert {:error, error} =
               received
               |> Ash.Changeset.for_update(:receive_award, %{}, scope: admin)
               |> Ash.update()

      assert Exception.message(error) =~ "already been received"
    end

    test "an unmapped grant_deferred meaning refuses fail-honest", %{org: org, admin: admin} do
      fund = new_cost_object!(admin, org, "FUND-UNMAPPED")
      cash = new_account(admin, org, "1000", :asset, :debit)
      new_posting_account(admin, org, :cash, cash)

      grant = new_grant!(admin, org, fund)

      assert {:error, error} =
               grant
               |> Ash.Changeset.for_update(:receive_award, %{}, scope: admin)
               |> Ash.update()

      assert Exception.message(error) =~ "grant_deferred"

      reloaded =
        Grant
        |> Ash.Query.filter(id == ^grant.id)
        |> Ash.read_one!(authorize?: false)

      assert reloaded.received_on == nil
    end
  end

  # ── the recognition schedule ──────────────────────────────────────────────

  describe "the recognition schedule" do
    test "opens once with :cost_incurred, grant_deferred and the fund", %{
      org: org,
      admin: admin
    } do
      fund = new_cost_object!(admin, org, "FUND-SCHEDULE")
      grant = new_grant!(admin, org, fund) |> open!(admin)

      schedule = Ash.get!(RevenueSchedule, grant.schedule_id, authorize?: false)

      assert schedule.method == :cost_incurred
      assert schedule.deferred_key == :grant_deferred
      assert schedule.cost_object_id == fund.id
      assert schedule.total_cents == 120_000
      assert schedule.months == 12
      assert schedule.start_on == ~D[2026-01-01]

      assert {:error, error} =
               grant
               |> Ash.Changeset.for_update(:open_recognition, %{}, scope: admin)
               |> Ash.update()

      assert Exception.message(error) =~ "already has an open recognition schedule"
    end

    test "recognizes incurred cost, never ahead of it, and carries the fund dimension", %{
      org: org,
      admin: admin,
      tenant: tenant
    } do
      books = books!(admin, org)
      fund = new_cost_object!(admin, org, "FUND-RUN")
      grant = new_grant!(admin, org, fund) |> open!(admin) |> receive!(admin)

      expense_entry!(admin, org, books, fund, 10_000)

      assert {:ok, %{posted: [_id]}} = RecognitionRun.run(period: {2026, 1})

      assert [recognition] = recognitions(org, tenant)
      assert recognition.amount_cents == 10_000
      assert recognition.period_key == "2026-01"

      entry =
        JournalEntry
        |> Ash.Query.filter(source_key == "revenue_recognition" and source_id == ^recognition.id)
        |> Ash.read_one!(scope: tenant)

      lines = entry |> Ash.load!(:lines, authorize?: false) |> Map.fetch!(:lines)

      assert line_on(lines, books.deferred).debit_cents == 10_000
      assert line_on(lines, books.income).credit_cents == 10_000
      assert line_on(lines, books.deferred).dimension_refs == %{"fund" => fund.id}
      assert line_on(lines, books.income).dimension_refs == %{"fund" => fund.id}

      # A period with no allowable cost recognizes ZERO — never ahead of cost.
      assert {:ok, %{posted: []}} = RecognitionRun.run(period: {2026, 2})
      assert length(recognitions(org, tenant)) == 1
      assert Ash.get!(RevenueSchedule, grant.schedule_id, authorize?: false)
    end

    test "a CLOSED period refuses the recognition", %{org: org, admin: admin, tenant: tenant} do
      books = books!(admin, org)
      fund = new_cost_object!(admin, org, "FUND-CLOSED")
      _grant = new_grant!(admin, org, fund) |> open!(admin)

      # The allowable cost lands while the period is still open; the close is
      # what the recognition must then respect.
      expense_entry!(admin, org, books, fund, 10_000)

      FiscalPeriod
      |> Ash.Changeset.for_create(:create, %{org_id: org, year: 2026, month: 1}, scope: admin)
      |> Ash.create!()
      |> then(fn period ->
        period
        |> Ash.Changeset.for_update(:soft_close, %{}, scope: admin)
        |> Ash.update!()
        |> Ash.Changeset.for_update(:close, %{}, scope: admin)
        |> Ash.update!()
      end)

      assert {:error, _} = RecognitionRun.run(period: {2026, 1})
      assert recognitions(org, tenant) == []
    end
  end

  # ── R11 ───────────────────────────────────────────────────────────────────

  describe "R11 — grants reconcile with the fund" do
    test "recognized == fund income == approved claims, and never above incurred cost", %{
      org: org,
      admin: admin,
      tenant: tenant
    } do
      books = books!(admin, org)
      fund = new_cost_object!(admin, org, "FUND-R11")
      grant = new_grant!(admin, org, fund) |> open!(admin) |> receive!(admin)

      expense_entry!(admin, org, books, fund, 10_000)
      assert {:ok, %{posted: [_]}} = RecognitionRun.run(period: {2026, 1})

      approved = submit_claim!(tenant, org, grant, 10_000) |> approve_claim!(admin)

      state = GrantCompliance.statement(grant, @repo, statement_opts())

      assert state.grant_id == grant.id
      assert state.award_cents == 120_000
      assert state.received_cents == 120_000
      assert state.recognized_cents == 10_000
      assert state.fund_income_cents == 10_000
      assert state.deferred_cents == 110_000
      assert state.claimed_cents == 10_000
      assert state.incurred_cents == 10_000
      assert state.issues == []
      assert state.balanced?
      assert approved.status == :approved

      assert {:ok, true, []} = GrantReconcile.reconciled?(org, @repo, reconcile_opts())
      assert {:ok, []} = GrantReconcile.divergences(org, @repo, reconcile_opts())
    end

    test "a SUBMITTED claim is a proposal, an APPROVED one is a fact", %{
      org: org,
      admin: admin,
      tenant: tenant
    } do
      books = books!(admin, org)
      fund = new_cost_object!(admin, org, "FUND-CLAIM")
      grant = new_grant!(admin, org, fund) |> open!(admin) |> receive!(admin)

      expense_entry!(admin, org, books, fund, 10_000)
      assert {:ok, %{posted: [_]}} = RecognitionRun.run(period: {2026, 1})

      _approved = submit_claim!(tenant, org, grant, 10_000) |> approve_claim!(admin)
      submitted = submit_claim!(tenant, org, grant, 5_000)

      assert GrantCompliance.statement(grant, @repo, statement_opts()).claimed_cents == 10_000
      assert submitted.status == :submitted

      _approved_too = approve_claim!(submitted, admin)

      assert {:ok, false, [divergence]} =
               GrantReconcile.reconciled?(org, @repo, reconcile_opts())

      assert divergence.grant_id == grant.id
      assert :claim_mismatch in divergence.issues
    end

    test "the anti-tautology leg: a recognition with no GL leg is DETECTED", %{
      org: org,
      admin: admin,
      tenant: tenant
    } do
      books = books!(admin, org)
      fund = new_cost_object!(admin, org, "FUND-ANTI")
      grant = new_grant!(admin, org, fund) |> open!(admin) |> receive!(admin)

      expense_entry!(admin, org, books, fund, 10_000)
      assert {:ok, %{posted: [_]}} = RecognitionRun.run(period: {2026, 1})

      _approved = submit_claim!(tenant, org, grant, 10_000) |> approve_claim!(admin)

      # A raw recognition below the cascade: recognized rises, the GL does not.
      Ecto.Adapters.SQL.query!(
        @repo,
        """
        INSERT INTO frc_revenue_recognition
          (frc_org_id, frc_schedule_id, frc_period_key, frc_amount_cents,
           frc_recognized_on, frc_id, frc_inserted_at, frc_updated_at)
        VALUES ($1, $2, '2026-03', 5_000, '2026-03-31', gen_random_uuid(), now(), now())
        """,
        [Ecto.UUID.dump!(org), Ecto.UUID.dump!(grant.schedule_id)]
      )

      assert {:ok, false, [divergence]} =
               GrantReconcile.reconciled?(org, @repo, reconcile_opts())

      assert divergence.recognized_cents == 15_000
      assert divergence.fund_income_cents == 10_000
      assert :fund_income_mismatch in divergence.issues
    end
  end

  # ── the personnel report ──────────────────────────────────────────────────

  describe "the personnel report" do
    test "resolves the opaque employee id on the caller's plane", %{
      org: org,
      admin: admin,
      tenant: tenant
    } do
      fund = new_cost_object!(admin, org, "FUND-PEOPLE")
      grant = new_grant!(admin, org, fund)

      employee = new_employee!(admin, org, "G-001")

      GrantPersonnel
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org,
          grant_id: grant.id,
          employee_id: employee.id,
          effort_pct: 50,
          effective_on: ~D[2026-01-01]
        },
        scope: admin
      )
      |> Ash.create!()

      assert {:ok, [row]} = GrantCompliance.personnel(grant, tenant, personnel_opts())
      assert row.effort_pct == 50

      tenant_name = row.name
      assert is_binary(tenant_name)
      assert Jason.decode!(tenant_name) == %{"first" => @plain_first, "last" => @plain_last}
      refute to_string(tenant_name) =~ "vt_"

      assert {:ok, [operator_row]} =
               GrantCompliance.personnel(grant, operator_scope(), personnel_opts())

      assert_plane_masked!(operator_row.name, tenant_name)
      assert_two_plane!(tenant_name, operator_row.name, tenant_name)

      # The sabotage twin: the same scan that passes the masked render catches
      # a leaked one — the mask assertion is refutable, not vacuous.
      assert_leak_detected!("name: #{tenant_name}", tenant_name)

      assert {:error, :personnel_not_wired} =
               GrantCompliance.personnel(grant, tenant, rows: GrantPersonnel, repo: @repo)
    end
  end

  # ── the tracker, the claim decision and close ─────────────────────────────

  describe "the grant workflow" do
    test "milestones, claims, opportunities and close are one-way where they must be", %{
      org: org,
      admin: admin,
      tenant: tenant,
      other_admin: other_admin
    } do
      fund = new_cost_object!(admin, org, "FUND-WORKFLOW")
      grant = new_grant!(admin, org, fund)

      milestone =
        GrantMilestone
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: org,
            grant_id: grant.id,
            name: "Prototype",
            due_on: ~D[2026-06-30],
            amount_cents: 30_000
          },
          scope: tenant
        )
        |> Ash.create!()

      claim =
        GrantClaim
        |> Ash.Changeset.for_create(
          :submit,
          %{
            org_id: org,
            grant_id: grant.id,
            milestone_id: milestone.id,
            claimed_on: ~D[2026-06-20],
            amount_cents: 30_000,
            evidence_files: [Ash.UUID.generate()]
          },
          scope: tenant
        )
        |> Ash.create!()

      approved = approve_claim!(claim, admin)
      assert approved.status == :approved
      assert approved.approved_on == Date.utc_today()

      assert {:error, error} =
               approved
               |> Ash.Changeset.for_update(:reject, %{}, scope: admin)
               |> Ash.update()

      assert Exception.message(error) =~ "already"

      opportunity =
        GrantOpportunity
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: org,
            funder: "NSERC",
            program: "Alliance",
            stage: :identified,
            deadline: ~D[2026-09-01],
            amount_cents: 50_000,
            probability: 40
          },
          scope: tenant
        )
        |> Ash.create!()

      applied =
        opportunity
        |> Ash.Changeset.for_update(:update, %{stage: :applied}, scope: tenant)
        |> Ash.update!()

      assert applied.stage == :applied

      closed =
        grant
        |> Ash.Changeset.for_update(:close, %{}, scope: admin)
        |> Ash.update!()

      assert closed.status == :closed
      assert closed.closed_on == Date.utc_today()

      assert {:error, _} =
               closed
               |> Ash.Changeset.for_update(:close, %{}, scope: admin)
               |> Ash.update()

      # OrgScope: another org sees none of it.
      assert [] =
               Grant
               |> Ash.Query.filter(id == ^grant.id)
               |> Ash.read!(scope: other_admin)
    end
  end

  defp new_employee!(admin, org, number) do
    Employee
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        employee_number: number,
        hired_at: ~D[2026-01-05],
        employment_type: :full_time,
        full_name: %Samen.Type.FullName{first: @plain_first, last: @plain_last},
        work_emails: [%{label: "work", address: "grant-person@example.test"}],
        work_phones: [%{label: "mobile", number: "+1-555-0199"}],
        dob: ~D[1990-01-01]
      },
      scope: admin
    )
    |> Ash.create!()
  end
end
