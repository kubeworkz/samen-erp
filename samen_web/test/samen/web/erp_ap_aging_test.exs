defmodule Samen.Web.ErpApAgingTest do
  @moduledoc """
  The AP aging / vendor statements page (`/erp/ap-aging`) over the REAL
  `Samen.WebTest.Erp.ApInvoice` and the kernel's payment runs:

    * the page renders approved-bill buckets and open rows;
    * `?as_of=` moves the aging date;
    * a vendor statement includes open and paid bills plus effective payments;
    * a reversed payment is not counted as effective and the bill ages again;
    * an empty vendor selection is refused inline.
  """

  use Samen.WebTest.DataCase, async: false

  alias Samen.Scopes.Finance.{ApPaymentReversal, ApPaymentRun}
  alias Samen.Web.Erp.ApAgingLive
  alias Samen.WebTest.Erp.{Account, ApInvoice, PostingAccount}

  @org "55555555-6666-7777-8888-999999999999"
  @as_of "2026-11-08"

  # -- harness ----------------------------------------------------------------

  defp open(params \\ %{"org" => @org, "as_of" => @as_of}) do
    mount = build_mount(:erp)
    session = mount_session(mount)
    {:ok, socket} = ApAgingLive.mount(params, session, %Phoenix.LiveView.Socket{})

    {:noreply, socket} =
      ApAgingLive.handle_params(
        params,
        "http://localhost/erp/ap-aging?as_of=#{params["as_of"]}",
        socket
      )

    socket
  end

  defp event(socket, name, params) do
    {:noreply, socket} = ApAgingLive.handle_event(name, params, socket)
    socket
  end

  defp render(socket), do: render_html(ApAgingLive, socket.assigns)

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

  defp bill!(vendor_id, number, due_date, amount_cents, opts \\ []) do
    expense = account!("6" <> binary_part(Ash.UUID.generate(), 0, 8))

    bill =
      ApInvoice
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: @org,
          vendor_id: vendor_id,
          number: number,
          bill_date: ~D[2026-10-01],
          due_date: due_date,
          lines: [%{account_id: expense.id, amount_cents: amount_cents, memo: "test"}]
        },
        authorize?: false
      )
      |> Ash.create!()

    if Keyword.get(opts, :approved, true), do: approve_raw!(bill), else: bill
  end

  defp approve_raw!(bill) do
    Samen.WebTest.Repo.query!(
      "UPDATE fai_ap_invoice SET fai_status = 'approved' WHERE fai_id = $1",
      [Ecto.UUID.dump!(bill.id)]
    )

    Ash.get!(ApInvoice, bill.id, authorize?: false)
  end

  defp requester_scope do
    %Samen.Scope{
      actor: %{
        id: "requester:other",
        org_id: @org,
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

  defp pay!(bill, reference) do
    {:ok, pending} =
      ApPaymentRun.request(
        ap_invoice: ApInvoice,
        repo: Samen.WebTest.Repo,
        scope: requester_scope(),
        bill_ids: [bill.id],
        payment_date: ~D[2026-11-08],
        reference: reference
      )

    {:ok, paid} =
      ApPaymentRun.approve(
        ap_invoice: ApInvoice,
        repo: Samen.WebTest.Repo,
        scope: admin_scope("approver:other"),
        run_id: pending.id
      )

    paid
  end

  defp reverse!(paid_run) do
    {:ok, reversal} =
      ApPaymentReversal.request(
        repo: Samen.WebTest.Repo,
        scope: admin_scope("requester:admin"),
        run_id: paid_run.id,
        reason: "Returned by the bank"
      )

    assert {:ok, _reversed} =
             ApPaymentReversal.approve(
               repo: Samen.WebTest.Repo,
               scope: admin_scope("approver:other"),
               ap_invoice: ApInvoice,
               reversal_id: reversal.id
             )
  end

  # -- aging ------------------------------------------------------------------

  test "renders the org's approved-bill aging inside the ERP shell with its nav item active" do
    seed_posting_accounts()
    vendor = Ash.UUID.generate()

    overdue = bill!(vendor, "AP-1001", ~D[2026-09-01], 10_000)
    current = bill!(vendor, "AP-1002", ~D[2027-01-01], 5_000)
    paid = bill!(vendor, "AP-1003", ~D[2026-09-15], 4_000)
    draft = bill!(vendor, "AP-1004", ~D[2026-09-20], 7_000, approved: false)
    pay!(paid, "PAID-1003")

    socket = open()
    html = render(socket)

    assert html =~ ~s(id="erp-ap-aging")
    assert html =~ ~s(class="app")
    assert html =~ ~s(href="/erp/ap-aging?org=#{@org}" class="on")
    assert html =~ "AP aging"
    assert html =~ ~s(id="aging-bucket-days_61_90")
    assert html =~ "$100.00"
    assert html =~ ~s(id="aging-bucket-current")
    assert html =~ "$50.00"
    assert html =~ ~s(id="aging-total")
    assert html =~ "$150.00"
    assert html =~ ~s(id="aging-row-#{overdue.id}")
    assert html =~ ~s(id="aging-row-#{current.id}")
    assert html =~ ~s(id="view-bill-#{overdue.id}")
    refute html =~ ~s(id="aging-row-#{paid.id}")
    refute html =~ ~s(id="aging-row-#{draft.id}")

    assert socket.assigns.aging.buckets.days_61_90 == 10_000
    assert socket.assigns.aging.total_cents == 15_000
  end

  test "?as_of= moves the aging date and the page states which date it used" do
    vcendor = Ash.UUID.generate()
    bill!(vcendor, "AP-2001", ~D[2026-09-01], 10_000)

    socket = open(%{"org" => @org, "as_of" => "2026-10-01"})
    html = render(socket)

    assert html =~ "as of 2026-10-01"
    assert html =~ ~s(id="aging-bucket-days_1_30")
    assert html =~ "$100.00"
  end

  test "an org with nothing outstanding renders the honest empty state" do
    html = render(open())

    assert html =~ "Nothing outstanding as of 2026-11-08."
    assert html =~ "$0.00"
  end

  # -- vendor statement -------------------------------------------------------

  test "opens one vendor's statement with open and paid bills plus effective payments" do
    seed_posting_accounts()
    vendor = Ash.UUID.generate()
    other = Ash.UUID.generate()

    first = bill!(vendor, "AP-3001", ~D[2026-09-01], 10_000)
    second = bill!(vendor, "AP-3002", ~D[2027-01-01], 5_000)
    paid = bill!(vendor, "AP-3003", ~D[2026-09-15], 4_000)
    other_bill = bill!(other, "AP-4001", ~D[2026-09-15], 99_000)

    pay!(paid, "PAID-3003")

    socket = event(open(), "statement", %{"vendor_id" => vendor})
    html = render(socket)

    assert html =~ ~s(id="vendor-statement")
    assert html =~ ~s(id="statement-billed")
    assert html =~ ~s(id="statement-paid")
    assert html =~ ~s(id="statement-outstanding")
    assert html =~ ~s(id="statement-bill-#{first.id}")
    assert html =~ ~s(id="statement-bill-#{second.id}")
    assert html =~ ~s(id="statement-bill-#{paid.id}")

    assert html =~
             ~s(id="statement-payment-#{socket.assigns.statement.payments |> hd() |> Map.fetch!(:run_id)}-#{paid.id}")

    assert html =~ "PAID-3003"
    refute html =~ ~s(id="statement-bill-#{other_bill.id}")
    refute html =~ ~s(id="statement-payment-#{other_bill.id}")

    statement = socket.assigns.statement
    assert statement.vendor_id == vendor
    assert length(statement.bills) == 3
    assert length(statement.payments) == 1
    assert statement.totals.billed_cents == 19_000
    assert statement.totals.paid_cents == 4_000
    assert statement.totals.outstanding_cents == 15_000
  end

  test "a reversed payment is excluded and its bill ages again" do
    seed_posting_accounts()
    vendor = Ash.UUID.generate()
    bill = bill!(vendor, "AP-5001", ~D[2026-09-01], 10_000)
    paid = pay!(bill, "PAID-5001")
    reverse!(paid)

    socket = event(open(), "statement", %{"vendor_id" => vendor})
    html = render(socket)

    assert Ash.get!(ApInvoice, bill.id, authorize?: false).status == :approved
    assert socket.assigns.aging.total_cents == 10_000
    assert socket.assigns.statement.payments == []

    assert socket.assigns.statement.totals == %{
             billed_cents: 10_000,
             paid_cents: 0,
             outstanding_cents: 10_000
           }

    assert html =~ "Approved"
    refute html =~ "Effective payments"
    refute html =~ "PAID-5001"
  end

  test "a vendor with no documents renders an empty statement, not an error" do
    socket = event(open(), "statement", %{"vendor_id" => Ash.UUID.generate()})
    html = render(socket)

    assert html =~ ~s(id="vendor-statement")
    assert socket.assigns.statement.totals.outstanding_cents == 0
    assert html =~ "$0.00"
    refute html =~ ~s(id="statement-error")
  end

  test "an empty vendor selection is refused inline" do
    socket = event(open(), "statement", %{"vendor_id" => ""})

    assert render(socket) =~ "Choose a vendor."
  end
end
