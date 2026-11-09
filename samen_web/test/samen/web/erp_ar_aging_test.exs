defmodule Samen.Web.ErpArAgingTest do
  @moduledoc """
  The AR aging / customer statements page (`/erp/ar-aging`) over the REAL
  `Samen.WebTest.Billing.Invoice` and `Samen.WebTest.Erp.PaymentReceipt` through
  `Samen.Scopes.Finance.ArAging`:

    * the page renders the bucket totals + the open-invoice rows for the org;
    * `?as_of=` moves the aging date (and the page says which date it used);
    * opening a customer's statement renders that customer's invoices and totals;
    * a customer with nothing on file renders an honest empty statement.
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Scopes.Finance.ArReceiptApplication
  alias Samen.Web.Erp.ArAgingLive
  alias Samen.WebTest.Billing.Invoice
  alias Samen.WebTest.Erp.{Account, PaymentReceipt, PostingAccount}

  @org "55555555-6666-7777-8888-999999999999"
  @as_of "2026-11-08"

  # -- harness ----------------------------------------------------------------

  defp open(params \\ %{"org" => @org, "as_of" => @as_of}) do
    mount = build_mount(:erp)
    session = mount_session(mount)
    {:ok, socket} = ArAgingLive.mount(params, session, %Phoenix.LiveView.Socket{})

    {:noreply, socket} =
      ArAgingLive.handle_params(
        params,
        "http://localhost/erp/ar-aging?as_of=#{@as_of}",
        socket
      )

    socket
  end

  defp event(socket, name, params) do
    {:noreply, socket} = ArAgingLive.handle_event(name, params, socket)
    socket
  end

  defp render(socket), do: render_html(ArAgingLive, socket.assigns)

  # -- seeds ------------------------------------------------------------------

  defp seed_posting_accounts do
    cash = account!("1000")
    ar = account!("1100")

    for {key, account} <- [cash: cash, ar_clearing: ar] do
      PostingAccount
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: @org, key: key, account_id: account.id},
        authorize?: false
      )
      |> Ash.create!()
    end
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

  defp customer! do
    id = Ash.UUID.generate()

    Samen.WebTest.Repo.query!(
      """
      INSERT INTO wbc_customer (wbc_id, wbc_org_id, wbc_inserted_at, wbc_updated_at)
      VALUES ($1, $2, now(), now())
      """,
      [Ecto.UUID.dump!(id), Ecto.UUID.dump!(@org)]
    )

    id
  end

  defp invoice!(customer_id, due_date, cents) do
    Invoice
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: @org,
        customer_id: customer_id,
        status: :open,
        amount_due_cents: cents,
        amount_paid_cents: 0,
        currency: "USD",
        due_date: due_date,
        line_items: []
      },
      authorize?: false
    )
    |> Ash.create!()
  end

  # -- read -------------------------------------------------------------------

  test "renders the org's aging buckets and open invoices inside the ERP shell" do
    customer_id = customer!()
    overdue = invoice!(customer_id, ~U[2026-09-01 00:00:00Z], 10_000)
    current = invoice!(customer_id, ~U[2027-01-01 00:00:00Z], 5_000)

    html = render(open())

    assert html =~ ~s(id="erp-ar-aging")
    assert html =~ ~s(class="app")
    assert html =~ ~s(href="/erp/ar-aging?org=#{@org}" class="on")
    assert html =~ "AR aging"
    assert html =~ ~s(id="aging-bucket-days_61_90")
    assert html =~ "$100.00"
    assert html =~ ~s(id="aging-bucket-current")
    assert html =~ "$50.00"
    assert html =~ ~s(id="aging-total")
    assert html =~ "$150.00"
    assert html =~ ~s(id="aging-row-#{overdue.id}")
    assert html =~ ~s(id="aging-row-#{current.id}")
    assert html =~ ~s(id="record-receipt-#{overdue.id}")
    assert html =~ ~s(id="record-receipt-#{current.id}")

    assert html =~
             ~s(href="/erp/ar-receipts?org=#{@org}&amp;customer_id=#{customer_id}&amp;invoice_id=#{overdue.id}&amp;as_of=#{@as_of}")
  end

  test "?as_of= moves the aging date and the page states which date it used" do
    customer_id = customer!()
    invoice!(customer_id, ~U[2026-09-01 00:00:00Z], 10_000)

    socket = open(%{"org" => @org, "as_of" => "2026-10-01"})
    html = render(socket)

    assert html =~ "as of 2026-10-01"
    # 30 days overdue → the 1–30 bucket, not 61–90.
    assert html =~ "$100.00"
    assert html =~ ~s(id="aging-bucket-days_1_30")
  end

  test "an org with nothing outstanding renders the honest empty state" do
    html = render(open())

    assert html =~ "Nothing outstanding as of 2026-11-08."
    assert html =~ "$0.00"
  end

  # -- statement --------------------------------------------------------------

  test "opens one customer's statement with its invoices and totals" do
    customer_id = customer!()
    other_id = customer!()
    first = invoice!(customer_id, ~U[2026-09-01 00:00:00Z], 10_000)
    second = invoice!(customer_id, ~U[2027-01-01 00:00:00Z], 5_000)
    other_invoice = invoice!(other_id, ~U[2026-09-15 00:00:00Z], 99_000)

    socket = event(open(), "statement", %{"customer_id" => customer_id})
    html = render(socket)

    assert html =~ ~s(id="customer-statement")
    assert html =~ ~s(id="statement-invoiced")
    assert html =~ "$150.00"
    assert html =~ ~s(id="statement-outstanding")
    assert html =~ ~s(id="record-receipt-link")
    assert html =~ "Record receipt"

    assert html =~
             ~s(href="/erp/ar-receipts?org=#{@org}&amp;customer_id=#{customer_id}&amp;as_of=#{@as_of}")

    assert html =~ ~s(id="statement-record-receipt-#{first.id}")
    assert html =~ ~s(id="statement-record-receipt-#{second.id}")

    assert html =~
             ~s(href="/erp/ar-receipts?org=#{@org}&amp;customer_id=#{customer_id}&amp;invoice_id=#{first.id}&amp;as_of=#{@as_of}")

    statement = socket.assigns.statement
    assert statement.customer_id == customer_id
    assert length(statement.invoices) == 2
    assert statement.totals.outstanding_cents == 15_000
    refute Enum.any?(statement.invoices, &(&1.invoice_id == other_invoice.id))
  end

  test "a fully paid statement row renders no Record receipt link" do
    seed_posting_accounts()
    customer_id = customer!()
    paid = invoice!(customer_id, ~U[2026-09-01 00:00:00Z], 10_000)

    assert {:ok, _run} =
             ArReceiptApplication.apply(
               invoice: Invoice,
               receipt: PaymentReceipt,
               repo: Samen.WebTest.Repo,
               scope: Samen.Web.Plane.scope(Samen.Web.Plane.tenant(), @org),
               org_id: @org,
               customer_id: customer_id,
               paid_at: ~D[2026-11-08],
               allocations: [%{invoice_id: paid.id, amount_cents: 10_000}]
             )

    socket = event(open(), "statement", %{"customer_id" => customer_id})
    html = render(socket)

    assert [row] = socket.assigns.statement.invoices
    assert row.invoice_id == paid.id
    assert row.paid_cents == 10_000
    assert row.outstanding_cents == 0

    assert html =~ ~s(id="customer-statement")
    assert html =~ "$100.00"

    refute html =~ ~s(id="statement-record-receipt-#{paid.id}")
    refute html =~ ~s(id="record-receipt-#{paid.id}")
    refute html =~ ~s(id="aging-row-#{paid.id}")
  end

  test "a partially paid statement row still renders its Record receipt link" do
    seed_posting_accounts()
    customer_id = customer!()
    partial = invoice!(customer_id, ~U[2026-09-01 00:00:00Z], 10_000)

    assert {:ok, _run} =
             ArReceiptApplication.apply(
               invoice: Invoice,
               receipt: PaymentReceipt,
               repo: Samen.WebTest.Repo,
               scope: Samen.Web.Plane.scope(Samen.Web.Plane.tenant(), @org),
               org_id: @org,
               customer_id: customer_id,
               paid_at: ~D[2026-11-08],
               allocations: [%{invoice_id: partial.id, amount_cents: 4_000}]
             )

    socket = event(open(), "statement", %{"customer_id" => customer_id})
    html = render(socket)

    assert [row] = socket.assigns.statement.invoices
    assert row.invoice_id == partial.id
    assert row.paid_cents == 4_000
    assert row.outstanding_cents == 6_000

    assert html =~ ~s(id="statement-record-receipt-#{partial.id}")
    assert html =~ ~s(id="record-receipt-#{partial.id}")
    assert html =~ "$60.00"

    assert html =~
             ~s(href="/erp/ar-receipts?org=#{@org}&amp;customer_id=#{customer_id}&amp;invoice_id=#{partial.id}&amp;as_of=#{@as_of}")
  end

  test "a customer with no documents renders an empty statement, not an error" do
    socket = event(open(), "statement", %{"customer_id" => Ash.UUID.generate()})
    html = render(socket)

    assert html =~ ~s(id="customer-statement")
    assert socket.assigns.statement.totals.outstanding_cents == 0
    assert html =~ "$0.00"
    refute html =~ ~s(id="statement-error")
  end

  test "an empty customer selection is refused inline" do
    socket = event(open(), "statement", %{"customer_id" => ""})

    assert render(socket) =~ "Choose a customer."
  end
end
