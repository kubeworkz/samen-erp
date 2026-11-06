defmodule Samenerp.CloseWalkthroughTest do
  @moduledoc """
  WS-ACCT Phase 12 — **the close run, executed end to end** on the Kubeworkz
  host (build plan Phase 12).

  One real month is driven through the source manual's ten phases:

    pre-close → transaction processing (AP/AR) → inventory & WIP → accruals &
    provisions → grant accounting → variance → reconciliations → financial
    statements → forecast actuals roll-in → review & reporting,

  and the close dashboard is read at every step. The assertions are the phase's
  acceptance criteria:

    * the ten phases exist as Work tasks anchored to the `CloseRun`
      (`subject_key: "close_run"`) with the manual's role assignments;
    * a document posted after soft-close is REFUSED while a journal-only close
      adjustment is ADMITTED (Phase 3's guard, exercised through the close);
    * the dashboard reports completeness HONESTLY — completing a task without
      signing the phase leaves it open, and a task reopened after sign-off makes
      the dashboard report the phase open again even though `done_at` is set.

  ## Scope of the roll-in

  Phase 14 owns the forecast store, so this phase proves the *actuals packet*
  the roll-in consumes (revenue, expenses, net income, cash) is assembled and
  reconciled; it does not claim a forecast version was rolled. The close
  dashboard's completeness is the Phase 12 deliverable, and every number it
  reports comes from a posted ledger fact or a Work task — never a hand figure.
  """

  use Samenerp.DataCase, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.{
    AssetSchedule,
    BalanceSheet,
    CloseBoard,
    CloseChecklist,
    ClosePhases,
    PeriodReconcile,
    ProfitLoss,
    Reconcile,
    ReconcileVariance,
    TrialBalance
  }

  alias Samenerp.Erp
  alias Samenerp.Kubeworkz.Books
  alias Samenerp.Operator, as: Op
  alias Samenerp.Work

  @year 2026
  @month 10
  @period_key "2026-10"
  @repo Samenerp.Repo

  setup do
    org = create_org!("Kubeworkz Close Walkthrough")
    Books.seed!(org.id)
    org_id = to_string(org.id)

    {:ok, org: org, org_id: org_id, admin: admin_scope(org_id)}
  end

  test "one October closes end to end, with the dashboard honest at every step", %{
    org_id: org_id,
    admin: admin
  } do
    period = open_period!(admin, org_id)
    run = start_run!(admin, org_id, period.id)

    # ── Phase 1 · Pre-Close ──────────────────────────────────────────────────
    # The run seeds the manual's ten phases AND their anchored Work tasks.
    assert length(run.phases) == 10
    assert Enum.map(run.phases, & &1["key"]) == ClosePhases.keys()
    assert Enum.all?(run.phases, &(&1["done_at"] == nil))

    tasks = CloseChecklist.tasks(run, task: Work.Task)
    assert length(tasks) == 10
    assert Enum.map(tasks, &CloseChecklist.phase_key/1) == ClosePhases.keys()

    assert Enum.all?(tasks, fn task ->
             task.subject_key == "close_run" and task.subject_id == run.id and
               task.status == :pending
           end)

    # The twelve role assignments are all present on the checklist, and each
    # task carries its phase's lead role.
    assigned = run.phases |> Enum.flat_map(& &1["roles"]) |> MapSet.new()
    assert MapSet.subset?(MapSet.new(ClosePhases.roles()), assigned)

    for task <- tasks do
      key = CloseChecklist.phase_key(task)
      phase = ClosePhases.fetch(key)
      assert task.custom["close_phase"] == key
      assert phase.role in ClosePhases.roles()
      assert Enum.find(run.phases, &(&1["key"] == key))["role"] == phase.role
    end

    board = board(run, period)
    assert board.completeness.total == 10
    assert board.completeness.done == 0
    assert board.completeness.open == 10
    refute board.completeness.complete?
    assert board.next_phase.key == "pre_close"
    assert board.tasks.total == 10
    assert board.tasks.completed == 0
    assert board.discrepancies == []

    # HONESTY (1): a completed task without a signed phase is still OPEN — work
    # done is not a sign-off.
    complete_task!(run, "pre_close")
    assert phase(board(run, period), "pre_close").status == :open
    assert board(run, period).completeness.done == 0

    # The sign-off and the task now agree, so the phase is done.
    run = sign!(run, admin, "pre_close")
    assert phase(board(run, period), "pre_close").status == :done
    assert board(run, period).completeness.done == 1

    # ── Phase 2 · Transaction Processing (AP / AR) ───────────────────────────
    wip_foundry = account_id!(org_id, "1300")

    # AP: a foundry bill, approved by a distinct party (the ADR-040 Gate), which
    # posts the expense + liability entry anchored `source_key: "ap_invoice"`.
    invoice =
      Erp.ApInvoice
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          vendor_id: Ecto.UUID.generate(),
          number: "AP-2026-10-001",
          bill_date: ~D[2026-10-05],
          due_date: ~D[2026-11-04],
          memo: "wafer.space October fabrication",
          lines: [%{account_id: wip_foundry, amount_cents: 2_500_000}]
        },
        scope: admin
      )
      |> Ash.create!()

    assert {:gated, approval_id} = gate_approve(invoice, admin)

    assert {:ok, _, _} =
             Samen.Approvals.approve(approval_id, "approver:#{org_id}",
               approval_resource: Samenerp.Approvals.Approval,
               repo: Samenerp.Repo
             )

    invoice = Ash.get!(Erp.ApInvoice, invoice.id, scope: admin)
    assert invoice.status == :approved
    assert invoice.posted_entry_id != nil

    # AR: a real PDB shipment through the sales bridge — stock consumed and the
    # host's Billing invoice emitted in one transaction.
    board_item = create_item!(org_id, "PDB-CLOSE", "PDB development board")
    warehouse = create_warehouse!(org_id, "FG-MAIN", "Finished goods", :owned)

    receive_stock!(org_id, board_item, warehouse, 50, 20_000, "goods_receipt")

    customer =
      Samenerp.Billing.Customer
      |> Ash.Changeset.for_create(:create, %{org_id: org_id, currency: "USD"}, scope: admin)
      |> Ash.create!()

    so =
      Erp.SalesOrder
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          customer_id: customer.id,
          number: "SO-2026-10-001",
          order_date: ~D[2026-10-20],
          warehouse_id: warehouse.id,
          lines: [%{item_id: board_item.id, qty: 5, unit_price_cents: 40_000}]
        },
        scope: admin
      )
      |> Ash.create!()
      |> then(&(Ash.Changeset.for_update(&1, :confirm, %{}, scope: admin) |> Ash.update!()))
      |> then(&(Ash.Changeset.for_update(&1, :fulfill, %{}, scope: admin) |> Ash.update!()))

    assert so.status == :fulfilled
    emitted = Ash.get!(Samenerp.Billing.Invoice, so.invoice_id, scope: admin)
    assert emitted.amount_due_cents == 200_000

    # The manual's shipment entries (JE-050/051): AR ↔ revenue, COGS ↔ FG.
    post_entry!(org_id, ~D[2026-10-20], [
      %{account_id: account_id!(org_id, "1100"), debit_cents: 200_000},
      %{account_id: account_id!(org_id, "4000"), credit_cents: 200_000}
    ], "JE-050 board sale")

    post_entry!(org_id, ~D[2026-10-20], [
      %{account_id: account_id!(org_id, "5000"), debit_cents: 100_000},
      %{account_id: account_id!(org_id, "1430"), credit_cents: 100_000}
    ], "JE-051 board COGS")

    run = finish_phase!(run, admin, "transaction_processing")

    # ── Phase 3 · Inventory & WIP ────────────────────────────────────────────
    # Foundry WIP is stock at a SUPPLIER location (ADR-054 D3) — the one stock
    # ledger, not a parallel WIP register.
    wafer = create_item!(org_id, "WAFER-RV64", "RISC-V64 SoC wafer")
    foundry_wip = create_warehouse!(org_id, "FOUNDRY-WIP", "wafer.space WIP", :supplier)

    receive_stock!(org_id, wafer, foundry_wip, 10, 300_000, "fab_order")

    wip_level = stock_level!(org_id, wafer.id, foundry_wip.id)
    assert wip_level.qty_on_hand == 10
    assert wip_level.stock_value_cents == 3_000_000

    run = finish_phase!(run, admin, "inventory_and_wip")

    # ── Phase 4 · Accruals & Provisions ──────────────────────────────────────
    # The month-end accrual lands POSTED with its linked DRAFT reversal — the
    # manual's control mechanised (ADR-054 D6), not left as a habit.
    accrual =
      Erp.JournalEntry
      |> Ash.Changeset.for_create(
        :post_accrual,
        %{
          org_id: org_id,
          entry_date: ~D[2026-10-31],
          memo: "October foundry fabrication accrual",
          reversal_on: ~D[2026-11-01],
          lines: [
            %{account_id: wip_foundry, debit_cents: 500_000},
            %{account_id: account_id!(org_id, "2100"), credit_cents: 500_000}
          ]
        },
        scope: admin
      )
      |> Ash.create!()

    assert accrual.status == :posted

    reversal =
      Erp.JournalEntry
      |> Ash.Query.filter(
        org_id == ^org_id and source_key == "accrual_reversal" and source_id == ^accrual.id
      )
      |> Ash.read_one!(authorize?: false)

    assert reversal.status == :draft
    assert reversal.entry_date == ~D[2026-11-01]

    # The PDK licence's October amortization, derived from the asset contract.
    pdk =
      Erp.Asset
      |> Ash.Query.filter(org_id == ^org_id and code == "PDK-PHOTONICS")
      |> Ash.read_one!(authorize?: false)

    assert {:ok, slice} = AssetSchedule.slice(pdk, @period_key)

    posting =
      Erp.AssetPosting
      |> Ash.Changeset.for_create(
        :depreciate,
        %{
          org_id: org_id,
          asset_id: pdk.id,
          period_key: @period_key,
          amount_cents: slice,
          depreciated_on: ~D[2026-10-31]
        },
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    assert posting.amount_cents == 1_666_666

    run = finish_phase!(run, admin, "accruals_and_provisions")

    # ── Phase 5 · Grant Accounting ───────────────────────────────────────────
    fund = cost_object!(org_id, "fund-grants")

    grant =
      Erp.Grant
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          funder: "NRC IRAP",
          program: "Fabless AI chip R&D",
          award_ref: "IRAP-2026-014",
          award_cents: 5_000_000,
          period_start: ~D[2026-01-01],
          period_end: ~D[2026-12-31],
          restricted: true,
          fund_cost_object_id: fund.id
        },
        scope: admin
      )
      |> Ash.create!()

    grant =
      grant
      |> Ash.Changeset.for_update(:open_recognition, %{}, scope: admin)
      |> Ash.update!()

    assert grant.schedule_id != nil

    fund_dims = %{"fund" => fund.id}

    # JE-070: the restricted receipt (Dr cash / Cr grant_deferred), fund-tagged.
    post_entry!(
      org_id,
      ~D[2026-10-02],
      [
        %{account_id: account_id!(org_id, "1000"), debit_cents: 5_000_000, dimension_refs: fund_dims},
        %{
          account_id: account_id!(org_id, "2200"),
          credit_cents: 5_000_000,
          dimension_refs: fund_dims
        }
      ],
      "JE-070 grant award received",
      %{source_key: "grant_award", source_id: grant.id}
    )

    # The allowable cost incurred this month (grant-funded labour), fund-tagged.
    post_entry!(org_id, ~D[2026-10-31], [
      %{
        account_id: account_id!(org_id, "6020"),
        debit_cents: 1_200_000,
        dimension_refs: fund_dims
      },
      %{
        account_id: account_id!(org_id, "2100"),
        credit_cents: 1_200_000,
        dimension_refs: fund_dims
      }
    ], "JE-071 grant-funded labour")

    # JE-072: recognize the deferred award as allowable cost is incurred.
    recognition =
      Erp.RevenueRecognition
      |> Ash.Changeset.for_create(
        :recognize,
        %{
          org_id: org_id,
          schedule_id: grant.schedule_id,
          period_key: @period_key,
          amount_cents: 1_200_000,
          recognized_on: ~D[2026-10-31]
        },
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    assert recognition.period_key == @period_key

    run = finish_phase!(run, admin, "grant_accounting")

    # ── Phase 6 · Variance Analysis ──────────────────────────────────────────
    chip = cost_object!(org_id, "riscv64-soc")

    standard =
      Erp.CostStandard
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          code: "RV64-STD-2026",
          cost_object_id: chip.id,
          output_item_id: wafer.id,
          effective_on: ~D[2026-01-01],
          dimension_key: :project
        },
        authorize?: false
      )
      |> Ash.create!(authorize?: false)

    material = standard_line!(org_id, standard.id, wafer.id, :material, 1, 300_000, 9_500, :yield)
    labor = standard_line!(org_id, standard.id, nil, :labor, 6, 2_400, 10_000, :none)

    overhead =
      standard_line!(org_id, standard.id, nil, :overhead, 6, 4_200, 10_000, :none)

    actuals = %{
      "output_units" => 10,
      "lines" => %{
        material.id => %{"qty" => 11, "unit_price_cents" => 310_000},
        labor.id => %{"qty" => 70, "unit_price_cents" => 2_500},
        overhead.id => %{"qty" => 70, "unit_price_cents" => 4_500}
      }
    }

    standard
    |> Ash.Changeset.for_update(
      :post_variances,
      %{period_key: @period_key, actuals: actuals},
      authorize?: false
    )
    |> Ash.update!(authorize?: false)

    variances =
      Erp.CostVariance
      |> Ash.Query.filter(org_id == ^org_id and period_key == ^@period_key)
      |> Ash.read!(authorize?: false)

    assert length(variances) == 6

    run = finish_phase!(run, admin, "variance_analysis")

    # ── Phase 7 · Reconciliations, then LOCK the period ──────────────────────
    # The independent read mirrors, not the write-side guards: R1, R10 and R8.
    assert {:ok, 0} = Reconcile.org_balance(org_id, @repo, line_resource: Erp.JournalLine)

    assert {:ok, true} =
             PeriodReconcile.clean?(org_id, @repo,
               entry_resource: Erp.JournalEntry,
               period_resource: Erp.FiscalPeriod
             )

    variance_report =
      ReconcileVariance.report(org_id, @period_key,
        variance: Erp.CostVariance,
        standard: Erp.CostStandard,
        standard_line: Erp.CostStandardLine,
        entry: Erp.JournalEntry,
        line: Erp.JournalLine,
        posting_account: Erp.PostingAccount
      )

    assert variance_report.ok?, inspect(variance_report.violations)

    # 7.3.5 — lock the period. The DOCUMENT window shuts; the adjustment window
    # stays open (Phase 3's soft-close).
    period =
      period
      |> Ash.Changeset.for_update(:soft_close, %{}, scope: admin)
      |> Ash.update!()

    assert period.status == :soft_closed

    blocked = document_entry(org_id, ~D[2026-10-30])
    refused = blocked |> Ash.Changeset.for_update(:post, %{}, scope: admin) |> Ash.update()
    assert {:error, _} = refused
    assert inspect(refused) =~ "SOFT-CLOSED"
    assert inspect(refused) =~ "documents may no longer land"

    # CONTROL: a journal-only close adjustment is admitted in the same period.
    adjustment =
      Erp.JournalEntry
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          entry_date: ~D[2026-10-30],
          memo: "Close adjustment — reclass prototype test",
          lines: [
            %{account_id: account_id!(org_id, "6030"), debit_cents: 10_000},
            %{account_id: account_id!(org_id, "1300"), credit_cents: 10_000}
          ]
        },
        scope: admin
      )
      |> Ash.create!()
      |> then(&(Ash.Changeset.for_update(&1, :post, %{}, scope: admin) |> Ash.update!()))

    assert adjustment.status == :posted

    run = finish_phase!(run, admin, "reconciliations")

    # ── Phase 8 · Financial Statements ───────────────────────────────────────
    as_of = DateTime.utc_now()

    assert {:ok, tb} =
             TrialBalance.generate(org_id, as_of,
               repo: @repo,
               account_resource: Erp.Account,
               line_resource: Erp.JournalLine,
               entry_resource: Erp.JournalEntry
             )

    assert tb.balanced
    assert tb.total_debits == tb.total_credits
    assert tb.total_debits > 0

    assert {:ok, bs} =
             BalanceSheet.generate(org_id, as_of,
               repo: @repo,
               account_resource: Erp.Account,
               line_resource: Erp.JournalLine,
               entry_resource: Erp.JournalEntry
             )

    assert is_integer(bs.total_assets)
    assert bs.balanced, "assets #{bs.total_assets} != liabilities + equity #{bs.total_liabilities + bs.total_equity}"

    assert {:ok, pl} =
             ProfitLoss.generate(org_id, ~U[2026-10-01 00:00:00Z], as_of,
               repo: @repo,
               account_resource: Erp.Account,
               line_resource: Erp.JournalLine,
               entry_resource: Erp.JournalEntry
             )

    assert pl.total_revenue > 0
    assert is_integer(pl.net_income)

    run = finish_phase!(run, admin, "financial_statements")

    # HONESTY (2): a task reopened AFTER its phase was signed cannot be reported
    # done. The dashboard re-derives from both facts and flags the disagreement.
    reopened = reopen_task!(run, "financial_statements")
    honest = board(run, period)

    assert phase(honest, "financial_statements").signed?
    assert phase(honest, "financial_statements").task.status == :pending
    assert phase(honest, "financial_statements").status == :open
    assert honest.completeness.done == 7
    assert Enum.any?(honest.discrepancies, &(&1.phase == "financial_statements"))

    CloseChecklist.complete!(reopened)
    assert phase(board(run, period), "financial_statements").status == :done

    # ── Phase 9 · Rolling Forecast Update (actuals roll-in) ──────────────────
    # Phase 14 owns the forecast store. What the close certifies here is the
    # actuals packet the roll-in consumes — every figure a posted fact.
    cash =
      Enum.find(tb.accounts, &(&1.code == "1000")) ||
        flunk("the trial balance carries no cash account")

    assert cash.balance != 0
    assert pl.total_revenue == 1_400_000
    assert is_integer(pl.total_expenses)

    run = finish_phase!(run, admin, "rolling_forecast_update")

    # ── Phase 10 · Review & Reporting ────────────────────────────────────────
    before_final = board(run, period)
    assert before_final.completeness.done == 9
    assert before_final.completeness.open == 1
    assert before_final.next_phase.key == "review_and_reporting"
    refute before_final.completeness.complete?

    run = finish_phase!(run, admin, "review_and_reporting")

    # The run's own finish is the last gate: every phase signed, then completed.
    run =
      run
      |> Ash.Changeset.for_update(:finish, %{}, scope: admin)
      |> Ash.update!()

    assert run.status == :completed
    assert run.completed_at != nil

    final = board(run, period)
    assert final.completeness.done == 10
    assert final.completeness.open == 0
    assert final.completeness.percent == 100
    assert final.completeness.complete?
    assert final.next_phase == nil
    assert final.discrepancies == []
    assert final.tasks.total == 10
    assert final.tasks.completed == 10
    assert final.tasks.open == 0
    assert final.tasks.missing == 0
    assert final.period.status == :soft_closed
    assert Enum.all?(final.phases, &(&1.status == :done))
  end

  # ── the period, run and board ──────────────────────────────────────────────

  defp open_period!(admin, org_id) do
    Erp.FiscalPeriod
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, year: @year, month: @month},
      scope: admin
    )
    |> Ash.create!()
  end

  defp start_run!(admin, org_id, period_id) do
    Erp.CloseRun
    |> Ash.Changeset.for_create(
      :start,
      %{org_id: org_id, period_id: period_id},
      scope: admin
    )
    |> Ash.create!()
  end

  defp sign!(run, admin, key) do
    run
    |> Ash.Changeset.for_update(:complete_phase, %{phase: key}, scope: admin)
    |> Ash.update!()
  end

  defp finish_phase!(run, admin, key) do
    complete_task!(run, key)
    sign!(run, admin, key)
  end

  defp complete_task!(run, key) do
    run
    |> CloseChecklist.task_for(key, task: Work.Task)
    |> CloseChecklist.complete!()
  end

  defp reopen_task!(run, key) do
    run
    |> CloseChecklist.task_for(key, task: Work.Task)
    |> Ash.Changeset.for_update(
      :update,
      %{status: :pending, completed_at: nil},
      authorize?: false
    )
    |> Ash.update!(authorize?: false)
  end

  defp board(run, period) do
    CloseBoard.report(run, task: Work.Task, period: period)
  end

  defp phase(board, key), do: Enum.find(board.phases, &(&1.key == key))

  # ── ledger + master-data fixtures ──────────────────────────────────────────

  defp create_org!(name) do
    Op.Org
    |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp admin_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "a:#{org_id}", org_id: org_id, role: :admin, kind: :tenant, plane: :tenant}
    }
  end

  defp account_id!(org_id, code) do
    Erp.Account
    |> Ash.Query.filter(org_id == ^org_id and code == ^code)
    |> Ash.read_one!(authorize?: false)
    |> Map.fetch!(:id)
  end

  defp cost_object!(org_id, code) do
    Erp.CostObject
    |> Ash.Query.filter(org_id == ^org_id and code == ^code)
    |> Ash.read_one!(authorize?: false)
  end

  defp create_item!(org_id, sku, name) do
    Erp.Item
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, sku: sku, name: name, kind: :stocked, uom: :unit},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp create_warehouse!(org_id, code, name, kind) do
    Erp.Warehouse
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, code: code, name: name, kind: kind},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp receive_stock!(org_id, item, warehouse, qty, unit_cost_cents, source_key) do
    Erp.StockLedger
    |> Ash.Changeset.for_create(
      :record,
      %{
        org_id: org_id,
        kind: :receipt,
        qty: qty,
        unit_cost_cents: unit_cost_cents,
        item_id: item.id,
        warehouse_id: warehouse.id,
        source_key: source_key
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp stock_level!(org_id, item_id, warehouse_id) do
    Erp.StockLevel
    |> Ash.Query.filter(
      org_id == ^org_id and item_id == ^item_id and warehouse_id == ^warehouse_id
    )
    |> Ash.read_one!(authorize?: false)
  end

  defp post_entry!(org_id, date, lines, memo, extra \\ %{}) do
    attrs =
      Map.merge(
        %{org_id: org_id, entry_date: date, memo: memo, lines: lines},
        extra
      )

    Erp.JournalEntry
    |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
    |> Ash.create!(authorize?: false)
    |> then(&(Ash.Changeset.for_update(&1, :post, %{}, authorize?: false) |> Ash.update!(authorize?: false)))
  end

  # A DOCUMENT-anchored entry: the shape soft-close refuses (no ledger-internal
  # allowlist key). Used for the RED leg of the lock control.
  defp document_entry(org_id, date) do
    Erp.JournalEntry
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        entry_date: date,
        memo: "A late supplier bill",
        source_key: "ap_invoice",
        source_id: Ecto.UUID.generate(),
        lines: [
          %{account_id: account_id!(org_id, "1300"), debit_cents: 40_000},
          %{account_id: account_id!(org_id, "2100"), credit_cents: 40_000}
        ]
      },
      scope: org_scope(org_id)
    )
    |> Ash.create!()
  end

  defp org_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "m:#{org_id}", org_id: org_id, role: :member, kind: :tenant, plane: :tenant}
    }
  end

  defp standard_line!(org_id, standard_id, item_id, element, qty, price, yield_bp, usage) do
    Erp.CostStandardLine
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        standard_id: standard_id,
        element: element,
        item_id: item_id,
        standard_qty: qty,
        standard_unit_price_cents: price,
        expected_yield_bp: yield_bp,
        usage_basis: usage
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  # ── the ADR-040 Gate (the E2/E8 pattern) ───────────────────────────────────

  defp gate_approve(record, scope) do
    result =
      record
      |> Ash.Changeset.for_update(:approve, %{}, scope: scope)
      |> Ash.update()

    case result do
      {:error, %Ash.Error.Forbidden{errors: errors}} ->
        case Enum.find(errors, &match?(%{__struct__: Samen.Approvals.ApprovalRequired}, &1)) do
          nil -> flunk("expected ApprovalRequired, got: #{inspect(errors)}")
          found -> {:gated, found.approval_id}
        end

      {:ok, _} ->
        flunk("the :approve action succeeded WITHOUT the Gate — the approval discipline is broken")

      {:error, other} ->
        flunk("expected ApprovalRequired, got: #{inspect(other)}")
    end
  end
end
