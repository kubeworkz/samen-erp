defmodule Samen.Web.BillingInvoiceDetailTest do
  @moduledoc """
  The invoice DETAIL twin (`Samen.Web.Billing.InvoiceLive`) — the record page
  behind the invoices list:

    * **Render** — bounded facts `<dl>` + the invoice's jsonb `line_items` table +
      the breadcrumb/back link (org-threaded) + the sidebar's Invoices nav item
      marked active + the hosted link tenant-side only.
    * **Edit (AC-G1-1/2)** — the `AshPhoenix.Form.for_update` modal: an INVALID
      save (non-numeric amount) renders the kit's inline errors and persists
      NOTHING; a valid save persists + re-renders. Status is NOT an edit field.
    * **Status transitions** — the CLOSED table: a pre-state-allowed move lands
      through the admin write scope; an out-of-pre-state or unknown key is a
      SILENT no-op; buttons render only for allowed moves.
    * **Delete** — the `delete_confirm/1` interlock event destroys through Ash and
      navigates back to the list.
    * **Operator posture (belt)** — no write affordance in the operator DOM, the
      hosted links hidden, the joined customer rendered ••••.
    * **Not found** — a bogus id is the honest not-found state, never a raise.
  """
  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  alias Samen.Web.Billing.InvoiceLive

  setup do
    seeded = Seeds.seed_all()

    %{
      org_id: seeded.org_id,
      invoice: seeded.billing.invoice,
      customer: seeded.billing.customer
    }
  end

  # -- harness -----------------------------------------------------------------

  defp mount_socket(org_id, invoice_id, plane_opts \\ []) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, build_mount(:billing, plane_opts))
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> Phoenix.Component.assign(:return_to, nil)
    |> InvoiceLive.load(org_id, invoice_id)
  end

  defp html(socket), do: render_html(InvoiceLive, socket.assigns)

  defp event(socket, name, params) do
    {:noreply, socket} = InvoiceLive.handle_event(name, params, socket)
    socket
  end

  defp raw_invoice(id) do
    Samen.WebTest.Billing.Invoice
    |> Ash.Query.ensure_selected([:org_id, :status, :amount_due_cents, :currency])
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.limit(1)
    |> Ash.read!(authorize?: false)
    |> List.first()
  end

  defp fresh_invoice(org_id, customer_id, attrs) do
    Samen.WebTest.Billing.Invoice
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(
        %{
          org_id: org_id,
          customer_id: customer_id,
          status: :draft,
          amount_due_cents: 10_000,
          currency: "USD"
        },
        attrs
      ),
      authorize?: false
    )
    |> Ash.create!()
  end

  # ---------------------------------------------------------------------------

  test "detail renders the facts, the jsonb line items, breadcrumb/back link, and the active nav",
       %{org_id: org_id, customer: customer} do
    invoice =
      fresh_invoice(org_id, customer.id, %{
        status: :open,
        line_items: [
          %{"description" => "Consulting", "quantity" => 2, "amount_cents" => 50_000},
          %{"description" => "Expenses", "quantity" => 1, "amount_cents" => 1_250}
        ],
        hosted_invoice_url: "https://pay.example/inv_hosted_1"
      })

    socket = mount_socket(org_id, invoice.id)
    rendered = html(socket)

    label = "INV-#{String.slice(invoice.id, 0, 8)}"
    assert rendered =~ ~s(id="invoice-facts")
    assert rendered =~ label

    # The jsonb document lines render verbatim.
    assert rendered =~ ~s(id="invoice-lines")
    assert rendered =~ "Consulting"
    assert rendered =~ "Expenses"
    assert rendered =~ "$500.00"
    assert rendered =~ "$12.50"

    # Hosted provider link renders TENANT-side.
    assert rendered =~ "inv_hosted_1"

    # Breadcrumb leaf (inert) + the Invoices crumb / Back link, org-threaded.
    assert rendered =~ ~s(href="/billing/invoices?org=#{org_id}")
    assert rendered =~ "Back to invoices"

    # The sidebar nav item is the active one (`href=… class="on"`).
    assert rendered =~ ~s(href="/billing/invoices?org=#{org_id}" class="on")

    # Status actions: an :open invoice offers paid/void/uncollectible, NOT open.
    assert rendered =~ ~s(id="invoice-status-actions")
    assert rendered =~ ~s(id="transition-paid")
    assert rendered =~ ~s(id="transition-void")
    refute rendered =~ ~s(id="transition-open")
  end

  test "a bogus id renders the honest not-found state", %{org_id: org_id} do
    socket = mount_socket(org_id, Ash.UUID.generate())
    assert html(socket) =~ "Invoice not found."
  end

  # ---------------------------------------------------------------------------
  # Edit — invalid persists NOTHING, valid lands (status never an edit field)
  # ---------------------------------------------------------------------------

  test "EDIT: an invalid save renders inline errors and persists NOTHING; a valid save lands",
       %{org_id: org_id, invoice: invoice} do
    socket = mount_socket(org_id, invoice.id)
    socket = event(socket, "edit_invoice", %{})
    assert html(socket) =~ ~s(id="edit-invoice-modal")

    bad = %{"amount_due_cents" => "not-a-number", "currency" => "USD"}
    socket = event(socket, "validate_edit", %{"form" => bad})
    socket = event(socket, "save_edit", %{"form" => bad})

    rendered = html(socket)
    assert rendered =~ ~s(id="edit-invoice-modal")
    assert rendered =~ "field-invalid"
    assert rendered =~ "field-error"
    assert raw_invoice(invoice.id).amount_due_cents == 29_900

    good = %{"amount_due_cents" => "55000", "currency" => "EUR"}
    socket = event(socket, "save_edit", %{"form" => good})

    refute html(socket) =~ ~s(id="edit-invoice-modal")
    raw = raw_invoice(invoice.id)
    assert raw.amount_due_cents == 55_000
    assert raw.currency == "EUR"
    assert html(socket) =~ "$550.00"
    # The status never moved through the edit path.
    assert raw.status == :open
  end

  # ---------------------------------------------------------------------------
  # Status transitions — closed table, pre-state gated
  # ---------------------------------------------------------------------------

  test "TRANSITION: a pre-state-allowed move lands through the write scope",
       %{org_id: org_id, invoice: invoice} do
    socket = mount_socket(org_id, invoice.id)

    socket = event(socket, "transition", %{"action" => "paid"})
    assert raw_invoice(invoice.id).status == :paid

    # Terminal: no further moves are offered from :paid.
    refute html(socket) =~ ~s(id="transition-")
  end

  test "TRANSITION: a draft invoice offers Mark open and lands it",
       %{org_id: org_id, customer: customer} do
    draft = fresh_invoice(org_id, customer.id, %{})

    socket = mount_socket(org_id, draft.id)
    assert html(socket) =~ ~s(id="transition-open")

    socket = event(socket, "transition", %{"action" => "open"})
    assert raw_invoice(draft.id).status == :open
  end

  test "TRANSITION: an out-of-pre-state or unknown action is a silent no-op",
       %{org_id: org_id, invoice: invoice} do
    socket = mount_socket(org_id, invoice.id)

    # `open` moves only FROM :draft — the seeded invoice is already :open.
    socket = event(socket, "transition", %{"action" => "open"})
    assert raw_invoice(invoice.id).status == :open

    # An unknown key never reaches an atom mint or a write.
    socket = event(socket, "transition", %{"action" => "explode"})
    assert raw_invoice(invoice.id).status == :open

    refute html(socket) =~ ~s(id="action-error")
  end

  # ---------------------------------------------------------------------------
  # Delete — interlock event destroys + navigates back to the list
  # ---------------------------------------------------------------------------

  test "DELETE: the confirm event destroys the invoice and navigates back to the list",
       %{org_id: org_id, invoice: invoice} do
    socket = mount_socket(org_id, invoice.id)
    rendered = html(socket)
    assert rendered =~ "data-confirm"

    socket = event(socket, "delete", %{"id" => invoice.id})
    assert {:live, :redirect, %{to: to}} = socket.redirected
    assert to =~ "/billing/invoices"
    assert raw_invoice(invoice.id) == nil
  end

  # ---------------------------------------------------------------------------
  # Operator posture (belt) — no write affordance, masked customer, no hosted link
  # ---------------------------------------------------------------------------

  test "OPERATOR plane: no write affordance; customer masked; hosted links hidden",
       %{org_id: org_id, customer: customer} do
    invoice =
      fresh_invoice(org_id, customer.id, %{
        status: :open,
        hosted_invoice_url: "https://pay.example/inv_hosted_2"
      })

    socket = mount_socket(org_id, invoice.id, plane: :operator, target_org_id: org_id)
    rendered = html(socket)

    assert rendered =~ ~s(id="invoice-facts")
    refute rendered =~ ~s(id="edit-invoice")
    refute rendered =~ ~s(id="delete-invoice")
    refute rendered =~ ~s(id="transition-")
    refute rendered =~ "data-confirm"
    refute rendered =~ "inv_hosted_2"
    refute rendered =~ Seeds.customer_name()
    assert rendered =~ "••••"
  end
end
