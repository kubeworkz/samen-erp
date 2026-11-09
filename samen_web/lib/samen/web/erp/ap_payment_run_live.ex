defmodule Samen.Web.Erp.ApPaymentRunLive do
  @moduledoc """
  The AP payment run audit page (`<erp>/ap-payments/:id`) — one immutable
  `ApPaymentRunRecord` with its request-time bill snapshot and decision
  evidence.

  The page is a READ of the durable run row, org-pinned through
  `ApPaymentRun.get_run/3`; it never re-reads the live bills and never offers a
  write. It shows who requested the run, who approved/rejected/cancelled it and
  when, the snapshot lines that were reviewed, and the remittance CSV stored at
  approval. A run from another org is indistinguishable from a missing one.

  The record is the audit trail: the database trigger refuses a self-approval,
  a rewritten snapshot, a second decision and every DELETE, so this page is
  reading evidence rather than a process-memory summary.
  """

  use Samen.Web.Tenant.Live

  import Samen.UI
  import Samen.Web.Erp.Live, only: [assign_mount: 2, erp_sidebar: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Scopes.Finance.ApPaymentRun
  alias Samen.Web.Crumbs
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Erp
  alias Samen.Web.Mount

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)

    {:ok,
     socket
     |> assign(
       org_id: org_id,
       run_id: params["id"],
       run: nil,
       missing: nil,
       return_to: nil
     )
     |> load()}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = CurrentOrg.reresolve(socket, params)

    {:noreply,
     socket
     |> assign(org_id: org_id, run_id: params["id"], return_to: return_path(uri))
     |> load()}
  end

  @doc false
  def load(socket) do
    socket
    |> assign_new(:run_id, fn -> nil end)
    |> assign_new(:run, fn -> nil end)
    |> assign_new(:missing, fn -> nil end)
    |> do_load()
  end

  defp do_load(%{assigns: %{org_id: nil}} = socket),
    do: assign(socket, run: nil, missing: :no_org)

  defp do_load(
         %{assigns: %{samen_mount: %Mount{} = mount, org_id: org_id, run_id: run_id}} = socket
       )
       when is_binary(run_id) do
    case ApPaymentRun.get_run(mount.repo, org_id, run_id) do
      {:ok, run} -> assign(socket, run: run, missing: nil)
      {:error, :not_found} -> assign(socket, run: nil, missing: :not_found)
    end
  end

  defp do_load(socket), do: assign(socket, run: nil, missing: :not_found)

  @impl Samen.Web.Tenant.Live
  def tenant_sidebar(assigns) do
    ~H"""
    <.erp_sidebar
      mount={@samen_mount}
      org_id={@org_id}
      active={:erp_ap_payments}
      return_to={@return_to}
    />
    """
  end

  @impl Samen.Web.Tenant.Live
  def tenant_page(assigns) do
    ~H"""
    <div id="erp-ap-payment-run">
      <.topbar
        title={page_title(@run)}
        crumbs={crumbs(@samen_mount, @org_id, @run)}
      />

      <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

      <div class="wrap">
        <%= if @missing == :no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <%= if @missing == :not_found do %>
            <div class="card" id="ap-run-not-found" style="padding:16px">
              <div style="font-size:14px;font-weight:700;margin-bottom:4px">
                Payment run not found
              </div>
              <p style="margin:0 0 10px;font-size:13px;color:var(--muted)">
                This run does not exist in this workspace. It may belong to another organization.
              </p>
              <a href={ap_payments_href(@samen_mount, @org_id)} style="font-size:13px">
                Back to AP payments
              </a>
            </div>
          <% else %>
            <div class="gtitle">
              <h3>Payment run <code>{@run.reference}</code></h3>
              <span class="n">{@run.bill_count}</span>
              <span class="lane">· immutable audit record</span>
            </div>

            <div class="card" id="ap-run-summary" style="padding:16px;margin-bottom:10px">
              <div style="display:flex;justify-content:space-between;gap:12px;align-items:flex-start;margin-bottom:14px">
                <div>
                  <div style="font-size:11px;color:var(--muted);margin-bottom:4px">Status</div>
                  <span id="ap-run-status" style={status_style(@run.status)}>
                    {status_label(@run.status)}
                  </span>
                </div>
                <div style="text-align:right">
                  <div style="font-size:11px;color:var(--muted)">Run total</div>
                  <div style="font-size:20px;font-weight:750">{money(@run.total_cents)}</div>
                </div>
              </div>

              <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px">
                <.fact label="Payment date" value={date_text(@run.payment_date)} />
                <.fact label="Vendor name" value={@run.vendor_name || "—"} />
                <.fact label="Vendor id" value={@run.vendor_id || "—"} />
                <.fact label="Remittance address" value={@run.remittance_address || "—"} />
                <.fact label="Bills" value={to_string(@run.bill_count)} />
                <.fact label="Memo" value={@run.memo || "—"} />
                <.fact label="Run id" value={@run.id} />
                <.fact label="Recorded" value={stamp(@run.inserted_at)} />
              </div>
            </div>

            <div
              class="card"
              id="ap-run-approval-evidence"
              style="padding:16px;margin-bottom:10px"
            >
              <div style="font-size:13px;font-weight:700;margin-bottom:2px">Approval evidence</div>
              <p style="margin:0 0 12px;font-size:12px;color:var(--muted)">
                The request and decision are stored on the run row. The database trigger refuses
                a self-approval, a rewritten snapshot, a second decision and every delete.
              </p>

              <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px">
                <.fact label="Requested by" value={@run.requested_by || "—"} />
                <.fact label="Requested at" value={stamp(@run.requested_at)} />
                <.fact label={decision_label(@run.status)} value={decision_actor(@run)} />
                <.fact label={decision_at_label(@run.status)} value={decision_at(@run)} />
                <.fact
                  :if={@run.status == :paid}
                  label="Executed at"
                  value={stamp(@run.executed_at)}
                />
                <.fact
                  :if={@run.status == :paid}
                  label="Record updated"
                  value={stamp(@run.updated_at)}
                />
              </div>

              <div
                :if={@run.status == :pending_approval}
                id="ap-run-no-decision"
                style="margin-top:14px;padding:10px 12px;border:1px solid var(--border,#e5e7eb);border-radius:8px;font-size:12px;color:var(--muted)"
              >
                No decision is recorded. This run has paid nothing; a different admin must
                approve it before any cash moves.
                <a href={ap_payments_href(@samen_mount, @org_id)} style="margin-left:4px">
                  Review pending approvals
                </a>
              </div>

              <div
                :if={@run.status == :rejected}
                id="ap-run-rejected"
                style="margin-top:14px;padding:10px 12px;border:1px solid var(--border,#e5e7eb);border-radius:8px;font-size:12px;color:var(--muted)"
              >
                Rejected by <code>{@run.rejected_by || "—"}</code>.
                No cash moved.
              </div>

              <div
                :if={@run.status == :cancelled}
                id="ap-run-cancelled"
                style="margin-top:14px;padding:10px 12px;border:1px solid var(--border,#e5e7eb);border-radius:8px;font-size:12px;color:var(--muted)"
              >
                Cancelled by <code>{@run.cancelled_by || "—"}</code>.
                No cash moved.
              </div>

              <div
                :if={@run.status == :paid}
                id="ap-run-remittance"
                style="margin-top:14px;display:flex;gap:14px;align-items:center;flex-wrap:wrap"
              >
                <a
                  id="print-remittance"
                  href={remittance_href(@samen_mount, @org_id, @run.id)}
                  target="_blank"
                  rel="noopener"
                  style="font-size:13px"
                >
                  Print remittance advice
                </a>
                <a
                  :if={@run.remittance_csv}
                  id="download-run-remittance"
                  download={"remittance-#{@run.reference}.csv"}
                  href={"data:text/csv;base64," <> Base.encode64(@run.remittance_csv)}
                  style="font-size:13px"
                >
                  Download stored remittance CSV
                </a>
              </div>
            </div>

            <div class="card" id="ap-run-snapshot" style="padding:16px;margin-bottom:10px">
              <div style="font-size:13px;font-weight:700;margin-bottom:2px">
                Immutable bill snapshot
              </div>
              <p style="margin:0 0 10px;font-size:12px;color:var(--muted)">
                Captured when the run was requested. Approval revalidated these bills before
                posting; this table reads the stored snapshot, not the current bills.
              </p>

              <table style="width:100%;border-collapse:collapse;font-size:12px">
                <thead>
                  <tr>
                    <th scope="col" style="text-align:left;padding:5px 8px;border-bottom:1px solid var(--border,#e5e7eb);color:var(--muted)">Bill</th>
                    <th scope="col" style="text-align:left;padding:5px 8px;border-bottom:1px solid var(--border,#e5e7eb);color:var(--muted)">Snapshot bill id</th>
                    <th scope="col" style="text-align:left;padding:5px 8px;border-bottom:1px solid var(--border,#e5e7eb);color:var(--muted)">Due</th>
                    <th scope="col" style="text-align:right;padding:5px 8px;border-bottom:1px solid var(--border,#e5e7eb);color:var(--muted)">Amount</th>
                  </tr>
                </thead>
                <tbody>
                  <tr
                    :for={{payment, index} <- Enum.with_index(@run.payments)}
                    id={"ap-run-payment-#{index}"}
                  >
                    <td style="padding:5px 8px;border-bottom:1px solid var(--border,#f3f4f6)">
                      <a
                        :if={field(payment, :bill_id)}
                        href={bill_href(field(payment, :bill_id), @samen_mount, @org_id)}
                        style="color:inherit;text-decoration:underline;text-underline-offset:2px"
                      >
                        {field(payment, :number) || "—"}
                      </a>
                      <span :if={is_nil(field(payment, :bill_id))}>
                        {field(payment, :number) || "—"}
                      </span>
                    </td>
                    <td style="padding:5px 8px;border-bottom:1px solid var(--border,#f3f4f6)">
                      <code style="font-size:11px">{field(payment, :bill_id) || "—"}</code>
                    </td>
                    <td style="padding:5px 8px;border-bottom:1px solid var(--border,#f3f4f6)">
                      {date_text(field(payment, :due_date))}
                    </td>
                    <td style="padding:5px 8px;border-bottom:1px solid var(--border,#f3f4f6);text-align:right">
                      {money(field(payment, :amount_cents))}
                    </td>
                  </tr>

                  <tr :if={@run.payments == []}>
                    <td colspan="4" style="padding:16px 8px;color:var(--muted)">
                      This run has no snapshot lines.
                    </td>
                  </tr>
                </tbody>
                <tfoot>
                  <tr>
                    <td colspan="3" style="padding:8px;text-align:right;font-weight:700">
                      Snapshot total
                    </td>
                    <td style="padding:8px;text-align:right;font-weight:700">
                      {money(@run.total_cents)}
                    </td>
                  </tr>
                </tfoot>
              </table>
            </div>

            <div style="margin-top:14px">
              <a href={ap_payments_href(@samen_mount, @org_id)} style="font-size:13px">
                ← Back to AP payments
              </a>
            </div>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)

  defp fact(assigns) do
    ~H"""
    <div>
      <div style="font-size:10px;text-transform:uppercase;letter-spacing:.04em;color:var(--muted);margin-bottom:2px">
        {@label}
      </div>
      <div style="font-size:12px;overflow-wrap:anywhere">{@value}</div>
    </div>
    """
  end

  defp page_title(nil), do: "Payment run"
  defp page_title(run), do: "Payment run #{run.reference}"

  defp crumbs(mount, org_id, run) do
    base = [
      Crumbs.org(mount, org_id),
      "ERP",
      {Erp.ap_payments_label(), ap_payments_href(mount, org_id)}
    ]

    if run, do: base ++ [run.reference], else: base ++ ["Payment run"]
  end

  defp ap_payments_href(mount, org_id) do
    path = Mount.label(mount, :erp_path, "/erp")
    query = if is_binary(org_id), do: "?org=#{org_id}", else: ""
    "#{path}/ap-payments#{query}"
  end

  defp remittance_href(mount, org_id, run_id) do
    path = Mount.label(mount, :erp_path, "/erp")
    query = if is_binary(org_id), do: "?org=#{org_id}", else: ""
    "#{path}/ap-payments/#{run_id}/remittance#{query}"
  end

  defp bill_href(bill_id, mount, org_id) do
    path = Mount.label(mount, :erp_path, "/erp")
    query = if is_binary(org_id), do: "?org=#{org_id}", else: ""
    "#{path}/ap_invoices/#{bill_id}#{query}"
  end

  defp status_label(:pending_approval), do: "Awaiting approval"
  defp status_label(:paid), do: "Paid"
  defp status_label(:rejected), do: "Rejected"
  defp status_label(:cancelled), do: "Cancelled"
  defp status_label(other), do: to_string(other)

  defp status_style(:pending_approval),
    do:
      "display:inline-block;padding:3px 8px;border-radius:999px;background:#FEF3C7;color:#92400E;font-size:11px;font-weight:700"

  defp status_style(:paid),
    do:
      "display:inline-block;padding:3px 8px;border-radius:999px;background:#D1FAE5;color:#065F46;font-size:11px;font-weight:700"

  defp status_style(:rejected),
    do:
      "display:inline-block;padding:3px 8px;border-radius:999px;background:#FEE2E2;color:#991B1B;font-size:11px;font-weight:700"

  defp status_style(:cancelled),
    do:
      "display:inline-block;padding:3px 8px;border-radius:999px;background:#E5E7EB;color:#374151;font-size:11px;font-weight:700"

  defp status_style(_),
    do:
      "display:inline-block;padding:3px 8px;border-radius:999px;background:#E5E7EB;color:#374151;font-size:11px;font-weight:700"

  defp decision_label(:paid), do: "Approved by"
  defp decision_label(:rejected), do: "Rejected by"
  defp decision_label(:cancelled), do: "Cancelled by"
  defp decision_label(_), do: "Decision"

  defp decision_at_label(:paid), do: "Approved at"
  defp decision_at_label(:rejected), do: "Rejected at"
  defp decision_at_label(:cancelled), do: "Cancelled at"
  defp decision_at_label(_), do: "Decision at"

  defp decision_actor(%{status: :paid, approved_by: by}), do: by || "—"
  defp decision_actor(%{status: :rejected, rejected_by: by}), do: by || "—"
  defp decision_actor(%{status: :cancelled, cancelled_by: by}), do: by || "—"
  defp decision_actor(_run), do: "—"

  defp decision_at(%{status: :paid, approved_at: at}), do: stamp(at)
  defp decision_at(%{status: :rejected, rejected_at: at}), do: stamp(at)
  defp decision_at(%{status: :cancelled, cancelled_at: at}), do: stamp(at)
  defp decision_at(_run), do: "—"

  defp stamp(nil), do: "—"
  defp stamp(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")
  defp stamp(other), do: to_string(other)

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
