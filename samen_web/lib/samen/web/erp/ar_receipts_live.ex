defmodule Samen.Web.Erp.ArReceiptsLive do
  @moduledoc """
  The AR receipt intake page (`<erp>/ar-receipts`).

  One customer payment is split across the customer's open Billing invoices.
  The page is a thin form over `Samen.Scopes.Finance.ArReceiptApplication`: the
  kernel validates each allocation against the live aging read, creates one
  `PaymentReceipt` per invoice, and posts every receipt in one transaction.

  The page never writes a receipt itself and never trusts a client-supplied
  customer or invoice set. `org_id` is the server-side fact; the customer is
  selected from the org's own open-invoice list; the service re-reads the
  statement before accepting any allocation.

  After a post the page reloads the same `ArAging` projection, so the open
  invoice list and the AR aging page immediately reflect the posted cash.
  """

  use Samen.Web.Tenant.Live

  import Samen.UI
  import Samen.Web.Erp.Live, only: [assign_mount: 2, erp_sidebar: 1, writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Scopes.Finance.{ArAging, ArReceiptApplication}
  alias Samen.Web.Crumbs
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Erp
  alias Samen.Web.TenantRole

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    today = Date.utc_today()

    {:ok,
     socket
     |> assign(
       org_id: org_id,
       return_to: nil,
       as_of: today,
       payment_date: today,
       customers: [],
       selected_customer: nil,
       preselected_invoice_id: nil,
       statement: nil,
       open_invoices: [],
       aging: nil,
       reference: "",
       memo: "",
       posted: nil,
       error: nil,
       statement_error: nil,
       missing: nil
     )
     |> load()}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = CurrentOrg.reresolve(socket, params)
    as_of = parse_date(params["as_of"]) || socket.assigns.as_of
    customer_id = parse_id(params["customer_id"]) || socket.assigns.selected_customer
    invoice_id = parse_id(params["invoice_id"])

    {:noreply,
     socket
     |> assign(
       org_id: org_id,
       return_to: return_path(uri),
       as_of: as_of,
       selected_customer: customer_id,
       preselected_invoice_id: invoice_id
     )
     |> load()}
  end

  @doc false
  def load(socket) do
    socket
    |> assign_new(:customers, fn -> [] end)
    |> assign_new(:selected_customer, fn -> nil end)
    |> assign_new(:preselected_invoice_id, fn -> nil end)
    |> assign_new(:statement, fn -> nil end)
    |> assign_new(:open_invoices, fn -> [] end)
    |> assign_new(:aging, fn -> nil end)
    |> assign_new(:posted, fn -> nil end)
    |> assign_new(:error, fn -> nil end)
    |> assign_new(:statement_error, fn -> nil end)
    |> assign_new(:return_to, fn -> nil end)
    |> do_load()
  end

  defp do_load(%{assigns: %{org_id: nil}} = socket) do
    assign(socket,
      org_id: nil,
      missing: :no_org,
      aging: nil,
      customers: [],
      statement: nil,
      open_invoices: []
    )
  end

  defp do_load(socket) do
    %{samen_mount: mount, org_id: org_id, as_of: as_of} = socket.assigns
    credit_note = Erp.credit_note(mount)
    receipt_allocation = Erp.receipt_allocation(mount)

    with invoice when not is_nil(invoice) <- Erp.billing_invoice(mount),
         receipt when not is_nil(receipt) <- Erp.payment_receipt(mount),
         {:ok, aging} <-
           ArAging.for_org(
             invoice: invoice,
             receipt: receipt,
             receipt_allocation: Erp.receipt_allocation(mount),
             credit_note: credit_note,
             org_id: org_id,
             scope: TenantRole.authenticated_scope(mount, org_id),
             as_of: as_of
           ) do
      customers =
        aging.invoices
        |> Enum.map(& &1.customer_id)
        |> Enum.reject(&is_nil/1)
        |> Enum.uniq()
        |> Enum.sort()

      socket
      |> assign(aging: aging, customers: customers, missing: nil)
      |> read_customer(
        invoice,
        receipt,
        receipt_allocation,
        credit_note,
        org_id,
        TenantRole.authenticated_scope(mount, org_id),
        as_of
      )
    else
      nil ->
        assign(socket,
          missing: :unmounted,
          aging: nil,
          customers: [],
          statement: nil,
          open_invoices: []
        )

      {:error, _reason} ->
        assign(socket,
          missing: :unreadable,
          aging: nil,
          customers: [],
          statement: nil,
          open_invoices: []
        )
    end
  end

  defp read_customer(
         %{assigns: %{selected_customer: nil}} = socket,
         _invoice,
         _receipt,
         _receipt_allocation,
         _credit_note,
         _org_id,
         _scope,
         _as_of
       ) do
    assign(socket,
      statement: nil,
      open_invoices: [],
      preselected_invoice_id: nil,
      statement_error: nil
    )
  end

  defp read_customer(
         socket,
         invoice,
         receipt,
         receipt_allocation,
         credit_note,
         org_id,
         scope,
         as_of
       ) do
    customer_id = socket.assigns.selected_customer

    case ArAging.statement_for_customer(
           invoice: invoice,
           receipt: receipt,
           receipt_allocation: receipt_allocation,
           credit_note: credit_note,
           org_id: org_id,
           scope: scope,
           customer_id: customer_id,
           as_of: as_of
         ) do
      {:ok, statement} ->
        open_invoices = Enum.filter(statement.invoices, &(&1.outstanding_cents > 0))
        preselected = socket.assigns.preselected_invoice_id

        preselected =
          if Enum.any?(open_invoices, &(&1.invoice_id == preselected)), do: preselected

        assign(socket,
          statement: statement,
          open_invoices: open_invoices,
          preselected_invoice_id: preselected,
          statement_error: nil
        )

      {:error, _reason} ->
        assign(socket,
          statement: nil,
          open_invoices: [],
          statement_error: "The customer's open invoices could not be read. Try again."
        )
    end
  end

  # -- events -----------------------------------------------------------------

  @impl true
  def handle_event("customer", %{"customer_id" => raw}, socket) do
    customer_id = String.trim(raw || "")

    socket =
      socket
      |> assign(
        selected_customer: if(customer_id == "", do: nil, else: customer_id),
        preselected_invoice_id: nil,
        posted: nil,
        error: nil
      )
      |> load()

    {:noreply, socket}
  end

  def handle_event("apply", %{"receipt" => params}, socket) do
    %{samen_mount: mount, org_id: org_id, selected_customer: customer_id, as_of: as_of} =
      socket.assigns

    cond do
      not writable?(mount) ->
        {:noreply, assign(socket, error: "Receipts are read-only on this plane.")}

      customer_id in [nil, ""] ->
        {:noreply, assign(socket, error: "Choose a customer.")}

      true ->
        with {:ok, paid_at} <- parse_paid_at(params["paid_at"] || as_of),
             {:ok, allocations} <- parse_allocations(params["allocations"]),
             {:ok, unapplied} <- parse_unapplied(params["unapplied_cents"]) do
          if allocations == [] and unapplied == 0 do
            {:noreply, assign(socket, error: "Select an invoice or enter unapplied cash.")}
          else
            apply_receipt(
              socket,
              mount,
              org_id,
              customer_id,
              paid_at,
              allocations,
              unapplied,
              params
            )
          end
        else
          {:error, message} -> {:noreply, assign(socket, error: message)}
        end
    end
  end

  def handle_event("apply_credit", %{"credit" => params}, socket),
    do: apply_credit_event(socket, params)

  defp apply_receipt(
         socket,
         mount,
         org_id,
         customer_id,
         paid_at,
         allocations,
         unapplied,
         params
       ) do
    case ArReceiptApplication.apply(
           invoice: Erp.billing_invoice(mount),
           receipt: Erp.payment_receipt(mount),
           receipt_allocation: Erp.receipt_allocation(mount),
           credit_note: Erp.credit_note(mount),
           repo: mount.repo,
           scope: TenantRole.authenticated_scope(mount, org_id),
           org_id: org_id,
           customer_id: customer_id,
           paid_at: paid_at,
           reference: blank_to_nil(params["reference"]),
           memo: blank_to_nil(params["memo"]),
           currency: blank_to_nil(params["currency"]),
           unapplied_cents: unapplied,
           allocations: allocations
         ) do
      {:ok, posted} ->
        socket =
          socket
          |> assign(
            posted: posted,
            error: nil,
            reference: "",
            memo: "",
            preselected_invoice_id: nil
          )
          |> load()

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, posted: nil, error: receipt_error(reason))}
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp parse_paid_at(%Date{} = date) do
    case DateTime.new(date, ~T[00:00:00], "Etc/UTC") do
      {:ok, datetime} -> {:ok, datetime}
      {:error, _reason} -> {:error, "Choose a receipt date."}
    end
  end

  defp parse_paid_at(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> parse_paid_at(date)
      {:error, _reason} -> {:error, "Choose a receipt date."}
    end
  end

  defp parse_paid_at(_value), do: {:error, "Choose a receipt date."}

  defp apply_credit_event(socket, params) do
    %{samen_mount: mount, org_id: org_id, selected_customer: customer_id} =
      socket.assigns

    with true <- writable?(mount),
         {:ok, cents} <- parse_cents(params["amount_cents"]),
         receipt_id when is_binary(receipt_id) <- blank_to_nil(params["receipt_id"]),
         invoice_id when is_binary(invoice_id) <- blank_to_nil(params["invoice_id"]) do
      case ArReceiptApplication.apply_credit(
             invoice: Erp.billing_invoice(mount),
             receipt: Erp.payment_receipt(mount),
             receipt_allocation: Erp.receipt_allocation(mount),
             credit_note: Erp.credit_note(mount),
             repo: mount.repo,
             scope: TenantRole.authenticated_scope(mount, org_id),
             org_id: org_id,
             customer_id: customer_id,
             receipt_id: receipt_id,
             invoice_id: invoice_id,
             amount_cents: cents
           ) do
        {:ok, _allocation} ->
          {:noreply, socket |> assign(posted: nil, error: nil) |> load()}

        {:error, reason} ->
          {:noreply, assign(socket, error: receipt_error(reason))}
      end
    else
      false -> {:noreply, assign(socket, error: "Receipts are read-only on this plane.")}
      _ -> {:noreply, assign(socket, error: "Choose an invoice and a positive amount.")}
    end
  end

  defp parse_allocations(allocations) when is_map(allocations) do
    allocations
    |> Enum.filter(fn {_invoice_id, row} ->
      is_map(row) and truthy(row["selected"])
    end)
    |> Enum.reduce_while({:ok, []}, fn {invoice_id, row}, {:ok, acc} ->
      case parse_cents(row["amount_cents"]) do
        {:ok, cents} ->
          {:cont, {:ok, [%{invoice_id: invoice_id, amount_cents: cents} | acc]}}

        :error ->
          {:halt, {:error, "Enter a positive amount for each selected invoice."}}
      end
    end)
    |> case do
      {:ok, []} -> {:ok, []}
      {:ok, allocations} -> {:ok, Enum.reverse(allocations)}
      {:error, message} -> {:error, message}
    end
  end

  defp parse_allocations(_allocations), do: {:ok, []}

  defp parse_unapplied(nil), do: {:ok, 0}

  defp parse_unapplied(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.replace(",", "")

    case normalized do
      "" ->
        {:ok, 0}

      _other ->
        case Integer.parse(normalized) do
          {cents, ""} when cents >= 0 -> {:ok, cents}
          _other -> {:error, "Enter a positive amount of unapplied cash."}
        end
    end
  end

  defp parse_unapplied(value) when is_integer(value) and value >= 0, do: {:ok, value}
  defp parse_unapplied(_value), do: {:error, "Enter a positive amount of unapplied cash."}

  defp parse_cents(value) when is_integer(value) and value > 0, do: {:ok, value}

  defp parse_cents(value) when is_binary(value) do
    normalized = value |> String.trim() |> String.replace(",", "")

    case Integer.parse(normalized) do
      {cents, ""} when cents > 0 -> {:ok, cents}
      _other -> :error
    end
  end

  defp parse_cents(_value), do: :error

  defp truthy(value), do: value in [true, "1", "true", "on"]

  defp receipt_error(:customer_required), do: "Choose a customer."
  defp receipt_error(:paid_at_required), do: "Choose a receipt date."

  defp receipt_error(:allocations_required),
    do: "Select at least one invoice or enter unapplied cash."

  defp receipt_error(:currency_required),
    do: "Choose the currency for on-account cash."

  defp receipt_error({:currency_mismatch, receipt_currency, invoice_currency}),
    do:
      "The receipt currency #{receipt_currency} does not match the invoice currency #{invoice_currency}."

  defp receipt_error({:mixed_currencies, currencies}),
    do: "Select invoices in one currency at a time (#{Enum.join(currencies, ", ")})."

  defp receipt_error(:unapplied_amount_invalid),
    do: "Enter a positive amount of unapplied cash."

  defp receipt_error({:credit_exceeded, remaining_cents}),
    do: "The credit exceeds the receipt's remaining balance (#{money(remaining_cents)})."

  defp receipt_error(:not_on_account),
    do: "That receipt is already tied to an invoice; only on-account cash can be applied."

  defp receipt_error(:credit_not_posted),
    do: "That receipt is not posted yet."

  defp receipt_error(:receipt_not_found), do: "That receipt could not be found."
  defp receipt_error(:customer_mismatch), do: "That receipt belongs to another customer."

  defp receipt_error(:duplicate_allocation), do: "Select each invoice once."

  defp receipt_error(:allocation_amount_invalid),
    do: "Enter a positive amount for each selected invoice."

  defp receipt_error(:invoice_id_required),
    do: "One selected invoice is missing its id. Refresh and try again."

  defp receipt_error({:invoice_not_found, _invoice_id}),
    do: "One of the selected invoices is not open for this customer. Refresh and try again."

  defp receipt_error({:invoice_already_paid, _invoice_id}),
    do: "One of the selected invoices is already paid. Refresh and try again."

  defp receipt_error({:over_allocation, _invoice_id, outstanding_cents}),
    do: "An allocation exceeds that invoice's outstanding balance (#{money(outstanding_cents)})."

  defp receipt_error({:already_applied, _invoice_id}),
    do: "One of the selected invoices already has a posted receipt. Refresh and try again."

  defp receipt_error({:statement_unreadable, _reason}),
    do: "The customer's open invoices could not be read. Try again."

  defp receipt_error(_reason),
    do: "The receipt could not be posted. Nothing was posted."

  defp parse_id(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      id -> id
    end
  end

  defp parse_id(_value), do: nil

  defp parse_date(%Date{} = date), do: date

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _other -> nil
    end
  end

  defp parse_date(_value), do: nil

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp short(nil), do: "—"
  defp short(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short(other), do: to_string(other)

  defp date_of(nil), do: nil
  defp date_of(%DateTime{} = datetime), do: DateTime.to_date(datetime)
  defp date_of(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_date(datetime)
  defp date_of(%Date{} = date), do: date

  defp date_text(nil), do: "—"
  defp date_text(%Date{} = date), do: Date.to_iso8601(date)
  defp date_text(other), do: to_string(other)

  defp money(nil), do: "—"

  defp money(cents) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    cents = abs(cents)

    "#{sign}$#{div(cents, 100)}.#{cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp money(other), do: to_string(other)

  defp total_outstanding(rows), do: Enum.reduce(rows, 0, &(&1.outstanding_cents + &2))

  defp crumbs(mount, org_id) do
    [Crumbs.org(mount, org_id), "ERP", Erp.ar_receipts_label()]
  end

  @impl Samen.Web.Tenant.Live
  def tenant_sidebar(assigns) do
    ~H"""
    <.erp_sidebar
      mount={@samen_mount}
      org_id={@org_id}
      active={:erp_ar_receipts}
      return_to={@return_to}
    />
    """
  end

  @impl Samen.Web.Tenant.Live
  def tenant_page(assigns) do
    ~H"""
    <div id="erp-ar-receipts">
    <.topbar
      title={Erp.ar_receipts_label()}
      crumbs={crumbs(@samen_mount, @org_id)}
    >
      <:actions>
        <a
          href={"#{Samen.Web.Mount.label(@samen_mount, :erp_path, "/erp")}/ar-aging?org=#{@org_id}&as_of=#{Date.to_iso8601(@as_of)}"}
          style="font-size:13px"
        >
          Open AR aging
        </a>
      </:actions>
    </.topbar>

    <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

    <div class="wrap">
      <%= if @missing == :no_org do %>
        <.no_org_card mount={@samen_mount} />
      <% else %>
        <%= if @missing in [:unmounted, :unreadable] do %>
          <div class="card" style="padding:16px;color:var(--muted)">
            <%= if @missing == :unreadable do %>
              The AR documents could not be read. Try again.
            <% else %>
              AR receipts need this workspace's mounted Billing invoices and Finance
              payment receipts.
            <% end %>
          </div>
        <% else %>
          <div class="gtitle">
            <h3>{Erp.ar_receipts_label()}</h3>
            <span class="n">{length(@open_invoices)}</span>
            <span class="lane">· one payment across open invoices · posted on apply</span>
          </div>

          <div
            :if={@posted}
            id="ar-receipt-result"
            class="card"
            style="padding:14px 16px;margin-bottom:10px"
          >
            <div style="font-size:13px;font-weight:700;color:var(--ok, #047857);margin-bottom:4px">
              Receipt posted
            </div>
            <div style="font-size:13px;margin-bottom:6px">
              Reference <code>{@posted.reference}</code> ·
              {length(@posted.receipts)} invoices ·
              {money(@posted.total_cents)}
            </div>
            <a
              id="ar-receipt-aging-link"
              href={"#{Samen.Web.Mount.label(@samen_mount, :erp_path, "/erp")}/ar-aging?org=#{@org_id}&as_of=#{Date.to_iso8601(@as_of)}"}
              style="font-size:13px"
            >
              Open the refreshed AR aging
            </a>
          </div>

          <div
            :if={@error}
            id="ar-receipt-error"
            class="card form-error"
            style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px;margin-bottom:10px"
          >
            {@error}
          </div>

          <div class="card" style="padding:14px 16px;margin-bottom:10px">
            <form id="ar-customer-form" phx-change="customer">
              <label
                for="ar-customer"
                style="display:block;font-size:12px;font-weight:600;margin-bottom:5px"
              >
                Customer
              </label>
              <select
                name="customer_id"
                id="ar-customer"
                style="font-size:12px;padding:6px 8px;min-width:240px"
              >
                <option value="">Choose a customer…</option>
                <option
                  :for={customer_id <- @customers}
                  value={customer_id}
                  selected={customer_id == @selected_customer}
                >
                  {short(customer_id)}
                </option>
              </select>
            </form>
          </div>

          <div
            :if={@statement_error}
            id="ar-statement-error"
            style="font-size:12px;color:var(--bad, #b91c1c);margin-bottom:10px"
          >
            {@statement_error}
          </div>

          <%= if @selected_customer && @open_invoices == [] && @posted == nil do %>
            <div class="card" id="ar-receipt-empty" style="padding:16px;color:var(--muted)">
              No open invoices for this customer. You can still record on-account cash below.
            </div>
          <% end %>

          <form :if={@selected_customer} id="ar-receipt-form" phx-submit="apply">
            <div
              class="card"
              style="padding:12px 16px;margin-bottom:10px;display:flex;gap:10px;flex-wrap:wrap;align-items:end"
            >
              <div style="display:flex;flex-direction:column;gap:4px">
                <label for="ar-receipt-date" style="font-size:12px;font-weight:600">
                  Received
                </label>
                <input
                  type="date"
                  id="ar-receipt-date"
                  name="receipt[paid_at]"
                  value={Date.to_iso8601(@payment_date)}
                  style="font-size:12px;padding:6px 8px"
                />
              </div>
              <div style="display:flex;flex-direction:column;gap:4px">
                <label for="ar-receipt-reference" style="font-size:12px;font-weight:600">
                  Reference
                </label>
                <input
                  type="text"
                  id="ar-receipt-reference"
                  name="receipt[reference]"
                  value={@reference}
                  placeholder="Deposit / wire reference"
                  style="font-size:12px;padding:6px 8px"
                />
              </div>
              <div style="display:flex;flex-direction:column;gap:4px;flex:1;min-width:180px">
                <label for="ar-receipt-memo" style="font-size:12px;font-weight:600">
                  Memo
                </label>
                <input
                  type="text"
                  id="ar-receipt-memo"
                  name="receipt[memo]"
                  value={@memo}
                  style="font-size:12px;padding:6px 8px"
                />
              </div>
              <div style="display:flex;flex-direction:column;gap:4px">
                <label for="ar-receipt-currency" style="font-size:12px;font-weight:600">
                  Currency
                </label>
                <input
                  type="text"
                  id="ar-receipt-currency"
                  name="receipt[currency]"
                  value=""
                  placeholder="Derived; required on-account"
                  maxlength="3"
                  style="font-size:12px;padding:6px 8px;width:120px;text-transform:uppercase"
                />
              </div>
              <div style="display:flex;flex-direction:column;gap:4px">
                <label for="ar-receipt-unapplied" style="font-size:12px;font-weight:600">
                  Unapplied cash
                </label>
                <input
                  type="number"
                  id="ar-receipt-unapplied"
                  name="receipt[unapplied_cents]"
                  min="0"
                  value="0"
                  style="font-size:12px;padding:6px 8px;width:130px;text-align:right"
                />
              </div>
            </div>

            <table style="width:100%;border-collapse:collapse;font-size:13px">
              <thead>
                <tr>
                  <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Apply</th>
                  <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Invoice</th>
                  <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Due</th>
                  <th scope="col" style="text-align:right;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Outstanding</th>
                  <th scope="col" style="text-align:right;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Amount (cents)</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @open_invoices} id={"ar-open-invoice-#{row.invoice_id}"}>
                  <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                    <input
                      type="checkbox"
                      id={"ar-apply-#{row.invoice_id}"}
                      name={"receipt[allocations][#{row.invoice_id}][selected]"}
                      value="true"
                      checked={row.invoice_id == @preselected_invoice_id}
                    />
                  </td>
                  <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                    {short(row.invoice_id)}
                  </td>
                  <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                    {date_text(row.due_date)}
                  </td>
                  <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6);text-align:right">
                    {money(row.outstanding_cents)}
                  </td>
                  <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6);text-align:right">
                    <input
                      type="number"
                      min="1"
                      max={row.outstanding_cents}
                      name={"receipt[allocations][#{row.invoice_id}][amount_cents]"}
                      value={row.outstanding_cents}
                      style="font-size:12px;padding:5px 7px;width:120px;text-align:right"
                    />
                  </td>
                </tr>
                <tr :if={@open_invoices == []}>
                  <td colspan="5" style="padding:10px 8px;color:var(--muted)">
                    No open invoices. Enter an amount under Unapplied cash to record on-account cash.
                  </td>
                </tr>
              </tbody>
            </table>

            <div
              style="display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;margin-top:10px"
            >
              <span style="font-size:12px;color:var(--muted)">
                Selected invoices post as one receipt. Unapplied cash is held as customer credit; an allocation over an invoice's balance is split into credit.
              </span>
              <span style="font-size:13px">
                <b>Open:</b> {money(total_outstanding(@open_invoices))}
              </span>
              <.button type="submit" id="apply-receipt">Apply receipt</.button>
            </div>
          </form>

          <div
            :if={@statement && @statement.unapplied_cash != []}
            id="ar-credit-panel"
            class="card"
            style="padding:14px 16px;margin-top:10px"
          >
            <div style="font-size:13px;font-weight:700;margin-bottom:6px">Unapplied cash</div>
            <div
              :for={credit <- @statement.unapplied_cash}
              id={"ar-credit-#{credit.receipt_id}"}
              style="padding:8px 0;border-bottom:1px solid var(--border, #f3f4f6)"
            >
              <div style="font-size:12px;margin-bottom:5px">
                {credit.currency} {money(credit.unapplied_cents)} available
                <span style="color:var(--muted)">· received {date_text(date_of(credit.paid_at))}</span>
              </div>
              <form phx-submit="apply_credit" style="display:flex;gap:6px;align-items:center;flex-wrap:wrap">
                <input type="hidden" name="credit[receipt_id]" value={credit.receipt_id} />
                <select name="credit[invoice_id]" style="font-size:12px;padding:5px 7px">
                  <option value="">Apply to invoice…</option>
                  <option
                    :for={row <- @open_invoices}
                    :if={row.currency == credit.currency}
                    value={row.invoice_id}
                  >
                    {short(row.invoice_id)} · {money(row.outstanding_cents)} open
                  </option>
                </select>
                <input
                  type="number"
                  name="credit[amount_cents]"
                  min="1"
                  value={credit.unapplied_cents}
                  style="font-size:12px;padding:5px 7px;width:120px;text-align:right"
                />
                <.button type="submit">Apply credit</.button>
              </form>
            </div>
          </div>
        <% end %>
      <% end %>
    </div>
    </div>
    """
  end
end
