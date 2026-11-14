defmodule Samen.FinanceFxRevaluationTest do
  @moduledoc """
  Period-end AP FX revaluation against the close (WS-ACCT close).

  The tests pair the accounting result with the carrying-amount update:
  a CAD-functional org's USD bill is approved at one rate, remeasured at the
  closing rate, and then carried at the remeasured amount so settlement books
  only the subsequent realized difference. A missing closing rate is a
  fail-closed preview/post, not a stale-rate fallback.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.{ApPaymentRun, FxRevaluation, PostingMarker}

  alias SamenCore.Support.FinanceFixture.{
    Account,
    ApInvoice,
    CloseRun,
    ExchangeRate,
    FiscalPeriod,
    JournalEntry,
    JournalLine,
    OrgFxSettings,
    PostingAccount,
    VendorCredit
  }

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()
    {:ok, org: org, admin: admin_scope(org)}
  end

  describe "preview and post" do
    test "a weaker CAD books an unrealized loss and moves the carrying amount", %{
      org: org,
      admin: admin
    } do
      accounts = seed_posting_accounts(org)
      seed_cad_fx!(org, [{~U[2026-09-01 00:00:00Z], "1.35"}, {~U[2026-09-30 00:00:00Z], "1.40"}])

      bill = approved_usd_bill!(org, admin, accounts.expense)
      run = close_run!(org, admin, 2026, 9)

      assert {:ok, preview} = preview_via_close(run, admin)
      assert preview.status == :ready
      assert preview.as_of == ~D[2026-09-30]
      assert preview.base_currency == "CAD"
      assert preview.loss_cents == 500
      assert preview.gain_cents == 0
      assert [row] = preview.bills
      assert row.carrying_base_cents == 13_500
      assert row.remeasured_base_cents == 14_000
      assert row.delta_cents == 500
      assert row.direction == :loss

      # The adjustment is a ledger-internal close entry: it must still land
      # after the document window shuts.
      _soft = period!(org) |> soft_close!(admin)
      assert {:ok, _posted} = post!(run, admin)

      entry = revaluation_entry!(org, run.id)
      lines = entry_lines(entry.id)
      assert entry.status == :posted
      assert entry.entry_date == ~D[2026-09-30]
      assert entry.source_key == "fx_revaluation"
      assert entry.source_id == run.id
      assert Enum.find(lines, &(&1.account_id == accounts.unrealized.id)).debit_cents == 500
      assert Enum.find(lines, &(&1.account_id == accounts.ap.id)).credit_cents == 500
      assert sums_balance?(lines)

      reloaded = Ash.get!(ApInvoice, bill.id, authorize?: false)
      assert reloaded.base_total_cents == 14_000
      assert reloaded.exchange_rate == "1.40"

      # A second run at the same closing rate is a no-op, not a duplicated
      # unrealized entry.
      assert {:ok, noop} = FxRevaluation.preview(run, period!(org), fx_opts())
      assert noop.status == :noop
      assert noop.loss_cents == 0
      assert noop.gain_cents == 0
      assert {:ok, _} = post!(run, admin)
      assert length(revaluation_entries(org, run.id)) == 1
    end

    test "payment after revaluation books only the subsequent realized difference", %{
      org: org,
      admin: admin
    } do
      accounts = seed_posting_accounts(org)

      seed_cad_fx!(org, [
        {~U[2026-09-01 00:00:00Z], "1.35"},
        {~U[2026-09-30 00:00:00Z], "1.40"},
        {~U[2026-10-05 00:00:00Z], "1.38"}
      ])

      bill = approved_usd_bill!(org, admin, accounts.expense)
      run = close_run!(org, admin, 2026, 9)
      assert {:ok, _posted} = post!(run, admin)
      assert Ash.get!(ApInvoice, bill.id, authorize?: false).base_total_cents == 14_000

      assert {:ok, pending} =
               ApPaymentRun.request(
                 ap_invoice: ApInvoice,
                 repo: @repo,
                 scope: admin,
                 bill_ids: [bill.id],
                 payment_date: ~D[2026-10-05],
                 reference: "RUN-FX-REVAL-1"
               )

      assert {:ok, _paid} =
               ApPaymentRun.approve(
                 ap_invoice: ApInvoice,
                 repo: @repo,
                 scope: admin_scope(org, "a2:#{org}"),
                 run_id: pending.id
               )

      payment =
        JournalEntry
        |> Ash.Query.filter(
          org_id == ^org and source_key == "ap_payment" and source_id == ^bill.id
        )
        |> Ash.read_one!(authorize?: false)

      lines = entry_lines(payment.id)
      assert Enum.find(lines, &(&1.account_id == accounts.ap.id)).debit_cents == 14_000
      assert Enum.find(lines, &(&1.account_id == accounts.cash.id)).credit_cents == 13_800
      assert Enum.find(lines, &(&1.account_id == accounts.fx.id)).credit_cents == 200
      refute Enum.any?(lines, &(&1.account_id == accounts.fx.id and (&1.debit_cents || 0) > 0))
      assert sums_balance?(lines)
    end

    test "a stronger CAD books an unrealized gain", %{org: org, admin: admin} do
      accounts = seed_posting_accounts(org)
      seed_cad_fx!(org, [{~U[2026-09-01 00:00:00Z], "1.35"}, {~U[2026-09-30 00:00:00Z], "1.30"}])

      _bill = approved_usd_bill!(org, admin, accounts.expense)
      run = close_run!(org, admin, 2026, 9)

      assert {:ok, preview} = FxRevaluation.preview(run, period!(org), fx_opts())
      assert preview.loss_cents == 0
      assert preview.gain_cents == 500
      assert [row] = preview.bills
      assert row.delta_cents == -500
      assert row.direction == :gain

      assert {:ok, _posted} = post!(run, admin)
      entry = revaluation_entry!(org, run.id)
      lines = entry_lines(entry.id)

      assert Enum.find(lines, &(&1.account_id == accounts.ap.id)).debit_cents == 500
      assert Enum.find(lines, &(&1.account_id == accounts.unrealized.id)).credit_cents == 500
      assert sums_balance?(lines)
    end
  end

  describe "fail closed" do
    test "preview is admin-only and org-scoped", %{org: org, admin: admin} do
      run = close_run!(org, admin, 2026, 9)

      assert {:error, %Ash.Error.Forbidden{}} = preview_via_close(run, tenant_scope(org))

      other_admin = admin_scope(Ash.UUID.generate(), "a:other")

      # A cross-org admin passes the role check but the read policy hides the
      # run as NotFound (not Forbidden), so it cannot even prove it exists.
      assert {:error, %Ash.Error.Invalid{errors: errors}} = preview_via_close(run, other_admin)
      assert Enum.any?(errors, &match?(%Ash.Error.Query.NotFound{}, &1))
    end

    test "a member cannot post and the denial leaves the bill and ledger untouched", %{
      org: org,
      admin: admin
    } do
      accounts = seed_posting_accounts(org)
      seed_cad_fx!(org, [{~U[2026-09-01 00:00:00Z], "1.35"}, {~U[2026-09-30 00:00:00Z], "1.40"}])

      bill = approved_usd_bill!(org, admin, accounts.expense)
      run = close_run!(org, admin, 2026, 9)

      # The admin preview proves the run is ready to post, so the member's
      # denial below is authorization, not an unrelated setup failure.
      assert {:ok, %{status: :ready}} = preview_via_close(run, admin)

      before_bill = Ash.get!(ApInvoice, bill.id, authorize?: false)
      before_ledger = ledger_snapshot(org)

      assert {:error, %Ash.Error.Forbidden{}} = post(run, tenant_scope(org))

      after_bill = Ash.get!(ApInvoice, bill.id, authorize?: false)
      assert after_bill.base_total_cents == before_bill.base_total_cents
      assert after_bill.exchange_rate == before_bill.exchange_rate
      assert after_bill.base_currency == before_bill.base_currency
      assert after_bill.status == before_bill.status
      assert ledger_snapshot(org) == before_ledger
      assert revaluation_entries(org, run.id) == []

      # POSITIVE CONTROL: the same run posts for an admin, so the unchanged
      # bill/ledger above is evidence of the denial, not of a no-op setup.
      assert {:ok, _posted} = post!(run, admin)
      assert [_entry] = revaluation_entries(org, run.id)
      assert Ash.get!(ApInvoice, bill.id, authorize?: false).base_total_cents == 14_000
    end

    test "a missing closing rate refuses preview and post without writing", %{
      org: org,
      admin: admin
    } do
      accounts = seed_posting_accounts(org)
      seed_cad_fx!(org, [])

      bill = force_approved_bill!(org, accounts.expense)
      run = close_run!(org, admin, 2026, 9)

      assert {:error, reason} = FxRevaluation.preview(run, period!(org), fx_opts())
      assert inspect(reason) =~ "rate_not_found"
      assert revaluation_entries(org, run.id) == []

      assert {:error, _} = post!(run, admin)
      assert revaluation_entries(org, run.id) == []

      reloaded = Ash.get!(ApInvoice, bill.id, authorize?: false)
      assert reloaded.base_total_cents == 13_500
      assert reloaded.exchange_rate == "1.35"
    end

    test "a completed close run refuses a post", %{org: org, admin: admin} do
      accounts = seed_posting_accounts(org)
      seed_cad_fx!(org, [{~U[2026-09-01 00:00:00Z], "1.35"}, {~U[2026-09-30 00:00:00Z], "1.40"}])
      _bill = approved_usd_bill!(org, admin, accounts.expense)
      run = close_run!(org, admin, 2026, 9)

      completed = %{run | status: :completed}

      assert {:error, reason} = FxRevaluation.post(completed, fx_opts())
      assert inspect(reason) =~ "close_run_completed"
      assert revaluation_entries(org, run.id) == []
    end
  end

  describe "void after revaluation" do
    test "an admin void clears AP, expense, and cumulative unrealized FX", %{
      org: org,
      admin: admin
    } do
      accounts = seed_posting_accounts(org)

      seed_cad_fx!(org, [
        {~U[2026-09-01 00:00:00Z], "1.35"},
        {~U[2026-09-30 00:00:00Z], "1.40"}
      ])

      bill = approved_usd_bill!(org, admin, accounts.expense)
      run = close_run!(org, admin, 2026, 9)
      assert {:ok, _posted} = post!(run, admin)

      # The revaluation is a period-end fact. Closing the document window must
      # not make the later bill void impossible: its clearing entry is dated
      # today, not the closed bill/revaluation date.
      _soft = period!(org) |> soft_close!(admin)

      assert Ash.get!(ApInvoice, bill.id, authorize?: false).base_total_cents == 14_000
      assert length(revaluation_entries(org, run.id)) == 1

      # A member cannot void a bill; the refusal leaves the bill and ledger
      # untouched (the same red-path discipline as the close actions).
      before = ledger_snapshot(org)
      assert {:error, %Ash.Error.Forbidden{}} = void_bill(bill, tenant_scope(org))
      assert ledger_snapshot(org) == before
      assert Ash.get!(ApInvoice, bill.id, authorize?: false).status == :approved

      assert {:ok, voided} = void_bill(bill, admin)
      assert voided.status == :void
      assert Ash.get!(ApInvoice, bill.id, authorize?: false).status == :void

      entry = ap_void_entry!(org, bill.id)
      lines = entry_lines(entry.id)

      assert entry.status == :posted
      assert entry.source_key == "ap_void"
      assert entry.source_id == bill.id
      assert entry.entry_date == Date.utc_today()
      assert entry.memo == "Void of AP bill #{bill.number}"
      assert account_credits(lines, accounts.expense.id) == 13_500
      assert account_debits(lines, accounts.ap.id) == 14_000
      assert account_credits(lines, accounts.unrealized.id) == 500
      assert sums_balance?(lines)

      # The approval and the close's shared revaluation entry remain posted
      # history. The bill-specific clearing entry nets them to zero, rather
      # than trying to void an entry that also covers other bills.
      assert Ash.get!(JournalEntry, bill.posted_entry_id, authorize?: false).status == :posted
      assert revaluation_entry!(org, run.id).status == :posted

      assert posted_balance(org, accounts.ap.id) == 0
      assert posted_balance(org, accounts.expense.id) == 0
      assert posted_balance(org, accounts.unrealized.id) == 0

      # A second void is refused and cannot duplicate the clearing entry.
      assert {:error, _} = void_bill(voided, admin)
      assert length(ap_void_entries(org, bill.id)) == 1
    end

    test "a revaluation gain is cleared in the opposite direction", %{org: org, admin: admin} do
      accounts = seed_posting_accounts(org)

      seed_cad_fx!(org, [
        {~U[2026-09-01 00:00:00Z], "1.35"},
        {~U[2026-09-30 00:00:00Z], "1.30"}
      ])

      bill = approved_usd_bill!(org, admin, accounts.expense)
      run = close_run!(org, admin, 2026, 9)
      assert {:ok, _posted} = post!(run, admin)
      assert Ash.get!(ApInvoice, bill.id, authorize?: false).base_total_cents == 13_000

      assert {:ok, voided} = void_bill(bill, admin)
      assert voided.status == :void

      lines = entry_lines(ap_void_entry!(org, bill.id).id)

      assert account_debits(lines, accounts.ap.id) == 13_500
      assert account_credits(lines, accounts.ap.id) == 500
      assert account_debits(lines, accounts.unrealized.id) == 500
      assert sums_balance?(lines)

      assert posted_balance(org, accounts.ap.id) == 0
      assert posted_balance(org, accounts.expense.id) == 0
      assert posted_balance(org, accounts.unrealized.id) == 0
    end

    test "an open vendor credit blocks the bill void until it is voided", %{
      org: org,
      admin: admin
    } do
      accounts = seed_posting_accounts(org)
      vendor_credit_clearing = seed_vendor_credit_clearing!(org)

      seed_cad_fx!(org, [
        {~U[2026-09-01 00:00:00Z], "1.35"},
        {~U[2026-09-30 00:00:00Z], "1.40"}
      ])

      bill = approved_usd_bill!(org, admin, accounts.expense)
      run = close_run!(org, admin, 2026, 9)
      assert {:ok, _posted} = post!(run, admin)

      credit = open_vendor_credit!(org, admin, bill)
      assert credit.status == :open

      assert_void_blocked_by_vendor_credit(bill, run, org, admin)

      # POSITIVE CONTROL: once the open credit is voided, the bill can void.
      assert {:ok, %{status: :void}} = void_vendor_credit(credit, admin)
      assert {:ok, voided_bill} = void_bill(bill, admin)
      assert voided_bill.status == :void

      # The vendor credit was voided (its original is history plus a posted
      # reversal), so include void history in this economic net check.
      assert all_entry_balance(org, accounts.ap.id) == 0
      assert all_entry_balance(org, accounts.expense.id) == 0
      assert all_entry_balance(org, accounts.unrealized.id) == 0
      assert all_entry_balance(org, vendor_credit_clearing.id) == 0
    end

    test "an applied vendor credit blocks the bill void", %{org: org, admin: admin} do
      accounts = seed_posting_accounts(org)
      seed_vendor_credit_clearing!(org)

      seed_cad_fx!(org, [
        {~U[2026-09-01 00:00:00Z], "1.35"},
        {~U[2026-09-30 00:00:00Z], "1.40"}
      ])

      bill = approved_usd_bill!(org, admin, accounts.expense)
      run = close_run!(org, admin, 2026, 9)
      assert {:ok, _posted} = post!(run, admin)

      credit = open_vendor_credit!(org, admin, bill) |> apply_vendor_credit!(admin)
      assert credit.status == :applied

      assert_void_blocked_by_vendor_credit(bill, run, org, admin)
    end

    test "a direct JournalEntry void cannot bypass the bill void", %{org: org, admin: admin} do
      accounts = seed_posting_accounts(org)

      seed_cad_fx!(org, [
        {~U[2026-09-01 00:00:00Z], "1.35"},
        {~U[2026-09-30 00:00:00Z], "1.40"}
      ])

      bill = approved_usd_bill!(org, admin, accounts.expense)
      run = close_run!(org, admin, 2026, 9)
      assert {:ok, _posted} = post!(run, admin)

      approval = Ash.get!(JournalEntry, bill.posted_entry_id, authorize?: false)
      before = ledger_snapshot(org)

      assert {:error, error} = direct_void(approval, admin)
      assert inspect(error) =~ "cannot be voided directly"
      assert Ash.get!(JournalEntry, approval.id, authorize?: false).status == :posted
      assert Ash.get!(ApInvoice, bill.id, authorize?: false).status == :approved
      assert revaluation_entry!(org, run.id).status == :posted
      assert ledger_snapshot(org) == before

      # POSITIVE CONTROL: the bill's own void is still the governed path.
      assert {:ok, voided} = void_bill(bill, admin)
      assert voided.status == :void

      clearing = ap_void_entry!(org, bill.id)
      after_bill_void = ledger_snapshot(org)

      assert {:error, clearing_error} = direct_void(clearing, admin)
      assert inspect(clearing_error) =~ "cannot be voided directly"
      assert ledger_snapshot(org) == after_bill_void

      assert posted_balance(org, accounts.ap.id) == 0
      assert posted_balance(org, accounts.expense.id) == 0
      assert posted_balance(org, accounts.unrealized.id) == 0
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp fx_opts do
    [
      ap_invoice: SamenCore.Support.FinanceFixture.ApInvoice,
      entry: SamenCore.Support.FinanceFixture.JournalEntry,
      posting_account: SamenCore.Support.FinanceFixture.PostingAccount,
      org_fx_settings: SamenCore.Support.FinanceFixture.OrgFxSettings,
      exchange_rate: SamenCore.Support.FinanceFixture.ExchangeRate,
      period: SamenCore.Support.FinanceFixture.FiscalPeriod,
      repo: @repo
    ]
  end

  defp tenant_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, kind: :tenant, plane: :tenant}
    }
  end

  defp admin_scope(org_id), do: admin_scope(org_id, "a:#{org_id}")

  defp admin_scope(org_id, actor_id) do
    %Samen.Scope{
      actor: %{id: actor_id, org_id: org_id, role: :admin, kind: :tenant, plane: :tenant}
    }
  end

  defp new_account(scope, org, code, attrs \\ %{}) do
    Account
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{org_id: org, code: code, name: "Account #{code}", kind: :asset, normal_side: :debit},
        attrs
      ),
      scope: scope
    )
    |> Ash.create!()
  end

  defp seed_posting_accounts(org) do
    expense = new_account(tenant_scope(org), org, "6000", %{kind: :expense, normal_side: :debit})
    ap = new_account(tenant_scope(org), org, "2000", %{kind: :liability, normal_side: :credit})

    cash = new_account(tenant_scope(org), org, "1000")
    fx = new_account(tenant_scope(org), org, "7900", %{kind: :income, normal_side: :credit})

    unrealized =
      new_account(tenant_scope(org), org, "7910", %{kind: :income, normal_side: :credit})

    for {key, account} <- [
          {:ap_clearing, ap},
          {:cash, cash},
          {:income, new_account(tenant_scope(org), org, "4000")},
          {:fx_gain_loss, fx},
          {:unrealized_fx_gain_loss, unrealized}
        ] do
      posting_account!(org, key, account)
    end

    %{expense: expense, ap: ap, cash: cash, fx: fx, unrealized: unrealized}
  end

  defp seed_vendor_credit_clearing!(org) do
    account =
      new_account(tenant_scope(org), org, "2100", %{kind: :liability, normal_side: :credit})

    posting_account!(org, :vendor_credit_clearing, account)
    account
  end

  defp posting_account!(org, key, account) do
    PostingAccount
    |> Ash.Changeset.for_create(:create, %{org_id: org, key: key, account_id: account.id},
      scope: admin_scope(org)
    )
    |> Ash.create!()
  end

  defp seed_cad_fx!(org, rates) do
    OrgFxSettings
    |> Ash.Changeset.for_create(:create, %{org_id: org, base_currency: "CAD"},
      scope: admin_scope(org)
    )
    |> Ash.create!()

    Enum.each(rates, fn {valid_at, rate} ->
      ExchangeRate
      |> Ash.Changeset.for_create(
        :create_rate,
        %{
          org_id: org,
          from_currency: "USD",
          to_currency: "CAD",
          rate: rate,
          source: :manual,
          valid_at: valid_at
        },
        scope: admin_scope(org)
      )
      |> Ash.create!()
    end)
  end

  defp preview_via_close(run, admin) do
    CloseRun
    |> Ash.ActionInput.for_action(:preview_fx_revaluation, %{close_run_id: run.id}, scope: admin)
    |> Ash.run_action()
  end

  defp approved_usd_bill!(org, admin, expense) do
    bill =
      ApInvoice
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org,
          vendor_id: Ash.UUID.generate(),
          number: "V-FX-" <> binary_part(Ash.UUID.generate(), 0, 8),
          bill_date: ~D[2026-09-01],
          currency: "USD",
          lines: [%{account_id: expense.id, amount_cents: 10_000}]
        },
        scope: tenant_scope(org)
      )
      |> Ash.create!()

    {:gated, approval_id} = gate(bill, admin)
    assert {:ok, _, _} = decide(approval_id)

    Ash.get!(ApInvoice, bill.id, authorize?: false)
  end

  # Simulate a legacy/manual-approved carrying amount with no rate row. This is
  # the only way an approved foreign bill reaches the close without a rate at
  # or before the period end; the close must still refuse it rather than fall
  # back to a future or stale rate.
  defp force_approved_bill!(org, expense) do
    bill =
      ApInvoice
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org,
          vendor_id: Ash.UUID.generate(),
          number: "V-FX-MISSING-" <> binary_part(Ash.UUID.generate(), 0, 8),
          bill_date: ~D[2026-09-01],
          currency: "USD",
          lines: [%{account_id: expense.id, amount_cents: 10_000}]
        },
        scope: tenant_scope(org)
      )
      |> Ash.create!()

    prior = PostingMarker.arm_now(@repo)

    try do
      bill
      |> Ash.Changeset.for_update(:update, %{}, authorize?: false)
      |> Ash.Changeset.force_change_attribute(:status, :approved)
      |> Ash.Changeset.force_change_attribute(:base_currency, "CAD")
      |> Ash.Changeset.force_change_attribute(:base_total_cents, 13_500)
      |> Ash.Changeset.force_change_attribute(:exchange_rate, "1.35")
      |> Ash.update!(authorize?: false)
    after
      PostingMarker.restore(@repo, prior)
    end
  end

  defp period!(org) do
    FiscalPeriod
    |> Ash.Query.filter(org_id == ^org and year == 2026 and month == 9)
    |> Ash.read_one!(authorize?: false)
  end

  defp soft_close!(period, admin) do
    period
    |> Ash.Changeset.for_update(:soft_close, %{}, scope: admin)
    |> Ash.update!()
  end

  defp close_run!(org, admin, year, month) do
    period =
      FiscalPeriod
      |> Ash.Changeset.for_create(:create, %{org_id: org, year: year, month: month}, scope: admin)
      |> Ash.create!()

    CloseRun
    |> Ash.Changeset.for_create(:start, %{org_id: org, period_id: period.id}, scope: admin)
    |> Ash.create!()
  end

  defp post(run, scope) do
    run
    |> Ash.Changeset.for_update(:post_fx_revaluation, %{}, scope: scope)
    |> Ash.update()
  end

  defp post!(run, admin), do: post(run, admin)

  defp revaluation_entries(org, close_run_id) do
    JournalEntry
    |> Ash.Query.filter(
      org_id == ^org and source_key == "fx_revaluation" and source_id == ^close_run_id
    )
    |> Ash.read!(authorize?: false)
  end

  defp revaluation_entry!(org, close_run_id) do
    case revaluation_entries(org, close_run_id) do
      [entry] -> entry
      [] -> flunk("no fx_revaluation entry was posted")
      entries -> flunk("expected one fx_revaluation entry, got #{length(entries)}")
    end
  end

  defp entry_lines(entry_id) do
    JournalLine
    |> Ash.Query.filter(entry_id == ^entry_id)
    |> Ash.read!(authorize?: false)
  end

  defp void_bill(bill, scope) do
    bill
    |> Ash.Changeset.for_update(:void, %{}, scope: scope)
    |> Ash.update()
  end

  defp open_vendor_credit!(org, admin, bill) do
    credit =
      VendorCredit
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org,
          vendor_id: bill.vendor_id,
          number: "VC-" <> binary_part(Ash.UUID.generate(), 0, 8),
          date: ~D[2026-09-10],
          currency: "USD",
          amount_cents: 500,
          bill_id: bill.id
        },
        scope: admin
      )
      |> Ash.create!()

    credit
    |> Ash.Changeset.for_update(:open, %{}, scope: admin)
    |> Ash.update!()
  end

  defp apply_vendor_credit!(credit, admin) do
    credit
    |> Ash.Changeset.for_update(:apply, %{}, scope: admin)
    |> Ash.update!()
  end

  defp void_vendor_credit(credit, admin) do
    credit
    |> Ash.Changeset.for_update(:void, %{}, scope: admin)
    |> Ash.update()
  end

  defp assert_void_blocked_by_vendor_credit(bill, run, org, admin) do
    before = ledger_snapshot(org)

    assert {:error, error} = void_bill(bill, admin)
    assert inspect(error) =~ "vendor credit"
    assert Ash.get!(ApInvoice, bill.id, authorize?: false).status == :approved
    assert revaluation_entry!(org, run.id).status == :posted
    assert ap_void_entries(org, bill.id) == []
    assert ledger_snapshot(org) == before
  end

  defp direct_void(entry, scope) do
    entry
    |> Ash.Changeset.for_update(:void, %{}, scope: scope)
    |> Ash.update()
  end

  defp ap_void_entries(org, bill_id) do
    JournalEntry
    |> Ash.Query.filter(org_id == ^org and source_key == "ap_void" and source_id == ^bill_id)
    |> Ash.read!(authorize?: false)
  end

  defp ap_void_entry!(org, bill_id) do
    case ap_void_entries(org, bill_id) do
      [entry] -> entry
      [] -> flunk("no ap_void clearing entry was posted")
      entries -> flunk("expected one ap_void clearing entry, got #{length(entries)}")
    end
  end

  defp posted_balance(org, account_id) do
    entry_ids =
      JournalEntry
      |> Ash.Query.filter(org_id == ^org and status == :posted)
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.id)

    account_balance(entry_ids, account_id)
  end

  defp all_entry_balance(org, account_id) do
    entry_ids =
      JournalEntry
      |> Ash.Query.filter(org_id == ^org)
      |> Ash.read!(authorize?: false)
      |> Enum.map(& &1.id)

    account_balance(entry_ids, account_id)
  end

  defp account_balance(entry_ids, account_id) do
    JournalLine
    |> Ash.Query.filter(entry_id in ^entry_ids and account_id == ^account_id)
    |> Ash.read!(authorize?: false)
    |> Enum.reduce(0, fn line, total ->
      total + (line.debit_cents || 0) - (line.credit_cents || 0)
    end)
  end

  defp ledger_snapshot(org) do
    entries =
      JournalEntry
      |> Ash.Query.filter(org_id == ^org)
      |> Ash.read!(authorize?: false)

    entry_ids = Enum.map(entries, & &1.id)

    lines =
      JournalLine
      |> Ash.Query.filter(entry_id in ^entry_ids)
      |> Ash.read!(authorize?: false)

    entry_snapshot =
      entries
      |> Enum.map(&{&1.id, &1.status, &1.source_key, &1.source_id, &1.entry_date})
      |> Enum.sort()

    line_snapshot =
      lines
      |> Enum.map(&{&1.id, &1.entry_id, &1.account_id, &1.debit_cents, &1.credit_cents, &1.memo})
      |> Enum.sort()

    {entry_snapshot, line_snapshot}
  end

  defp sums_balance?(lines) do
    Enum.sum(Enum.map(lines, &(&1.debit_cents || 0))) ==
      Enum.sum(Enum.map(lines, &(&1.credit_cents || 0)))
  end

  defp account_debits(lines, account_id) do
    lines
    |> Enum.filter(&(&1.account_id == account_id))
    |> Enum.reduce(0, fn line, total -> total + (line.debit_cents || 0) end)
  end

  defp account_credits(lines, account_id) do
    lines
    |> Enum.filter(&(&1.account_id == account_id))
    |> Enum.reduce(0, fn line, total -> total + (line.credit_cents || 0) end)
  end

  # The Gate discipline: an ungated :approve fails with ApprovalRequired and
  # returns the pending approval id. A bare success is a broken control.
  defp gate(bill, scope) do
    result =
      bill
      |> Ash.Changeset.for_update(:approve, %{}, scope: scope)
      |> Ash.update()

    case result do
      {:error, %Ash.Error.Forbidden{errors: errors}} ->
        case Enum.find(errors, &match?(%{__struct__: Samen.Approvals.ApprovalRequired}, &1)) do
          nil -> flunk("expected ApprovalRequired, got: #{inspect(errors)}")
          found -> {:gated, found.approval_id}
        end

      {:ok, _} ->
        flunk("the :approve action succeeded WITHOUT the Gate")

      {:error, other} ->
        flunk("unexpected :approve failure: #{inspect(other)}")
    end
  end

  defp decide(approval_id) do
    Samen.Approvals.approve(approval_id, "a2:decider",
      approval_resource: SamenCore.Support.ApprovalsFixture.Approval,
      repo: @repo
    )
  end
end
