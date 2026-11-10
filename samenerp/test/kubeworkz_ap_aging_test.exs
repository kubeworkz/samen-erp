defmodule Samenerp.KubeworkzApAgingTest do
  @moduledoc """
  Host proof for the AP read layer: approved `Erp.ApInvoice` bills are the AP
  subledger, and a paid bill is settled by a dual-controlled payment run. AP
  aging buckets the remaining approved bills; a vendor statement combines open
  and paid bills with the effective payment history.
  """

  use Samenerp.DataCase, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.{ApAging, ApPaymentRun}
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

  defp approver_scope(org_id) do
    %Samen.Scope{
      actor: %{
        id: "approver:#{org_id}",
        org_id: org_id,
        role: :admin,
        kind: :tenant,
        plane: :tenant
      }
    }
  end

  defp account!(org_id, code) do
    Erp.Account
    |> Ash.Query.filter(org_id == ^org_id and code == ^code)
    |> Ash.read_one!(authorize?: false)
  end

  defp new_bill(scope, org_id, vendor_id, number, due_date, amount_cents, account) do
    Erp.ApInvoice
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        vendor_id: vendor_id,
        number: number,
        bill_date: ~D[2026-10-01],
        due_date: due_date,
        memo: "Kubeworkz AP aging proof",
        lines: [%{account_id: account.id, amount_cents: amount_cents}]
      },
      scope: scope
    )
    |> Ash.create!(scope: scope)
  end

  defp gate(bill, scope) do
    case bill
         |> Ash.Changeset.for_update(:approve, %{}, scope: scope)
         |> Ash.update() do
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

  defp approve!(bill, org_id, scope) do
    {:gated, approval_id} = gate(bill, scope)

    assert {:ok, _, _} =
             Samen.Approvals.approve(approval_id, "approver:#{org_id}",
               approval_resource: Samenerp.Approvals.Approval,
               repo: Samenerp.Repo
             )

    Ash.get!(Erp.ApInvoice, bill.id, scope: scope)
  end

  test "ages Kubeworkz bills and emits a vendor statement with effective payments" do
    org = create_org!("Kubeworkz AP Aging")
    admin = admin_scope(org.id)

    assert %{cost_objects: %{created: 9}} = Books.seed!(org.id)

    expense = account!(org.id, "6000")
    vendor = Ash.UUID.generate()

    overdue =
      new_bill(admin, org.id, vendor, "KUBE-AP-AGING-001", ~D[2026-09-30], 100_000, expense)
      |> approve!(org.id, admin)

    current =
      new_bill(admin, org.id, vendor, "KUBE-AP-AGING-002", ~D[2026-11-30], 50_000, expense)
      |> approve!(org.id, admin)

    paid_bill =
      new_bill(admin, org.id, vendor, "KUBE-AP-AGING-003", ~D[2026-10-31], 40_000, expense)
      |> approve!(org.id, admin)

    assert {:ok, pending} =
             ApPaymentRun.request(
               ap_invoice: Erp.ApInvoice,
               repo: Samenerp.Repo,
               scope: admin,
               bill_ids: [paid_bill.id],
               payment_date: ~D[2026-10-31],
               reference: "KUBE-AP-AGING-PAID-1"
             )

    assert {:ok, paid} =
             ApPaymentRun.approve(
               ap_invoice: Erp.ApInvoice,
               repo: Samenerp.Repo,
               scope: approver_scope(org.id),
               run_id: pending.id
             )

    assert paid.status == :paid

    assert {:ok, aging} =
             ApAging.for_org(
               ap_invoice: Erp.ApInvoice,
               org_id: org.id,
               scope: admin,
               as_of: ~D[2026-11-15]
             )

    assert aging.total_cents == 150_000
    assert aging.buckets.days_31_60 == 100_000
    assert aging.buckets.current == 50_000
    assert length(aging.bills) == 2
    assert aging.vendor_ids == [vendor]
    refute Enum.any?(aging.bills, &(&1.bill_id == paid_bill.id))

    assert {:ok, statement} =
             ApAging.statement_for_vendor(
               ap_invoice: Erp.ApInvoice,
               repo: Samenerp.Repo,
               org_id: org.id,
               scope: admin,
               vendor_id: vendor,
               as_of: ~D[2026-11-15]
             )

    assert statement.totals == %{
             billed_cents: 190_000,
             paid_cents: 40_000,
             credited_cents: 0,
             outstanding_cents: 150_000
           }

    assert length(statement.bills) == 3
    assert length(statement.payments) == 1
    assert hd(statement.payments).reference == "KUBE-AP-AGING-PAID-1"
    assert statement.aging.total_cents == 150_000

    assert Enum.find(statement.bills, &(&1.bill_id == paid_bill.id)).status == :paid
    assert Enum.find(statement.bills, &(&1.bill_id == overdue.id)).outstanding_cents == 100_000
    assert Enum.find(statement.bills, &(&1.bill_id == current.id)).outstanding_cents == 50_000
  end
end
