defmodule Samen.Web.ErpApPaymentRunTest do
  @moduledoc """
  The AP payment run audit page (`/erp/ap-payments/:id`) over the REAL
  `Samen.WebTest.Erp.ApInvoice` + the kernel's `ApPaymentRun`:

    * a pending run shows its immutable bill snapshot and requester evidence,
      and says no decision exists;
    * a paid run shows the distinct approver, the execution timestamp, and the
      stored remittance CSV;
    * a run from another org is indistinguishable from a missing run.
  """

  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.{ApAchArtifact, ApPaymentReversal, ApPaymentRun}
  alias Samen.Web.Erp.{ApPaymentRunLive, ApPaymentRunPrintLive}
  alias Samen.WebTest.Erp.{Account, ApInvoice, JournalEntry, PostingAccount}

  @org "55555555-6666-7777-8888-999999999999"
  @other_org "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"

  # -- harness ----------------------------------------------------------------

  defp open(id, org \\ @org) do
    params = %{"org" => org, "id" => id}
    mount = build_mount(:erp)
    session = mount_session(mount)
    {:ok, socket} = ApPaymentRunLive.mount(params, session, %Phoenix.LiveView.Socket{})

    {:noreply, socket} =
      ApPaymentRunLive.handle_params(
        params,
        "http://localhost/erp/ap-payments/#{id}",
        socket
      )

    socket
  end

  defp render(socket), do: render_html(ApPaymentRunLive, socket.assigns)

  defp event(socket, name, params) do
    {:noreply, socket} = ApPaymentRunLive.handle_event(name, params, socket)
    socket
  end

  defp open_print(id, org \\ @org) do
    params = %{"org" => org, "id" => id}
    mount = build_mount(:erp)
    session = mount_session(mount)
    {:ok, socket} = ApPaymentRunPrintLive.mount(params, session, %Phoenix.LiveView.Socket{})

    {:noreply, socket} =
      ApPaymentRunPrintLive.handle_params(
        params,
        "http://localhost/erp/ap-payments/#{id}/remittance",
        socket
      )

    socket
  end

  defp render_print(socket), do: render_html(ApPaymentRunPrintLive, socket.assigns)

  # -- seeds ------------------------------------------------------------------

  defp seed_posting_accounts do
    cash = account!("1000")
    ap = account!("2000")

    for {key, account} <- [cash: cash, ap_clearing: ap] do
      PostingAccount
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: @org, key: key, account_id: account.id},
        authorize?: false
      )
      |> Ash.create!()
    end

    cash
  end

  defp account!(code) do
    Account
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: @org,
        code: code,
        name: "Account #{code}",
        kind: :asset,
        normal_side: :debit
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  defp bill!(attrs) do
    expense = account!(Map.get(attrs, :__code__, "6" <> binary_part(Ash.UUID.generate(), 0, 8)))

    bill =
      ApInvoice
      |> Ash.Changeset.for_create(
        :create,
        Map.merge(
          %{
            org_id: @org,
            vendor_id: Ash.UUID.generate(),
            number: "BILL-" <> binary_part(Ash.UUID.generate(), 0, 8),
            bill_date: ~D[2026-10-01],
            due_date: ~D[2026-10-31],
            lines: [%{account_id: expense.id, amount_cents: 4_000, memo: "freight"}]
          },
          Map.drop(attrs, [:__code__])
        ),
        authorize?: false
      )
      |> Ash.create!()

    approve_raw!(bill)
  end

  defp approve_raw!(bill) do
    Samen.WebTest.Repo.query!(
      "UPDATE fai_ap_invoice SET fai_status = 'approved' WHERE fai_id = $1",
      [Ecto.UUID.dump!(bill.id)]
    )

    Ash.get!(ApInvoice, bill.id, authorize?: false)
  end

  defp scope(actor_id, role) do
    %Samen.Scope{
      actor: %{
        id: actor_id,
        org_id: @org,
        role: role,
        kind: :tenant,
        plane: :tenant
      }
    }
  end

  defp payment_entries(bill_id) do
    JournalEntry
    |> Ash.Query.filter(org_id == ^@org and source_key == "ap_payment" and source_id == ^bill_id)
    |> Ash.read!(authorize?: false)
  end

  defp pending_run!(bill, reference, opts \\ []) do
    {:ok, run} =
      ApPaymentRun.request(
        ap_invoice: ApInvoice,
        repo: Samen.WebTest.Repo,
        scope: scope("requester:other", :member),
        bill_ids: [bill.id],
        payment_date: ~D[2026-11-08],
        reference: reference,
        vendor_name: opts[:vendor_name],
        remittance_address: opts[:remittance_address]
      )

    run
  end

  # -- read -------------------------------------------------------------------

  test "renders a pending run's immutable snapshot and requester evidence" do
    seed_posting_accounts()
    bill = bill!(%{number: "BILL-5001"})
    run = pending_run!(bill, "NOV-RUN-1")

    html = render(open(run.id))

    assert html =~ ~s(id="erp-ap-payment-run")
    assert html =~ "Payment run"
    assert html =~ "NOV-RUN-1"
    assert html =~ "Awaiting approval"
    assert html =~ "Approval evidence"
    assert html =~ "requester:other"
    assert html =~ "BILL-5001"
    assert html =~ "$40.00"
    assert html =~ ~s(id="ap-run-snapshot")
    assert html =~ ~s(id="ap-run-payment-0")
    assert html =~ ~s(href="/erp/ap_invoices/#{bill.id}?org=#{@org}")
    assert html =~ "No decision is recorded"
    refute html =~ ~s(id="download-run-remittance")
    refute html =~ ~s(id="print-remittance")
  end

  test "renders a paid run's distinct approver, execution time and stored CSV" do
    seed_posting_accounts()
    bill = bill!(%{number: "BILL-5002"})

    pending =
      pending_run!(bill, "NOV-RUN-2",
        vendor_name: "Acme Supply Co",
        remittance_address: "PO Box 400\nSpringfield, IL 62701"
      )

    assert {:ok, paid} =
             ApPaymentRun.approve(
               ap_invoice: ApInvoice,
               repo: Samen.WebTest.Repo,
               scope: scope("approver:other", :admin),
               run_id: pending.id
             )

    assert paid.status == :paid
    assert paid.approved_by == "approver:other"
    assert paid.requested_by == "requester:other"
    assert paid.approved_at
    assert paid.executed_at
    assert paid.remittance_csv

    html = render(open(paid.id))

    assert html =~ "Paid"
    assert html =~ "Approval evidence"
    assert html =~ "requester:other"
    assert html =~ "approver:other"
    assert html =~ "Executed at"
    assert html =~ ~s(id="download-run-remittance")
    assert html =~ "data:text/csv;base64,"
    assert html =~ "BILL-5002"
    assert html =~ "Acme Supply Co"
    assert html =~ "PO Box 400"
    assert html =~ "Springfield, IL 62701"
    assert html =~ ~s(id="print-remittance")
    assert html =~ ~s(href="/erp/ap-payments/#{paid.id}/remittance?org=#{@org}")

    print_html = render_print(open_print(paid.id))

    assert print_html =~ ~s(id="remittance-advice")
    assert print_html =~ "Remittance advice"
    assert print_html =~ "NOV-RUN-2"
    assert print_html =~ "BILL-5002"
    assert print_html =~ "$40.00"
    assert print_html =~ paid.vendor_id
    assert print_html =~ ~s(class="payee-name")
    assert print_html =~ "Acme Supply Co"
    assert print_html =~ "PO Box 400"
    assert print_html =~ "Springfield, IL 62701"
    assert print_html =~ "window.print()"
    assert print_html =~ "@media print"
    assert print_html =~ ~s(href="/erp/ap-payments/#{paid.id}?org=#{@org}")
  end

  test "a paid run exposes its stored ACH file and a distinct admin reverses it" do
    seed_posting_accounts()
    bill = bill!(%{number: "BILL-5007"})
    pending = pending_run!(bill, "NOV-RUN-7")

    assert {:ok, paid} =
             ApPaymentRun.approve(
               ap_invoice: ApInvoice,
               repo: Samen.WebTest.Repo,
               scope: scope("approver:other", :admin),
               run_id: pending.id
             )

    file =
      "101 021000021 1123456789\n" <>
        "627 123456789 0000004000\n" <> "90000010000010000010000010\n"

    assert {:ok, artifact} =
             ApAchArtifact.store(
               repo: Samen.WebTest.Repo,
               scope: scope("requester:other", :member),
               run: paid,
               file: file,
               name: "ach-NOV-RUN-7.ach",
               originator: %{name: "Acme Supply Co", id: "1123456789", dfi: "021000021"},
               receiver: %{
                 account_holder: "Acme Supply Co",
                 account_number: "123456789",
                 routing_number: "011000015"
               }
             )

    assert artifact.generated_by == "requester:other"
    assert artifact.receiver_name == "Acme Supply Co"
    assert artifact.receiver_account_last4 == "6789"

    assert {:ok, reversal} =
             ApPaymentReversal.request(
               repo: Samen.WebTest.Repo,
               scope: scope("requester:other", :admin),
               run_id: paid.id,
               reason: "Vendor returned the funds"
             )

    assert reversal.status == :pending_approval

    html = render(open(paid.id))

    assert html =~ ~s(id="ap-run-ach-artifacts")
    assert html =~ ~s(id="ap-run-ach-#{artifact.id}")
    assert html =~ "Download ach-NOV-RUN-7.ach"
    assert html =~ "sha256 " <> String.slice(artifact.digest, 0, 12)
    assert html =~ "••••6789"
    assert html =~ "Generated by requester:other"

    assert html =~ ~s(id="ap-run-reversal-pending")
    assert html =~ "Vendor returned the funds"
    assert html =~ "Requested by <code>requester:other</code>"
    assert html =~ "Approve reversal"
    refute html =~ "Cancel request"

    socket = open(paid.id) |> event("approve_reversal", %{})

    assert socket.assigns.reversal.status == :reversed
    assert socket.assigns.reversal.approved_by == "broker:#{@org}"
    assert Ash.get!(ApInvoice, bill.id, authorize?: false).status == :approved

    assert [entry] = payment_entries(bill.id)
    assert entry.status == :void
    assert entry.voided_entry_id

    html = render(socket)
    assert html =~ ~s(id="ap-run-reversal-badge")
    assert html =~ ~s(id="ap-run-reversal-done")
    assert html =~ "Reversed by <code>broker:#{@org}</code>"
    assert html =~ "The payment entries are void and the bills are approved again"
    refute html =~ ~s(id="ap-run-reversal-form")
  end

  test "printed advice falls back to the vendor account when no payee details were captured" do
    seed_posting_accounts()
    bill = bill!(%{number: "BILL-5006"})
    pending = pending_run!(bill, "NOV-RUN-6")

    assert {:ok, paid} =
             ApPaymentRun.approve(
               ap_invoice: ApInvoice,
               repo: Samen.WebTest.Repo,
               scope: scope("approver:other", :admin),
               run_id: pending.id
             )

    assert paid.vendor_name == nil
    assert paid.remittance_address == nil

    html = render_print(open_print(paid.id))

    assert html =~ ~s(class="payee-name mono")
    assert html =~ paid.vendor_id
    assert html =~ "Vendor account #{paid.vendor_id}"
  end

  test "printable advice is unavailable before payment" do
    seed_posting_accounts()
    bill = bill!(%{number: "BILL-5004"})
    run = pending_run!(bill, "NOV-RUN-4")

    html = render_print(open_print(run.id))

    assert html =~ "Remittance advice unavailable"
    assert html =~ "has not been paid"
    refute html =~ "BILL-5004"
    refute html =~ "window.print()"
  end

  test "printable advice is not exposed across orgs" do
    seed_posting_accounts()
    bill = bill!(%{number: "BILL-5005"})
    run = pending_run!(bill, "NOV-RUN-5")

    html = render_print(open_print(run.id, @other_org))

    assert html =~ "Payment run not found in this workspace."
    refute html =~ "NOV-RUN-5"
    refute html =~ "BILL-5005"
  end

  test "a run from another org is not exposed" do
    seed_posting_accounts()
    bill = bill!(%{number: "BILL-5003"})
    run = pending_run!(bill, "NOV-RUN-3")

    html = render(open(run.id, @other_org))

    assert html =~ "Payment run not found"
    assert html =~ "It may belong to another organization."
    refute html =~ "NOV-RUN-3"
    refute html =~ "BILL-5003"
  end
end
