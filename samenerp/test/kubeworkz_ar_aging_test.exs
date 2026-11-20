defmodule Samenerp.KubeworkzArAgingTest do
  @moduledoc """
  Host proof for the AR read layer: Billing invoices are the AR document spine,
  and only POSTED `PaymentReceipt` cash reduces an invoice. The first invoice's
  provider mirror claims it is fully paid, but only 40,000 of its 100,000 has
  actually posted — aging must still show 60,000 outstanding.
  """

  use Samenerp.DataCase, async: false

  alias Samen.Scopes.Finance.ArAging
  alias Samenerp.Erp
  alias Samenerp.Kubeworkz.Books
  alias Samenerp.Operator, as: Op

  defp create_org!(name) do
    Op.Org
    |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
    |> Ash.create!(authorize?: false)
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

  defp invoice!(org_id, customer_id, scope, attrs) do
    Samenerp.Billing.Invoice
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          org_id: org_id,
          customer_id: customer_id,
          status: :open,
          amount_due_cents: 0,
          amount_paid_cents: 0,
          currency: "CAD",
          due_date: ~U[2026-10-01 00:00:00Z],
          period_start: ~U[2026-09-01 00:00:00Z],
          period_end: ~U[2026-09-30 00:00:00Z],
          line_items: []
        },
        Map.new(attrs)
      ),
      scope: scope
    )
    |> Ash.create!(scope: scope)
  end

  # Legacy posted cash on a provider-mirror invoice: the B0 guard refuses this
  # through the sanctioned path, so seed the pre-guard fact as it exists in
  # production data. ArAging still reads it (R12 would flag it as contamination).
  defp post_receipt!(org_id, invoice, amount, _scope) do
    Samenerp.Repo.query!("SELECT set_config('samen.finance_posting', 'on', true)")

    %{rows: [[id]]} =
      Samenerp.Repo.query!(
        """
        INSERT INTO ecr_payment_receipt
          (ecr_org_id, ecr_customer_id, ecr_invoice_key, ecr_invoice_id,
           ecr_amount_cents, ecr_currency, ecr_paid_at, ecr_status,
           ecr_inserted_at, ecr_updated_at)
        VALUES ($1, $2, 'billing_invoice', $3, $4, 'CAD', $5, 'posted', $5, $5)
        RETURNING ecr_id
        """,
        [
          Ecto.UUID.dump!(org_id),
          Ecto.UUID.dump!(invoice.customer_id),
          Ecto.UUID.dump!(invoice.id),
          amount,
          ~U[2026-09-15 12:00:00Z]
        ]
      )

    %{id: Ecto.UUID.load!(id)}
  end

  test "ages the host's AR documents and emits a customer statement" do
    org = create_org!("Kubeworkz AR Aging")
    admin = admin_scope(org.id)

    assert %{cost_objects: %{created: 9}} = Books.seed!(org.id)

    customer = customer!(org.id, admin)

    overdue =
      invoice!(org.id, customer.id, admin,
        provider_invoice_ref: "KUBE-AR-001",
        status: :paid,
        amount_due_cents: 100_000,
        amount_paid_cents: 100_000,
        due_date: ~U[2026-09-01 00:00:00Z]
      )

    current =
      invoice!(org.id, customer.id, admin,
        provider_invoice_ref: "KUBE-AR-002",
        amount_due_cents: 50_000,
        due_date: ~U[2026-10-01 00:00:00Z]
      )

    receipt = post_receipt!(org.id, overdue, 40_000, admin)

    assert {:ok, aging} =
             ArAging.for_org(
               invoice: Samenerp.Billing.Invoice,
               receipt: Erp.PaymentReceipt,
               org_id: org.id,
               scope: admin,
               as_of: ~D[2026-10-15]
             )

    assert aging.total_cents == 110_000
    assert aging.buckets.days_1_30 == 50_000
    assert aging.buckets.days_31_60 == 60_000

    assert {:ok, statement} =
             ArAging.statement_for_customer(
               invoice: Samenerp.Billing.Invoice,
               receipt: Erp.PaymentReceipt,
               org_id: org.id,
               scope: admin,
               customer_id: customer.id,
               as_of: ~D[2026-10-15]
             )

    assert statement.totals == %{
             currency: "CAD",
             invoiced_cents: 150_000,
             paid_cents: 40_000,
             credited_cents: 0,
             outstanding_cents: 110_000,
             unapplied_cents: 0
           }

    assert length(statement.invoices) == 2
    assert length(statement.receipts) == 1
    assert hd(statement.receipts).id == receipt.id
    assert statement.aging.total_cents == 110_000

    overdue_row = Enum.find(statement.invoices, &(&1.invoice_id == overdue.id))
    assert overdue_row.paid_cents == 40_000
    assert overdue_row.outstanding_cents == 60_000

    assert hd(statement.receipts).amount_cents == 40_000
    assert length(statement.aging.invoices) == 2

    assert Enum.find(statement.aging.invoices, &(&1.invoice_id == current.id)).outstanding_cents ==
             50_000
  end
end
