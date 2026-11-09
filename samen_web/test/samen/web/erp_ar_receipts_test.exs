defmodule Samen.Web.ErpArReceiptsTest do
  @moduledoc """
  The AR receipt intake page (`/erp/ar-receipts`) over the REAL
  `Samen.WebTest.Billing.Invoice` and `Samen.WebTest.Erp.PaymentReceipt`:

    * the page lists the selected customer's open invoices inside the ERP shell;
    * one payment applies across several invoices, posting one receipt and one
      cash+AR entry per invoice;
    * the reload after posting clears the applied aging;
    * partial allocations leave the remainder open;
    * over-allocations, cross-customer invoices, empty selections and a second
      receipt for an already-settled invoice are refused with nothing posted.
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.ArReceiptApplication
  alias Samen.Web.Erp.ArReceiptsLive
  alias Samen.WebTest.Billing.Invoice
  alias Samen.WebTest.Erp.{Account, JournalEntry, JournalLine, PaymentReceipt, PostingAccount}

  defmodule RaceRepo do
    @moduledoc false

    # A test-only gate at the validation/transaction boundary: both applications
    # finish their statement checks, park here, and are released one at a time.
    # Every read and write still goes through the real repo; the gate only makes
    # the write order deterministic (the sandbox wraps each transaction in a
    # savepoint, so the loser's rollback cannot poison the test transaction).
    def transaction(fun) do
      send(Process.get(:race_parent), {:race_at_transaction, self()})

      receive do
        :race_commit -> :ok
      end

      Samen.WebTest.Repo.transaction(fun)
    end

    def rollback(reason), do: Samen.WebTest.Repo.rollback(reason)
  end

  @org "55555555-6666-7777-8888-999999999999"
  @as_of "2026-11-08"

  # -- harness ----------------------------------------------------------------

  defp open(params \\ %{"org" => @org, "as_of" => @as_of}) do
    mount = build_mount(:erp)
    session = mount_session(mount)
    {:ok, socket} = ArReceiptsLive.mount(params, session, %Phoenix.LiveView.Socket{})

    {:noreply, socket} =
      ArReceiptsLive.handle_params(
        params,
        "http://localhost/erp/ar-receipts?as_of=#{@as_of}",
        socket
      )

    socket
  end

  defp event(socket, name, params) do
    {:noreply, socket} = ArReceiptsLive.handle_event(name, params, socket)
    socket
  end

  defp render(socket), do: render_html(ArReceiptsLive, socket.assigns)

  defp select_customer(socket, customer_id) do
    event(socket, "customer", %{"customer_id" => customer_id})
  end

  defp allocation(_invoice_id, cents) do
    %{"selected" => "true", "amount_cents" => Integer.to_string(cents)}
  end

  defp apply_receipt(socket, allocations, overrides \\ %{}) do
    receipt =
      %{
        "paid_at" => @as_of,
        "reference" => "DEP-100",
        "memo" => "wire",
        "allocations" => allocations
      }
      |> Map.merge(overrides)

    event(socket, "apply", %{"receipt" => receipt})
  end

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

  defp receipts! do
    PaymentReceipt
    |> Ash.Query.filter(org_id == ^@org and status == :posted)
    |> Ash.read!(authorize?: false)
    |> Enum.sort_by(& &1.invoice_id)
  end

  defp entries! do
    JournalEntry
    |> Ash.Query.filter(org_id == ^@org and source_key == "billing_payment")
    |> Ash.read!(authorize?: false)
  end

  defp lines!(entry_id) do
    JournalLine
    |> Ash.Query.filter(entry_id == ^entry_id)
    |> Ash.read!(authorize?: false)
  end

  # -- read -------------------------------------------------------------------

  test "renders the intake page with the selected customer's open invoices" do
    seed_posting_accounts()
    customer_id = customer!()
    overdue = invoice!(customer_id, ~U[2026-09-01 00:00:00Z], 10_000)
    current = invoice!(customer_id, ~U[2027-01-01 00:00:00Z], 5_000)

    socket = open()
    html = render(socket)

    assert html =~ ~s(id="erp-ar-receipts")
    assert html =~ ~s(class="app")
    assert html =~ ~s(href="/erp/ar-receipts?org=#{@org}" class="on")
    assert html =~ "AR receipts"
    assert html =~ ~s(id="ar-customer-form")

    socket = select_customer(socket, customer_id)
    html = render(socket)

    assert html =~ ~s(id="ar-open-invoice-#{overdue.id}")
    assert html =~ ~s(id="ar-open-invoice-#{current.id}")
    assert html =~ ~s(id="ar-receipt-form")
    assert html =~ "$100.00"
    assert html =~ "$50.00"
    assert length(socket.assigns.open_invoices) == 2
  end

  test "?customer_id= and ?invoice_id= preselect the invoice and its outstanding amount" do
    seed_posting_accounts()
    customer_id = customer!()
    other_id = customer!()
    invoice = invoice!(customer_id, ~U[2026-09-01 00:00:00Z], 10_000)
    other = invoice!(other_id, ~U[2026-09-01 00:00:00Z], 5_000)

    socket =
      open(%{
        "org" => @org,
        "as_of" => @as_of,
        "customer_id" => customer_id,
        "invoice_id" => invoice.id
      })

    assert socket.assigns.selected_customer == customer_id
    assert socket.assigns.preselected_invoice_id == invoice.id
    assert [row] = socket.assigns.open_invoices
    assert row.invoice_id == invoice.id

    html = render(socket)
    assert html =~ ~s(id="ar-open-invoice-#{invoice.id}")
    refute html =~ ~s(id="ar-open-invoice-#{other.id}")

    assert html =~
             ~r/id="ar-apply-#{invoice.id}"\s+name="receipt\[allocations\]\[#{invoice.id}\]\[selected\]"\s+value="true"\s+checked/

    refute html =~ ~r/id="ar-apply-#{other.id}"[^>]*checked/

    assert html =~
             ~r/name="receipt\[allocations\]\[#{invoice.id}\]\[amount_cents\]"\s+value="#{invoice.amount_due_cents}"/
  end

  # -- apply ------------------------------------------------------------------

  test "applies one receipt across two invoices, posts the GL, and clears aging" do
    seed_posting_accounts()
    customer_id = customer!()
    first = invoice!(customer_id, ~U[2026-09-01 00:00:00Z], 10_000)
    second = invoice!(customer_id, ~U[2027-01-01 00:00:00Z], 5_000)

    socket =
      open()
      |> select_customer(customer_id)
      |> apply_receipt(%{
        first.id => allocation(first.id, 10_000),
        second.id => allocation(second.id, 5_000)
      })

    assert socket.assigns.error == nil
    assert %{reference: "DEP-100", total_cents: 15_000, receipts: posted} = socket.assigns.posted
    assert length(posted) == 2
    assert socket.assigns.aging.total_cents == 0
    assert socket.assigns.open_invoices == []

    saved = receipts!()
    assert length(saved) == 2
    assert Enum.map(saved, & &1.amount_cents) |> Enum.sort() == [5_000, 10_000]
    assert Enum.all?(saved, &(&1.invoice_key == "billing_invoice"))
    assert Enum.all?(saved, &(&1.memo =~ "DEP-100"))

    for receipt <- saved do
      assert [entry] = Enum.filter(entries!(), &(&1.source_id == receipt.id))
      assert entry.status == :posted
      assert entry.entry_date == ~D[2026-11-08]

      lines = lines!(entry.id)
      assert Enum.sum(Enum.map(lines, & &1.debit_cents)) == receipt.amount_cents
      assert Enum.sum(Enum.map(lines, & &1.credit_cents)) == receipt.amount_cents
    end

    html = render(socket)
    assert html =~ "Receipt posted"
    assert html =~ "DEP-100"
    assert html =~ ~s(id="ar-receipt-result")
    assert html =~ ~s(id="ar-receipt-aging-link")
    refute html =~ ~s(id="ar-open-invoice-#{first.id}")
  end

  test "resubmitting the same multi-invoice receipt posts nothing twice" do
    seed_posting_accounts()
    customer_id = customer!()
    first = invoice!(customer_id, ~U[2026-09-01 00:00:00Z], 10_000)
    second = invoice!(customer_id, ~U[2027-01-01 00:00:00Z], 5_000)

    allocations = %{
      first.id => allocation(first.id, 10_000),
      second.id => allocation(second.id, 5_000)
    }

    socket = open() |> select_customer(customer_id)
    posted = apply_receipt(socket, allocations)

    assert posted.assigns.error == nil
    assert %{reference: "DEP-100", total_cents: 15_000} = posted.assigns.posted

    receipts = receipts!()
    entries = entries!()
    assert length(receipts) == 2
    assert length(entries) == 2
    assert Enum.sum(Enum.map(receipts, & &1.amount_cents)) == 15_000

    # Replay the SAME submission from the pre-post socket (a double submit).
    refused = apply_receipt(socket, allocations)

    assert refused.assigns.posted == nil
    assert refused.assigns.error =~ "already"

    assert Enum.sort(Enum.map(receipts!(), & &1.id)) ==
             Enum.sort(Enum.map(receipts, & &1.id))

    assert Enum.sort(Enum.map(entries!(), & &1.id)) == Enum.sort(Enum.map(entries, & &1.id))

    html = render(refused)
    assert html =~ ~s(id="ar-receipt-error")
    refute html =~ ~s(id="ar-receipt-result")
  end

  test "two racing applications against one invoice: the database anchor rejects the loser" do
    seed_posting_accounts()
    customer_id = customer!()
    invoice = invoice!(customer_id, ~U[2026-09-01 00:00:00Z], 10_000)
    parent = self()

    race = fn ->
      Process.put(:race_parent, parent)

      ArReceiptApplication.apply(
        invoice: Invoice,
        receipt: PaymentReceipt,
        repo: RaceRepo,
        scope: Samen.Web.Plane.scope(Samen.Web.Plane.tenant(), @org),
        org_id: @org,
        customer_id: customer_id,
        paid_at: ~D[2026-11-08],
        reference: "RACE-100",
        allocations: [%{invoice_id: invoice.id, amount_cents: 10_000}]
      )
    end

    winner_task = Task.async(race)
    loser_task = Task.async(race)

    # Both applications passed validate_allocations + validate_not_posted before
    # either one wrote: this is the race window the database anchor closes.
    assert_receive {:race_at_transaction, first_pid}, 2_000
    assert_receive {:race_at_transaction, second_pid}, 2_000

    assert MapSet.new([first_pid, second_pid]) ==
             MapSet.new([winner_task.pid, loser_task.pid])

    send(winner_task.pid, :race_commit)
    assert {:ok, winner} = Task.await(winner_task, 5_000)
    assert winner.total_cents == 10_000

    send(loser_task.pid, :race_commit)
    assert {:error, reason} = Task.await(loser_task, 5_000)

    message = inspect(reason)
    assert message =~ "prc_anchor_unique" or message =~ "unique_violation"

    assert [receipt] = receipts!()
    assert receipt.amount_cents == 10_000
    assert [entry] = entries!()
    assert entry.source_id == receipt.id
  end

  test "a partial allocation leaves the invoice's remainder open" do
    seed_posting_accounts()
    customer_id = customer!()
    invoice = invoice!(customer_id, ~U[2026-09-01 00:00:00Z], 10_000)

    socket =
      open()
      |> select_customer(customer_id)
      |> apply_receipt(%{invoice.id => allocation(invoice.id, 4_000)})

    assert socket.assigns.error == nil
    assert socket.assigns.aging.total_cents == 6_000
    assert [receipt] = receipts!()
    assert receipt.amount_cents == 4_000

    html = render(socket)
    assert html =~ ~s(id="ar-open-invoice-#{invoice.id}")
    assert html =~ "$60.00"
  end

  # -- refusals ---------------------------------------------------------------

  test "an over-allocation is refused and posts nothing" do
    seed_posting_accounts()
    customer_id = customer!()
    invoice = invoice!(customer_id, ~U[2026-09-01 00:00:00Z], 10_000)

    socket =
      open()
      |> select_customer(customer_id)
      |> apply_receipt(%{invoice.id => allocation(invoice.id, 10_001)})

    assert socket.assigns.error =~ "exceeds"
    assert socket.assigns.error =~ "$100.00"
    assert socket.assigns.posted == nil
    assert receipts!() == []
    assert socket.assigns.aging.total_cents == 10_000

    html = render(socket)
    assert html =~ ~s(id="ar-receipt-error")
    refute html =~ ~s(id="ar-receipt-result")
  end

  test "an invoice from another customer is refused and posts nothing" do
    seed_posting_accounts()
    first_customer = customer!()
    second_customer = customer!()
    _first = invoice!(first_customer, ~U[2026-09-01 00:00:00Z], 10_000)
    second = invoice!(second_customer, ~U[2026-09-01 00:00:00Z], 5_000)

    socket =
      open()
      |> select_customer(first_customer)
      |> apply_receipt(%{second.id => allocation(second.id, 5_000)})

    assert socket.assigns.error =~ "not open for this customer"
    assert socket.assigns.posted == nil
    assert receipts!() == []
  end

  test "an empty selection is refused inline" do
    seed_posting_accounts()
    customer_id = customer!()
    _invoice = invoice!(customer_id, ~U[2026-09-01 00:00:00Z], 10_000)

    socket =
      open()
      |> select_customer(customer_id)
      |> apply_receipt(%{})

    assert socket.assigns.error =~ "Select at least one invoice"
    assert receipts!() == []
  end

  test "a second receipt for an already-settled invoice is refused" do
    seed_posting_accounts()
    customer_id = customer!()
    invoice = invoice!(customer_id, ~U[2026-09-01 00:00:00Z], 10_000)

    socket =
      open()
      |> select_customer(customer_id)
      |> apply_receipt(%{invoice.id => allocation(invoice.id, 4_000)})

    assert socket.assigns.error == nil
    assert [first] = receipts!()

    refused =
      apply_receipt(socket, %{invoice.id => allocation(invoice.id, 1_000)})

    assert refused.assigns.error =~ "already has a posted receipt"
    assert [^first] = receipts!()
  end

  test "the service refuses a duplicated invoice in one allocation list" do
    seed_posting_accounts()
    customer_id = customer!()
    invoice = invoice!(customer_id, ~U[2026-09-01 00:00:00Z], 10_000)

    scope = Samen.Web.Plane.scope(Samen.Web.Plane.tenant(), @org)

    assert {:error, :duplicate_allocation} =
             ArReceiptApplication.apply(
               invoice: Invoice,
               receipt: PaymentReceipt,
               repo: Samen.WebTest.Repo,
               scope: scope,
               org_id: @org,
               customer_id: customer_id,
               paid_at: ~D[2026-11-08],
               allocations: [
                 %{invoice_id: invoice.id, amount_cents: 1_000},
                 %{invoice_id: invoice.id, amount_cents: 2_000}
               ]
             )

    assert receipts!() == []
  end
end
