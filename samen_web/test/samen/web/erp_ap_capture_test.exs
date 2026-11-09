defmodule Samen.Web.ErpApCaptureTest do
  @moduledoc """
  The AP capture page (`/erp/ap-capture`) over the REAL test-host
  `Samen.WebTest.Erp.ApInvoice` + `Account`:

    * the page renders inside the ERP shell with its nav item active;
    * pasted invoice text becomes a reviewable draft (number, lines, total);
    * an invoice number already on a bill is flagged immediately and blocks
      confirmation;
    * confirming creates ONE `:draft` bill — capture never approves;
    * a missing vendor is refused with a readable message.

  The document/OCR path is covered at the module level
  (`samen_core/test/invoice_ocr_test.exs`); the headless harness mounts without a
  LiveView endpoint, so this page renders its paste path there by design.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Erp.ApCaptureLive
  alias Samen.Web.Erp.OcrQuota
  alias Samen.Web.Erp.OcrQuota.PubSub, as: OcrQuotaPubSub
  alias Samen.WebTest.Erp.{Account, ApInvoice}
  alias Samen.WebTest.RateLimitFlood
  alias Samen.WebTest.Repo

  @org "55555555-6666-7777-8888-999999999999"
  @vendor "11111111-2222-3333-4444-555555555555"

  defp open(params \\ %{"org" => @org}) do
    mount = build_mount(:erp)
    session = mount_session(mount)
    {:ok, socket} = ApCaptureLive.mount(params, session, %Phoenix.LiveView.Socket{})

    {:noreply, socket} =
      ApCaptureLive.handle_params(params, "http://localhost/erp/ap-capture", socket)

    socket
  end

  defp open_connected(params \\ %{"org" => @org}) do
    mount = build_mount(:erp)
    session = mount_session(mount)

    {:ok, socket} =
      ApCaptureLive.mount(params, session, %Phoenix.LiveView.Socket{transport_pid: self()})

    {:noreply, socket} =
      ApCaptureLive.handle_params(params, "http://localhost/erp/ap-capture", socket)

    socket
  end

  defp event(socket, name, params) do
    {:noreply, socket} = ApCaptureLive.handle_event(name, params, socket)
    socket
  end

  defp render(socket), do: render_html(ApCaptureLive, socket.assigns)

  defp configure_ocr do
    previous = Application.get_env(:samen_core, :invoice_ocr)
    Application.put_env(:samen_core, :invoice_ocr, Samen.WebTest.FakeOcrAdapter)
    on_exit(fn -> restore_invoice_ocr(previous) end)
  end

  defp account! do
    Account
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: @org, code: "6100", name: "Office expense", kind: :expense, normal_side: :debit},
      authorize?: false
    )
    |> Ash.create!()
  end

  defp invoice_text(number, amount) do
    """
    ACME INDUSTRIAL SUPPLY
    Invoice No: #{number}
    Invoice Date: 2026-10-14
    Due Date: 2026-11-13
    Widgets                 #{amount}
    Total Due: $#{amount}
    """
  end

  test "renders the capture page inside the ERP shell with its nav item active" do
    account!()
    html = render(open())

    assert html =~ ~s(id="erp-ap-capture")
    assert html =~ ~s(href="/erp/ap-capture?org=#{@org}" class="on")
    assert html =~ "AP capture"
    assert html =~ ~s(id="ap-capture-form")
    assert html =~ ~s(id="capture-text")
  end

  test "pasted text becomes a reviewable draft" do
    account!()

    socket = event(open(), "capture", %{"text" => invoice_text("INV-CAP-1", "100.00")})

    assert socket.assigns.draft.number == "INV-CAP-1"
    assert socket.assigns.draft.total_cents == 10_000
    assert socket.assigns.draft.invoice_date == ~D[2026-10-14]

    html = render(socket)
    assert html =~ ~s(id="ap-capture-review")
    assert html =~ "INV-CAP-1"
    assert html =~ "$100.00"
    refute html =~ ~s(id="ap-capture-error")
  end

  test "a number already on a bill is flagged at capture time and blocks confirm" do
    account = account!()

    ApInvoice
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: @org,
        vendor_id: @vendor,
        number: "INV-DUP-1",
        bill_date: ~D[2026-10-14],
        due_date: ~D[2026-11-13],
        lines: [%{account_id: account.id, amount_cents: 10_000, memo: "Widgets"}]
      },
      authorize?: false
    )
    |> Ash.create!()

    socket = event(open(), "capture", %{"text" => invoice_text("INV-DUP-1", "100.00")})

    assert socket.assigns.existing.number == "INV-DUP-1"

    html = render(socket)
    assert html =~ ~s(id="ap-capture-duplicate")
    assert html =~ "cannot be captured twice"
  end

  test "confirming creates ONE draft bill — never an approved one" do
    account = account!()
    socket = event(open(), "capture", %{"text" => invoice_text("INV-CAP-2", "250.50")})

    confirmed =
      event(socket, "confirm", %{
        "vendor_id" => @vendor,
        "account_id" => account.id,
        "number" => "INV-CAP-2",
        "invoice_date" => "2026-10-14",
        "due_date" => "2026-11-13",
        "memo" => "captured"
      })

    bill = confirmed.assigns.created
    assert bill
    assert bill.number == "INV-CAP-2"
    assert bill.status == :draft
    assert Ash.get!(ApInvoice, bill.id, authorize?: false).status == :draft

    html = render(confirmed)
    assert html =~ "Captured INV-CAP-2 as a draft bill."
    refute html =~ ~s(id="ap-capture-review")
  end

  test "a missing vendor is refused with a readable message" do
    account = account!()
    socket = event(open(), "capture", %{"text" => invoice_text("INV-CAP-3", "10.00")})

    refused =
      event(socket, "confirm", %{
        "vendor_id" => "",
        "account_id" => account.id,
        "number" => "INV-CAP-3",
        "invoice_date" => "2026-10-14"
      })

    assert refused.assigns.created == nil
    assert render(refused) =~ "Enter the vendor id."
  end

  test "empty input is refused inline" do
    account!()
    socket = event(open(), "capture", %{"text" => "  "})

    assert render(socket) =~ "Paste the invoice text or choose a document."
  end

  test "documents spend the org's OCR budget; paste and text files do not" do
    configure_ocr()
    RateLimitFlood.pin!(%{erp_invoice_ocr: {1, 3_600_000}})
    :ok = Phoenix.PubSub.subscribe(Samen.WebTest.PubSub, OcrQuotaPubSub.topic(@org))

    assert :ok =
             ApCaptureLive.document_ocr_gate(
               %{content_type: "application/pdf"},
               @org,
               Samen.WebTest.Repo,
               pubsub: Samen.WebTest.PubSub
             )

    assert_receive {:ocr_quota_changed, @org}

    assert {:error, :ocr_rate_limited} =
             ApCaptureLive.document_ocr_gate(
               %{content_type: "application/pdf"},
               @org,
               Samen.WebTest.Repo,
               pubsub: Samen.WebTest.PubSub
             )

    # A refused document changes no budget, so it announces nothing.
    refute_received {:ocr_quota_changed, @org}

    # A text file takes the free text path, and a paste carries no upload at all.
    assert :ok =
             ApCaptureLive.document_ocr_gate(
               %{content_type: "text/plain"},
               @org,
               Samen.WebTest.Repo
             )

    assert :ok = ApCaptureLive.document_ocr_gate(nil, @org, Samen.WebTest.Repo)
  end

  test "the page shows the org's remaining OCR budget before an upload" do
    account!()
    configure_ocr()
    RateLimitFlood.pin!(%{erp_invoice_ocr: {3, 3_600_000}})

    html = render(open())

    assert html =~ ~s(id="ap-capture-ocr-budget")
    assert html =~ "3 of 3 documents left"
    assert html =~ ~s(id="ap-capture-ocr-reset")
    assert html =~ "Resets in "
  end

  test "the reset line refreshes on the page's own timer" do
    account!()
    configure_ocr()
    RateLimitFlood.pin!(%{erp_invoice_ocr: {2, 3_600_000}})

    socket = open_connected()
    assert render(socket) =~ "2 of 2 documents left"
    assert is_reference(socket.assigns.ocr_window_timer)

    remaining = Process.read_timer(socket.assigns.ocr_window_timer)
    assert is_integer(remaining) and remaining <= 60_000

    assert :ok = OcrQuota.check(@org, repo: Repo)
    {:noreply, socket} = ApCaptureLive.handle_info(:ocr_quota_refresh, socket)

    html = render(socket)
    assert html =~ "1 of 2 documents left"
    assert html =~ ~s(id="ap-capture-ocr-reset")
    assert is_reference(socket.assigns.ocr_window_timer)
  end

  test "an unreadable budget does not show a reset time" do
    account!()
    configure_ocr()
    Repo.query!("DROP TABLE web_ocr_quota")

    html = render(open())

    assert html =~ ~s(id="ap-capture-ocr-budget-unavailable")
    refute html =~ ~s(id="ap-capture-ocr-reset")
  end

  defp restore_invoice_ocr(nil), do: Application.delete_env(:samen_core, :invoice_ocr)
  defp restore_invoice_ocr(module), do: Application.put_env(:samen_core, :invoice_ocr, module)
end
