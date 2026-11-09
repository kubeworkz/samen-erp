defmodule Samen.Web.ErpApPaymentsTest do
  @moduledoc """
  The AP payment run surface (`/erp/ap-payments`) over the REAL
  `Samen.WebTest.Erp.ApInvoice` + the kernel's `ApPaymentRun`:

    * approved bills render inside the ERP shell with the page's nav item active;
    * selecting a bill and submitting posts ONE payment entry, flips the bill to
      `:paid`, and offers the remittance CSV;
    * a mixed-vendor selection is refused by the kernel and pays nothing;
    * an empty selection is refused inline.

  Bills are seeded already-`:approved` (the raw UPDATE below stands in for the
  approval flow, which is exercised by its own suites) so this test proves the
  PAGE's contract: read approved bills, call the run, render the outcome.
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

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

  # -- payment run ------------------------------------------------------------

  test "runs a payment for the selected bills and offers the remittance CSV" do
    seed_posting_accounts()
    bill = bill!(%{number: "BILL-2001"})

    socket =
      open()
      |> event("pay", %{
        "bill_ids" => [bill.id],
        "payment_date" => "2026-11-08",
        "reference" => "NOV-AP-1",
        "memo" => "wire"
      })

    assert Ash.get!(ApInvoice, bill.id, authorize?: false).status == :paid

    assert [entry] = payment_entries(bill.id)
    assert entry.status == :posted
    assert entry.entry_date == ~D[2026-11-08]
    assert entry.memo =~ "NOV-AP-1"

    html = render(socket)
    assert html =~ "Payment run posted"
    assert html =~ "NOV-AP-1"
    assert html =~ ~s(id="download-remittance")
    assert html =~ "data:text/csv;base64,"
    refute html =~ ~s(id="ap-payment-error")
    # The paid bill left the approved list.
    refute html =~ ~s(id="ap-bill-#{bill.id}")
  end

  test "a mixed-vendor selection is refused and pays nothing" do
    seed_posting_accounts()
    first = bill!()
    second = bill!()

    socket =
      event(open(), "pay", %{"bill_ids" => [first.id, second.id], "payment_date" => "2026-11-08"})

    assert Ash.get!(ApInvoice, first.id, authorize?: false).status == :approved
    assert Ash.get!(ApInvoice, second.id, authorize?: false).status == :approved
    assert payment_entries(first.id) == []

    html = render(socket)
    assert html =~ "one vendor"
    assert html =~ ~s(id="ap-payment-error")
  end

  test "an empty selection is refused inline" do
    seed_posting_accounts()
    socket = event(open(), "pay", %{"bill_ids" => [], "payment_date" => "2026-11-08"})

    assert render(socket) =~ "Select at least one approved bill."
  end

  # -- duplicate detection ----------------------------------------------------

  test "possible duplicate bills are flagged and refuse the run until confirmed" do
    seed_posting_accounts()
    vendor = Ash.UUID.generate()
    first = bill!(%{vendor_id: vendor, number: "BILL-3001"})
    second = bill!(%{vendor_id: vendor, number: "BILL-3002"})

    html = render(open())
    assert html =~ ~s(id="ap-bill-duplicate-#{first.id}")
    assert html =~ ~s(id="ap-bill-duplicate-#{second.id}")

    refused =
      event(open(), "pay", %{"bill_ids" => [first.id, second.id], "payment_date" => "2026-11-08"})

    assert Ash.get!(ApInvoice, first.id, authorize?: false).status == :approved
    assert Ash.get!(ApInvoice, second.id, authorize?: false).status == :approved
    assert payment_entries(first.id) == []

    html = render(refused)
    assert html =~ "look like duplicates"
    assert html =~ "BILL-3001"
    assert html =~ "BILL-3002"
    refute html =~ ~s(id="ap-payment-result")

    confirmed =
      event(refused, "pay", %{
        "bill_ids" => [first.id, second.id],
        "payment_date" => "2026-11-08",
        "allow_duplicates" => "1"
      })

    assert Ash.get!(ApInvoice, first.id, authorize?: false).status == :paid
    assert Ash.get!(ApInvoice, second.id, authorize?: false).status == :paid
    assert [_, _] = payment_entries(first.id) ++ payment_entries(second.id)
    assert render(confirmed) =~ "Payment run posted"
  end

  # -- ACH / EFT file ---------------------------------------------------------

  test "builds an ACH file for the posted run and refuses invalid bank details" do
    seed_posting_accounts()
    bill = bill!(%{number: "BILL-4001"})

    paid =
      event(open(), "pay", %{
        "bill_ids" => [bill.id],
        "payment_date" => "2026-11-08",
        "reference" => "NOV-ACH-1"
      })

    assert paid.assigns.run

    fields = %{
      "originator_name" => "Sample Co",
      "originator_id" => "1123456789",
      "originator_dfi" => "021000021",
      "receiver_name" => "Vendor One",
      "receiver_account" => "123456789",
      "receiver_dfi" => "011000015",
      "account_type" => "checking"
    }

    invalid = event(paid, "ach", %{fields | "receiver_dfi" => "021000022"})
    assert invalid.assigns.ach_error =~ "not a valid ABA number"

    html = render(invalid)
    assert html =~ ~s(id="ach-file-error")
    refute html =~ ~s(id="download-ach")

    built = event(paid, "ach", fields)
    assert built.assigns.ach_name == "ach-NOV-ACH-1.ach"
    assert String.starts_with?(built.assigns.ach_file, "101 ")
    assert built.assigns.ach_error == nil

    html = render(built)
    assert html =~ ~s(id="download-ach")
    assert html =~ "data:application/octet-stream;base64,"
    assert html =~ "ach-NOV-ACH-1.ach"
    refute html =~ ~s(id="ach-file-error")
  end
end
