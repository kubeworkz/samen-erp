defmodule Samenerp.KubeworkzReconcileArTest do
  @moduledoc """
  Host R12 proof: a provider-mirror invoice is excluded from the local aging
  and counted as excluded; a receipt or allocation linked to it is
  contamination even when the cents happen to net.
  """

  use Samenerp.DataCase, async: false

  alias Samen.Scopes.Finance.ReconcileAr
  alias Samenerp.Erp
  alias Samenerp.Kubeworkz.Books
  alias Samenerp.Operator, as: Op

  setup do
    org =
      Op.Org
      |> Ash.Changeset.for_create(:create, %{name: "Kubeworkz AR Reconcile"}, authorize?: false)
      |> Ash.create!(authorize?: false)

    admin = admin_scope(org.id)
    customer = customer!(org.id, admin)

    {:ok, org: org, admin: admin, customer: customer}
  end

  test "a provider-mirror invoice is excluded and counted", %{
    org: org,
    admin: admin,
    customer: customer
  } do
    Books.seed!(org.id)

    provider_invoice =
      provider_invoice!(org.id, customer.id, admin, %{
        status: :paid,
        amount_paid_cents: 50_000
      })

    assert {:ok, report} = reconcile(org.id, admin)

    assert report.aging_cents == 0
    assert report.unapplied_cents == 0
    assert report.expected_gl_cents == 0
    assert report.gl_cents == 0
    assert report.difference_cents == 0
    assert report.balanced?
    assert report.excluded_provider_invoices == 1
    assert report.provider_linked_receipts == 0
    assert report.provider_linked_credit_notes == 0
    assert report.provider_linked_allocations == 0
    refute report.contaminated?

    assert provider_invoice.provider_invoice_ref == "KUBE-PROVIDER-R12"
  end

  test "a posted provider-linked receipt is contamination even when it nets", %{
    org: org,
    admin: admin,
    customer: customer
  } do
    Books.seed!(org.id)

    provider_invoice = provider_invoice!(org.id, customer.id, admin)
    receipt = receipt!(org.id, admin, customer.id, provider_invoice.id, 10_000)
    mark_receipt_posted!(receipt.id)

    assert {:ok, report} = reconcile(org.id, admin)

    assert report.aging_cents == 0
    assert report.expected_gl_cents == 0
    assert report.gl_cents == 0
    assert report.difference_cents == 0
    refute report.balanced?
    assert report.excluded_provider_invoices == 1
    assert report.provider_linked_receipts == 1
    assert report.provider_linked_allocations == 0
    assert report.contaminated?
  end

  test "an open provider-linked credit note is contamination", %{
    org: org,
    admin: admin,
    customer: customer
  } do
    Books.seed!(org.id)

    provider_invoice = provider_invoice!(org.id, customer.id, admin)
    credit_note = credit_note!(org.id, admin, customer.id, provider_invoice.id)
    mark_credit_note_open!(credit_note.id)

    assert {:ok, report} = reconcile(org.id, admin)

    assert report.aging_cents == 0
    assert report.expected_gl_cents == 0
    assert report.gl_cents == 0
    assert report.difference_cents == 0
    refute report.balanced?
    assert report.excluded_provider_invoices == 1
    assert report.provider_linked_credit_notes == 1
    assert report.contaminated?
  end

  test "an on-account receipt allocated to a provider invoice is contamination", %{
    org: org,
    admin: admin,
    customer: customer
  } do
    Books.seed!(org.id)

    provider_invoice = provider_invoice!(org.id, customer.id, admin)
    receipt = receipt!(org.id, admin, customer.id, nil, 10_000)
    mark_receipt_posted!(receipt.id)

    allocation =
      Erp.ReceiptAllocation
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org.id,
          receipt_id: receipt.id,
          invoice_key: "billing_invoice",
          invoice_id: provider_invoice.id,
          amount_cents: 4_000,
          currency: "CAD",
          applied_at: DateTime.utc_now() |> DateTime.truncate(:second)
        },
        scope: admin
      )
      |> Ash.create!(scope: admin)

    assert allocation.invoice_id == provider_invoice.id

    assert {:ok, report} = reconcile(org.id, admin)

    assert report.aging_cents == 0
    assert report.unapplied_cents == 0
    assert report.expected_gl_cents == 0
    assert report.gl_cents == 0
    assert report.difference_cents == 0
    refute report.balanced?
    assert report.excluded_provider_invoices == 1
    assert report.provider_linked_receipts == 1
    assert report.provider_linked_allocations == 1
    assert report.contaminated?
  end

  defp reconcile(org_id, scope) do
    ReconcileAr.for_org(
      invoice: Samenerp.Billing.Invoice,
      receipt: Erp.PaymentReceipt,
      receipt_allocation: Erp.ReceiptAllocation,
      credit_note: Erp.CreditNote,
      org_id: org_id,
      scope: scope,
      as_of: Date.utc_today(),
      posting_account: Erp.PostingAccount,
      entry: Erp.JournalEntry,
      line: Erp.JournalLine,
      repo: Samenerp.Repo
    )
  end

  defp admin_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "admin:#{org_id}", org_id: org_id, role: :admin, kind: :tenant, plane: :tenant}
    }
  end

  defp customer!(org_id, scope) do
    Samenerp.Billing.Customer
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, currency: "CAD"}, scope: scope)
    |> Ash.create!(scope: scope)
  end

  defp provider_invoice!(org_id, customer_id, scope, attrs \\ %{}) do
    attrs =
      Map.merge(
        %{
          org_id: org_id,
          customer_id: customer_id,
          provider_invoice_ref: "KUBE-PROVIDER-R12",
          status: :open,
          amount_due_cents: 50_000,
          amount_paid_cents: 0,
          currency: "CAD",
          due_date: ~U[2026-10-01 00:00:00Z],
          period_start: ~U[2026-09-01 00:00:00Z],
          period_end: ~U[2026-09-30 00:00:00Z],
          line_items: []
        },
        attrs
      )

    Samenerp.Billing.Invoice
    |> Ash.Changeset.for_create(:create, attrs, scope: scope)
    |> Ash.create!(scope: scope)
  end

  defp receipt!(org_id, scope, customer_id, invoice_id, amount_cents) do
    attrs = %{
      org_id: org_id,
      customer_id: customer_id,
      amount_cents: amount_cents,
      currency: "CAD",
      paid_at: DateTime.utc_now() |> DateTime.truncate(:second)
    }

    attrs =
      if invoice_id do
        Map.merge(attrs, %{invoice_key: "billing_invoice", invoice_id: invoice_id})
      else
        attrs
      end

    Erp.PaymentReceipt
    |> Ash.Changeset.for_create(:create, attrs, scope: scope)
    |> Ash.create!(scope: scope)
  end

  defp credit_note!(org_id, scope, customer_id, invoice_id) do
    Erp.CreditNote
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        customer_id: customer_id,
        number: "CN-R12-" <> binary_part(Ash.UUID.generate(), 0, 8),
        date: Date.utc_today(),
        currency: "CAD",
        amount_cents: 2_000,
        kind: :credit,
        invoice_id: invoice_id
      },
      scope: scope
    )
    |> Ash.create!(scope: scope)
  end

  defp mark_credit_note_open!(credit_note_id) do
    # R12 only reads the document state; this lands the open credit fact below
    # the posting action so the test isolates the contamination signal.
    Samenerp.Repo.query!(
      "UPDATE ecn_credit_note SET ecn_status = 'open' WHERE ecn_id = $1",
      [Ecto.UUID.dump!(credit_note_id)]
    )
  end

  defp mark_receipt_posted!(receipt_id) do
    # R12 only reads posted receipts. The normal :post_receipt path would also
    # post a cash/AR entry; this test is about the provider-link contamination
    # signal, so land the posted fact directly below the ledger.
    Samenerp.Repo.query!("SELECT set_config('samen.finance_posting', 'on', true)")

    Samenerp.Repo.query!(
      "UPDATE ecr_payment_receipt SET ecr_status = 'posted' WHERE ecr_id = $1",
      [Ecto.UUID.dump!(receipt_id)]
    )
  end
end
