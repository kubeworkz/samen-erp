defmodule Samen.Web.Erp.ApCaptureLive do
  @moduledoc """
  The AP invoice capture page (`<erp>/ap-capture`): paste invoice text (or, on a
  host with an OCR adapter, choose a document), review the parsed draft, and
  confirm it into ONE draft `ApInvoice`.

  Capture is deliberately not an approval shortcut: the bill it creates is a
  `:draft`, so it still walks the same gated `:approve` path (ADR-040) as a
  hand-keyed bill. What capture removes is typing, not governance.

  ## Duplicate detection at capture time

    * As soon as a draft parses, the page looks the invoice NUMBER up across the
      org. `{org, number}` is unique at the database, so a hit is the same
      document however it was keyed — the page says which bill holds it and
      refuses to confirm.
    * On confirm, `ApInvoiceCapture` runs the softer vendor + total + bill-date
      check (`ApDuplicates`, the payment run's definition) and refuses unless
      the operator ticks "Capture anyway".

  ## OCR

  Text is captured on every host. A document needs an OCR adapter
  (`Samen.Scopes.Finance.InvoiceOcr`): without one the page says so and points
  at the paste path — it never pretends a scan was read.  The uploader is only
  offered when a LiveView endpoint is present (a real mount), which also keeps
  the page renderable by the headless test harness.

  A document is metered: hosted OCR costs money per page, so each organization
  gets a budget of document submissions per hour on the shared
  `Samen.Web.RateLimit` seam (`Samen.Web.Erp.OcrQuota`). Pasting text and text
  files are free and never consume it; over the budget the page refuses the
  document and points at the paste path.

  The page shows both the remaining documents and the time until the window
  resets; a connected page re-reads once a minute and just past the boundary.
  """

  use Samen.Web.Tenant.Live

  require Ash.Query

  import Samen.Web.Erp.Live, only: [assign_mount: 2, erp_sidebar: 1, writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Scopes.Finance.{ApInvoiceCapture, InvoiceOcr}
  alias Samen.Web.Crumbs
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Erp
  alias Samen.Web.Erp.OcrQuota
  alias Samen.Web.Erp.OcrQuota.PubSub, as: OcrQuotaPubSub
  alias Samen.Web.TenantRole

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)

    {:ok,
     socket
     |> maybe_allow_upload()
     |> assign(
       org_id: org_id,
       return_to: nil,
       resource: nil,
       accounts: [],
       account_id: nil,
       vendor_id: "",
       text: "",
       draft: nil,
       number: "",
       invoice_date: nil,
       due_date: nil,
       memo: "",
       error: nil,
       notice: nil,
       existing: nil,
       duplicates: [],
       created: nil,
       missing: nil,
       ocr_budget: OcrQuota.budget(org_id, repo: socket.assigns.samen_mount.repo),
       ocr_configured: InvoiceOcr.configured?()
     )
     |> assign_ocr_window()
     |> load()}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = CurrentOrg.reresolve(socket, params)

    {:noreply,
     socket
     |> assign(org_id: org_id, return_to: return_path(uri))
     |> load()
     |> assign_ocr_budget()}
  end

  @doc false
  def load(socket) do
    socket
    |> assign_new(:draft, fn -> nil end)
    |> assign_new(:existing, fn -> nil end)
    |> assign_new(:duplicates, fn -> [] end)
    |> assign_new(:account_id, fn -> nil end)
    |> assign_new(:return_to, fn -> nil end)
    |> do_load()
  end

  defp do_load(%{assigns: %{org_id: nil}} = socket) do
    assign(socket, missing: :no_org, resource: nil, accounts: [])
  end

  defp do_load(socket) do
    mount = socket.assigns.samen_mount
    org_id = socket.assigns.org_id

    with resource when is_atom(resource) and not is_nil(resource) <- Erp.ap_invoice(mount),
         account_resource when is_atom(account_resource) and not is_nil(account_resource) <-
           Erp.account(mount) do
      scope = TenantRole.authenticated_scope(mount, org_id)

      case read_accounts(account_resource, org_id, scope) do
        {:ok, accounts} ->
          assign(socket,
            resource: resource,
            accounts: accounts,
            account_id: socket.assigns.account_id || first_id(accounts),
            missing: nil
          )

        {:error, _reason} ->
          assign(socket, resource: resource, accounts: [], missing: :unreadable)
      end
    else
      nil -> assign(socket, missing: :unmounted, resource: nil, accounts: [])
    end
  end

  defp read_accounts(account_resource, org_id, scope) do
    account_resource
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.Query.sort(code: :asc)
    |> Ash.read(scope: scope)
  end

  defp first_id([]), do: nil
  defp first_id([row | _rest]), do: row.id

  # A real LiveView mount carries its endpoint; the headless harness does not.
  # Without one we skip the uploader and keep the paste path (which needs no
  # endpoint), instead of crashing the page in tests.
  defp maybe_allow_upload(%{endpoint: nil} = socket), do: socket

  defp maybe_allow_upload(socket) do
    allow_upload(socket, :document,
      accept: ~w(.pdf .png .jpg .jpeg .txt .csv),
      max_entries: 1,
      max_file_size: 5_000_000
    )
  end

  # -- events -----------------------------------------------------------------

  @impl true
  def handle_event("noop", _params, socket), do: {:noreply, socket}

  def handle_event("capture", params, socket) do
    if writable?(socket.assigns.samen_mount) do
      {uploaded, socket} = uploaded_document(socket)

      case document_ocr_gate(
             uploaded,
             socket.assigns.org_id,
             socket.assigns.samen_mount.repo,
             pubsub: OcrQuotaPubSub.server(socket.assigns.samen_mount)
           ) do
        :ok ->
          {:noreply, socket} = read_invoice(socket, params, uploaded)
          {:noreply, assign_ocr_budget(socket)}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(error: ocr_gate_error(reason))
           |> assign_ocr_budget()}
      end
    else
      {:noreply, assign(socket, error: "Capture is read-only on this plane.")}
    end
  end

  def handle_event("confirm", params, socket) do
    case socket.assigns.draft do
      nil ->
        {:noreply, assign(socket, error: "Capture an invoice first.")}

      draft ->
        confirm(socket, draft, params)
    end
  end

  def handle_event("discard", _params, socket) do
    {:noreply,
     assign(socket,
       draft: nil,
       existing: nil,
       duplicates: [],
       error: nil,
       notice: nil,
       number: "",
       invoice_date: nil,
       due_date: nil
     )}
  end

  @impl true
  def handle_info(:ocr_quota_refresh, socket) do
    {:noreply, assign_ocr_budget(socket)}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # A document the operator is about to spend a hosted OCR call on. Paste and
  # text files never reach this budget — only what will call the adapter.
  # `opts` passes through to `OcrQuota.check/2` (notably `:pubsub`, so the
  # dashboard hears about the charge).
  @doc false
  def document_ocr_gate(uploaded, org_id, repo, opts \\ [])

  def document_ocr_gate(nil, _org_id, _repo, _opts), do: :ok

  def document_ocr_gate(%{content_type: content_type}, org_id, repo, opts) do
    if InvoiceOcr.configured?() and InvoiceOcr.adapter_required?(content_type) do
      OcrQuota.check(org_id, Keyword.merge(opts, repo: repo))
    else
      :ok
    end
  end

  def document_ocr_gate(_uploaded, _org_id, _repo, _opts), do: :ok

  defp ocr_gate_error(:ocr_rate_limited) do
    "This workspace has reached its OCR limit for now. Paste the invoice text, or try again later."
  end

  defp ocr_gate_error(:ocr_quota_unavailable) do
    "Hosted OCR is unavailable right now. Paste the invoice text, or try again later."
  end

  defp assign_ocr_budget(socket) do
    socket
    |> assign(
      ocr_budget: OcrQuota.budget(socket.assigns.org_id, repo: socket.assigns.samen_mount.repo)
    )
    |> assign_ocr_window()
  end

  # The reset label is a database-clock fact; read it for the dead render too,
  # but only a connected page needs the refresh timer. The shared delay keeps
  # this page's minute cadence identical to the dashboard's.
  defp assign_ocr_window(socket) do
    cancel_ocr_window_timer(socket)
    remaining_ms = ocr_window_remaining_ms(socket)
    socket = assign(socket, ocr_reset_in: OcrQuota.format_window_remaining(remaining_ms))

    if connected?(socket) and is_binary(socket.assigns.org_id) and InvoiceOcr.configured?() do
      ref =
        Process.send_after(
          self(),
          :ocr_quota_refresh,
          OcrQuota.refresh_delay_ms(remaining_ms)
        )

      assign(socket, ocr_window_timer: ref)
    else
      assign(socket, ocr_window_timer: nil)
    end
  end

  defp ocr_window_remaining_ms(socket) do
    if is_binary(socket.assigns.org_id) and InvoiceOcr.configured?() do
      case OcrQuota.window_remaining_ms(repo: socket.assigns.samen_mount.repo) do
        {:ok, remaining_ms} -> remaining_ms
        {:error, _reason} -> nil
      end
    end
  end

  defp cancel_ocr_window_timer(socket) do
    case socket.assigns[:ocr_window_timer] do
      ref when is_reference(ref) -> Process.cancel_timer(ref)
      _other -> :ok
    end
  end

  defp read_invoice(socket, params, uploaded) do
    options = uploaded || [text: params["text"] || ""]

    case ApInvoiceCapture.capture(options) do
      {:ok, draft} ->
        {:noreply,
         socket
         |> assign(
           draft: draft,
           error: nil,
           notice: nil,
           created: nil,
           duplicates: [],
           text: params["text"] || socket.assigns.text,
           number: draft.number || "",
           invoice_date: draft.invoice_date,
           due_date: draft.due_date,
           vendor_name: draft.vendor_name
         )
         |> preview_existing()}

      {:error, :empty_text} ->
        {:noreply, assign(socket, error: "Paste the invoice text or choose a document.")}

      {:error, :ocr_not_configured} ->
        {:noreply,
         assign(socket,
           error:
             "This document needs OCR and no OCR adapter is configured on this host. Paste the invoice text instead."
         )}

      {:error, reason} ->
        {:noreply, assign(socket, error: capture_error(reason))}
    end
  end

  defp confirm(socket, draft, params) do
    %{samen_mount: mount, org_id: org_id, resource: resource} = socket.assigns

    if not writable?(mount) do
      {:noreply, assign(socket, error: "Capture is read-only on this plane.")}
    else
      draft = put_line_refs(draft, params)

      socket =
        assign(socket,
          draft: draft,
          vendor_id: params["vendor_id"] || "",
          memo: params["memo"] || socket.assigns.memo
        )

      case ApInvoiceCapture.confirm(
             ap_invoice: resource,
             scope: TenantRole.authenticated_scope(mount, org_id),
             org_id: org_id,
             vendor_id: params["vendor_id"],
             account_id: params["account_id"] || socket.assigns.account_id,
             number: params["number"],
             invoice_date: parse_date(params["invoice_date"]),
             bill_date: parse_date(params["invoice_date"]),
             due_date: parse_date(params["due_date"]),
             total_cents: draft.total_cents,
             lines: draft.lines,
             memo: params["memo"],
             match_tolerance_cents: parse_non_negative_integer(params["match_tolerance_cents"]),
             match_tolerance_pct: parse_non_negative_integer(params["match_tolerance_pct"]),
             allow_duplicate: truthy(params["allow_duplicate"])
           ) do
        {:ok, bill} ->
          {:noreply,
           socket
           |> assign(
             draft: nil,
             existing: nil,
             duplicates: [],
             created: bill,
             error: nil,
             notice: "Captured #{bill.number} as a draft bill.",
             number: "",
             invoice_date: nil,
             due_date: nil,
             memo: ""
           )
           |> load()}

        {:error, {:duplicate_number, bill}} ->
          {:noreply,
           assign(socket,
             existing: bill,
             error:
               "Invoice #{bill.number} is already on a bill. A number can only be captured once."
           )}

        {:error, {:possible_duplicates, numbers}} ->
          {:noreply,
           assign(socket,
             duplicates: numbers,
             error:
               "Possible duplicate of #{Enum.join(numbers, ", ")}. Tick \"Capture anyway\" to keep both."
           )}

        {:error, reason} ->
          {:noreply, assign(socket, error: confirm_error(reason))}
      end
    end
  end

  defp uploaded_document(socket) do
    if socket.assigns[:uploads] do
      {results, socket} =
        consume_uploaded_entries(socket, :document, fn %{path: path}, entry ->
          {:ok,
           [
             document: File.read!(path),
             content_type: entry.client_type,
             file_name: entry.client_name
           ]}
        end)

      {List.first(results), socket}
    else
      {nil, socket}
    end
  end

  defp preview_existing(socket) do
    %{draft: draft, resource: resource, org_id: org_id, samen_mount: mount} = socket.assigns

    existing =
      case ApInvoiceCapture.existing_number(
             resource,
             TenantRole.authenticated_scope(mount, org_id),
             org_id,
             draft.number
           ) do
        {:ok, nil} -> nil
        {:ok, bill} -> bill
        _error -> nil
      end

    assign(socket, existing: existing)
  end

  # -- messages ---------------------------------------------------------------

  defp capture_error({:vision_error, status, nil}) when is_integer(status) do
    "The OCR provider rejected the request (#{status}). Check the API key and that the Vision API is enabled."
  end

  defp capture_error({:vision_error, status, message}) when is_integer(status) do
    "The OCR provider rejected the request (#{status}): #{message}"
  end

  defp capture_error({:vision_page_error, _code, message}),
    do: "The OCR provider could not read a page: #{message}"

  defp capture_error({:vision_unexpected_response, _value}),
    do: "The OCR provider returned something unusable."

  defp capture_error(:document_too_large), do: "That document is larger than 2 MB."
  defp capture_error(:unreadable_text), do: "That file is not readable text."
  defp capture_error(:empty_document), do: "That file is empty."
  defp capture_error(:not_binary), do: "That document could not be read."

  defp capture_error({:invalid_ocr_adapter, _module}),
    do: "This host's OCR adapter is misconfigured."

  defp capture_error({:invalid_ocr_adapter_result, _value}),
    do: "The OCR adapter returned something unusable."

  defp capture_error(_reason), do: "The invoice could not be read."

  defp confirm_error(:invoice_number_required), do: "Enter the invoice number."
  defp confirm_error(:vendor_required), do: "Enter the vendor id."
  defp confirm_error(:account_required), do: "Choose an expense account."
  defp confirm_error(:invoice_date_required), do: "Choose the invoice date."
  defp confirm_error(:lines_required), do: "The invoice has no lines to capture."
  defp confirm_error(:invalid_total), do: "The parsed total is not a valid amount."
  defp confirm_error({:invalid_line, _line}), do: "Every captured line needs a positive amount."

  defp confirm_error({:invalid_tolerance, :match_tolerance_cents}),
    do: "Match tolerance in cents must be a non-negative whole number."

  defp confirm_error({:invalid_tolerance, :match_tolerance_pct}),
    do: "Match tolerance percent must be a whole number between 0 and 100."

  defp confirm_error({:lines_total_mismatch, total, sum}) do
    "The captured lines total #{money(sum)} but the invoice total is #{money(total)} — fix the lines before confirming."
  end

  defp confirm_error({:duplicate_check_failed, _reason}),
    do: "The duplicate check could not run. Try again."

  defp confirm_error(_reason), do: "The invoice could not be captured."

  defp truthy(value), do: value in [true, "1", "true", "on"]

  defp parse_date(%Date{} = date), do: date

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _other -> nil
    end
  end

  defp parse_date(_value), do: nil

  defp parse_non_negative_integer(nil), do: 0
  defp parse_non_negative_integer(""), do: 0

  defp parse_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {integer, ""} -> integer
      _other -> :invalid
    end
  end

  defp parse_non_negative_integer(_value), do: :invalid

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

  defp put_line_refs(draft, params) do
    lines =
      draft.lines
      |> Enum.with_index()
      |> Enum.map(fn {line, index} ->
        line
        |> Map.put(:po_line_id, blank_to_nil(params["line_po_line_id_#{index}"]))
        |> Map.put(:receipt_line_id, blank_to_nil(params["line_receipt_line_id_#{index}"]))
      end)

    %{draft | lines: lines}
  end

  defp money(nil), do: "—"

  defp money(cents) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    cents = abs(cents)

    "#{sign}$#{div(cents, 100)}.#{cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp money(other), do: to_string(other)

  defp crumbs(mount, org_id) do
    [Crumbs.org(mount, org_id), "ERP", Erp.ap_capture_label()]
  end

  @impl Samen.Web.Tenant.Live
  def tenant_sidebar(assigns) do
    ~H"""
    <.erp_sidebar
      mount={@samen_mount}
      org_id={@org_id}
      active={:erp_ap_capture}
      return_to={@return_to}
    />
    """
  end

  @impl Samen.Web.Tenant.Live
  def tenant_page(assigns) do
    ~H"""
    <div id="erp-ap-capture">
    <.topbar
      title={Erp.ap_capture_label()}
      crumbs={crumbs(@samen_mount, @org_id)}
    />

    <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

    <div class="wrap">
      <%= if @missing == :no_org do %>
        <.no_org_card mount={@samen_mount} />
      <% else %>
        <%= if @missing in [:unmounted, :unreadable] do %>
          <div class="card" style="padding:16px;color:var(--muted)">
            <%= if @missing == :unreadable do %>
              The chart of accounts could not be read. Try again.
            <% else %>
              Capture needs the AP ledger and the chart of accounts on this workspace's mounted modules.
            <% end %>
          </div>
        <% else %>
          <div class="gtitle">
            <h3>{Erp.ap_capture_label()}</h3>
            <span class="lane">· paste or read a vendor invoice · duplicates checked before it becomes a bill</span>
          </div>

          <div
            :if={@notice}
            id="ap-capture-notice"
            class="card"
            style="padding:10px 14px;margin-bottom:10px;font-size:13px;color:var(--ok, #047857)"
          >
            {@notice}
            <a :if={@created} href={"/erp/ap_invoices/#{@created.id}?org=#{@org_id}"} style="margin-left:8px">
              Open the draft bill
            </a>
          </div>

          <div
            :if={@error}
            id="ap-capture-error"
            class="card form-error"
            style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px;margin-bottom:10px"
          >
            {@error}
          </div>

          <form id="ap-capture-form" phx-change="noop" phx-submit="capture">
            <div class="card" style="padding:14px 16px;margin-bottom:10px">
              <label for="capture-text" class="field-label" style="font-size:12px;font-weight:600">
                Invoice text
              </label>
              <textarea
                id="capture-text"
                name="text"
                rows="8"
                placeholder="Paste the vendor invoice text — number, dates, lines and total."
                style="width:100%;font-size:12px;font-family:ui-monospace,SFMono-Regular,Menlo,monospace;padding:8px"
              >{@text}</textarea>

              <div
                :if={assigns[:uploads]}
                style="margin-top:10px;font-size:12px;color:var(--muted);display:flex;gap:10px;align-items:center"
              >
                <span>or a document:</span>
                <%= live_file_input(assigns[:uploads].document) %>
              </div>

              <p
                :if={@ocr_configured && @ocr_budget.remaining != nil}
                id="ap-capture-ocr-budget"
                style="margin:8px 0 0;font-size:12px;color:var(--muted)"
              >
                Hosted OCR: {@ocr_budget.remaining} of {@ocr_budget.limit} documents left in this window.
              </p>

              <p
                :if={@ocr_configured && @ocr_budget.remaining != nil && @ocr_reset_in}
                id="ap-capture-ocr-reset"
                style="margin:4px 0 0;font-size:12px;color:var(--muted)"
              >
                Resets in {@ocr_reset_in}.
              </p>

              <p
                :if={@ocr_configured && @ocr_budget.remaining == nil}
                id="ap-capture-ocr-budget-unavailable"
                style="margin:8px 0 0;font-size:12px;color:var(--muted)"
              >
                Hosted OCR budget unavailable right now.
              </p>

              <p
                :if={assigns[:uploads] && not @ocr_configured}
                id="ap-capture-ocr-note"
                style="margin:8px 0 0;font-size:12px;color:var(--muted)"
              >
                PDFs and images need an OCR adapter on this host; pasted text works without one.
              </p>

              <div style="display:flex;justify-content:flex-end;margin-top:10px">
                <.button variant="primary" type="submit" id="capture-invoice">Read invoice</.button>
              </div>
            </div>
          </form>

          <div :if={@draft} id="ap-capture-review" class="card" style="padding:14px 16px">
            <div style="display:flex;justify-content:space-between;align-items:baseline;margin-bottom:8px">
              <div style="font-size:13px;font-weight:700">Review the capture</div>
              <span id="ap-capture-total" style="font-size:13px;font-weight:700">{money(@draft.total_cents)}</span>
            </div>

            <div
              :if={@existing}
              id="ap-capture-duplicate"
              style="padding:8px 10px;margin-bottom:10px;font-size:12px;color:var(--bad, #b91c1c);border:1px solid currentColor;border-radius:6px"
            >
              Invoice {@existing.number} is already on a bill ({@existing.status}). It cannot be captured twice.
            </div>

            <ul
              :if={@draft.warnings != []}
              id="ap-capture-warnings"
              style="margin:0 0 10px;padding-left:18px;font-size:12px;color:var(--warn, #b45309)"
            >
              <li :for={warning <- @draft.warnings}>{warning}</li>
            </ul>

            <form id="ap-capture-confirm" phx-submit="confirm">
              <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(190px,1fr));gap:10px;margin-bottom:10px">
                <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
                  Vendor id
                  <input
                    type="text"
                    name="vendor_id"
                    value={@vendor_id}
                    placeholder="Vendor uuid"
                    style="font-size:12px;padding:6px 8px;font-weight:400"
                  />
                </label>
                <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
                  Invoice number
                  <input
                    type="text"
                    name="number"
                    value={@number}
                    style="font-size:12px;padding:6px 8px;font-weight:400"
                  />
                </label>
                <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
                  Invoice date
                  <input
                    type="date"
                    name="invoice_date"
                    value={@invoice_date && Date.to_iso8601(@invoice_date)}
                    style="font-size:12px;padding:6px 8px;font-weight:400"
                  />
                </label>
                <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
                  Due date
                  <input
                    type="date"
                    name="due_date"
                    value={@due_date && Date.to_iso8601(@due_date)}
                    style="font-size:12px;padding:6px 8px;font-weight:400"
                  />
                </label>
                <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
                  Expense account
                  <select name="account_id" style="font-size:12px;padding:6px 8px;font-weight:400">
                    <option :for={account <- @accounts} value={account.id} selected={account.id == @account_id}>
                      {account.code} — {account.name}
                    </option>
                  </select>
                </label>
                <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
                  Memo
                  <input
                    type="text"
                    name="memo"
                    value={@memo}
                    placeholder="Optional"
                    style="font-size:12px;padding:6px 8px;font-weight:400"
                  />
                </label>
                <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
                  Match tolerance (cents)
                  <input
                    type="number"
                    name="match_tolerance_cents"
                    value="0"
                    min="0"
                    step="1"
                    style="font-size:12px;padding:6px 8px;font-weight:400"
                  />
                </label>
                <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
                  Match tolerance (%)
                  <input
                    type="number"
                    name="match_tolerance_pct"
                    value="0"
                    min="0"
                    max="100"
                    step="1"
                    style="font-size:12px;padding:6px 8px;font-weight:400"
                  />
                </label>
              </div>

              <table id="ap-capture-lines" style="width:100%;border-collapse:collapse;font-size:12px;margin-bottom:10px">
                <thead>
                  <tr>
                    <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Line</th>
                    <th scope="col" style="text-align:right;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Amount</th>
                    <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">PO line</th>
                    <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Receipt line</th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={{line, index} <- Enum.with_index(@draft.lines)}>
                    <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">{line.description}</td>
                    <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6);text-align:right">
                      {money(line.amount_cents)}
                    </td>
                    <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                      <input
                        type="text"
                        name={"line_po_line_id_#{index}"}
                        value={Map.get(line, :po_line_id, "")}
                        placeholder="Optional"
                        style="font-size:11px;padding:4px 6px;width:100%"
                      />
                    </td>
                    <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                      <input
                        type="text"
                        name={"line_receipt_line_id_#{index}"}
                        value={Map.get(line, :receipt_line_id, "")}
                        placeholder="Optional"
                        style="font-size:11px;padding:4px 6px;width:100%"
                      />
                    </td>
                  </tr>
                </tbody>
              </table>

              <div style="display:flex;gap:14px;align-items:center;justify-content:flex-end">
                <label
                  :if={@duplicates != []}
                  id="ap-capture-allow-duplicate"
                  style="display:flex;align-items:center;gap:6px;font-size:12px;color:var(--muted)"
                >
                  <input type="checkbox" name="allow_duplicate" value="1" />
                  Capture anyway
                </label>
                <button type="button" phx-click="discard" class="btn" style="font-size:12px">Discard</button>
                <button
                  type="submit"
                  id="confirm-capture"
                  class="btn primary"
                  disabled={@existing != nil}
                >
                  Capture draft bill
                </button>
              </div>
            </form>
          </div>
        <% end %>
      <% end %>
    </div>
    </div>
    """
  end
end
