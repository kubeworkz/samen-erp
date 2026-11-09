defmodule Samen.Web.ErpApPaymentsTest do
  @moduledoc """
  The dual-control AP payment run surface (`/erp/ap-payments`) over the REAL
  `Samen.WebTest.Erp.ApInvoice` + the kernel's `ApPaymentRun`:

    * a request persists `:pending_approval`, renders on the page, and pays
      nothing;
    * the requester cannot approve their own run;
    * a DIFFERENT admin's approval posts the payment, flips the bill to `:paid`,
      and offers the persisted remittance CSV;
    * mixed-vendor requests are refused by the kernel and pay nothing;
    * an empty selection is refused inline;
    * possible duplicates are flagged and refuse the request until confirmed;
    * the ACH file is available only after approval.

  Bills are seeded already-`:approved` (the raw UPDATE below stands in for the
  approval flow, which is exercised by its own suites) so this test proves the
  PAGE's contract: read approved bills, request a run, have a second actor
  approve it, render the outcome and the immutable history.
  """
  use Samen.WebTest.DataCase, async: false

  import Phoenix.LiveViewTest, only: [render_component: 2]

  require Ash.Query

  alias Samen.Scopes.Finance.{
    ApAchArtifact,
    ApPaymentReversal,
    ApPaymentRun,
    VendorPaymentProfile
  }

  alias Samen.Web.Erp.ApPaymentsLive
  alias Samen.WebTest.Erp.{Account, ApInvoice, JournalEntry, PostingAccount}

  @org "55555555-6666-7777-8888-999999999999"

  # -- harness ----------------------------------------------------------------

  defp open(params \\ %{"org" => @org}) do
    mount = build_mount(:erp)
    session = mount_session(mount)
    {:ok, socket} = ApPaymentsLive.mount(params, session, %Phoenix.LiveView.Socket{})

    {:noreply, socket} =
      ApPaymentsLive.handle_params(params, "http://localhost/erp/ap-payments", socket)

    socket
  end

  defp event(socket, name, params) do
    {:noreply, socket} = ApPaymentsLive.handle_event(name, params, socket)
    socket
  end

  defp render(socket), do: render_html(ApPaymentsLive, socket.assigns)

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

  defp bill!(attrs \\ %{}) do
    expense =
      account!(Map.get(attrs, :__code__, "6" <> binary_part(Ash.UUID.generate(), 0, 8)))

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

  # The raw approval stand-in — see the moduledoc. The kernel's `:pay` re-reads
  # the persisted status under a row lock, so an honest `:approved` row is all
  # the page needs.
  defp approve_raw!(bill) do
    Samen.WebTest.Repo.query!(
      "UPDATE fai_ap_invoice SET fai_status = 'approved' WHERE fai_id = $1",
      [Ecto.UUID.dump!(bill.id)]
    )

    Ash.get!(ApInvoice, bill.id, authorize?: false)
  end

  defp requester_scope(org_id) do
    %Samen.Scope{
      actor: %{
        id: "requester:other",
        org_id: org_id,
        role: :member,
        kind: :tenant,
        plane: :tenant
      }
    }
  end

  defp admin_scope(actor_id) do
    %Samen.Scope{
      actor: %{id: actor_id, org_id: @org, role: :admin, kind: :tenant, plane: :tenant}
    }
  end

  defp crm_sidebar_html(plane \\ Samen.Web.Plane.tenant()) do
    mount =
      Samen.Web.Mount.new(:crm, Samen.WebTest.Crm, Samen.WebTest.Repo,
        plane: plane,
        labels: %{erp_path: "/erp"}
      )

    render_component(&Samen.Web.CRM.Live.crm_sidebar/1, %{
      mount: mount,
      org_id: @org,
      active: :crm_dashboard,
      return_to: nil
    })
  end

  defp pending_run!(bill, reference) do
    {:ok, run} =
      ApPaymentRun.request(
        ap_invoice: ApInvoice,
        repo: Samen.WebTest.Repo,
        scope: requester_scope(@org),
        bill_ids: [bill.id],
        payment_date: ~D[2026-11-08],
        reference: reference
      )

    run
  end

  defp payment_entries(bill_id) do
    JournalEntry
    |> Ash.Query.filter(org_id == ^@org and source_key == "ap_payment" and source_id == ^bill_id)
    |> Ash.read!(authorize?: false)
  end

  # -- read -------------------------------------------------------------------

  test "renders the org's approved bills inside the ERP shell with its nav item active" do
    seed_posting_accounts()
    bill = bill!(%{number: "BILL-1001"})
    html = render(open())

    assert html =~ ~s(id="erp-ap-payments")
    assert html =~ ~s(class="app")
    assert html =~ ~s(href="/erp/ap-payments?org=#{@org}" class="on")
    assert html =~ "AP payments"
    assert html =~ "BILL-1001"
    assert html =~ "$40.00"
    assert html =~ ~s(id="ap-payment-run")
    assert html =~ ~s(id="ap-bill-#{bill.id}")
  end

  test "an org with no approved bills renders the honest empty state" do
    seed_posting_accounts()
    html = render(open())

    assert html =~ "No approved bills are waiting for payment."
    refute html =~ ~s(id="ap-payment-error")
  end

  # -- request / dual control -------------------------------------------------

  test "requesting a run persists a pending audit row and pays nothing" do
    seed_posting_accounts()
    bill = bill!(%{number: "BILL-2001"})

    socket =
      open()
      |> event("request", %{
        "bill_ids" => [bill.id],
        "payment_date" => "2026-11-08",
        "reference" => "NOV-AP-1",
        "memo" => "wire",
        "vendor_name" => "Acme Supply Co",
        "remittance_address" => "PO Box 400\nSpringfield, IL 62701"
      })

    assert Ash.get!(ApInvoice, bill.id, authorize?: false).status == :approved
    assert payment_entries(bill.id) == []

    assert [pending] = socket.assigns.pending_runs
    assert pending.status == :pending_approval
    assert pending.reference == "NOV-AP-1"
    assert pending.requested_by == "broker:#{@org}"
    assert pending.total_cents == 4_000
    assert pending.vendor_name == "Acme Supply Co"
    assert pending.remittance_address == "PO Box 400\nSpringfield, IL 62701"
    assert socket.assigns.vendor_name == ""
    assert socket.assigns.remittance_address == ""
    assert socket.assigns.run == nil

    html = render(socket)
    assert html =~ "Pending approval"
    assert html =~ "NOV-AP-1"
    assert html =~ "awaiting a different admin"
    assert html =~ ~s(id="payment-vendor-name")
    assert html =~ ~s(id="payment-remittance-address")
    assert html =~ ~s(href="/erp/ap-payments/#{pending.id}?org=#{@org}")
    assert html =~ ~s(id="cancel-run-#{pending.id}")
    refute html =~ ~s(id="ap-payment-result")
    refute html =~ ~s(id="download-remittance")
  end

  test "the requester cannot approve their own run; nothing is paid" do
    seed_posting_accounts()
    bill = bill!(%{number: "BILL-2002"})

    socket =
      open()
      |> event("request", %{
        "bill_ids" => [bill.id],
        "payment_date" => "2026-11-08",
        "reference" => "NOV-AP-2"
      })

    [pending] = socket.assigns.pending_runs

    socket = event(socket, "approve", %{"run_id" => pending.id})

    assert Ash.get!(ApInvoice, bill.id, authorize?: false).status == :approved
    assert payment_entries(bill.id) == []
    assert socket.assigns.error =~ "different admin"
    assert render(socket) =~ ~s(id="ap-payment-error")
  end

  test "a different admin approves the pending run and posts the payment" do
    seed_posting_accounts()
    bill = bill!(%{number: "BILL-2003"})
    pending = pending_run!(bill, "NOV-AP-3")

    socket = open()
    assert Enum.any?(socket.assigns.pending_runs, &(&1.id == pending.id))
    assert render(socket) =~ ~s(id="approve-run-#{pending.id}")

    socket = event(socket, "approve", %{"run_id" => pending.id})

    assert Ash.get!(ApInvoice, bill.id, authorize?: false).status == :paid
    assert [entry] = payment_entries(bill.id)
    assert entry.status == :posted
    assert entry.entry_date == ~D[2026-11-08]
    assert entry.memo =~ "NOV-AP-3"

    assert socket.assigns.run.status == :paid
    assert socket.assigns.run.requested_by == "requester:other"
    assert socket.assigns.run.approved_by == "broker:#{@org}"
    assert socket.assigns.pending_runs == []

    html = render(socket)
    assert html =~ "Payment run approved and posted"
    assert html =~ "NOV-AP-3"
    assert html =~ ~s(id="download-remittance")
    assert html =~ "data:text/csv;base64,"
    assert html =~ ~s(id="ap-payment-history")
    assert html =~ ~s(href="/erp/ap-payments/#{pending.id}?org=#{@org}")
    assert html =~ "Paid"
    refute html =~ ~s(id="ap-bill-#{bill.id}")
  end

  test "cancelling the request pays nothing and leaves an audit row" do
    seed_posting_accounts()
    bill = bill!(%{number: "BILL-2004"})

    socket =
      open()
      |> event("request", %{
        "bill_ids" => [bill.id],
        "payment_date" => "2026-11-08",
        "reference" => "NOV-AP-4"
      })

    [pending] = socket.assigns.pending_runs
    socket = event(socket, "cancel", %{"run_id" => pending.id})

    assert Ash.get!(ApInvoice, bill.id, authorize?: false).status == :approved
    assert payment_entries(bill.id) == []
    assert socket.assigns.pending_runs == []
    assert [cancelled] = socket.assigns.recent_runs
    assert cancelled.status == :cancelled
    assert cancelled.cancelled_by == "broker:#{@org}"
    assert render(socket) =~ "Cancelled"
  end

  test "a mixed-vendor selection is refused and requests nothing" do
    seed_posting_accounts()
    first = bill!()
    second = bill!()

    socket =
      event(open(), "request", %{
        "bill_ids" => [first.id, second.id],
        "payment_date" => "2026-11-08"
      })

    assert Ash.get!(ApInvoice, first.id, authorize?: false).status == :approved
    assert Ash.get!(ApInvoice, second.id, authorize?: false).status == :approved
    assert payment_entries(first.id) == []
    assert socket.assigns.pending_runs == []

    html = render(socket)
    assert html =~ "one vendor"
    assert html =~ ~s(id="ap-payment-error")
  end

  test "an empty selection is refused inline" do
    seed_posting_accounts()

    socket =
      event(open(), "request", %{"bill_ids" => [], "payment_date" => "2026-11-08"})

    assert render(socket) =~ "Select at least one approved bill."
  end

  # -- duplicate detection ----------------------------------------------------

  test "possible duplicate bills are flagged and refuse the request until confirmed" do
    seed_posting_accounts()
    vendor = Ash.UUID.generate()
    first = bill!(%{vendor_id: vendor, number: "BILL-3001"})
    second = bill!(%{vendor_id: vendor, number: "BILL-3002"})

    html = render(open())
    assert html =~ ~s(id="ap-bill-duplicate-#{first.id}")
    assert html =~ ~s(id="ap-bill-duplicate-#{second.id}")

    refused =
      event(open(), "request", %{
        "bill_ids" => [first.id, second.id],
        "payment_date" => "2026-11-08"
      })

    assert Ash.get!(ApInvoice, first.id, authorize?: false).status == :approved
    assert Ash.get!(ApInvoice, second.id, authorize?: false).status == :approved
    assert payment_entries(first.id) == []
    assert refused.assigns.pending_runs == []

    html = render(refused)
    assert html =~ "look like duplicates"
    assert html =~ "BILL-3001"
    assert html =~ "BILL-3002"
    refute html =~ ~s(id="ap-payment-result")

    confirmed =
      event(refused, "request", %{
        "bill_ids" => [first.id, second.id],
        "payment_date" => "2026-11-08",
        "allow_duplicates" => "1"
      })

    assert [pending] = confirmed.assigns.pending_runs
    assert pending.total_cents == 8_000
    assert Ash.get!(ApInvoice, first.id, authorize?: false).status == :approved
    assert Ash.get!(ApInvoice, second.id, authorize?: false).status == :approved
    assert payment_entries(first.id) == []
  end

  test "a different admin rejects the pending run; nothing is paid and the row is final" do
    seed_posting_accounts()
    bill = bill!(%{number: "BILL-2005"})
    pending = pending_run!(bill, "NOV-AP-5")

    socket =
      open()
      |> event("reject", %{"run_id" => pending.id})

    assert Ash.get!(ApInvoice, bill.id, authorize?: false).status == :approved
    assert payment_entries(bill.id) == []
    assert socket.assigns.pending_runs == []
    assert [rejected] = socket.assigns.recent_runs
    assert rejected.status == :rejected
    assert rejected.rejected_by == "broker:#{@org}"
    assert rejected.rejected_at

    html = render(socket)
    assert html =~ "Rejected"
    refute html =~ ~s(id="ap-payment-result")
  end

  # -- pending reversals ------------------------------------------------------

  test "the pending-reversals queue lets a distinct admin reverse a paid run" do
    seed_posting_accounts()
    bill = bill!(%{number: "BILL-6001"})
    pending = pending_run!(bill, "NOV-REV-QUEUE")

    assert {:ok, _paid} =
             ApPaymentRun.approve(
               ap_invoice: ApInvoice,
               repo: Samen.WebTest.Repo,
               scope: admin_scope("approver:other"),
               run_id: pending.id
             )

    assert {:ok, reversal} =
             ApPaymentReversal.request(
               repo: Samen.WebTest.Repo,
               scope: admin_scope("requester:admin"),
               run_id: pending.id,
               reason: "Bank returned the credit"
             )

    socket = open()

    assert [entry] = socket.assigns.pending_reversals
    assert entry.reversal.id == reversal.id
    assert entry.run.id == pending.id

    html = render(socket)
    assert html =~ ~s(id="ap-payment-pending-reversals")
    assert html =~ ~s(id="ap-pending-reversal-#{reversal.id}")
    assert html =~ "NOV-REV-QUEUE"
    assert html =~ "requester:admin"
    assert html =~ "Bank returned the credit"
    assert html =~ ~s(id="approve-reversal-#{reversal.id}")
    assert html =~ ~s(id="reject-reversal-#{reversal.id}")
    refute html =~ "awaiting a different admin"

    socket = event(socket, "approve_reversal", %{"reversal_id" => reversal.id})

    assert socket.assigns.pending_reversals == []
    assert socket.assigns.notice =~ "reversal approved"
    assert Ash.get!(ApInvoice, bill.id, authorize?: false).status == :approved

    assert [voided] = payment_entries(bill.id)
    assert voided.status == :void
    assert voided.voided_entry_id

    refute render(socket) =~ ~s(id="ap-payment-pending-reversals")
  end

  test "the shared nav badge counts reversals awaiting this admin across runs" do
    seed_posting_accounts()

    reversals =
      for {number, reference, requester} <- [
            {"BILL-6101", "NOV-BADGE-1", "requester:one"},
            {"BILL-6102", "NOV-BADGE-2", "requester:two"}
          ] do
        bill = bill!(%{number: number})
        pending = pending_run!(bill, reference)

        assert {:ok, _paid} =
                 ApPaymentRun.approve(
                   ap_invoice: ApInvoice,
                   repo: Samen.WebTest.Repo,
                   scope: admin_scope("approver:other"),
                   run_id: pending.id
                 )

        assert {:ok, reversal} =
                 ApPaymentReversal.request(
                   repo: Samen.WebTest.Repo,
                   scope: admin_scope(requester),
                   run_id: pending.id,
                   reason: "Returned by the bank"
                 )

        reversal
      end

    socket = open()
    assert render(socket) =~ ~s(class="cnt">2<)

    # The SAME badge rides the shared ERP nav group on a non-ERP tenant page: the
    # CRM sidebar threads only its mount, and `module_nav/1` derives the count. A
    # badge that only lit inside the ERP sidebar would leave the queue invisible
    # while an admin works in CRM.
    crm_html = crm_sidebar_html()
    assert crm_html =~ ~s(href="/erp/ap-payments?org=#{@org}")
    assert crm_html =~ ~s(class="cnt">2<)

    [first | _] = reversals
    socket = event(socket, "approve_reversal", %{"reversal_id" => first.id})

    html = render(socket)
    assert html =~ ~s(class="cnt">1<)
    refute html =~ ~s(class="cnt">2<)
  end

  test "the shared nav badge stays hidden on an operator-plane non-ERP page" do
    seed_posting_accounts()
    bill = bill!(%{number: "BILL-6201"})
    pending = pending_run!(bill, "NOV-BADGE-OPERATOR")

    assert {:ok, _paid} =
             ApPaymentRun.approve(
               ap_invoice: ApInvoice,
               repo: Samen.WebTest.Repo,
               scope: admin_scope("approver:other"),
               run_id: pending.id
             )

    assert {:ok, _reversal} =
             ApPaymentReversal.request(
               repo: Samen.WebTest.Repo,
               scope: admin_scope("requester:admin"),
               run_id: pending.id,
               reason: "Returned by the bank"
             )

    # Positive control: the same non-ERP page DOES light the badge for a tenant
    # admin who can decide this reversal.
    tenant_html = crm_sidebar_html()
    assert tenant_html =~ ~s(href="/erp/ap-payments?org=#{@org}")
    assert tenant_html =~ ~s(class="cnt">1<)

    operator_plane = Samen.Web.Plane.operator("op-1", @org, "test-session")
    operator_html = crm_sidebar_html(operator_plane)

    assert operator_html =~ ~s(href="/erp/ap-payments?org=#{@org}")
    refute operator_html =~ ~s(class="cnt">1<)
  end

  test "the queue shows the requester their own reversal without approve controls" do
    seed_posting_accounts()
    bill = bill!(%{number: "BILL-6002"})
    pending = pending_run!(bill, "NOV-REV-SELF")

    assert {:ok, _paid} =
             ApPaymentRun.approve(
               ap_invoice: ApInvoice,
               repo: Samen.WebTest.Repo,
               scope: admin_scope("approver:other"),
               run_id: pending.id
             )

    assert {:ok, reversal} =
             ApPaymentReversal.request(
               repo: Samen.WebTest.Repo,
               scope: admin_scope("broker:#{@org}"),
               run_id: pending.id,
               reason: "Duplicate payment"
             )

    html = render(open())

    assert html =~ ~s(id="ap-pending-reversal-#{reversal.id}")
    assert html =~ "awaiting a different admin"
    assert html =~ ~s(id="cancel-reversal-#{reversal.id}")
    refute html =~ ~s(id="approve-reversal-#{reversal.id}")
    refute html =~ ~s(id="reject-reversal-#{reversal.id}")
    refute html =~ ~s(class="cnt">1<)

    # The shared ERP group is present on a non-ERP page, but the badge stays
    # hidden: the only pending reversal belongs to the viewer, and the kernel
    # refuses self-approval.
    crm_html = crm_sidebar_html()
    assert crm_html =~ ~s(href="/erp/ap-payments?org=#{@org}")
    refute crm_html =~ ~s(class="cnt">1<)
  end

  test "the queue rejects a reversal without moving the paid run" do
    seed_posting_accounts()
    bill = bill!(%{number: "BILL-6003"})
    pending = pending_run!(bill, "NOV-REV-REJECT")

    assert {:ok, _paid} =
             ApPaymentRun.approve(
               ap_invoice: ApInvoice,
               repo: Samen.WebTest.Repo,
               scope: admin_scope("approver:other"),
               run_id: pending.id
             )

    assert {:ok, reversal} =
             ApPaymentReversal.request(
               repo: Samen.WebTest.Repo,
               scope: admin_scope("requester:admin"),
               run_id: pending.id,
               reason: "Wrong run"
             )

    socket = open() |> event("reject_reversal", %{"reversal_id" => reversal.id})

    assert socket.assigns.pending_reversals == []
    assert socket.assigns.notice =~ "Reversal rejected"
    assert Ash.get!(ApInvoice, bill.id, authorize?: false).status == :paid
    assert [entry] = payment_entries(bill.id)
    assert entry.status == :posted
    assert entry.voided_entry_id == nil
  end

  # -- ACH / EFT file ---------------------------------------------------------

  test "builds an ACH file only from the vendor's VERIFIED bank profile" do
    seed_posting_accounts()
    vendor = Ash.UUID.generate()
    bill = bill!(%{number: "BILL-4001", vendor_id: vendor})
    pending = pending_run!(bill, "NOV-ACH-1")

    originator = %{
      "originator_name" => "Sample Co",
      "originator_id" => "1123456789",
      "originator_dfi" => "021000021"
    }

    unapproved = event(open(), "ach", originator)
    assert unapproved.assigns.ach_error == "Approve a payment run first."
    refute render(unapproved) =~ ~s(id="download-ach")

    approved =
      open()
      |> event("approve", %{"run_id" => pending.id})

    assert approved.assigns.run.status == :paid

    # No profile yet: the form cannot invent a destination for the money.
    blocked = event(approved, "ach", originator)
    assert blocked.assigns.ach_error =~ "Register the vendor's bank details"
    refute render(blocked) =~ ~s(id="download-ach")

    # Invalid ABA routing is refused BEFORE anything is stored.
    invalid =
      event(open(), "save_profile", %{
        "intent" => "save",
        "vendor_id" => vendor,
        "bank_name" => "First Sample Bank",
        "account_holder" => "Vendor One",
        "account_number" => "123456789",
        "routing_number" => "021000022",
        "account_type" => "checking"
      })

    assert invalid.assigns.profile_error =~ "not a valid ABA number"
    assert invalid.assigns.vendor_profile == nil

    # Register as the request-side principal: that is the profile's `changed_by`.
    assert {:ok, profile} =
             VendorPaymentProfile.register(
               repo: Samen.WebTest.Repo,
               scope: requester_scope(@org),
               vendor_id: vendor,
               bank_name: "First Sample Bank",
               account_holder: "Vendor One",
               account_number: "123456789",
               routing_number: "011000015",
               account_type: "checking"
             )

    assert profile.status == :unverified

    unverified = event(approved, "ach", originator)
    assert unverified.assigns.ach_error =~ "not verified"

    # A DIFFERENT admin verifies from the page; the ACH then uses those fields.
    verified = event(approved, "verify_profile", %{"vendor_id" => vendor})
    assert verified.assigns.vendor_profile.status == :verified
    assert verified.assigns.profile_notice =~ "verified"
    assert render(verified) =~ ~s(id="ach-profile-verified")

    built = event(verified, "ach", originator)

    assert built.assigns.ach_name == "ach-NOV-ACH-1.ach",
           "ACH refused: #{inspect(built.assigns.ach_error)}"

    assert String.starts_with?(built.assigns.ach_file, "101 ")
    assert built.assigns.ach_error == nil

    [artifact] = ApAchArtifact.list(Samen.WebTest.Repo, @org, built.assigns.run.id)
    file = built.assigns.ach_file

    assert String.starts_with?(artifact.file_token, "vt_")
    assert String.length(artifact.digest) == 64
    assert artifact.size_bytes == byte_size(file)
    assert artifact.originator_name == "Sample Co"
    assert artifact.originator_dfi_last4 == "0021"
    assert artifact.receiver_account_last4 == "6789"
    assert artifact.receiver_routing_last4 == "0015"
    assert {:ok, ^file} = ApAchArtifact.reveal(artifact, Samen.WebTest.Repo)

    %{rows: [[token]]} =
      Samen.WebTest.Repo.query!(
        "SELECT ach_file_token FROM ach_ap_payment_ach_file WHERE ach_id = $1",
        [Ecto.UUID.dump!(artifact.id)]
      )

    assert token == artifact.file_token
    refute token =~ "101 "

    html = render(built)
    assert html =~ ~s(id="download-ach")
    assert html =~ "data:application/octet-stream;base64,"
    assert html =~ "ach-NOV-ACH-1.ach"
    refute html =~ ~s(id="ach-file-error")
  end
end
