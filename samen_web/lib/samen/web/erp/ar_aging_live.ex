defmodule Samen.Web.Erp.ArAgingLive do
  @moduledoc """
  The AR aging and customer statements page (`<erp>/ar-aging`).

  One read answers both questions the AR desk asks:

    * **aging** — `Samen.Scopes.Finance.ArAging.for_org/1` over the host's
      Billing invoices and POSTED `PaymentReceipt` cash, bucketed
      `current / 1–30 / 31–60 / 61–90 / 90+ / undated`;
    * **statement** — `statement_for_customer/1` for one customer: every invoice
      (paid or open), the posted receipts that settled them, and the totals.

  The read is the SAME kernel projection the API uses — the page renders only
  what `ArAging` computed, so the pixel and the export cannot diverge. The
  Billing mirror's `amount_paid_cents` is deliberately ignored there: provider
  state is not posted cash.

  No write affordance exists on this page. `org_id` is the server-side fact and
  the scope is the mount plane's, so an operator-plane mount reads masked and
  every caller is pinned to its own org.
  """

  use Samen.Web.Tenant.Live

  import Samen.UI
  import Samen.Web.Erp.Live, only: [assign_mount: 2, erp_sidebar: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Scopes.Finance.ArAging
  alias Samen.Web.Crumbs
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Erp
  alias Samen.Web.TenantRole

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)

    {:ok,
     socket
     |> assign(
       org_id: org_id,
       return_to: nil,
       as_of: Date.utc_today(),
       aging: nil,
       customers: [],
       selected_customer: nil,
       statement: nil,
       statement_error: nil,
       missing: nil
     )
     |> load()}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = CurrentOrg.reresolve(socket, params)

    {:noreply,
     socket
     |> assign(
       org_id: org_id,
       return_to: return_path(uri),
       as_of: parse_date(params["as_of"]) || socket.assigns.as_of
     )
     |> load()}
  end

  @doc false
  def load(socket) do
    socket
    |> assign_new(:as_of, fn -> Date.utc_today() end)
    |> assign_new(:customers, fn -> [] end)
    |> assign_new(:selected_customer, fn -> nil end)
    |> assign_new(:statement, fn -> nil end)
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
      statement: nil
    )
  end

  defp do_load(socket) do
    %{samen_mount: mount, org_id: org_id, as_of: as_of} = socket.assigns

    with invoice when not is_nil(invoice) <- Erp.billing_invoice(mount),
         receipt when not is_nil(receipt) <- Erp.payment_receipt(mount) do
      scope = TenantRole.authenticated_scope(mount, org_id)

      case ArAging.for_org(
             invoice: invoice,
             receipt: receipt,
             receipt_allocation: Erp.receipt_allocation(mount),
             credit_note: Erp.credit_note(mount),
             org_id: org_id,
             scope: scope,
             as_of: as_of
           ) do
        {:ok, aging} ->
          assign(socket,
            aging: aging,
            customers: customers(aging),
            missing: nil
          )

        {:error, _reason} ->
          assign(socket, aging: nil, customers: [], missing: :unreadable)
      end
    else
      _not_mounted ->
        assign(socket, aging: nil, customers: [], missing: :unmounted)
    end
  end

  defp customers(aging), do: aging.customer_ids

  # -- events -----------------------------------------------------------------

  @impl true
  def handle_event("as_of", %{"as_of" => value}, socket) do
    case parse_date(value) do
      nil ->
        {:noreply, socket}

      date ->
        {:noreply,
         socket
         |> assign(as_of: date, statement: nil, statement_error: nil)
         |> load()}
    end
  end

  def handle_event("statement", %{"customer_id" => raw}, socket) do
    %{samen_mount: mount, org_id: org_id, as_of: as_of} = socket.assigns
    customer_id = String.trim(raw || "")

    cond do
      customer_id == "" ->
        {:noreply,
         assign(socket,
           statement: nil,
           selected_customer: nil,
           statement_error: "Choose a customer."
         )}

      org_id == nil ->
        {:noreply, assign(socket, statement: nil, statement_error: "No workspace selected.")}

      true ->
        {:noreply, read_statement(socket, mount, org_id, customer_id, as_of)}
    end
  end

  defp read_statement(socket, mount, org_id, customer_id, as_of) do
    invoice = Erp.billing_invoice(mount)
    receipt = Erp.payment_receipt(mount)
    scope = TenantRole.authenticated_scope(mount, org_id)

    case ArAging.statement_for_customer(
           invoice: invoice,
           receipt: receipt,
           receipt_allocation: Erp.receipt_allocation(mount),
           credit_note: Erp.credit_note(mount),
           org_id: org_id,
           scope: scope,
           customer_id: customer_id,
           as_of: as_of
         ) do
      {:ok, statement} ->
        assign(socket,
          statement: statement,
          selected_customer: customer_id,
          statement_error: nil
        )

      {:error, _reason} ->
        assign(socket,
          statement: nil,
          selected_customer: customer_id,
          statement_error: "The statement could not be read. Try again."
        )
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp parse_date(%Date{} = date), do: date

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _other -> nil
    end
  end

  defp parse_date(_value), do: nil

  defp short(nil), do: "—"
  defp short(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short(other), do: to_string(other)

  defp date_text(nil), do: "—"
  defp date_text(%Date{} = date), do: Date.to_iso8601(date)
  defp date_text(other), do: to_string(other)

  defp days_text(nil), do: "—"
  defp days_text(0), do: "not due"
  defp days_text(days), do: "#{days}d"

  defp bucket_text(bucket) do
    case List.keyfind(Erp.aging_buckets(), bucket, 0) do
      {_key, label} -> label
      nil -> to_string(bucket)
    end
  end

  defp money(nil), do: "—"

  defp money(cents) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    cents = abs(cents)

    "#{sign}$#{div(cents, 100)}.#{cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp money(other), do: to_string(other)

  defp crumbs(mount, org_id) do
    [Crumbs.org(mount, org_id), "ERP", Erp.ar_aging_label()]
  end

  @impl Samen.Web.Tenant.Live
  def tenant_sidebar(assigns) do
    ~H"""
    <.erp_sidebar
      mount={@samen_mount}
      org_id={@org_id}
      active={:erp_ar_aging}
      return_to={@return_to}
    />
    """
  end

  @impl Samen.Web.Tenant.Live
  def tenant_page(assigns) do
    ~H"""
    <div id="erp-ar-aging">
    <.topbar
      title={Erp.ar_aging_label()}
      crumbs={crumbs(@samen_mount, @org_id)}
    >
      <:actions>
        <form id="as-of-form" phx-submit="as_of" style="display:flex;gap:6px;align-items:center">
          <label for="as-of-date" style="font-size:12px;color:var(--muted)">As of</label>
          <input
            type="date"
            id="as-of-date"
            name="as_of"
            value={Date.to_iso8601(@as_of)}
            style="font-size:12px;padding:5px 7px"
          />
          <.button type="submit" id="apply-as-of">Apply</.button>
        </form>
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
              AR aging needs this workspace's mounted Billing invoices and Finance
              payment receipts.
            <% end %>
          </div>
        <% else %>
          <div class="gtitle">
            <h3>{Erp.ar_aging_label()}</h3>
            <span class="n">{length(@aging.invoices)}</span>
            <span class="lane">· posted cash only · as of {Date.to_iso8601(@as_of)}</span>
          </div>

          <div
            :for={{currency, group} <- @aging.by_currency}
            id={"aging-currency-#{currency}"}
            style="margin-bottom:12px"
          >
            <div style="font-size:12px;font-weight:700;margin-bottom:6px">{currency}</div>
            <div style="display:flex;gap:10px;flex-wrap:wrap">
              <div
                :for={{key, label} <- Erp.aging_buckets()}
                class="card"
                style="padding:12px 16px;min-width:132px"
              >
                <div style="font-size:11px;color:var(--muted)">{label}</div>
                <div
                  id={bucket_dom_id(@aging.currencies, currency, key)}
                  style="font-size:16px;font-weight:700;margin-top:2px"
                >
                  {money(Map.get(group.buckets, key, 0))}
                </div>
              </div>
            </div>
          </div>

          <div
            :if={@aging.currencies == []}
            class="card"
            style="padding:12px 16px;margin-bottom:12px"
          >
            <span style="font-size:13px">
              <b>Outstanding:</b> <span id="aging-total">{money(0)}</span>
            </span>
          </div>

          <div
            class="card"
            style="padding:10px 16px;margin-bottom:12px;display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap"
          >
            <span :for={{currency, group} <- @aging.by_currency} style="font-size:13px">
              <b>{currency} outstanding:</b>
              <span id={total_dom_id(@aging.currencies, currency)}>
                {money(group.total_cents)}
              </span>
            </span>
            <span style="font-size:12px;color:var(--muted)">
              open invoices only · zero-balance invoices are omitted
            </span>
          </div>

          <div
            :for={{currency, cents} <- @aging.unapplied_by_currency}
            id={"aging-unapplied-#{currency}"}
            class="card"
            style="padding:10px 16px;margin-bottom:12px;font-size:13px"
          >
            <b>Unapplied cash ({currency}):</b> {money(cents)}
          </div>

          <table style="width:100%;border-collapse:collapse;font-size:13px">
            <thead>
              <tr>
                <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Invoice</th>
                <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Customer</th>
                <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Due</th>
                <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Overdue</th>
                <th scope="col" style="text-align:right;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Outstanding</th>
                <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Bucket</th>
                <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Receipt</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @aging.invoices} id={"aging-row-#{row.invoice_id}"}>
                <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                  {short(row.invoice_id)}
                </td>
                <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                  {short(row.customer_id)}
                </td>
                <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                  {date_text(row.due_date)}
                </td>
                <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                  {days_text(row.days_overdue)}
                </td>
                <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6);text-align:right">
                  {money(row.outstanding_cents)}
                </td>
                <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                  {bucket_text(row.bucket)}
                </td>
                <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                  <a
                    id={"record-receipt-#{row.invoice_id}"}
                    href={"#{Samen.Web.Mount.label(@samen_mount, :erp_path, "/erp")}/ar-receipts?org=#{@org_id}&customer_id=#{row.customer_id}&invoice_id=#{row.invoice_id}&as_of=#{Date.to_iso8601(@as_of)}"}
                    style="font-size:12px"
                  >
                    Record receipt
                  </a>
                </td>
              </tr>

              <tr :if={@aging.invoices == []}>
                <td colspan="7" style="padding:16px 8px;color:var(--muted)">
                  Nothing outstanding as of {Date.to_iso8601(@as_of)}.
                </td>
              </tr>
            </tbody>
          </table>

          <div class="card" style="padding:14px 16px;margin-top:14px" id="statement-panel">
            <div style="font-size:13px;font-weight:700;margin-bottom:8px">Customer statement</div>

            <form
              id="statement-form"
              phx-submit="statement"
              style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-bottom:10px"
            >
              <select
                name="customer_id"
                id="statement-customer"
                style="font-size:12px;padding:6px 8px;min-width:200px"
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
              <.button type="submit" id="open-statement">Open statement</.button>
            </form>

            <div
              :if={@statement_error}
              id="statement-error"
              style="font-size:12px;color:var(--bad, #b91c1c)"
            >
              {@statement_error}
            </div>

            <div :if={@statement} id="customer-statement">
              <div
                style="font-size:13px;margin-bottom:6px;display:flex;justify-content:space-between;gap:10px;flex-wrap:wrap;align-items:center"
              >
                <span>
                  <b>{short(@statement.customer_id)}</b>
                  <span style="color:var(--muted)">
                    · as of {Date.to_iso8601(@statement.as_of)}
                  </span>
                </span>
                <a
                  id="record-receipt-link"
                  href={"#{Samen.Web.Mount.label(@samen_mount, :erp_path, "/erp")}/ar-receipts?org=#{@org_id}&customer_id=#{@statement.customer_id}&as_of=#{Date.to_iso8601(@as_of)}"}
                  style="font-size:13px"
                >
                  Record receipt
                </a>
              </div>

              <div
                :for={{currency, totals} <- @statement.by_currency}
                style="display:flex;gap:16px;flex-wrap:wrap;font-size:12px;margin-bottom:8px"
              >
                <span><b>{currency}</b></span>
                <span>Invoiced <b id={statement_total_id(@statement.currencies, currency, "invoiced")}>{money(totals.invoiced_cents)}</b></span>
                <span>Paid <b id={statement_total_id(@statement.currencies, currency, "paid")}>{money(totals.paid_cents)}</b></span>
                <span>Outstanding <b id={statement_total_id(@statement.currencies, currency, "outstanding")}>{money(totals.outstanding_cents)}</b></span>
                <span>Unapplied <b id={statement_total_id(@statement.currencies, currency, "unapplied")}>{money(totals.unapplied_cents)}</b></span>
              </div>

              <table style="width:100%;border-collapse:collapse;font-size:12px">
                <thead>
                  <tr>
                    <th scope="col" style="text-align:left;padding:5px 7px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Invoice</th>
                    <th scope="col" style="text-align:left;padding:5px 7px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Dated</th>
                    <th scope="col" style="text-align:left;padding:5px 7px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Due</th>
                    <th scope="col" style="text-align:right;padding:5px 7px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Amount</th>
                    <th scope="col" style="text-align:right;padding:5px 7px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Paid</th>
                    <th scope="col" style="text-align:right;padding:5px 7px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Outstanding</th>
                    <th scope="col" style="text-align:left;padding:5px 7px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Receipt</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={row <- @statement.invoices}>
                    <td style="padding:5px 7px;border-bottom:1px solid var(--border, #f3f4f6)">{short(row.invoice_id)}</td>
                    <td style="padding:5px 7px;border-bottom:1px solid var(--border, #f3f4f6)">{date_text(row.invoice_date)}</td>
                    <td style="padding:5px 7px;border-bottom:1px solid var(--border, #f3f4f6)">{date_text(row.due_date)}</td>
                    <td style="padding:5px 7px;border-bottom:1px solid var(--border, #f3f4f6);text-align:right">{money(row.amount_cents)}</td>
                    <td style="padding:5px 7px;border-bottom:1px solid var(--border, #f3f4f6);text-align:right">{money(row.paid_cents)}</td>
                    <td style="padding:5px 7px;border-bottom:1px solid var(--border, #f3f4f6);text-align:right">{money(row.outstanding_cents)}</td>
                    <td style="padding:5px 7px;border-bottom:1px solid var(--border, #f3f4f6)">
                      <a
                        :if={row.outstanding_cents > 0}
                        id={"statement-record-receipt-#{row.invoice_id}"}
                        href={"#{Samen.Web.Mount.label(@samen_mount, :erp_path, "/erp")}/ar-receipts?org=#{@org_id}&customer_id=#{@statement.customer_id}&invoice_id=#{row.invoice_id}&as_of=#{Date.to_iso8601(@as_of)}"}
                        style="font-size:12px"
                      >
                        Record receipt
                      </a>
                    </td>
                  </tr>
                </tbody>
              </table>

              <div :if={@statement.receipts != []} style="margin-top:10px">
                <div style="font-size:12px;font-weight:700;margin-bottom:4px">Posted receipts</div>
                <table style="width:100%;border-collapse:collapse;font-size:12px">
                  <thead>
                    <tr>
                      <th scope="col" style="text-align:left;padding:5px 7px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Received</th>
                      <th scope="col" style="text-align:left;padding:5px 7px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Invoice</th>
                      <th scope="col" style="text-align:right;padding:5px 7px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Amount</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={receipt <- @statement.receipts}>
                      <td style="padding:5px 7px;border-bottom:1px solid var(--border, #f3f4f6)">{date_text(date_of(receipt.paid_at))}</td>
                      <td style="padding:5px 7px;border-bottom:1px solid var(--border, #f3f4f6)">{short(receipt.invoice_id)}</td>
                      <td style="padding:5px 7px;border-bottom:1px solid var(--border, #f3f4f6);text-align:right">{money(receipt.amount_cents)}</td>
                    </tr>
                  </tbody>
                </table>
              </div>
            </div>
          </div>
        <% end %>
      <% end %>
    </div>
    </div>
    """
  end

  defp bucket_dom_id([_single], _currency, key), do: "aging-bucket-#{key}"
  defp bucket_dom_id(_currencies, currency, key), do: "aging-bucket-#{currency}-#{key}"

  defp total_dom_id([_single], _currency), do: "aging-total"
  defp total_dom_id(_currencies, currency), do: "aging-total-#{currency}"

  defp statement_total_id([_single], _currency, field), do: "statement-#{field}"

  defp statement_total_id(_currencies, currency, field),
    do: "statement-#{field}-#{currency}"

  defp date_of(nil), do: nil
  defp date_of(%DateTime{} = datetime), do: DateTime.to_date(datetime)
  defp date_of(%NaiveDateTime{} = datetime), do: NaiveDateTime.to_date(datetime)
  defp date_of(%Date{} = date), do: date
end
