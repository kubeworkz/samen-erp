defmodule Samen.Web.Erp.ApPaymentRunPrintLive do
  @moduledoc """
  The printable remittance advice for a PAID AP payment run
  (`<erp>/ap-payments/:id/remittance`).

  This is a STANDALONE DOCUMENT, not a shell page: the router mounts it in a
  layout-less `live_session`, and `render/1` owns the whole `<html>` document so
  the browser's print output contains no sidebar, navigation or actions. The
  route still rides the tenant `:require_tenant` gate and reads the run through
  `ApPaymentRun.get_run/3`, org-pinned like the audit page.

  Only a `:paid` run produces advice. A pending, rejected or cancelled run
  renders an honest unavailable state, and a run from another org is
  indistinguishable from a missing one.
  """

  use Phoenix.LiveView

  import Samen.Web.Erp.Live, only: [assign_mount: 2]

  alias Samen.Scopes.Finance.ApPaymentRun
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)

    {:ok,
     socket
     |> assign(org_id: org_id, run_id: params["id"], run: nil, missing: nil, vendors: [])
     |> load()}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    org_id = CurrentOrg.reresolve(socket, params)

    {:noreply,
     socket
     |> assign(org_id: org_id, run_id: params["id"])
     |> load()}
  end

  @doc false
  def load(socket) do
    socket
    |> assign_new(:run_id, fn -> nil end)
    |> assign_new(:run, fn -> nil end)
    |> assign_new(:missing, fn -> nil end)
    |> assign_new(:vendors, fn -> [] end)
    |> do_load()
  end

  defp do_load(%{assigns: %{org_id: nil}} = socket),
    do: assign(socket, run: nil, missing: :no_org, vendors: [])

  defp do_load(
         %{assigns: %{samen_mount: %Mount{} = mount, org_id: org_id, run_id: run_id}} = socket
       )
       when is_binary(run_id) do
    case ApPaymentRun.get_run(mount.repo, org_id, run_id) do
      {:ok, run} -> assign(socket, run: run, missing: nil, vendors: vendor_groups(run))
      {:error, :not_found} -> assign(socket, run: nil, missing: :not_found, vendors: [])
    end
  end

  defp do_load(socket), do: assign(socket, run: nil, missing: :not_found, vendors: [])

  @impl true
  def render(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang="en">
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <title>{document_title(@run)}</title>
        <style>
          :root { color-scheme: light; }
          * { box-sizing: border-box; }
          body {
            margin: 0;
            background: #eef2f7;
            color: #111827;
            font: 14px/1.5 Arial, Helvetica, sans-serif;
            -webkit-print-color-adjust: exact;
            print-color-adjust: exact;
          }
          a { color: #065f46; }
          .screen-actions {
            max-width: 840px;
            margin: 0 auto;
            padding: 18px 20px;
            display: flex;
            justify-content: space-between;
            align-items: center;
            gap: 16px;
          }
          .screen-actions a { font-size: 13px; text-decoration: none; }
          .screen-actions button {
            font: inherit;
            font-size: 13px;
            font-weight: 700;
            padding: 8px 14px;
            color: #fff;
            background: #065f46;
            border: 0;
            border-radius: 6px;
            cursor: pointer;
          }
          .sheet {
            max-width: 840px;
            margin: 0 auto 40px;
            padding: 48px 56px;
            background: #fff;
            border: 1px solid #d1d5db;
            box-shadow: 0 1px 4px rgba(17, 24, 39, .12);
          }
          .doc-header {
            display: flex;
            justify-content: space-between;
            align-items: flex-start;
            gap: 28px;
          }
          .eyebrow {
            margin-bottom: 4px;
            font-size: 11px;
            font-weight: 700;
            letter-spacing: .12em;
            text-transform: uppercase;
            color: #065f46;
          }
          h1 {
            margin: 0;
            font-size: 25px;
            line-height: 1.2;
            letter-spacing: -.02em;
          }
          h1 + p { margin: 6px 0 0; }
          .reference { text-align: right; min-width: 180px; }
          .reference .value {
            margin-top: 3px;
            font-family: ui-monospace, SFMono-Regular, Consolas, monospace;
            font-size: 16px;
            font-weight: 700;
            white-space: nowrap;
          }
          .label {
            font-size: 10px;
            font-weight: 700;
            letter-spacing: .08em;
            text-transform: uppercase;
            color: #6b7280;
          }
          .muted { color: #6b7280; }
          .mono { font-family: ui-monospace, SFMono-Regular, Consolas, monospace; }
          .rule { margin: 24px 0; border-top: 2px solid #111827; }
          .meta {
            display: grid;
            grid-template-columns: repeat(4, minmax(0, 1fr));
            gap: 16px;
            margin-bottom: 24px;
          }
          .meta .value { margin-top: 3px; font-size: 13px; font-weight: 600; }
          .payee {
            margin-bottom: 24px;
            padding: 16px 18px;
            border: 1px solid #d1d5db;
            border-radius: 6px;
          }
          .payee-name { margin: 4px 0 2px; font-size: 14px; font-weight: 700; overflow-wrap: anywhere; }
          .payee-address { margin: 0 0 4px; font-size: 12px; overflow-wrap: anywhere; }
          .memo { margin-top: 10px; font-size: 12px; }
          .memo .label { display: inline; margin-right: 6px; }
          table { width: 100%; border-collapse: collapse; }
          th {
            padding: 8px 10px;
            border-bottom: 1px solid #9ca3af;
            font-size: 10px;
            letter-spacing: .08em;
            text-transform: uppercase;
            color: #6b7280;
            text-align: left;
          }
          td { padding: 9px 10px; border-bottom: 1px solid #e5e7eb; vertical-align: top; }
          .right { text-align: right; }
          .total-label { font-weight: 700; }
          .total { font-size: 17px; font-weight: 700; }
          .doc-footer {
            margin-top: 26px;
            padding-top: 12px;
            border-top: 1px solid #d1d5db;
            font-size: 11px;
            color: #6b7280;
          }
          .doc-footer p { margin: 0 0 4px; }
          .error-sheet { max-width: 620px; }
          .error-sheet h1 { font-size: 21px; }
          .error-sheet a { display: inline-block; margin-top: 10px; font-size: 13px; }

          @media print {
            @page { margin: 14mm; }
            body { background: #fff; font-size: 11pt; }
            .screen-actions { display: none !important; }
            .sheet {
              max-width: none;
              margin: 0;
              padding: 0;
              border: 0;
              box-shadow: none;
            }
            a { color: inherit; text-decoration: none; }
            .avoid-break { break-inside: avoid; }
          }
        </style>
      </head>
      <body>
        <div :if={@run && @run.status == :paid} class="screen-actions">
          <a href={detail_href(@samen_mount, @org_id, @run_id)}>← Back to audit record</a>
          <button type="button" id="print-remittance" onclick="window.print()">
            Print remittance advice
          </button>
        </div>

        <%= if @missing == :no_org do %>
          <main class="sheet error-sheet" id="remittance-unavailable">
            <h1>Remittance advice unavailable</h1>
            <p>No workspace is selected.</p>
            <a href={detail_href(@samen_mount, @org_id, @run_id)}>Back to AP payments</a>
          </main>
        <% else %>
          <%= if @missing == :not_found do %>
            <main class="sheet error-sheet" id="remittance-unavailable">
              <h1>Remittance advice unavailable</h1>
              <p>Payment run not found in this workspace.</p>
              <a href={detail_href(@samen_mount, @org_id, @run_id)}>Back to AP payments</a>
            </main>
          <% else %>
            <%= if @run.status == :paid do %>
              <main class="sheet" id="remittance-advice">
                <header class="doc-header">
                  <div>
                    <div class="eyebrow">Remittance advice</div>
                    <h1>{org_name(@samen_mount, @org_id)}</h1>
                    <p class="muted">Payment confirmation for the bills listed below.</p>
                  </div>
                  <div class="reference">
                    <div class="label">Reference</div>
                    <div class="value">{@run.reference}</div>
                  </div>
                </header>

                <div class="rule"></div>

                <section class="meta">
                  <div>
                    <div class="label">Payment date</div>
                    <div class="value">{date_text(@run.payment_date)}</div>
                  </div>
                  <div>
                    <div class="label">Status</div>
                    <div class="value">Paid</div>
                  </div>
                  <div>
                    <div class="label">Bills paid</div>
                    <div class="value">{@run.bill_count}</div>
                  </div>
                  <div>
                    <div class="label">
                      {if length(@vendors) == 1, do: "Vendor account", else: "Vendors"}
                    </div>
                    <div class="value mono">{vendor_meta(@vendors)}</div>
                  </div>
                </section>

                <section
                  :for={vendor <- @vendors}
                  class="payee"
                  id={"remittance-vendor-#{vendor.vendor_id}"}
                >
                  <div class="label">Paid to</div>
                  <div class={"payee-name" <> if(vendor.vendor_name, do: "", else: " mono")}>
                    {vendor.vendor_name || vendor.vendor_id || "—"}
                  </div>
                  <div :if={vendor.remittance_address} class="payee-address">
                    <div :for={line <- address_lines(vendor.remittance_address)}>{line}</div>
                  </div>
                  <div class="muted">Vendor account {vendor.vendor_id || "—"}</div>

                  <table style="margin-top:14px">
                    <thead>
                      <tr>
                        <th scope="col">Bill</th>
                        <th scope="col">Due date</th>
                        <th scope="col" class="right">Amount</th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={payment <- vendor.payments} class="avoid-break">
                        <td>{field(payment, :number) || "—"}</td>
                        <td>{date_text(field(payment, :due_date))}</td>
                        <td class="right">{money(field(payment, :amount_cents))}</td>
                      </tr>
                      <tr :if={vendor.payments == []}>
                        <td colspan="3" class="muted">No bills are recorded for this vendor.</td>
                      </tr>
                    </tbody>
                    <tfoot>
                      <tr>
                        <td colspan="2" class="right total-label">
                          {if length(@vendors) == 1, do: "Total paid", else: "Vendor total"}
                        </td>
                        <td class="right total">{money(vendor.total_cents)}</td>
                      </tr>
                    </tfoot>
                  </table>
                </section>

                <p :if={@vendors == []} class="muted">
                  No bills are recorded on this run.
                </p>

                <div :if={@run.memo} class="memo" style="margin-bottom:18px">
                  <span class="label">Memo</span>{@run.memo}
                </div>

                <div
                  :if={length(@vendors) > 1}
                  style="display:flex;justify-content:space-between;align-items:center;margin-top:14px;padding-top:12px;border-top:2px solid #111827"
                >
                  <span class="total-label">Total paid</span>
                  <span class="total">{money(@run.total_cents)}</span>
                </div>

                <footer class="doc-footer">
                  <p>
                    This remittance advice reflects the approved payment run stored in the
                    workspace. Payment reference <strong>{@run.reference}</strong>.
                  </p>
                  <p class="mono">Run ID {@run.id}</p>
                </footer>
              </main>
            <% else %>
              <main class="sheet error-sheet" id="remittance-unavailable">
                <h1>Remittance advice unavailable</h1>
                <p>
                  This run has not been paid. Remittance advice is available only after
                  approval and payment.
                </p>
                <a href={detail_href(@samen_mount, @org_id, @run_id)}>Back to the payment run</a>
              </main>
            <% end %>
          <% end %>
        <% end %>
      </body>
    </html>
    """
  end

  defp address_lines(address) do
    address
    |> String.split(~r/\r?\n/)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp vendor_meta([vendor]), do: vendor.vendor_id || "—"
  defp vendor_meta(vendors), do: "#{length(vendors)} vendors"

  defp vendor_groups(run) do
    vendor_ids = ApPaymentRun.vendor_ids(run)
    grouped = Enum.group_by(run.payments, &payment_vendor_id(&1, run))
    single? = length(vendor_ids) == 1

    Enum.map(vendor_ids, fn vendor_id ->
      payments = Map.get(grouped, vendor_id, [])

      %{
        vendor_id: vendor_id,
        payments: payments,
        total_cents: Enum.sum(Enum.map(payments, &payment_amount/1)),
        vendor_name: if(single?, do: run.vendor_name),
        remittance_address: if(single?, do: run.remittance_address)
      }
    end)
  end

  defp payment_vendor_id(payment, run), do: field(payment, :vendor_id) || run.vendor_id
  defp payment_amount(payment), do: field(payment, :amount_cents) || 0

  defp document_title(%{reference: reference}) when is_binary(reference),
    do: "Remittance advice — #{reference}"

  defp document_title(_run), do: "Remittance advice"

  defp org_name(mount, org_id), do: CurrentOrg.name(mount, org_id) || "Workspace"

  defp detail_href(mount, org_id, run_id) do
    path = Mount.label(mount, :erp_path, "/erp")
    query = if is_binary(org_id), do: "?org=#{org_id}", else: ""

    if is_binary(run_id) do
      "#{path}/ap-payments/#{run_id}#{query}"
    else
      "#{path}/ap-payments#{query}"
    end
  end

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

  defp field(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp field(_value, _key), do: nil
end
