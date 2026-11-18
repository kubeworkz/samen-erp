defmodule Samen.FinanceReconcileArTest do
  @moduledoc """
  R12 red/green proof: local AR aging less local on-account cash must equal the
  posted `:ar_clearing` balance; a missing or misvalued GL posting diverges;
  an unmapped clearing account refuses fail-honest.
  """

  use ExUnit.Case, async: false

  alias Samen.Scopes.Finance.{CloseBoard, ReconcileAr}

  alias SamenCore.Support.FinanceFixture.{
    Account,
    CreditNote,
    InvoiceMirror,
    JournalEntry,
    JournalLine,
    PaymentReceipt,
    PostingAccount,
    ReceiptAllocation
  }

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()

    {:ok, org: org, scope: admin_scope(org)}
  end

  test "local aging less unapplied cash ties to the ar_clearing GL balance", %{
    org: org,
    scope: scope
  } do
    accounts = seed_posting_accounts(org)
    invoice = new_invoice(org, amount_due_cents: 10_000)

    _entry =
      new_posted_entry(org, scope, [
        %{account_id: accounts.ar_clearing.id, debit_cents: 10_000, credit_cents: 0},
        %{account_id: accounts.income.id, debit_cents: 0, credit_cents: 10_000}
      ])

    receipt = new_on_account_receipt(scope, org, invoice.customer_id, 3_000)
    _posted = post_receipt!(receipt, scope)

    assert {:ok, report} = reconcile(org, scope)

    assert report.aging_cents == 10_000
    assert report.unapplied_cents == 3_000
    assert report.expected_gl_cents == 7_000
    assert report.gl_cents == 7_000
    assert report.difference_cents == 0
    assert report.balanced?
    assert report.excluded_provider_invoices == 0
    assert report.provider_linked_receipts == 0
    assert report.provider_linked_credit_notes == 0
    assert report.provider_linked_allocations == 0
    refute report.contaminated?

    assert accounts.ar_clearing.id
  end

  test "the period-end close board carries the R12 tie and contamination verdict", %{
    org: org,
    scope: scope
  } do
    accounts = seed_posting_accounts(org)
    invoice = new_invoice(org, amount_due_cents: 10_000)

    _entry =
      new_posted_entry(org, scope, [
        %{account_id: accounts.ar_clearing.id, debit_cents: 10_000, credit_cents: 0},
        %{account_id: accounts.income.id, debit_cents: 0, credit_cents: 10_000}
      ])

    receipt = new_on_account_receipt(scope, org, invoice.customer_id, 3_000)
    _posted = post_receipt!(receipt, scope)

    assert {:ok, report} = reconcile(org, scope)
    assert report.difference_cents == 0
    assert report.balanced?
    refute report.contaminated?

    run = %{
      id: Ash.UUID.generate(),
      status: :in_progress,
      started_at: DateTime.utc_now() |> DateTime.truncate(:second),
      completed_at: nil,
      phases: []
    }

    period = %{id: Ash.UUID.generate(), year: 2026, month: 9, status: :open}

    board = CloseBoard.report(run, period: period, ar_reconciliation: report)

    assert board.period == period
    assert board.ar_reconciliation == report
    assert board.ar_reconciliation.aging_cents == 10_000
    assert board.ar_reconciliation.unapplied_cents == 3_000
    assert board.ar_reconciliation.expected_gl_cents == 7_000
    assert board.ar_reconciliation.gl_cents == 7_000
    assert board.ar_reconciliation.difference_cents == 0
    assert board.ar_reconciliation.balanced?
    refute board.ar_reconciliation.contaminated?

    contaminated = %{
      report
      | balanced?: false,
        contaminated?: true,
        provider_linked_receipts: 1,
        provider_linked_allocations: 1
    }

    board = CloseBoard.report(run, period: period, ar_reconciliation: contaminated)

    refute board.ar_reconciliation.balanced?
    assert board.ar_reconciliation.contaminated?
    assert board.ar_reconciliation.provider_linked_receipts == 1
    assert board.ar_reconciliation.provider_linked_allocations == 1
  end

  test "a posted local credit reduces both the aging and the GL", %{org: org, scope: scope} do
    accounts = seed_posting_accounts(org)
    invoice = new_invoice(org, amount_due_cents: 10_000)

    _entry =
      new_posted_entry(org, scope, [
        %{account_id: accounts.ar_clearing.id, debit_cents: 10_000, credit_cents: 0},
        %{account_id: accounts.income.id, debit_cents: 0, credit_cents: 10_000}
      ])

    credit =
      scope
      |> new_credit_note(org, invoice, amount_cents: 2_000)
      |> open_credit!(scope)

    assert credit.status == :open

    assert {:ok, report} = reconcile(org, scope)
    assert report.aging_cents == 8_000
    assert report.unapplied_cents == 0
    assert report.expected_gl_cents == 8_000
    assert report.gl_cents == 8_000
    assert report.difference_cents == 0
    assert report.balanced?
    refute report.contaminated?
  end

  test "a local invoice with no GL posting diverges (the missing-posting red path)", %{
    org: org,
    scope: scope
  } do
    _accounts = seed_posting_accounts(org)
    _invoice = new_invoice(org, amount_due_cents: 4_500, status: :open)

    assert {:ok, report} = reconcile(org, scope)
    assert report.aging_cents == 4_500
    assert report.expected_gl_cents == 4_500
    assert report.gl_cents == 0
    assert report.difference_cents == -4_500
    refute report.balanced?
    refute report.contaminated?
  end

  test "a misvalued GL posting diverges even when the document rows say otherwise", %{
    org: org,
    scope: scope
  } do
    accounts = seed_posting_accounts(org)
    _invoice = new_invoice(org, amount_due_cents: 10_000)

    _entry =
      new_posted_entry(org, scope, [
        %{account_id: accounts.ar_clearing.id, debit_cents: 10_000, credit_cents: 0},
        %{account_id: accounts.income.id, debit_cents: 0, credit_cents: 10_000}
      ])

    # The subledger still says 10_000; this extra posted credit makes the GL
    # carry 9_000. The reconciliation must surface the difference rather than
    # deriving the GL number from the invoice rows.
    _entry =
      new_posted_entry(org, scope, [
        %{account_id: accounts.income.id, debit_cents: 1_000, credit_cents: 0},
        %{account_id: accounts.ar_clearing.id, debit_cents: 0, credit_cents: 1_000}
      ])

    assert {:ok, report} = reconcile(org, scope)
    assert report.aging_cents == 10_000
    assert report.expected_gl_cents == 10_000
    assert report.gl_cents == 9_000
    assert report.difference_cents == -1_000
    refute report.balanced?
  end

  test "an unmapped :ar_clearing refuses fail-honest", %{org: org, scope: scope} do
    _invoice = new_invoice(org, amount_due_cents: 5_000, status: :open)

    assert {:error, error} = reconcile(org, scope)
    assert inspect(error) =~ "unmapped_posting_account"
    assert inspect(error) =~ "ar_clearing"
  end

  defp reconcile(org, scope) do
    ReconcileAr.for_org(
      invoice: InvoiceMirror,
      receipt: PaymentReceipt,
      receipt_allocation: ReceiptAllocation,
      credit_note: CreditNote,
      org_id: org,
      scope: scope,
      as_of: Date.utc_today(),
      posting_account: PostingAccount,
      entry: JournalEntry,
      line: JournalLine,
      repo: @repo
    )
  end

  defp admin_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "a:#{org_id}", org_id: org_id, role: :admin, kind: :tenant, plane: :tenant}
    }
  end

  defp new_account(org, code, kind, side) do
    Account
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org, code: code, name: "Account #{code}", kind: kind, normal_side: side},
      scope: admin_scope(org)
    )
    |> Ash.create!()
  end

  defp seed_posting_accounts(org) do
    Map.new(
      [
        {:ar_clearing, "1200", :asset, :debit},
        {:cash, "1000", :asset, :debit},
        {:income, "4000", :income, :credit},
        {:credit_note_clearing, "4900", :asset, :debit}
      ],
      fn {key, code, kind, side} ->
        account = new_account(org, code, kind, side)

        PostingAccount
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org, key: key, account_id: account.id},
          scope: admin_scope(org)
        )
        |> Ash.create!()

        {key, account}
      end
    )
  end

  defp new_invoice(org, attrs) do
    attrs =
      Map.merge(
        %{
          org_id: org,
          customer_id: Ash.UUID.generate(),
          amount_due_cents: 10_000,
          amount_paid_cents: 0,
          status: :open,
          currency: "USD",
          line_items: []
        },
        Map.new(attrs)
      )

    InvoiceMirror
    |> Ash.Changeset.for_create(:create, attrs, scope: admin_scope(org))
    |> Ash.create!()
  end

  defp new_on_account_receipt(scope, org, customer_id, amount_cents) do
    PaymentReceipt
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        customer_id: customer_id,
        amount_cents: amount_cents,
        currency: "USD",
        paid_at: DateTime.utc_now() |> DateTime.truncate(:second)
      },
      scope: scope
    )
    |> Ash.create!()
  end

  defp new_credit_note(scope, org, invoice, attrs) do
    attrs =
      Map.merge(
        %{
          org_id: org,
          customer_id: invoice.customer_id,
          number: "CN-" <> binary_part(Ash.UUID.generate(), 0, 8),
          date: Date.utc_today(),
          amount_cents: 2_000,
          kind: :credit,
          invoice_id: invoice.id,
          currency: "USD"
        },
        Map.new(attrs)
      )

    CreditNote
    |> Ash.Changeset.for_create(:create, attrs, scope: scope)
    |> Ash.create!()
  end

  defp post_receipt!(receipt, scope) do
    receipt
    |> Ash.Changeset.for_update(:post_receipt, %{}, scope: scope)
    |> Ash.update!()
  end

  defp open_credit!(credit, scope) do
    credit
    |> Ash.Changeset.for_update(:open, %{}, scope: scope)
    |> Ash.update!()
  end

  defp new_posted_entry(org, scope, lines) do
    entry =
      JournalEntry
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org,
          entry_date: Date.utc_today(),
          memo: "R12 misvalue",
          lines: lines
        },
        scope: scope
      )
      |> Ash.create!()

    entry
    |> Ash.Changeset.for_update(:post, %{}, scope: scope)
    |> Ash.update!()
  end
end
