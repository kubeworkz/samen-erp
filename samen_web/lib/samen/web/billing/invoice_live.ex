defmodule Samen.Web.Billing.InvoiceLive do
  @moduledoc """
  Framework Billing / Invoice detail (`/billing/invoices/:id`) — the record page
  behind the invoices list (ADR-009, host-agnostic).

  The invoice itself is non-PII; the joined customer's `billing_name` is resolved
  through PiiResolution (tenant CLEAR / operator ••••) by `Reads.get_invoice/3` —
  this page renders whatever the resolver returned and never touches the vault.

  ## Page shape

  Header (label · status pill · amount) → bounded facts `<dl>` → the invoice's
  `line_items` table (the jsonb document lines, rendered verbatim) → the provider's
  itemized `tax_lines` breakdown when one exists (fail-honest: absent means the
  provider computed no tax, never a fabricated zero) → a Status-actions card.

  ## Writes — sanctioned `:update` only, admin-gated by the kernel

  * **Edit** opens a `modal/1` hosting an `AshPhoenix.Form.for_update/3` over the
    blueprint's `update: :*` (amount + currency — status is NOT an edit field; it
    moves only through the transition table below).
  * **Status transitions** ride a CLOSED table (`@transitions/0`): `{key, target,
    label, from_statuses}`. Buttons render only while the record's status is in
    `from_statuses`, and the server re-checks the table on every event, so a
    hand-crafted `transition` event is a no-op — never a state jump. The write
    itself goes through `Reads.write_scope/2` (same-org role elevation, plane-
    preserving), so the kernel's `OrgScope` + `RoleAtLeast :admin` govern it
    exactly as they govern a direct API call.
  * **Delete** carries the `delete_confirm/1` interlock and fails honest (linked
    payments refuse at the FK; the refusal is surfaced on the page).

  All write affordances are TENANT-plane only (`Samen.Web.Billing.Live.writable?/1`);
  the hosted invoice/receipt links are rendered tenant-side only (ADR-038 §3.5).
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Billing.Live, only: [assign_mount: 2, billing_sidebar: 1, writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.Crumbs
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  alias Samen.Web.Billing.Reads

  # The CLOSED invoice status-transition table (a UI state machine over the
  # resource's sanctioned `:update` — the kernel's OrgScope + RoleAtLeast :admin
  # govern the WRITE; this table only decides which moves this page offers).
  # `{key, target, label, from_statuses}` — display order.
  @transitions [
    {"open", :open, "Mark open", [:draft]},
    {"paid", :paid, "Mark paid", [:draft, :open]},
    {"uncollectible", :uncollectible, "Mark uncollectible", [:open]},
    {"void", :void, "Void invoice", [:draft, :open, :uncollectible]}
  ]

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    invoice_id = Map.get(params, "id")

    {:ok,
     load(
       assign(socket, org_id: org_id, invoice_id: invoice_id, return_to: nil),
       org_id,
       invoice_id
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Samen.Web.CurrentOrg.reresolve(socket, params)
    invoice_id = Map.get(params, "id") || socket.assigns.invoice_id

    {:noreply,
     load(
       assign(socket, org_id: org_id, invoice_id: invoice_id, return_to: return_path(uri)),
       org_id,
       invoice_id
     )}
  end

  @doc false
  def load(socket, nil, _invoice_id) do
    socket
    |> ensure_return_to()
    |> assign(
      no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil),
      org_id: nil,
      invoice_id: nil,
      invoice: nil,
      available_transitions: [],
      show_edit: false,
      edit_form: nil,
      action_error: nil,
      delete_error: nil
    )
  end

  def load(socket, org_id, invoice_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    invoice =
      if invoice_id do
        case Reads.get_invoice(mount, scope, invoice_id) do
          {:ok, inv} -> inv
          :error -> nil
        end
      end

    socket
    |> ensure_return_to()
    |> assign(
      no_org: false,
      org_id: org_id,
      invoice_id: invoice_id,
      invoice: invoice,
      available_transitions: allowed_transitions(invoice),
      show_edit: false,
      edit_form: nil,
      action_error: nil,
      delete_error: nil
    )
  end

  # -- writes (tenant posture in the render; kernel governs the write path) ----

  @impl true
  def handle_event("edit_invoice", _params, socket) do
    %{samen_mount: mount, org_id: org_id, invoice: invoice} = socket.assigns

    if is_binary(org_id) and invoice != nil do
      {:noreply, assign(socket, show_edit: true, edit_form: edit_form(mount, org_id, invoice))}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, show_edit: false)}
  end

  def handle_event("validate_edit", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.edit_form, params)
    {:noreply, assign(socket, edit_form: form)}
  end

  # The form's record already carries its org; the scope (server-side fact) does
  # the rest — no client input reaches org/identity fields.
  def handle_event("save_edit", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.edit_form, params: params) do
      {:ok, _invoice} ->
        {:noreply, load(socket, socket.assigns.org_id, socket.assigns.invoice_id)}

      {:error, form} ->
        {:noreply, assign(socket, edit_form: form)}
    end
  end

  # Status transition — the server-side re-check of the CLOSED table: an unknown
  # key or a move whose `from_statuses` excludes the record's current status is a
  # silent no-op (the buttons only render for allowed moves anyway).
  def handle_event("transition", %{"action" => key}, socket) do
    %{samen_mount: mount, org_id: org_id, invoice: invoice} = socket.assigns

    with true <- is_binary(org_id),
         %{status: status} <- invoice,
         {_key, target, _label, from} <- Enum.find(@transitions, fn {k, _, _, _} -> k == key end),
         true <- status in from do
      scope = Reads.write_scope(mount, org_id)

      invoice
      |> Ash.Changeset.for_update(:update, %{status: target}, scope: scope)
      |> Ash.update()
      |> case do
        {:ok, _} ->
          {:noreply, load(socket, org_id, socket.assigns.invoice_id)}

        {:error, _} ->
          {:noreply, assign(socket, action_error: "Could not update this invoice's status.")}
      end
    else
      _ -> {:noreply, socket}
    end
  end

  # FAIL-HONEST delete: an invoice with linked payments is refused by the DB (FK)
  # and the refusal is SURFACED on the page. Success navigates back to the list.
  def handle_event("delete", %{"id" => id}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    if is_binary(org_id) do
      case Reads.delete_invoice(mount, Reads.write_scope(mount, org_id), id) do
        :ok ->
          {:noreply, push_navigate(socket, to: invoices_path(org_id))}

        {:error, _reason} ->
          {:noreply,
           assign(socket, delete_error: "Could not delete this invoice — it still has linked records.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("dismiss_error", _params, socket) do
    {:noreply, assign(socket, action_error: nil, delete_error: nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="billing-invoice">
      <.app_shell>
        <:sidebar>
          <.billing_sidebar mount={@samen_mount} org_id={@org_id} active={:billing_invoices} return_to={@return_to} />
        </:sidebar>

        <.topbar title={invoice_label(@invoice)} crumbs={crumbs(@samen_mount, @org_id, invoice_label(@invoice))}>
          <:actions>
            <a href={invoices_path(@org_id)} class="btn" style="text-decoration:none">
              <span class="i">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M19 12H5M12 5l-7 7 7 7" />
                </svg>
              </span>
              Back to invoices
            </a>
            <.button :if={writable?(@samen_mount) and @invoice != nil} phx-click="edit_invoice" id="edit-invoice">
              Edit invoice
            </.button>
            <.delete_confirm
              :if={writable?(@samen_mount) and @invoice != nil}
              id="delete-invoice"
              message="Delete this invoice? This cannot be undone."
              phx-click="delete"
              phx-value-id={@invoice && @invoice.id}
            />
          </:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">Billing invoice org: {@org_id}</span>

          <div :if={@action_error} class="wrap" style="margin-bottom:0">
            <div class="card form-error" id="action-error" style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px;display:flex;gap:10px;align-items:center">
              <span>{@action_error}</span>
              <button type="button" class="btn" phx-click="dismiss_error" style="font-size:12px">Dismiss</button>
            </div>
          </div>

          <div :if={@delete_error} class="wrap" style="margin-bottom:0">
            <div class="card form-error" id="delete-error" style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px">
              {@delete_error}
            </div>
          </div>

          <%= if @invoice == nil do %>
            <div class="wrap">
              <div class="card" style="padding:22px 20px;color:var(--muted)">Invoice not found.</div>
            </div>
          <% else %>
            <div class="wrap" style="margin-bottom:0">
              <div class="card" id="invoice-header" style="padding:18px 20px;display:flex;align-items:center;gap:14px;flex-wrap:wrap">
                <div style="flex:1;min-width:0">
                  <h1 style="font-weight:600;font-size:18px;color:#2a2b35;margin:0 0 4px">{invoice_label(@invoice)}</h1>
                  <div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center">
                    <.pill variant={invoice_status_variant(@invoice)}>{invoice_status_label(@invoice)}</.pill>
                    <span style="font-size:13px;font-weight:500;color:#3a3b45">{dollars(@invoice.amount_due_cents)}</span>
                    <span :if={@invoice.due_date} style="font-size:12px;color:var(--muted)">
                      due {format_date(@invoice.due_date)}
                    </span>
                    <span style="font-size:12px;color:var(--muted)">· admin-gated writes · no PII</span>
                  </div>
                </div>
              </div>
            </div>

            <div class="wrap" style="margin-bottom:0;padding-top:10px">
              <div class="card" id="invoice-facts" style="padding:16px 18px">
                <dl style="display:grid;grid-template-columns:minmax(140px,220px) 1fr;gap:8px 16px;margin:0">
                  <div style="display:contents">
                    <dt style="font-size:12px;font-weight:600;color:var(--muted)">Status</dt>
                    <dd style="margin:0;font-size:13px">
                      <.pill variant={invoice_status_variant(@invoice)}>{invoice_status_label(@invoice)}</.pill>
                    </dd>
                  </div>
                  <div style="display:contents">
                    <dt style="font-size:12px;font-weight:600;color:var(--muted)">Amount due</dt>
                    <dd style="margin:0;font-size:13px;font-family:monospace">{dollars(@invoice.amount_due_cents)}</dd>
                  </div>
                  <div style="display:contents">
                    <dt style="font-size:12px;font-weight:600;color:var(--muted)">Amount paid</dt>
                    <dd style="margin:0;font-size:13px;font-family:monospace">{dollars(@invoice.amount_paid_cents)}</dd>
                  </div>
                  <div style="display:contents">
                    <dt style="font-size:12px;font-weight:600;color:var(--muted)">Tax</dt>
                    <dd style="margin:0;font-size:13px;font-family:monospace">{tax_display(@invoice.tax_amount_cents)}</dd>
                  </div>
                  <div style="display:contents">
                    <dt style="font-size:12px;font-weight:600;color:var(--muted)">Currency</dt>
                    <dd style="margin:0;font-size:13px;font-family:monospace">{@invoice.currency || "—"}</dd>
                  </div>
                  <div style="display:contents">
                    <dt style="font-size:12px;font-weight:600;color:var(--muted)">Customer</dt>
                    <dd style="margin:0;font-size:13px">{customer_name(@invoice)}</dd>
                  </div>
                  <div style="display:contents">
                    <dt style="font-size:12px;font-weight:600;color:var(--muted)">Due date</dt>
                    <dd style="margin:0;font-size:13px;font-family:monospace">{format_date(@invoice.due_date)}</dd>
                  </div>
                  <div style="display:contents">
                    <dt style="font-size:12px;font-weight:600;color:var(--muted)">Period</dt>
                    <dd style="margin:0;font-size:13px;font-family:monospace">
                      {format_date(@invoice.period_start)} → {format_date(@invoice.period_end)}
                    </dd>
                  </div>
                  <div style="display:contents">
                    <dt style="font-size:12px;font-weight:600;color:var(--muted)">Paid at</dt>
                    <dd style="margin:0;font-size:13px;font-family:monospace">{format_ts(@invoice.paid_at)}</dd>
                  </div>
                  <div style="display:contents">
                    <dt style="font-size:12px;font-weight:600;color:var(--muted)">Provider ref</dt>
                    <dd style="margin:0;font-size:13px;font-family:monospace;word-break:break-all">
                      {@invoice.provider_invoice_ref || "—"}
                    </dd>
                  </div>
                  <div :if={writable?(@samen_mount)} style="display:contents">
                    <dt style="font-size:12px;font-weight:600;color:var(--muted)">Hosted invoice</dt>
                    <dd style="margin:0;font-size:13px">
                      <a
                        :if={@invoice.hosted_invoice_url}
                        href={@invoice.hosted_invoice_url}
                        target="_blank"
                        rel="noopener noreferrer"
                        class="inv-hosted-invoice-link"
                      >
                        View invoice
                      </a>
                      <span :if={!@invoice.hosted_invoice_url} style="color:var(--muted)">—</span>
                    </dd>
                  </div>
                  <div :if={writable?(@samen_mount) and @invoice.hosted_receipt_url} style="display:contents">
                    <dt style="font-size:12px;font-weight:600;color:var(--muted)">Hosted receipt</dt>
                    <dd style="margin:0;font-size:13px">
                      <a
                        href={@invoice.hosted_receipt_url}
                        target="_blank"
                        rel="noopener noreferrer"
                        class="inv-hosted-receipt-link"
                      >
                        Receipt
                      </a>
                    </dd>
                  </div>
                  <div style="display:contents">
                    <dt style="font-size:12px;font-weight:600;color:var(--muted)">Inserted at</dt>
                    <dd style="margin:0;font-size:13px;font-family:monospace">{format_ts(@invoice.inserted_at)}</dd>
                  </div>
                </dl>
              </div>

              <div class="card" id="invoice-lines" style="padding:16px 18px;margin-top:10px">
                <div class="gtitle" style="margin-bottom:6px">
                  <h3 style="font-size:13px">Lines</h3>
                  <span class="n">{length(@invoice.line_items || [])}</span>
                  <span class="lane">· line items as recorded</span>
                </div>
                <table
                  :if={@invoice.line_items not in [nil, []]}
                  style="width:100%;border-collapse:collapse;font-size:13px"
                >
                  <thead>
                    <tr>
                      <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">
                        Description
                      </th>
                      <th scope="col" style="text-align:right;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">
                        Qty
                      </th>
                      <th scope="col" style="text-align:right;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">
                        Amount
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={line <- @invoice.line_items} class="invoice-line-row">
                      <td style="padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb)">
                        {line_value(line, :description) || "—"}
                      </td>
                      <td style="padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);text-align:right;font-family:monospace">
                        {line_value(line, :quantity) || "—"}
                      </td>
                      <td style="padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);text-align:right;font-family:monospace">
                        {line_money(line)}
                      </td>
                    </tr>
                  </tbody>
                </table>
                <p
                  :if={@invoice.line_items in [nil, []]}
                  style="margin:0;font-size:12px;color:var(--muted)"
                >
                  No line items recorded on this invoice.
                </p>
              </div>

              <div
                :if={@invoice.tax_lines not in [nil, []]}
                class="card"
                id="invoice-tax-lines"
                style="padding:16px 18px;margin-top:10px"
              >
                <div class="gtitle" style="margin-bottom:6px">
                  <h3 style="font-size:13px">Tax breakdown</h3>
                  <span class="n">{length(@invoice.tax_lines)}</span>
                  <span class="lane">· mirrored from the provider</span>
                </div>
                <table style="width:100%;border-collapse:collapse;font-size:13px">
                  <thead>
                    <tr>
                      <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">
                        Name
                      </th>
                      <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">
                        Jurisdiction
                      </th>
                      <th scope="col" style="text-align:right;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">
                        Rate
                      </th>
                      <th scope="col" style="text-align:right;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">
                        Amount
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={tax <- @invoice.tax_lines} class="invoice-tax-row">
                      <td style="padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb)">
                        {tax_value(tax, "display_name") || "—"}
                      </td>
                      <td style="padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">
                        {tax_value(tax, "jurisdiction") || "—"}
                      </td>
                      <td style="padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);text-align:right;font-family:monospace">
                        {tax_rate(tax)}
                      </td>
                      <td style="padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);text-align:right;font-family:monospace">
                        {dollars(tax_value(tax, "amount_cents"))}
                      </td>
                    </tr>
                  </tbody>
                </table>
              </div>

              <div class="wrap" style="margin-bottom:0;padding-top:10px" id="invoice-status-actions-wrap">
                <div class="card" id="invoice-status-actions" style="padding:16px 18px">
                  <div class="gtitle" style="margin-bottom:8px">
                    <h3 style="font-size:13px">Status actions</h3>
                    <span class="lane">· admin-gated · moves from {to_string(@invoice.status)} only</span>
                  </div>
                  <div :if={writable?(@samen_mount)} style="display:flex;gap:8px;flex-wrap:wrap">
                    <.button
                      :for={{key, _target, label, _from} <- @available_transitions}
                      phx-click="transition"
                      phx-value-action={key}
                      id={"transition-" <> key}
                    >
                      {label}
                    </.button>
                    <p
                      :if={@available_transitions == []}
                      style="margin:0;font-size:12px;color:var(--muted);align-self:center"
                    >
                      No further status moves from {to_string(@invoice.status)}.
                    </p>
                  </div>
                  <p
                    :if={!writable?(@samen_mount)}
                    style="margin:0;font-size:12px;color:var(--muted)"
                  >
                    Status is {to_string(@invoice.status)} · no write affordance on this plane.
                  </p>
                </div>
              </div>
            </div>

            <.modal
              :if={@show_edit and @edit_form != nil and writable?(@samen_mount)}
              id="edit-invoice-modal"
              title="Edit invoice"
              on_cancel="cancel_edit"
            >
              <.simple_form
                :let={f}
                for={@edit_form}
                id="edit-invoice-form"
                phx-change="validate_edit"
                phx-submit="save_edit"
              >
                <.form_field field={f[:amount_due_cents]} label="Amount due (cents)" type="number" />
                <.form_field field={f[:currency]} label="Currency" />
                <:actions>
                  <.button variant="primary" type="submit">Save changes</.button>
                  <.button type="button" phx-click="cancel_edit">Cancel</.button>
                </:actions>
              </.simple_form>
            </.modal>
          <% end %>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # -- helpers -----------------------------------------------------------------

  defp edit_form(invoice, scope) do
    invoice
    |> AshPhoenix.Form.for_update(:update, scope: scope)
    |> to_form()
  end

  defp edit_form(mount, org_id, invoice), do: edit_form(invoice, Reads.write_scope(mount, org_id))

  defp allowed_transitions(nil), do: []

  defp allowed_transitions(invoice) do
    Enum.filter(@transitions, fn {_key, _target, _label, from} -> invoice.status in from end)
  end

  defp crumbs(mount, org_id, leaf),
    do: [Crumbs.org(mount, org_id), Crumbs.section(mount, org_id, :billing), {"Invoices", invoices_path(org_id)}, leaf]

  defp invoices_path(nil), do: "/billing/invoices"
  defp invoices_path(org_id), do: "/billing/invoices?org=#{org_id}"

  defp invoice_label(nil), do: "Invoice"
  defp invoice_label(%{id: id}), do: "INV-#{String.slice(id, 0, 8)}"

  defp customer_name(invoice) do
    case Map.get(invoice, :__customer__) do
      %{billing_name: %Samen.Masked{} = masked} -> masked
      %{billing_name: name} when is_binary(name) -> name
      _ -> "—"
    end
  end

  # The overdue label mirrors the list's own status pill (open + past due reads
  # "overdue") — the detail page never invents a state the list doesn't show.
  defp invoice_status_label(inv) do
    if overdue?(inv), do: "overdue", else: to_string(inv.status)
  end

  defp invoice_status_variant(inv) do
    cond do
      inv.status == :paid -> "ok"
      overdue?(inv) -> "bad"
      inv.status == :open -> "info"
      true -> "mut"
    end
  end

  defp overdue?(%{status: :open, due_date: %DateTime{} = due}),
    do: DateTime.compare(due, DateTime.utc_now()) == :lt

  defp overdue?(_), do: false

  # Fail-honest tax display (ADR-014 shape applied to tax): `nil` means the
  # provider genuinely computed no tax — an honest "—", NEVER "$0.00".
  defp tax_display(nil), do: "—"
  defp tax_display(cents) when is_integer(cents), do: dollars(cents)
  defp tax_display(_), do: "—"

  defp dollars(cents) when is_integer(cents),
    do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"

  defp dollars(_), do: "—"

  # jsonb line/tax maps arrive string-keyed from Postgres (and from any client
  # form); accept both shapes without minting atoms.
  defp line_value(line, key) when is_map(line) do
    string_key = Atom.to_string(key)

    cond do
      is_map_key(line, key) -> Map.get(line, key)
      is_map_key(line, string_key) -> Map.get(line, string_key)
      true -> nil
    end
  end

  defp line_value(_line, _key), do: nil

  defp line_money(line) do
    case line_value(line, :amount_cents) do
      cents when is_integer(cents) -> dollars(cents)
      _ -> "—"
    end
  end

  # tax_lines mirror VERBATIM from the provider's jsonb — string keys, always.
  defp tax_value(tax, key) when is_map(tax), do: Map.get(tax, key)
  defp tax_value(_tax, _key), do: nil

  defp tax_rate(tax) do
    case tax_value(tax, "percentage") do
      pct when is_number(pct) -> "#{pct}%"
      pct when is_binary(pct) -> pct <> "%"
      _ -> "—"
    end
  end

  defp format_date(nil), do: "—"
  defp format_date(%DateTime{} = dt), do: "#{dt.year}-#{pad(dt.month)}-#{pad(dt.day)}"
  defp format_date(_), do: "—"

  defp format_ts(nil), do: "—"
  defp format_ts(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_ts(other), do: to_string(other)

  defp pad(n), do: String.pad_leading(to_string(n), 2, "0")

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to),
      do: socket,
      else: assign(socket, return_to: nil)
  end
end
