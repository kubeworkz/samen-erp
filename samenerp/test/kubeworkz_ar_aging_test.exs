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

  defp post_receipt!(org_id, invoice, amount, scope) do
    Erp.PaymentReceipt
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        invoice_key: "billing_invoice",
        invoice_id: invoice.id,
        amount_cents: amount,
        paid_at: ~U[2026-09-15 12:00:00Z]
      },
      scope: scope
    )
    |> Ash.create!(scope: scope)
    |> then(&(Ash.Changeset.for_update(&1, :post_receipt, %{}, scope: scope) |> Ash.update!()))
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
             invoiced_cents: 150_000,
             paid_cents: 40_000,
             outstanding_cents: 110_000
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
