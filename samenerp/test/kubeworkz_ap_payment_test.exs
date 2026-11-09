defmodule Samenerp.KubeworkzApPaymentTest do
  @moduledoc """
  The Kubeworkz host proof for the AP lifecycle's payment half: two approved
  vendor bills are paid in one run, each payment lands as its own posted
  `ap_payment` entry (Dr AP clearing / Cr cash), the bills become `:paid`, and
  the run emits remittance advice. A second attempt on a paid bill is refused.
  """

  use Samenerp.DataCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  require Ash.Query

  @endpoint SamenerpWeb.Endpoint

  setup do
    start_supervised!(SamenerpWeb.Endpoint)
    :ok
  end

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

    assert {:ok, pending} =
             ApPaymentRun.request(
               ap_invoice: Erp.ApInvoice,
               repo: Samenerp.Repo,
               scope: admin,
               bill_ids: [first.id, second.id],
               payment_date: ~D[2026-10-31],
               reference: "KUBE-AP-RUN-1"
             )

    assert pending.status == :pending_approval
    assert pending.requested_by == "admin:#{org.id}"
    assert pending.total_cents == 375_000
    assert payment_entries(org.id, [first.id, second.id]) == []

    # Dual control: the requester's own approval is refused before any cash moves.
    assert {:error, :self_approval} =
             ApPaymentRun.approve(
               ap_invoice: Erp.ApInvoice,
               repo: Samenerp.Repo,
               scope: admin,
               run_id: pending.id
             )

    assert Ash.get!(Erp.ApInvoice, first.id, authorize?: false).status == :approved

    approver = approver_scope(org.id)

    assert {:ok, run} =
             ApPaymentRun.approve(
               ap_invoice: Erp.ApInvoice,
               repo: Samenerp.Repo,
               scope: approver,
               run_id: pending.id
             )

    assert run.status == :paid
    assert run.requested_by == "admin:#{org.id}"
    assert run.approved_by == "approver:#{org.id}"
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

    csv = run.remittance_csv
    assert is_binary(csv)
    assert csv =~ "KUBE-AP-RUN-1"
    assert csv =~ "AP-PAY-001"
    assert csv =~ "AP-PAY-002"
    assert csv =~ "125000"

    assert {:ok, stored} = ApPaymentRun.get_run(Samenerp.Repo, org.id, run.id)
    assert stored.status == :paid
    assert stored.requested_by == "admin:#{org.id}"
    assert stored.approved_by == "approver:#{org.id}"
    assert stored.approved_at
    assert stored.executed_at
    assert stored.remittance_csv == csv
    assert stored.bill_count == 2
    assert [listed] = ApPaymentRun.list_runs(Samenerp.Repo, org.id)
    assert listed.id == stored.id

    # The stale :approved struct still cannot pay a second time: `:pay` is
    # system-only (a direct call is refused) and the run already paid it.
    assert {:error, _} =
             first
             |> Ash.Changeset.for_update(:pay, %{payment_date: ~D[2026-11-01]}, scope: admin)
             |> Ash.update()

    assert length(payment_entries(org.id, [first.id, second.id])) == 2
  end

  test "printed advice lays out a long vendor name and multi-line address" do
    org = create_org!("Kubeworkz Remittance Layout")
    admin = admin_scope(org.id)

    assert %{cost_objects: %{created: 9}} = Books.seed!(org.id)

    expense = account!(org.id, "6000")
    vendor = Ash.UUID.generate()

    bill =
      new_bill(admin, org.id, vendor, "AP-REMIT-LONG-1", 125_000, expense)
      |> approve!(org.id, admin)

    long_name = "Acme Industrial Supply, Fabrication & Distribution Company of Central Illinois"

    long_address = """
      Accounts Receivable — Wholesale Division

      Attn: Remittance Processing, Building 12, Suite 400
      18475 West Industrial Commerce Parkway
      Springfield, IL 62708-4217
      United States
    """

    assert {:ok, pending} =
             ApPaymentRun.request(
               ap_invoice: Erp.ApInvoice,
               repo: Samenerp.Repo,
               scope: admin,
               bill_ids: [bill.id],
               payment_date: ~D[2026-11-09],
               reference: "KUBE-REMIT-LONG-1",
               vendor_name: long_name,
               remittance_address: long_address
             )

    assert {:ok, paid} =
             ApPaymentRun.approve(
               ap_invoice: Erp.ApInvoice,
               repo: Samenerp.Repo,
               scope: approver_scope(org.id),
               run_id: pending.id
             )

    assert {:ok, _view, html} =
             live(build_conn(), "/erp/ap-payments/#{paid.id}/remittance?org=#{org.id}")

    document = LazyHTML.from_document(html)

    name_text = document |> LazyHTML.query(".payee-name") |> LazyHTML.text() |> String.trim()
    assert name_text == long_name

    reference_text =
      document |> LazyHTML.query(".reference .value") |> LazyHTML.text() |> String.trim()

    assert reference_text == "KUBE-REMIT-LONG-1"

    address_lines =
      document
      |> LazyHTML.query(".payee-address > div")
      |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

    assert address_lines == [
             "Accounts Receivable — Wholesale Division",
             "Attn: Remittance Processing, Building 12, Suite 400",
             "18475 West Industrial Commerce Parkway",
             "Springfield, IL 62708-4217",
             "United States"
           ]

    style = document |> LazyHTML.query("style") |> LazyHTML.text()

    assert style =~ ~r/\.payee-name\s*\{[^}]*overflow-wrap:\s*anywhere/
    assert style =~ ~r/\.payee-address\s*\{[^}]*overflow-wrap:\s*anywhere/
    assert style =~ ~r/\.reference \.value\s*\{[^}]*white-space:\s*nowrap/
  end
end
