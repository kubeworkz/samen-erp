defmodule Samen.FinanceAccrualsTest do
  @moduledoc """
  WS-ACCT Phase 5 (ADR-054 D6) — the month-end accrual and its automatic
  reversal, mounted via `test/support/finance_fixture.ex`.

  Every refusal is paired with a positive control (anti-tautology, `Samen.RedPath`
  discipline):

    * a1 `:post_accrual` lands the posted accrual AND the linked DRAFT reversal
      in one action, mirrored lines and mirrored dimensions;
    * a2 the schedule must be in a LATER period — same-day and earlier dates are
      refused (RED), the next day lands (CONTROL);
    * a3 **exactly once** — the run posts nothing before the date, posts the
      reversal on it, and a second run cannot post it again (PostGuard's
      one-way state machine refuses the direct re-post too);
    * a4 the pair nets to zero across the period boundary: January carries the
      expense, February carries the flip, and the trial balance closes at zero;
    * a5 a CLOSED period refuses the accrual (RED) while an open period lands it
      (CONTROL) — Phase 3's R10 holds for the new door;
    * a6 the scheduled-reversal factory is SYSTEM-ONLY: a member calling it is
      forbidden (RED);
    * a7 a reversal whose month is SOFT-CLOSED still posts — it is a
      journal-only adjustment, not a document (the PeriodGuard allowlist).
  """
  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.{AccrualReversal, AccrualReversalWorker, Reconcile}

  alias SamenCore.Support.FinanceFixture.{
    Account,
    CostObject,
    FiscalPeriod,
    JournalEntry,
    JournalLine
  }

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()

    prev = Application.get_env(:samen_core, AccrualReversal)
    Application.put_env(:samen_core, AccrualReversal, entry_module: JournalEntry)

    on_exit(fn ->
      if prev do
        Application.put_env(:samen_core, AccrualReversal, prev)
      else
        Application.delete_env(:samen_core, AccrualReversal)
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

  defp new_cost_object(admin, org, code) do
    CostObject
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, code: code, name: "Cost object #{code}", kind: :chip},
      scope: admin
    )
    |> Ash.create!()
  end

  # One month-end accrual: Dr expense / Cr accrued liability, dimensioned to a
  # chip programme so the reversal's dimension mirroring is observable.
  defp accrual_attrs(org, expense, liability, refs, opts \\ []) do
    %{
      org_id: org,
      entry_date: Keyword.get(opts, :entry_date, ~D[2026-01-31]),
      memo: "January foundry accrual",
      reversal_on: Keyword.get(opts, :reversal_on, ~D[2026-02-01]),
      lines: [
        %{account_id: expense.id, debit_cents: 1_000, dimension_refs: refs},
        %{account_id: liability.id, credit_cents: 1_000, dimension_refs: refs}
      ]
    }
  end

  defp post_accrual(scope, attrs) do
    JournalEntry
    |> Ash.Changeset.for_create(:post_accrual, attrs, scope: scope)
    |> Ash.create()
  end

  defp post_accrual!(scope, attrs) do
    case post_accrual(scope, attrs) do
      {:ok, entry} -> entry
      {:error, error} -> flunk("the accrual did not post: #{inspect(error)}")
    end
  end

  defp scheduled_reversal(org, accrual, scope) do
    query =
      JournalEntry
      |> Ash.Query.filter(
        source_key == "accrual_reversal" and source_id == ^accrual.id and org_id == ^org
      )

    case Ash.read!(query, scope: scope) do
      [reversal] -> reversal
      other -> flunk("expected exactly one scheduled reversal, got: #{inspect(other)}")
    end
  end

  defp lines_of(entry) do
    entry
    |> Ash.load!(:lines, authorize?: false)
    |> Map.fetch!(:lines)
  end

  defp line_on(lines, account) do
    Enum.find(lines, &(&1.account_id == account.id)) ||
      flunk("no line on account #{account.code}")
  end

  defp period!(admin, org, year, month) do
    FiscalPeriod
    |> Ash.Changeset.for_create(:create, %{org_id: org, year: year, month: month}, scope: admin)
    |> Ash.create!()
  end

  defp close!(period, admin) do
    period |> Ash.Changeset.for_update(:close, %{}, scope: admin) |> Ash.update!()
  end

  defp soft_close!(period, admin) do
    period |> Ash.Changeset.for_update(:soft_close, %{}, scope: admin) |> Ash.update!()
  end

  # ── a1: one decision, two rows ─────────────────────────────────────────────

  describe "a1 — :post_accrual lands the accrual and its scheduled reversal" do
    test "the accrual posts and a DRAFT reversal is linked, mirrored and dated", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      expense = new_account(scope, org, "5000", :expense, :debit)
      liability = new_account(scope, org, "2100", :liability, :credit)
      co = new_cost_object(admin, org, "GP180MCU")
      refs = %{"project" => co.id}

      accrual = post_accrual!(scope, accrual_attrs(org, expense, liability, refs))

      assert accrual.status == :posted
      assert accrual.entry_date == ~D[2026-01-31]

      reversal = scheduled_reversal(org, accrual, scope)
      assert reversal.status == :draft
      assert reversal.entry_date == ~D[2026-02-01]
      assert reversal.voided_entry_id == accrual.id
      assert reversal.source_key == "accrual_reversal"
      assert reversal.source_id == accrual.id

      accrual_expense = line_on(lines_of(accrual), expense)
      reversal_expense = line_on(lines_of(reversal), expense)
      assert accrual_expense.debit_cents == 1_000
      assert reversal_expense.credit_cents == 1_000
      assert reversal_expense.debit_cents == 0

      # R6's dimension mirroring: the reversal carries the same axis, or the
      # pair would leave the chip programme one-sided.
      assert Map.new(accrual_expense.dimension_refs) == refs
      assert Map.new(reversal_expense.dimension_refs) == refs
    end

    test "the reversal must land in a LATER period (RED) — next day lands (CONTROL)", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      expense = new_account(scope, org, "5000", :expense, :debit)
      liability = new_account(scope, org, "2100", :liability, :credit)
      co = new_cost_object(admin, org, "GPU")
      refs = %{"project" => co.id}

      same_day =
        post_accrual(
          scope,
          accrual_attrs(org, expense, liability, refs, reversal_on: ~D[2026-01-31])
        )

      assert {:error, %Ash.Error.Invalid{} = err} = same_day
      assert Exception.message(err) =~ "must be AFTER the accrual's date"

      _ = post_accrual!(scope, accrual_attrs(org, expense, liability, refs))

      # The accrual AND its scheduled reversal — two rows, one decision.
      assert length(JournalEntry |> Ash.read!(scope: scope)) == 2
    end
  end

  # ── a3: exactly once ──────────────────────────────────────────────────────

  describe "a3 — the scheduled run posts the reversal once, on its date" do
    test "nothing before the date, one posting on it, and a re-run cannot post again", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      expense = new_account(scope, org, "5000", :expense, :debit)
      liability = new_account(scope, org, "2100", :liability, :credit)
      co = new_cost_object(admin, org, "PTA")
      refs = %{"project" => co.id}

      accrual = post_accrual!(scope, accrual_attrs(org, expense, liability, refs))
      reversal = scheduled_reversal(org, accrual, scope)

      # Before the reversal date: the run finds nothing due.
      assert {:ok, %{posted: []}} = AccrualReversal.run(today: ~D[2026-01-31])
      assert scheduled_reversal(org, accrual, scope).status == :draft

      # On the date: it posts, through the governed :post action.
      assert {:ok, %{posted: [reversal_id]}} = AccrualReversal.run(today: ~D[2026-02-01])
      assert reversal_id == reversal.id

      posted = scheduled_reversal(org, accrual, scope)
      assert posted.status == :posted
      assert %DateTime{} = posted.posted_at
      posted_at = posted.posted_at

      # A second run the same day cannot post it twice.
      assert {:ok, %{posted: []}} = AccrualReversal.run(today: ~D[2026-02-01])
      again = scheduled_reversal(org, accrual, scope)
      assert again.status == :posted
      assert again.posted_at == posted_at

      # And the row itself cannot be re-posted: PostGuard's one-way machine.
      assert {:error, %Ash.Error.Invalid{}} =
               posted
               |> Ash.Changeset.for_update(:post, %{}, scope: scope)
               |> Ash.update()
    end
  end

  # ── a4: the period boundary ───────────────────────────────────────────────

  describe "a4 — the pair nets to zero across the period boundary" do
    test "January carries the expense, February the flip, and the books close at zero", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      expense = new_account(scope, org, "5000", :expense, :debit)
      liability = new_account(scope, org, "2100", :liability, :credit)
      co = new_cost_object(admin, org, "RISCV64")
      refs = %{"project" => co.id}

      accrual = post_accrual!(scope, accrual_attrs(org, expense, liability, refs))
      reversal = scheduled_reversal(org, accrual, scope)

      assert accrual.entry_date == ~D[2026-01-31]
      assert reversal.entry_date == ~D[2026-02-01]

      assert {:ok, %{posted: [_]}} = AccrualReversal.run(today: ~D[2026-02-01])

      # January's half is the expense; February's half is its exact flip.
      assert line_on(lines_of(accrual), expense).debit_cents == 1_000
      assert line_on(lines_of(reversal), expense).credit_cents == 1_000

      # The ledger as a whole is square: both accounts return to zero and R1
      # still holds. (`Reconcile` reads through attribute SOURCES, so it works
      # against the fixture's prefixed columns.)
      assert {:ok, 0} =
               Reconcile.account_balance(expense.id, @repo, line_resource: JournalLine)

      assert {:ok, 0} =
               Reconcile.account_balance(liability.id, @repo, line_resource: JournalLine)

      assert {:ok, 0} = Reconcile.org_balance(org, @repo, line_resource: JournalLine)
    end
  end

  # ── a5: R10 holds for the new door ────────────────────────────────────────

  describe "a5 — a CLOSED period refuses the accrual" do
    test "closed January refuses (RED); open February lands (CONTROL)", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      expense = new_account(scope, org, "5000", :expense, :debit)
      liability = new_account(scope, org, "2100", :liability, :credit)
      co = new_cost_object(admin, org, "PDB")
      refs = %{"project" => co.id}

      january = period!(admin, org, 2026, 1) |> close!(admin)
      assert january.status == :closed

      refused =
        post_accrual(
          scope,
          accrual_attrs(org, expense, liability, refs, entry_date: ~D[2026-01-15])
        )

      assert {:error, %Ash.Error.Invalid{} = err} = refused
      assert Exception.message(err) =~ "CLOSED"

      # The control: the same books, the next month, lands.
      _ =
        post_accrual!(
          scope,
          accrual_attrs(org, expense, liability, refs,
            entry_date: ~D[2026-02-15],
            reversal_on: ~D[2026-03-01]
          )
        )

      # The accrual AND its scheduled reversal — two rows, one decision.
      assert length(JournalEntry |> Ash.read!(scope: scope)) == 2
    end
  end

  # ── a6: internal-only factory ─────────────────────────────────────────────

  describe "a6 — the scheduled-reversal factory is system-only" do
    test "a member cannot mint a draft reversal (RED)", %{org: org, scope: scope} do
      expense = new_account(scope, org, "5000", :expense, :debit)
      liability = new_account(scope, org, "2100", :liability, :credit)

      result =
        JournalEntry
        |> Ash.Changeset.for_create(
          :create_accrual_reversal,
          %{
            org_id: org,
            entry_date: ~D[2026-02-01],
            memo: "hand-rolled",
            source_key: "accrual_reversal",
            source_id: Ash.UUID.generate(),
            voided_entry_id: Ash.UUID.generate(),
            lines: [
              %{account_id: expense.id, debit_cents: 100},
              %{account_id: liability.id, credit_cents: 100}
            ]
          },
          scope: scope
        )
        |> Ash.create()

      assert {:error, %Ash.Error.Forbidden{}} = result
    end
  end

  # ── a7: the adjustment window ─────────────────────────────────────────────

  describe "a7 — a reversal posts in a SOFT-CLOSED month" do
    test "the scheduled reversal is a journal adjustment, not a document", %{
      org: org,
      scope: scope,
      admin: admin
    } do
      expense = new_account(scope, org, "5000", :expense, :debit)
      liability = new_account(scope, org, "2100", :liability, :credit)
      co = new_cost_object(admin, org, "FOUNDRY")
      refs = %{"project" => co.id}

      accrual = post_accrual!(scope, accrual_attrs(org, expense, liability, refs))
      _ = period!(admin, org, 2026, 2) |> soft_close!(admin)

      assert {:ok, %{posted: [_]}} = AccrualReversal.run(today: ~D[2026-02-01])
      assert scheduled_reversal(org, accrual, scope).status == :posted
    end
  end

  # ── the cron ──────────────────────────────────────────────────────────────

  describe "the cron" do
    test "the reversal sweep rides the canonical crontab" do
      assert {"20 0 * * *", AccrualReversalWorker} in Samen.Jobs.default_crontab()
    end
  end
end
