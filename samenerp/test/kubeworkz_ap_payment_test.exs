defmodule Samenerp.KubeworkzApPaymentTest do
  @moduledoc """
  The Kubeworkz host proof for the AP lifecycle's payment half: two approved
  vendor bills are paid in one run, each payment lands as its own posted
  `ap_payment` entry (Dr AP clearing / Cr cash), the bills become `:paid`, and
  the run emits remittance advice. A second attempt on a paid bill is refused.
  """

  use Samenerp.DataCase, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.ApPaymentRun
  alias Samen.Scopes.Finance.Reconcile
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

  defp account!(org_id, code) do
    Erp.Account
    |> Ash.Query.filter(org_id == ^org_id and code == ^code)
    |> Ash.read_one!(authorize?: false)
  end

  defp new_bill(scope, org_id, vendor_id, number, amount_cents, account) do
    Erp.ApInvoice
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org_id,
        vendor_id: vendor_id,
        number: number,
        bill_date: ~D[2026-10-01],
        due_date: ~D[2026-10-31],
        memo: "Kubeworkz AP payment proof",
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

  defp payment_entries(org_id, bill_ids) do
    Erp.JournalEntry
    |> Ash.Query.filter(
      org_id == ^org_id and source_key == "ap_payment" and source_id in ^bill_ids
    )
    |> Ash.read!(authorize?: false)
  end

  defp lines(entry_id) do
    Erp.JournalLine
    |> Ash.Query.filter(entry_id == ^entry_id)
    |> Ash.read!(authorize?: false)
  end

  test "a run pays two approved Kubeworkz bills and emits remittance" do
    org = create_org!("Kubeworkz AP Payment Run")
    admin = admin_scope(org.id)

    assert %{cost_objects: %{created: 9}} = Books.seed!(org.id)

    expense = account!(org.id, "6000")
    cash = account!(org.id, "1000")
    ap = account!(org.id, "2000")
    vendor = Ash.UUID.generate()

    first =
      new_bill(admin, org.id, vendor, "AP-PAY-001", 125_000, expense)
      |> approve!(org.id, admin)

    second =
      new_bill(admin, org.id, vendor, "AP-PAY-002", 250_000, expense)
      |> approve!(org.id, admin)

    assert {:ok, run} =
             ApPaymentRun.pay(
               ap_invoice: Erp.ApInvoice,
               repo: Samenerp.Repo,
               scope: admin,
               bill_ids: [first.id, second.id],
               payment_date: ~D[2026-10-31],
               reference: "KUBE-AP-RUN-1"
             )

    assert run.reference == "KUBE-AP-RUN-1"
    assert run.vendor_id == vendor
    assert run.total_cents == 375_000

    assert Ash.get!(Erp.ApInvoice, first.id, authorize?: false).status == :paid
    assert Ash.get!(Erp.ApInvoice, second.id, authorize?: false).status == :paid

    entries = payment_entries(org.id, [first.id, second.id])
    assert length(entries) == 2
    assert Enum.all?(entries, &(&1.status == :posted))

    first_entry = Enum.find(entries, &(&1.source_id == first.id))
    assert first_entry.memo =~ "KUBE-AP-RUN-1"

    first_lines = lines(first_entry.id)
    assert Enum.any?(first_lines, &(&1.account_id == ap.id and &1.debit_cents == 125_000))
    assert Enum.any?(first_lines, &(&1.account_id == cash.id and &1.credit_cents == 125_000))

    assert Reconcile.org_balance(org.id, Samenerp.Repo, line_resource: Erp.JournalLine) ==
             {:ok, 0}

    csv = ApPaymentRun.remittance_csv(run)
    assert csv =~ "KUBE-AP-RUN-1"
    assert csv =~ "AP-PAY-001"
    assert csv =~ "AP-PAY-002"
    assert csv =~ "125000"

    # The stale :approved struct still cannot pay a second time: the payment
    # cascade locks the persisted row and sees :paid.
    assert {:error, _} =
             first
             |> Ash.Changeset.for_update(:pay, %{payment_date: ~D[2026-11-01]}, scope: admin)
             |> Ash.update()

    assert length(payment_entries(org.id, [first.id, second.id])) == 2
  end
end
