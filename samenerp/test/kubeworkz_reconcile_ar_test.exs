defmodule Samenerp.KubeworkzReconcileArTest do
  @moduledoc """
  Host R12 proof: a provider-mirror invoice is excluded from the local aging
  and counted as excluded; a receipt or allocation linked to it is
  contamination even when the cents happen to net.
  """

  use Samenerp.DataCase, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.{ArReceiptApplication, ReconcileAr}
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
    legacy_provider_receipt!(org.id, customer.id, provider_invoice.id, 10_000)

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

    legacy_provider_allocation!(org.id, receipt.id, provider_invoice.id, 4_000)

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

  test "a provider-mirror invoice refuses local receipts", %{
    org: org,
    admin: admin,
    customer: customer
  } do
    Books.seed!(org.id)

    provider_invoice = provider_invoice!(org.id, customer.id, admin)
    local_invoice = local_invoice!(org.id, customer.id, admin)

    assert {:error, error} =
             attempt_receipt(org.id, admin, customer.id, provider_invoice.id, 10_000)

    assert inspect(error) =~ "provider_invoice_not_local"
    assert receipts(org.id) == []

    assert {:ok, receipt} =
             attempt_receipt(org.id, admin, customer.id, local_invoice.id, 10_000)

    assert receipt.invoice_id == local_invoice.id
    assert receipt.status == :draft
  end

  test "a provider-mirror invoice refuses a customer cash application", %{
    org: org,
    admin: admin,
    customer: customer
  } do
    Books.seed!(org.id)

    provider_invoice = provider_invoice!(org.id, customer.id, admin)

    assert {:error, {:provider_invoice_not_local, provider_id}} =
             ArReceiptApplication.apply(
               invoice: Samenerp.Billing.Invoice,
               receipt: Erp.PaymentReceipt,
               receipt_allocation: Erp.ReceiptAllocation,
               repo: Samenerp.Repo,
               scope: admin,
               org_id: org.id,
               customer_id: customer.id,
               paid_at: ~U[2026-11-08 00:00:00Z],
               allocations: [%{invoice_id: provider_invoice.id, amount_cents: 5_000}]
             )

    assert provider_id == provider_invoice.id
    assert receipts(org.id) == []

    # CONTROL: the same service still posts on-account cash once.
    assert {:ok, run} =
             ArReceiptApplication.apply(
               invoice: Samenerp.Billing.Invoice,
               receipt: Erp.PaymentReceipt,
               receipt_allocation: Erp.ReceiptAllocation,
               repo: Samenerp.Repo,
               scope: admin,
               org_id: org.id,
               customer_id: customer.id,
               paid_at: ~U[2026-11-08 00:00:00Z],
               currency: "CAD",
               unapplied_cents: 5_000
             )

    assert run.credit_receipt.status == :posted
  end

  test "applying on-account cash to a provider-mirror invoice is refused", %{
    org: org,
    admin: admin,
    customer: customer
  } do
    Books.seed!(org.id)

    provider_invoice = provider_invoice!(org.id, customer.id, admin)
    local_invoice = local_invoice!(org.id, customer.id, admin)

    assert {:ok, run} =
             ArReceiptApplication.apply(
               invoice: Samenerp.Billing.Invoice,
               receipt: Erp.PaymentReceipt,
               receipt_allocation: Erp.ReceiptAllocation,
               repo: Samenerp.Repo,
               scope: admin,
               org_id: org.id,
               customer_id: customer.id,
               paid_at: ~U[2026-11-08 00:00:00Z],
               currency: "CAD",
               unapplied_cents: 5_000
             )

    assert {:error, {:provider_invoice_not_local, provider_id}} =
             ArReceiptApplication.apply_credit(
               invoice: Samenerp.Billing.Invoice,
               receipt: Erp.PaymentReceipt,
               receipt_allocation: Erp.ReceiptAllocation,
               repo: Samenerp.Repo,
               scope: admin,
               org_id: org.id,
               customer_id: customer.id,
               receipt_id: run.credit_receipt.id,
               invoice_id: provider_invoice.id,
               amount_cents: 2_000
             )

    assert provider_id == provider_invoice.id
    assert allocations(org.id) == []

    # CONTROL: the same cash applies to a local invoice.
    assert {:ok, allocation} =
             ArReceiptApplication.apply_credit(
               invoice: Samenerp.Billing.Invoice,
               receipt: Erp.PaymentReceipt,
               receipt_allocation: Erp.ReceiptAllocation,
               repo: Samenerp.Repo,
               scope: admin,
               org_id: org.id,
               customer_id: customer.id,
               receipt_id: run.credit_receipt.id,
               invoice_id: local_invoice.id,
               amount_cents: 2_000
             )

    assert allocation.invoice_id == local_invoice.id
  end

  test "a direct allocation to a provider-mirror invoice is refused", %{
    org: org,
    admin: admin,
    customer: customer
  } do
    Books.seed!(org.id)

    provider_invoice = provider_invoice!(org.id, customer.id, admin)
    local_invoice = local_invoice!(org.id, customer.id, admin)

    assert {:ok, run} =
             ArReceiptApplication.apply(
               invoice: Samenerp.Billing.Invoice,
               receipt: Erp.PaymentReceipt,
               receipt_allocation: Erp.ReceiptAllocation,
               repo: Samenerp.Repo,
               scope: admin,
               org_id: org.id,
               customer_id: customer.id,
               paid_at: ~U[2026-11-08 00:00:00Z],
               currency: "CAD",
               unapplied_cents: 5_000
             )

    receipt = run.credit_receipt

    assert {:error, error} =
             attempt_allocation(org.id, admin, receipt.id, provider_invoice.id, 4_000)

    assert inspect(error) =~ "provider_invoice_not_local"
    assert allocations(org.id) == []

    assert {:ok, allocation} =
             attempt_allocation(org.id, admin, receipt.id, local_invoice.id, 4_000)

    assert allocation.invoice_id == local_invoice.id
  end

  test "a credit note against a provider-mirror invoice refuses before posting", %{
    org: org,
    admin: admin,
    customer: customer
  } do
    Books.seed!(org.id)

    provider_invoice = provider_invoice!(org.id, customer.id, admin)
    local_invoice = local_invoice!(org.id, customer.id, admin)
    map_credit_note_clearing!(org.id, admin)

    provider_note = credit_note!(org.id, admin, customer.id, provider_invoice.id)

    assert {:error, error} =
             provider_note
             |> Ash.Changeset.for_update(:open, %{}, scope: admin)
             |> Ash.update()

    assert inspect(error) =~ "provider_invoice_not_local"
    assert Ash.get!(Erp.CreditNote, provider_note.id, authorize?: false).status == :draft
    assert entries_for_note(provider_note.id) == []

    # CONTROL: a local invoice still opens a credit note and posts its entry.
    local_note = credit_note!(org.id, admin, customer.id, local_invoice.id)

    assert {:ok, opened} =
             local_note
             |> Ash.Changeset.for_update(:open, %{}, scope: admin)
             |> Ash.update()

    assert opened.status == :open
    assert [_entry] = entries_for_note(local_note.id)
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

  defp attempt_receipt(org_id, scope, customer_id, invoice_id, amount_cents) do
    Erp.PaymentReceipt
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        customer_id: customer_id,
        invoice_key: "billing_invoice",
        invoice_id: invoice_id,
        amount_cents: amount_cents,
        currency: "CAD",
        paid_at: DateTime.utc_now() |> DateTime.truncate(:second)
      },
      scope: scope
    )
    |> Ash.create(scope: scope)
  end

  defp attempt_allocation(org_id, scope, receipt_id, invoice_id, amount_cents) do
    Erp.ReceiptAllocation
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        receipt_id: receipt_id,
        invoice_key: "billing_invoice",
        invoice_id: invoice_id,
        amount_cents: amount_cents,
        currency: "CAD",
        applied_at: DateTime.utc_now() |> DateTime.truncate(:second)
      },
      scope: scope
    )
    |> Ash.create(scope: scope)
  end

  defp receipts(org_id) do
    Erp.PaymentReceipt
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.read!(authorize?: false)
  end

  defp allocations(org_id) do
    Erp.ReceiptAllocation
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.read!(authorize?: false)
  end

  defp entries_for_note(note_id) do
    Erp.JournalEntry
    |> Ash.Query.filter(source_key == "credit_note" and source_id == ^note_id)
    |> Ash.read!(authorize?: false)
  end

  defp local_invoice!(org_id, customer_id, scope) do
    invoice =
      Samenerp.Billing.Invoice
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org_id,
          customer_id: customer_id,
          status: :draft,
          amount_due_cents: 50_000,
          amount_paid_cents: 0,
          currency: "CAD",
          due_date: ~U[2026-10-01 00:00:00Z],
          period_start: ~U[2026-09-01 00:00:00Z],
          period_end: ~U[2026-09-30 00:00:00Z],
          line_items: []
        },
        scope: scope
      )
      |> Ash.create!(scope: scope)

    invoice
    |> Ash.Changeset.for_update(:issue, %{}, scope: scope)
    |> Ash.update!()
  end

  defp map_credit_note_clearing!(org_id, scope) do
    account =
      Erp.Account
      |> Ash.Query.filter(org_id == ^org_id and code == "4000")
      |> Ash.read_one!(authorize?: false)

    Erp.PostingAccount
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org_id, key: :credit_note_clearing, account_id: account.id},
      scope: scope
    )
    |> Ash.create!(scope: scope)
  end

  defp legacy_provider_receipt!(org_id, customer_id, invoice_id, amount_cents) do
    # R12 reads posted receipts; seed the posted fact below the B0 receipt
    # guard so the test isolates the legacy contamination signal.
    Samenerp.Repo.query!("SELECT set_config('samen.finance_posting', 'on', true)")

    Samenerp.Repo.query!(
      """
      INSERT INTO ecr_payment_receipt
        (ecr_org_id, ecr_customer_id, ecr_invoice_key, ecr_invoice_id,
         ecr_amount_cents, ecr_currency, ecr_paid_at, ecr_status,
         ecr_inserted_at, ecr_updated_at)
      VALUES ($1, $2, 'billing_invoice', $3, $4, 'CAD', $5, 'posted', $5, $5)
      """,
      [
        Ecto.UUID.dump!(org_id),
        Ecto.UUID.dump!(customer_id),
        Ecto.UUID.dump!(invoice_id),
        amount_cents,
        DateTime.utc_now() |> DateTime.truncate(:second)
      ]
    )

    :ok
  end

  defp legacy_provider_allocation!(org_id, receipt_id, invoice_id, amount_cents) do
    Samenerp.Repo.query!(
      """
      INSERT INTO eaa_receipt_allocation
        (eaa_org_id, eaa_receipt_id, eaa_invoice_key, eaa_invoice_id,
         eaa_amount_cents, eaa_currency, eaa_applied_at, eaa_inserted_at, eaa_updated_at)
      VALUES ($1, $2, 'billing_invoice', $3, $4, 'CAD', $5, $5, $5)
      """,
      [
        Ecto.UUID.dump!(org_id),
        Ecto.UUID.dump!(receipt_id),
        Ecto.UUID.dump!(invoice_id),
        amount_cents,
        DateTime.utc_now() |> DateTime.truncate(:second)
      ]
    )

    :ok
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
