defmodule Samen.FinanceRecognitionTest do
  @moduledoc """
  WS-ACCT Phase 6 (ADR-054 D5) — deferred revenue and its recognition
  schedules, mounted via `test/support/finance_fixture.ex`.

  Every refusal is paired with a positive control (`Samen.RedPath` discipline):

    * a1 `:straight_line` releases even slices, the LAST one absorbing the
      division remainder so the term releases the total exactly — and the entry
      posts Dr deferred / Cr income anchored to the recognition;
    * a2 `:cost_incurred` recognizes the period's incurred allowable cost (only
      posted, expense-account, dimensioned lines), and a period with NO cost
      recognizes ZERO — the fail-honest red path: never ahead of cost;
    * a3 the remaining balance caps every slice — no arithmetic path releases
      more than the contract holds;
    * a4 R9: per-schedule recognized == released, the org totals agree, and a
      recognition with no GL leg is DETECTED (the anti-tautology leg);
    * a5 R10 on the new door: a CLOSED period refuses the recognition (RED); a
      SOFT-CLOSED one admits it, because a release is a journal-only adjustment
      (CONTROL);
    * a6 the schedule's shape guards: `:cost_incurred` needs a cost object
      (RED) and a term shorter than its cents is refused (RED);
    * a7 exactly once: a second run in the same period is a clean no-op (the
      read guard), the unique index is the belt, and the belt refuses UPDATE and
      DELETE outright (append-only fact);
    * a8 the monthly cron rides the canonical crontab.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.{
    RecognitionRun,
    ReconcileRecognition,
    RevenueRecognitionWorker
  }

  alias SamenCore.Support.FinanceFixture.{
    Account,
    CostObject,
    FiscalPeriod,
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

    {:ok, org: org, scope: tenant_scope(org), admin: admin_scope(org)}
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

  defp new_cost_object(admin, org, code, kind \\ :fund) do
    CostObject
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, code: code, name: "Cost object #{code}", kind: kind},
      scope: admin
    )
    |> Ash.create!()
  end

  # The org's four GL accounts this suite needs: income, the two deferred
  # meanings and an expense for the incurred-cost legs.
  defp books!(admin, org) do
    income = new_account(admin, org, "4000", :income, :credit)
    deferred = new_account(admin, org, "2200", :liability, :credit)
    grant_deferred = new_account(admin, org, "2210", :liability, :credit)
    expense = new_account(admin, org, "5000", :expense, :debit)
    liability = new_account(admin, org, "2100", :liability, :credit)

    new_posting_account(admin, org, :income, income)
    new_posting_account(admin, org, :deferred_revenue, deferred)
    new_posting_account(admin, org, :grant_deferred, grant_deferred)

    %{
      income: income,
      deferred: deferred,
      grant_deferred: grant_deferred,
      expense: expense,
      liability: liability
    }
  end

  defp schedule!(admin, org, attrs) do
    attrs =
      Map.merge(
        %{org_id: org, start_on: ~D[2026-01-01], months: 12, method: :straight_line},
        attrs
      )

    RevenueSchedule
    |> Ash.Changeset.for_create(:create, attrs, scope: admin)
    |> Ash.create!()
  end

  defp create_schedule(admin, org, attrs) do
    attrs =
      Map.merge(
        %{org_id: org, start_on: ~D[2026-01-01], months: 12, method: :straight_line},
        attrs
      )

    RevenueSchedule
    |> Ash.Changeset.for_create(:create, attrs, scope: admin)
    |> Ash.create()
  end

  defp recognitions(org, scope, opts \\ []) do
    query =
      RevenueRecognition
      |> Ash.Query.filter(org_id == ^org)
      |> maybe_period(Keyword.get(opts, :period_key))

    Ash.read!(query, scope: scope)
  end

  defp maybe_period(query, nil), do: query
  defp maybe_period(query, key), do: Ash.Query.filter(query, period_key == ^key)

  defp recognized_cents(schedule, scope) do
    schedule
    |> Ash.load!([:recognized_cents], scope: scope)
    |> Map.fetch!(:recognized_cents)
    |> Kernel.||(0)
  end

  # An expense posting: Dr expense / Cr liability, optionally dimensioned.
  defp expense_entry!(admin, org, attrs) do
    attrs =
      Map.merge(%{org_id: org, entry_date: ~D[2026-01-15], memo: "allowable cost"}, attrs)

    entry =
      JournalEntry
      |> Ash.Changeset.for_create(:create, attrs, scope: admin)
      |> Ash.create!()

    entry |> Ash.Changeset.for_update(:post, %{}, scope: admin) |> Ash.update!()
  end

  defp period!(admin, org, year, month) do
    FiscalPeriod
    |> Ash.Changeset.for_create(:create, %{org_id: org, year: year, month: month}, scope: admin)
    |> Ash.create!()
  end

  defp lines_of(entry) do
    entry |> Ash.load!(:lines, authorize?: false) |> Map.fetch!(:lines)
  end

  defp line_on(lines, account) do
    Enum.find(lines, &(&1.account_id == account.id)) ||
      flunk("no line on account #{account.code}")
  end

  # ── a1: straight line, and the remainder ──────────────────────────────────

  describe "a1 — :straight_line releases the term exactly" do
    test "even slices, the last one absorbing the remainder, each with its entry", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      %{income: income, deferred: deferred} = books!(admin, org)

      schedule =
        schedule!(admin, org, %{
          source_key: "billing_invoice",
          source_id: Ash.UUID.generate(),
          total_cents: 100_000,
          months: 12
        })

      amounts =
        for month <- 1..12 do
          assert {:ok, %{posted: [_id]}} = RecognitionRun.run(period: {2026, month})
          [recognition] = recognitions(org, scope, period_key: "2026-#{pad(month)}")
          assert recognition.amount_cents == expected(month)
          assert recognition.recognized_on == Date.new!(2026, month, days(2026, month))
          recognition.amount_cents
        end

      # 100_000 / 12 = 8_333 remainder 4 — the last month takes 8_337, so the
      # term releases the total EXACTLY (nothing stranded in deferred).
      assert amounts == List.duplicate(8_333, 11) ++ [8_337]
      assert Enum.sum(amounts) == 100_000
      assert recognized_cents(schedule, scope) == 100_000

      # The entry: Dr deferred / Cr income, dated the period end, anchored on
      # the recognition (the ADR-041 object-ref shape).
      [january] = recognitions(org, scope, period_key: "2026-01")

      entry =
        JournalEntry
        |> Ash.Query.filter(source_key == "revenue_recognition" and source_id == ^january.id)
        |> Ash.read_one!(scope: scope)

      assert entry.entry_date == ~D[2026-01-31]
      assert entry.status == :posted
      assert line_on(lines_of(entry), deferred).debit_cents == 8_333
      assert line_on(lines_of(entry), income).credit_cents == 8_333
      assert line_on(lines_of(entry), deferred).credit_cents == 0

      # A 13th month is outside the term: nothing to release.
      assert {:ok, %{posted: []}} = RecognitionRun.run(period: {2027, 1})
    end
  end

  # ── a2: cost incurred, and the zero-incurrence red path ───────────────────

  describe "a2 — :cost_incurred recognizes incurred cost and NEVER ahead of it" do
    test "posted + dimensioned + expense rows count; an empty period recognizes ZERO", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      %{expense: expense, liability: liability} = books!(admin, org)
      fund = new_cost_object(admin, org, "GRANT-NSF")
      other = new_cost_object(admin, org, "GRANT-DARPA")

      schedule =
        schedule!(admin, org, %{
          method: :cost_incurred,
          deferred_key: :grant_deferred,
          total_cents: 500_000,
          start_on: ~D[2026-01-01],
          cost_object_id: fund.id
        })

      # January: 12_000 allowable...
      _ =
        expense_entry!(admin, org, %{
          entry_date: ~D[2026-01-15],
          lines: [
            %{account_id: expense.id, debit_cents: 12_000, dimension_refs: %{"fund" => fund.id}},
            %{
              account_id: liability.id,
              credit_cents: 12_000,
              dimension_refs: %{"fund" => fund.id}
            }
          ]
        })

      # ...plus three rows that must NOT count: undimensioned, another fund's,
      # and a DRAFT (not a fact yet).
      _ =
        expense_entry!(admin, org, %{
          entry_date: ~D[2026-01-16],
          lines: [
            %{account_id: expense.id, debit_cents: 9_999},
            %{account_id: liability.id, credit_cents: 9_999}
          ]
        })

      _ =
        expense_entry!(admin, org, %{
          entry_date: ~D[2026-01-17],
          lines: [
            %{account_id: expense.id, debit_cents: 7_777, dimension_refs: %{"fund" => other.id}},
            %{
              account_id: liability.id,
              credit_cents: 7_777,
              dimension_refs: %{"fund" => other.id}
            }
          ]
        })

      _ =
        JournalEntry
        |> Ash.Changeset.for_create(
          :create,
          %{
            org_id: org,
            entry_date: ~D[2026-01-18],
            memo: "draft cost",
            lines: [
              %{account_id: expense.id, debit_cents: 5_555, dimension_refs: %{"fund" => fund.id}},
              %{
                account_id: liability.id,
                credit_cents: 5_555,
                dimension_refs: %{"fund" => fund.id}
              }
            ]
          },
          scope: admin
        )
        |> Ash.create!()

      assert {:ok, %{posted: [_]}} = RecognitionRun.run(period: {2026, 1})
      assert recognized_cents(schedule, scope) == 12_000

      # February: no cost at all. The run posts NOTHING — revenue is never
      # recognized ahead of the cost it is earned against.
      assert {:ok, %{posted: []}} = RecognitionRun.run(period: {2026, 2})
      assert recognitions(org, scope, period_key: "2026-02") == []
      assert recognized_cents(schedule, scope) == 12_000

      # March: 50_000 incurred, below the remaining balance — the slice is the
      # full incurred amount (the cap is exercised in a3).
      _ =
        expense_entry!(admin, org, %{
          entry_date: ~D[2026-03-10],
          lines: [
            %{account_id: expense.id, debit_cents: 50_000, dimension_refs: %{"fund" => fund.id}},
            %{
              account_id: liability.id,
              credit_cents: 50_000,
              dimension_refs: %{"fund" => fund.id}
            }
          ]
        })

      assert {:ok, %{posted: [_]}} = RecognitionRun.run(period: {2026, 3})
      assert recognized_cents(schedule, scope) == 62_000
    end
  end

  # ── a3: the cap ───────────────────────────────────────────────────────────

  describe "a3 — no slice exceeds what is left" do
    test "a huge incurred-cost period releases only the remainder, then nothing", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      %{expense: expense, liability: liability} = books!(admin, org)
      fund = new_cost_object(admin, org, "GRANT-CAP")

      schedule =
        schedule!(admin, org, %{
          method: :cost_incurred,
          deferred_key: :grant_deferred,
          total_cents: 40_000,
          cost_object_id: fund.id
        })

      _ =
        expense_entry!(admin, org, %{
          entry_date: ~D[2026-01-10],
          lines: [
            %{account_id: expense.id, debit_cents: 100_000, dimension_refs: %{"fund" => fund.id}},
            %{
              account_id: liability.id,
              credit_cents: 100_000,
              dimension_refs: %{"fund" => fund.id}
            }
          ]
        })

      assert {:ok, %{posted: [_]}} = RecognitionRun.run(period: {2026, 1})
      assert recognized_cents(schedule, scope) == 40_000

      _ =
        expense_entry!(admin, org, %{
          entry_date: ~D[2026-02-10],
          lines: [
            %{account_id: expense.id, debit_cents: 10_000, dimension_refs: %{"fund" => fund.id}},
            %{
              account_id: liability.id,
              credit_cents: 10_000,
              dimension_refs: %{"fund" => fund.id}
            }
          ]
        })

      assert {:ok, %{posted: []}} = RecognitionRun.run(period: {2026, 2})
      assert recognized_cents(schedule, scope) == 40_000
    end
  end

  # ── a4: R9 ────────────────────────────────────────────────────────────────

  describe "a4 — R9: recognized == released, and a phantom row is DETECTED" do
    test "three months reconcile per schedule and org-wide; a row with no GL leg diverges", %{
      org: org,
      admin: admin
    } do
      %{deferred: deferred} = books!(admin, org)

      schedule =
        schedule!(admin, org, %{total_cents: 12_000, months: 12})

      for month <- 1..3 do
        assert {:ok, %{posted: [_]}} = RecognitionRun.run(period: {2026, month})
      end

      opts = [
        schedule_resource: RevenueSchedule,
        recognition_resource: RevenueRecognition,
        entry_resource: JournalEntry,
        line_resource: JournalLine,
        posting_account_resource: PostingAccount
      ]

      assert {:ok, [state]} = ReconcileRecognition.schedule_states(org, @repo, opts)
      assert state.schedule_id == schedule.id
      assert state.total_cents == 12_000
      assert state.recognized_cents == 3_000
      assert state.released_cents == 3_000
      assert state.remaining_cents == 9_000
      assert state.reconciled?

      assert {:ok, %{recognized_cents: 3_000, released_cents: 3_000}} =
               ReconcileRecognition.org_totals(org, @repo, opts)

      assert {:ok, true} = ReconcileRecognition.reconciled?(org, @repo, opts)

      # Anti-tautology: a recognition row inserted BELOW the cascade (no entry,
      # no GL release) must show up as a divergence — the read is not decoration.
      @repo.query!(
        """
        INSERT INTO frc_revenue_recognition
          (frc_id, frc_org_id, frc_schedule_id, frc_period_key, frc_amount_cents,
           frc_recognized_on, frc_inserted_at, frc_updated_at)
        VALUES (gen_random_uuid(), $1, $2, '2026-04', 1_000, '2026-04-30', now(), now())
        """,
        [
          Ecto.UUID.dump!(org),
          Ecto.UUID.dump!(schedule.id)
        ]
      )

      assert {:ok, [divergence]} = ReconcileRecognition.divergences(org, @repo, opts)
      assert divergence.schedule_id == schedule.id
      assert divergence.recognized_cents == 4_000
      assert divergence.released_cents == 3_000
      refute divergence.reconciled?

      assert {:ok, false, [_]} = ReconcileRecognition.reconciled?(org, @repo, opts)

      # The deferred ACCOUNT is what the GL leg was summed from: the three real
      # entries DEBITED the deferred liability by 3_000 (Σ debit − credit), which
      # is the released number above — the account moved by exactly that much.
      assert {:ok, balance} =
               Samen.Scopes.Finance.Reconcile.account_balance(deferred.id, @repo,
                 line_resource: JournalLine
               )

      assert balance == 3_000
    end
  end

  # ── a5: R10 on the new door ───────────────────────────────────────────────

  describe "a5 — a CLOSED period refuses the recognition; soft-closed admits it" do
    test "closed January RED, open February CONTROL", %{org: org, scope: scope, admin: admin} do
      _ = books!(admin, org)
      schedule = schedule!(admin, org, %{total_cents: 24_000, months: 12})

      january = period!(admin, org, 2026, 1)

      january =
        january |> Ash.Changeset.for_update(:close, %{}, scope: admin) |> Ash.update!()

      assert january.status == :closed

      assert {:error, {:recognition_failed, [{schedule_id, _reason}]}} =
               RecognitionRun.run(period: {2026, 1})

      assert schedule_id == schedule.id
      assert recognitions(org, scope) == []

      # The control: the same schedule, the next month.
      assert {:ok, %{posted: [_]}} = RecognitionRun.run(period: {2026, 2})
      assert recognized_cents(schedule, scope) == 2_000
    end

    test "a SOFT-CLOSED period admits the release — it is a journal-only adjustment", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      _ = books!(admin, org)
      schedule = schedule!(admin, org, %{total_cents: 12_000, months: 12})

      february = period!(admin, org, 2026, 2)

      february =
        february |> Ash.Changeset.for_update(:soft_close, %{}, scope: admin) |> Ash.update!()

      assert february.status == :soft_closed

      assert {:ok, %{posted: [_]}} = RecognitionRun.run(period: {2026, 2})
      assert recognized_cents(schedule, scope) == 1_000
    end
  end

  # ── a6: the schedule's shape ──────────────────────────────────────────────

  describe "a6 — the schedule's shape guards" do
    test "cost_incurred without a cost object is refused (RED); with one it lands (CONTROL)", %{
      org: org,
      admin: admin
    } do
      _ = books!(admin, org)

      refused =
        create_schedule(admin, org, %{
          method: :cost_incurred,
          total_cents: 12_000,
          cost_object_id: nil
        })

      assert {:error, %Ash.Error.Invalid{} = err} = refused
      assert Exception.message(err) =~ "must name the cost object"

      fund = new_cost_object(admin, org, "GRANT-OK")

      schedule =
        schedule!(admin, org, %{
          method: :cost_incurred,
          total_cents: 12_000,
          cost_object_id: fund.id
        })

      assert schedule.cost_object_id == fund.id
    end

    test "a term in months longer than its cents is refused (RED)", %{
      org: org,
      admin: admin
    } do
      _ = books!(admin, org)

      assert {:error, %Ash.Error.Invalid{} = err} =
               create_schedule(admin, org, %{total_cents: 6, months: 12})

      assert Exception.message(err) =~ "at least the term in months"
    end
  end

  # ── a7: exactly once ──────────────────────────────────────────────────────

  describe "a7 — exactly once per period" do
    test "a second run in the same period is a clean no-op; the row is append-only", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      _ = books!(admin, org)

      schedule = schedule!(admin, org, %{total_cents: 12_000, months: 12})

      assert {:ok, %{posted: [first]}} = RecognitionRun.run(period: {2026, 1})
      assert recognized_cents(schedule, scope) == 1_000

      # The READ guard: a repeated sweep (a retried cron) sees the row and
      # skips — no error, no duplicate, no second entry.
      assert {:ok, %{posted: [], skipped: [{schedule_id, :already_recognized}]}} =
               RecognitionRun.run(period: {2026, 1})

      assert schedule_id == schedule.id
      assert [%{id: ^first}] = recognitions(org, scope, period_key: "2026-01")
      assert recognized_cents(schedule, scope) == 1_000

      # The BELT: the unique index refuses a duplicate row even below Ash.
      assert {:error, %Postgrex.Error{}} =
               @repo.query(
                 """
                 INSERT INTO frc_revenue_recognition
                   (frc_id, frc_org_id, frc_schedule_id, frc_period_key, frc_amount_cents,
                    frc_recognized_on, frc_inserted_at, frc_updated_at)
                 VALUES (gen_random_uuid(), $1, $2, '2026-01', 1_000, '2026-01-31', now(), now())
                 """,
                 [Ecto.UUID.dump!(org), Ecto.UUID.dump!(schedule.id)]
               )
    end

    test "the append-only belt refuses UPDATE and DELETE", %{org: org, scope: scope, admin: admin} do
      _ = books!(admin, org)
      _ = schedule!(admin, org, %{total_cents: 12_000, months: 12})

      assert {:ok, %{posted: [id]}} = RecognitionRun.run(period: {2026, 1})
      assert [%{id: ^id}] = recognitions(org, scope)

      dumped = Ecto.UUID.dump!(id)

      assert {:error, %Postgrex.Error{}} =
               @repo.query(
                 "UPDATE frc_revenue_recognition SET frc_amount_cents = 1 WHERE frc_id = $1",
                 [dumped]
               )
    end
  end

  # ── a8: the cron ──────────────────────────────────────────────────────────

  describe "the cron" do
    test "the monthly recognition sweep rides the canonical crontab" do
      assert {"30 0 1 * *", RevenueRecognitionWorker} in Samen.Jobs.default_crontab()
    end
  end

  # ── small helpers ─────────────────────────────────────────────────────────

  defp expected(month), do: if(month == 12, do: 8_337, else: 8_333)

  defp pad(month), do: month |> Integer.to_string() |> String.pad_leading(2, "0")

  defp days(2026, 1), do: 31
  defp days(2026, 2), do: 28
  defp days(2026, 3), do: 31
  defp days(2026, 4), do: 30
  defp days(2026, 5), do: 31
  defp days(2026, 6), do: 30
  defp days(2026, 7), do: 31
  defp days(2026, 8), do: 31
  defp days(2026, 9), do: 30
  defp days(2026, 10), do: 31
  defp days(2026, 11), do: 30
  defp days(2026, 12), do: 31
end
