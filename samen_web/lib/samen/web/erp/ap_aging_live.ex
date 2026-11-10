defmodule Samen.Web.Erp.ApAgingLive do
  @moduledoc """
  The AP aging and vendor statements page (`<erp>/ap-aging`).

  One read answers both questions the AP desk asks:

    * **aging** — `Samen.Scopes.Finance.ApAging.for_org/1` over the host's
      approved AP bills, bucketed `current / 1–30 / 31–60 / 61–90 / 90+ /
      undated`. Draft and void bills were never a liability; paid bills are
      settled by a dual-controlled run and do not age;
    * **statement** — `statement_for_vendor/1` for one vendor: every open and
      paid bill, the effective payment runs that settled them, and the totals.
      A paid run whose reversal completed is excluded, because the restored
      bill is still a liability.

  The read is the SAME kernel projection the API uses — the page renders only
  what `ApAging` computed, so the pixel and the export cannot diverge. No
  write affordance exists on this page. `org_id` is the server-side fact and
  the scope is the mount plane's, so an operator-plane mount reads masked and
  every caller is pinned to its own org.
  """

  use Samen.Web.Tenant.Live

  import Samen.UI
  import Samen.Web.Erp.Live, only: [assign_mount: 2, erp_sidebar: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Scopes.Finance.ApAging
  alias Samen.Web.Crumbs
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Erp
  alias Samen.Web.Mount
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
       vendors: [],
       selected_vendor: nil,
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
    |> assign_new(:vendors, fn -> [] end)
    |> assign_new(:selected_vendor, fn -> nil end)
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
      vendors: [],
      statement: nil
    )
  end

  defp do_load(socket) do
    %{samen_mount: mount, org_id: org_id, as_of: as_of} = socket.assigns

    with ap_invoice when not is_nil(ap_invoice) <- Erp.ap_invoice(mount) do
      scope = TenantRole.authenticated_scope(mount, org_id)

      case ApAging.for_org(
             ap_invoice: ap_invoice,
             org_id: org_id,
             scope: scope,
             as_of: as_of
           ) do
        {:ok, aging} ->
          assign(socket,
            aging: aging,
            vendors: aging.vendor_ids,
            missing: nil
          )

        {:error, _reason} ->
          assign(socket, aging: nil, vendors: [], missing: :unreadable)
      end
    else
      _not_mounted ->
        assign(socket, aging: nil, vendors: [], missing: :unmounted)
    end
  end

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

  def handle_event("statement", %{"vendor_id" => raw}, socket) do
    %{samen_mount: mount, org_id: org_id, as_of: as_of} = socket.assigns
    vendor_id = String.trim(raw || "")

    cond do
      vendor_id == "" ->
        {:noreply,
         assign(socket,
           statement: nil,
           selected_vendor: nil,
           statement_error: "Choose a vendor."
         )}

      org_id == nil ->
        {:noreply, assign(socket, statement: nil, statement_error: "No workspace selected.")}

      true ->
        {:noreply, read_statement(socket, mount, org_id, vendor_id, as_of)}
    end
  end

  defp read_statement(socket, mount, org_id, vendor_id, as_of) do
    ap_invoice = Erp.ap_invoice(mount)
    scope = TenantRole.authenticated_scope(mount, org_id)

    case ApAging.statement_for_vendor(
           ap_invoice: ap_invoice,
           repo: mount.repo,
           org_id: org_id,
           scope: scope,
           vendor_id: vendor_id,
           as_of: as_of
         ) do
      {:ok, statement} ->
        assign(socket,
          statement: statement,
          selected_vendor: vendor_id,
          statement_error: nil
        )

      {:error, _reason} ->
        assign(socket,
          statement: nil,
          selected_vendor: vendor_id,
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

  defp status_text(nil), do: "—"
  defp status_text(status) when is_atom(status), do: status |> to_string() |> String.capitalize()
  defp status_text(status), do: to_string(status)

  defp money(nil), do: "—"

  defp money(cents) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    cents = abs(cents)

    "#{sign}$#{div(cents, 100)}.#{cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp money(other), do: to_string(other)

  defp vendor_label(statement) do
    statement.vendor_name || short(statement.vendor_id)
  end

  defp crumbs(mount, org_id) do
    [Crumbs.org(mount, org_id), "ERP", Erp.ap_aging_label()]
  end

  @impl Samen.Web.Tenant.Live
  def tenant_sidebar(assigns) do
    ~H"""
    <.erp_sidebar
      mount={@samen_mount}
      org_id={@org_id}
      active={:erp_ap_aging}
      return_to={@return_to}
    />
    """
  end

  @impl Samen.Web.Tenant.Live
  def tenant_page(assigns) do
    ~H"""
    <div id="erp-ap-aging">
    <.topbar
      title={Erp.ap_aging_label()}
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
              The AP documents could not be read. Try again.
            <% else %>
              AP aging needs this workspace's mounted Finance AP invoices.
            <% end %>
          </div>
        <% else %>
          <div class="gtitle">
            <h3>{Erp.ap_aging_label()}</h3>
            <span class="n">{length(@aging.bills)}</span>
            <span class="lane">· approved bills only · as of {Date.to_iso8601(@as_of)}</span>
          </div>

          <div style="display:flex;gap:10px;flex-wrap:wrap;margin-bottom:12px">
            <div
              :for={{key, label} <- Erp.aging_buckets()}
              class="card"
              style="padding:12px 16px;min-width:132px"
            >
              <div style="font-size:11px;color:var(--muted)">{label}</div>
              <div
                id={"aging-bucket-#{key}"}
                style="font-size:16px;font-weight:700;margin-top:2px"
              >
                {money(Map.get(@aging.buckets, key, 0))}
              </div>
            </div>
          </div>

          <div
            class="card"
            style="padding:10px 16px;margin-bottom:12px;display:flex;justify-content:space-between;gap:12px;flex-wrap:wrap"
          >
            <span style="font-size:13px">
              <b>Outstanding:</b>
              <span id="aging-total">{money(@aging.total_cents)}</span>
            </span>
            <span style="font-size:12px;color:var(--muted)">
              approved bills only · paid bills are settled by a dual-controlled run
            </span>
          </div>

          <table style="width:100%;border-collapse:collapse;font-size:13px">
            <thead>
              <tr>
                <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Bill</th>
                <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Vendor</th>
                <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Due</th>
                <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Overdue</th>
                <th scope="col" style="text-align:right;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Outstanding</th>
                <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Bucket</th>
                <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Bill</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @aging.bills} id={"aging-row-#{row.bill_id}"}>
                <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                  {row.number || short(row.bill_id)}
                </td>
                <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                  {short(row.vendor_id)}
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
                    id={"view-bill-#{row.bill_id}"}
                    href={"#{Mount.label(@samen_mount, :erp_path, "/erp")}/ap_invoices/#{row.bill_id}?org=#{@org_id}"}
                    style="font-size:12px"
                  >
                    View bill
                  </a>
                </td>
              </tr>

              <tr :if={@aging.bills == []}>
                <td colspan="7" style="padding:16px 8px;color:var(--muted)">
                  Nothing outstanding as of {Date.to_iso8601(@as_of)}.
                </td>
              </tr>
            </tbody>
          </table>

          <div class="card" style="padding:14px 16px;margin-top:14px" id="vendor-statement-panel">
            <div style="font-size:13px;font-weight:700;margin-bottom:8px">Vendor statement</div>

            <form
              id="vendor-statement-form"
              phx-submit="statement"
              style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-bottom:10px"
            >
              <select
                name="vendor_id"
                id="statement-vendor"
                style="font-size:12px;padding:6px 8px;min-width:200px"
              >
                <option value="">Choose a vendor…</option>
                <option
                  :for={vendor_id <- @vendors}
                  value={vendor_id}
                  selected={vendor_id == @selected_vendor}
                >
                  {short(vendor_id)}
                </option>
              </select>
              <.button type="submit" id="open-vendor-statement">Open statement</.button>
            </form>

            <div
              :if={@statement_error}
              id="statement-error"
              style="font-size:12px;color:var(--bad, #b91c1c)"
            >
              {@statement_error}
            </div>

            <div :if={@statement} id="vendor-statement">
              <div
                style="font-size:13px;margin-bottom:6px;display:flex;justify-content:space-between;gap:10px;flex-wrap:wrap;align-items:center"
              >
                <span>
                  <b>{vendor_label(@statement)}</b>
                  <span style="color:var(--muted)">
                    · as of {Date.to_iso8601(@statement.as_of)}
                  </span>
                </span>
              </div>

              <div style="display:flex;gap:16px;flex-wrap:wrap;font-size:12px;margin-bottom:8px">
                <span>Billed <b id="statement-billed">{money(@statement.totals.billed_cents)}</b></span>
                <span>Paid <b id="statement-paid">{money(@statement.totals.paid_cents)}</b></span>
                <span>Outstanding <b id="statement-outstanding">{money(@statement.totals.outstanding_cents)}</b></span>
              </div>

              <table style="width:100%;border-collapse:collapse;font-size:12px">
                <thead>
                  <tr>
                    <th scope="col" style="text-align:left;padding:5px 7px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Bill</th>
                    <th scope="col" style="text-align:left;padding:5px 7px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Dated</th>
                    <th scope="col" style="text-align:left;padding:5px 7px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Due</th>
                    <th scope="col" style="text-align:right;padding:5px 7px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Amount</th>
                    <th scope="col" style="text-align:right;padding:5px 7px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Paid</th>
                    <th scope="col" style="text-align:right;padding:5px 7px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Outstanding</th>
                    <th scope="col" style="text-align:left;padding:5px 7px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Status</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={row <- @statement.bills} id={"statement-bill-#{row.bill_id}"}>
                    <td style="padding:5px 7px;border-bottom:1px solid var(--border, #f3f4f6)">{row.number || short(row.bill_id)}</td>
                    <td style="padding:5px 7px;border-bottom:1px solid var(--border, #f3f4f6)">{date_text(row.bill_date)}</td>
                    <td style="padding:5px 7px;border-bottom:1px solid var(--border, #f3f4f6)">{date_text(row.due_date)}</td>
                    <td style="padding:5px 7px;border-bottom:1px solid var(--border, #f3f4f6);text-align:right">{money(row.amount_cents)}</td>
                    <td style="padding:5px 7px;border-bottom:1px solid var(--border, #f3f4f6);text-align:right">{money(row.paid_cents)}</td>
                    <td style="padding:5px 7px;border-bottom:1px solid var(--border, #f3f4f6);text-align:right">{money(row.outstanding_cents)}</td>
                    <td style="padding:5px 7px;border-bottom:1px solid var(--border, #f3f4f6)">{status_text(row.status)}</td>
                  </tr>
                </tbody>
              </table>

              <div :if={@statement.payments != []} style="margin-top:10px">
                <div style="font-size:12px;font-weight:700;margin-bottom:4px">Effective payments</div>
                <table style="width:100%;border-collapse:collapse;font-size:12px">
                  <thead>
                    <tr>
                      <th scope="col" style="text-align:left;padding:5px 7px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Paid</th>
                      <th scope="col" style="text-align:left;padding:5px 7px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Reference</th>
                      <th scope="col" style="text-align:left;padding:5px 7px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Bill</th>
                      <th scope="col" style="text-align:right;padding:5px 7px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Amount</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={payment <- @statement.payments} id={"statement-payment-#{payment.run_id}-#{payment.bill_id}"}>
                      <td style="padding:5px 7px;border-bottom:1px solid var(--border, #f3f4f6)">{date_text(payment.payment_date)}</td>
                      <td style="padding:5px 7px;border-bottom:1px solid var(--border, #f3f4f6)">{payment.reference || "—"}</td>
                      <td style="padding:5px 7px;border-bottom:1px solid var(--border, #f3f4f6)">{payment.bill_number || short(payment.bill_id)}</td>
                      <td style="padding:5px 7px;border-bottom:1px solid var(--border, #f3f4f6);text-align:right">{money(payment.amount_cents)}</td>
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
end
