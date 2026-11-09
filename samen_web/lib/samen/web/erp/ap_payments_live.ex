defmodule Samen.Web.Erp.ApPaymentsLive do
  @moduledoc """
  The AP payment run (`<erp>/ap-payments`) — select approved bills, run one
  payment batch, take the remittance advice.

  This page is a thin form over `Samen.Scopes.Finance.ApPaymentRun.pay/1`; the
  kernel owns every guarantee (same-vendor batch, still-approved bills, one
  repository transaction, exactly-once via the row lock, the posted payment
  entry). Nothing here posts by hand and no run header is persisted: the durable
  facts are the payment entries and each bill's `:paid` status.

  The read is the org's `:approved` bills, org-pinned through the mount's plane
  scope. `org_id` is the server-side fact; a client can only select among bills
  the org already owns. The page never offers a write on the operator plane
  (`Samen.Web.Erp.Live.writable?/1`) and the kernel refuses one regardless.

  The remittance advice is the run's CSV, handed to the browser as a download
  from the same render — there is no export route and no second read path. The
  ACH/EFT file is `Samen.Scopes.Finance.ApAchFile`, rendered from the posted run
  once the operator supplies the bank details the schema does not store
  (originator and vendor routing/account), and handed over the same way.

  Bills that look like the same vendor document entered twice are flagged on
  the list (vendor + total + bill date, `ApPaymentRun.duplicates/1`) and refuse
  the run unless the operator ticks "pay anyway".
  """

  use Samen.Web.Tenant.Live

  require Ash.Query

  import Samen.UI
  import Samen.Web.Erp.Live, only: [assign_mount: 2, erp_sidebar: 1, writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Scopes.Finance.{ApAchFile, ApPaymentRun}
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
       resource: nil,
       bills: [],
       selected_ids: [],
       duplicates: [],
       duplicate_ids: MapSet.new(),
       allow_duplicates: false,
       payment_date: Date.utc_today(),
       reference: "",
       memo: "",
       run: nil,
       csv: nil,
       ach: %{},
       ach_file: nil,
       ach_name: nil,
       ach_error: nil,
       error: nil,
       missing: nil
     )
     |> load()}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = CurrentOrg.reresolve(socket, params)

    {:noreply,
     socket
     |> assign(org_id: org_id, return_to: return_path(uri))
     |> load()}
  end

  @doc false
  def load(socket) do
    socket
    |> assign_new(:run, fn -> nil end)
    |> assign_new(:csv, fn -> nil end)
    |> assign_new(:ach, fn -> %{} end)
    |> assign_new(:ach_file, fn -> nil end)
    |> assign_new(:ach_name, fn -> nil end)
    |> assign_new(:ach_error, fn -> nil end)
    |> assign_new(:duplicates, fn -> [] end)
    |> assign_new(:duplicate_ids, fn -> MapSet.new() end)
    |> assign_new(:allow_duplicates, fn -> false end)
    |> assign_new(:error, fn -> nil end)
    |> assign_new(:selected_ids, fn -> [] end)
    |> assign_new(:payment_date, fn -> Date.utc_today() end)
    |> assign_new(:reference, fn -> "" end)
    |> assign_new(:memo, fn -> "" end)
    |> assign_new(:return_to, fn -> nil end)
    |> do_load()
  end

  defp do_load(%{assigns: %{org_id: nil}} = socket) do
    assign(socket,
      org_id: nil,
      missing: :no_org,
      resource: nil,
      bills: [],
      selected_ids: [],
      duplicates: [],
      duplicate_ids: MapSet.new()
    )
  end

  defp do_load(socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    case Erp.ap_invoice(mount) do
      nil ->
        assign(socket,
          missing: :unmounted,
          resource: nil,
          bills: [],
          selected_ids: [],
          duplicates: [],
          duplicate_ids: MapSet.new()
        )

      resource ->
        scope = TenantRole.authenticated_scope(mount, org_id)

        case read_approved(resource, org_id, scope) do
          {:ok, bills} ->
            duplicates = ApPaymentRun.duplicates(bills)

            assign(socket,
              resource: resource,
              bills: bills,
              duplicates: duplicates,
              duplicate_ids: duplicate_ids(duplicates),
              missing: nil
            )

          {:error, _reason} ->
            assign(socket,
              resource: resource,
              bills: [],
              selected_ids: [],
              duplicates: [],
              duplicate_ids: MapSet.new(),
              missing: :unreadable
            )
        end
    end
  end

  defp read_approved(resource, org_id, scope) do
    resource
    |> Ash.Query.filter(org_id == ^org_id and status == :approved)
    |> Ash.Query.sort(due_date: :asc)
    |> Ash.read(scope: scope)
  end

  # -- events -----------------------------------------------------------------

  # Selection is a UI convenience; the submit handler reads the same params
  # again, so nothing here is trusted as the write set.
  @impl true
  def handle_event("select", params, socket) do
    {:noreply,
     assign(socket,
       selected_ids: selected_ids(params),
       payment_date: parse_date(params["payment_date"]) || socket.assigns.payment_date,
       reference: params["reference"] || socket.assigns.reference,
       memo: params["memo"] || socket.assigns.memo,
       allow_duplicates: truthy(params["allow_duplicates"]),
       error: nil
     )}
  end

  def handle_event("ach", params, socket) do
    case socket.assigns.run do
      nil ->
        {:noreply, assign(socket, ach: params, ach_file: nil, ach_error: "Run a payment first.")}

      run ->
        opts = [
          originator_name: params["originator_name"],
          originator_id: params["originator_id"],
          originator_dfi: params["originator_dfi"],
          receiver_name: params["receiver_name"],
          receiver_account: params["receiver_account"],
          receiver_dfi: params["receiver_dfi"],
          account_type: account_type(params["account_type"]),
          effective_date: run.payment_date
        ]

        case ApAchFile.render(run, opts) do
          {:ok, file} ->
            {:noreply,
             assign(socket,
               ach: params,
               ach_file: file,
               ach_name: "ach-#{run.reference}.ach",
               ach_error: nil
             )}

          {:error, reason} ->
            {:noreply,
             assign(socket,
               ach: params,
               ach_file: nil,
               ach_name: nil,
               ach_error: ach_error(reason)
             )}
        end
    end
  end

  def handle_event("pay", params, socket) do
    %{samen_mount: mount, org_id: org_id, resource: resource} = socket.assigns
    selected = selected_ids(params)
    payment_date = parse_date(params["payment_date"])

    cond do
      not writable?(mount) ->
        {:noreply,
         assign(socket,
           error: "Payments are read-only on this plane.",
           selected_ids: selected
         )}

      resource == nil or org_id == nil ->
        {:noreply,
         assign(socket,
           error: "The AP ledger is not available on this workspace's mounted modules.",
           selected_ids: selected
         )}

      selected == [] ->
        {:noreply, assign(socket, error: "Select at least one approved bill.", selected_ids: [])}

      payment_date == nil ->
        {:noreply,
         assign(socket,
           error: "Choose a payment date.",
           selected_ids: selected,
           payment_date: socket.assigns.payment_date
         )}

      true ->
        {:noreply, run_payment(socket, selected, payment_date, params)}
    end
  end

  defp run_payment(socket, selected, payment_date, params) do
    %{samen_mount: mount, org_id: org_id, resource: resource} = socket.assigns
    scope = TenantRole.authenticated_scope(mount, org_id)

    case ApPaymentRun.pay(
           ap_invoice: resource,
           repo: mount.repo,
           scope: scope,
           bill_ids: selected,
           payment_date: payment_date,
           reference: blank_to_nil(params["reference"]),
           memo: blank_to_nil(params["memo"]),
           allow_duplicates: truthy(params["allow_duplicates"])
         ) do
      {:ok, run} ->
        socket
        |> assign(
          run: run,
          csv: ApPaymentRun.remittance_csv(run),
          ach: %{},
          ach_file: nil,
          ach_name: nil,
          ach_error: nil,
          error: nil,
          selected_ids: [],
          allow_duplicates: false,
          reference: "",
          memo: ""
        )
        |> load()

      {:error, reason} ->
        assign(socket,
          error: payment_error(reason, socket.assigns.bills),
          selected_ids: selected,
          allow_duplicates: truthy(params["allow_duplicates"])
        )
    end
  end

  # -- helpers ----------------------------------------------------------------

  # The run is ONE repository transaction, so every failure means nothing was
  # paid — the copy says so rather than leaving the reader to guess.
  defp payment_error({:not_approved, _id}),
    do: "One of the selected bills is no longer approved. Refresh and try again."

  defp payment_error(:mixed_vendors),
    do: "A payment run pays one vendor's bills. Select bills from a single vendor."

  defp payment_error(:bill_ids_required), do: "Select at least one approved bill."
  defp payment_error(:bill_ids_must_be_unique_uuids), do: "Select each bill once."

  defp payment_error({:bill_not_found, _id}),
    do: "One of the selected bills no longer exists. Refresh and try again."

  defp payment_error(:payment_date_required), do: "Choose a payment date."

  defp payment_error(_reason),
    do: "The payment run could not be completed. Nothing was paid."

  defp payment_error({:duplicate_bills, ids}, bills) do
    numbers =
      bills
      |> Enum.filter(&(&1.id in ids))
      |> Enum.map(& &1.number)
      |> Enum.sort()
      |> Enum.join(", ")

    "These bills look like duplicates of each other (#{numbers}). Tick \"Pay anyway\" to pay them as separate documents, or remove one from the run. Nothing was paid."
  end

  defp payment_error(reason, _bills), do: payment_error(reason)

  # -- ACH / EFT file ---------------------------------------------------------

  defp duplicate_ids(groups) do
    groups
    |> Enum.flat_map(fn %{bills: bills} -> bills end)
    |> MapSet.new(& &1.id)
  end

  defp truthy(value), do: value in [true, "1", "true", "on"]

  defp account_type("savings"), do: :savings
  defp account_type(_value), do: :checking

  defp ach_error(:originator_name_required), do: "Enter the originator's name."
  defp ach_error(:originator_id_required), do: "Enter the originator's company ID."

  defp ach_error(:originator_id_invalid),
    do: "The company ID must be up to 10 letters or digits."

  defp ach_error({:missing_routing, :originator_dfi}),
    do: "Enter the originator's 9-digit routing number."

  defp ach_error({:invalid_routing, :originator_dfi}),
    do: "The originator's routing number is not a valid ABA number."

  defp ach_error(:receiver_name_required), do: "Enter the vendor's bank account name."
  defp ach_error(:receiver_account_required), do: "Enter the vendor's account number."

  defp ach_error(:receiver_account_invalid),
    do: "The account number must be letters or digits only."

  defp ach_error(:receiver_account_too_long),
    do: "The account number is longer than the 17 characters an ACH entry can carry."

  defp ach_error({:missing_routing, :receiver_dfi}),
    do: "Enter the vendor's 9-digit routing number."

  defp ach_error({:invalid_routing, :receiver_dfi}),
    do: "The vendor's routing number is not a valid ABA number."

  defp ach_error({:invalid_account_type, _value}), do: "Choose checking or savings."
  defp ach_error(:no_payments), do: "The run has no payments to send."
  defp ach_error(:effective_date_required), do: "The run has no effective date."

  defp ach_error(_reason),
    do: "The ACH file could not be built. Check the bank details."

  defp selected_ids(params) do
    params
    |> Map.get("bill_ids", [])
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp selected_total(bills, ids) do
    bills
    |> Enum.filter(&(&1.id in ids))
    |> Enum.reduce(0, fn bill, sum -> sum + bill_total(bill) end)
  end

  defp bill_total(bill) do
    bill.lines
    |> List.wrap()
    |> Enum.reduce(0, fn line, sum ->
      sum + (Map.get(line, :amount_cents) || Map.get(line, "amount_cents") || 0)
    end)
  end

  defp parse_date(%Date{} = date), do: date

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> date
      _other -> nil
    end
  end

  defp parse_date(_value), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(_value), do: nil

  defp short(nil), do: "—"
  defp short(id) when is_binary(id), do: String.slice(id, 0, 8)
  defp short(other), do: to_string(other)

  defp money(nil), do: "—"

  defp money(cents) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    cents = abs(cents)

    "#{sign}$#{div(cents, 100)}.#{cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp money(other), do: to_string(other)

  defp crumbs(mount, org_id) do
    [Crumbs.org(mount, org_id), "ERP", Erp.ap_payments_label()]
  end

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
    <div id="erp-ap-payments">
    <.topbar
      title={Erp.ap_payments_label()}
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
              The approved bills could not be read. Try again.
            <% else %>
              The AP ledger is not available on this workspace's mounted modules.
            <% end %>
          </div>
        <% else %>
          <div class="gtitle">
            <h3>{Erp.ap_payments_label()}</h3>
            <span class="n">{length(@bills)}</span>
            <span class="lane">· approved bills · one vendor per run · posted on payment</span>
          </div>

          <div
            :if={@error}
            id="ap-payment-error"
            class="card form-error"
            style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px;margin-bottom:10px"
          >
            {@error}
          </div>

          <div
            :if={@run}
            id="ap-payment-result"
            class="card"
            style="padding:14px 16px;margin-bottom:10px"
          >
            <div style="font-size:13px;font-weight:700;color:var(--ok, #047857);margin-bottom:4px">
              Payment run posted
            </div>
            <div style="font-size:13px;margin-bottom:6px">
              Reference <code>{@run.reference}</code> ·
              {length(@run.payments)} bills ·
              {money(@run.total_cents)}
            </div>
            <a
              :if={@csv}
              id="download-remittance"
              download={"remittance-#{@run.reference}.csv"}
              href={"data:text/csv;base64," <> Base.encode64(@csv)}
              style="font-size:13px"
            >
              Download remittance CSV
            </a>
          </div>

          <div
            :if={@run}
            id="ach-file-card"
            class="card"
            style="padding:14px 16px;margin-bottom:10px"
          >
            <div style="font-size:13px;font-weight:700;margin-bottom:2px">
              ACH / EFT payment file
            </div>
            <p style="margin:0 0 10px;font-size:12px;color:var(--muted)">
              A NACHA CCD credit file for this run. Bank details are not stored on the bill — enter them for this file.
            </p>

            <form id="ach-file-form" phx-submit="ach">
              <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(180px,1fr));gap:10px;margin-bottom:10px">
                <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
                  Originator name
                  <input
                    type="text"
                    name="originator_name"
                    value={@ach["originator_name"]}
                    style="font-size:12px;padding:6px 8px;font-weight:400"
                  />
                </label>
                <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
                  Company ID
                  <input
                    type="text"
                    name="originator_id"
                    value={@ach["originator_id"]}
                    placeholder="Up to 10 letters or digits"
                    style="font-size:12px;padding:6px 8px;font-weight:400"
                  />
                </label>
                <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
                  Originator routing
                  <input
                    type="text"
                    name="originator_dfi"
                    value={@ach["originator_dfi"]}
                    placeholder="9 digits"
                    style="font-size:12px;padding:6px 8px;font-weight:400"
                  />
                </label>
                <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
                  Vendor account name
                  <input
                    type="text"
                    name="receiver_name"
                    value={@ach["receiver_name"]}
                    style="font-size:12px;padding:6px 8px;font-weight:400"
                  />
                </label>
                <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
                  Vendor account number
                  <input
                    type="text"
                    name="receiver_account"
                    value={@ach["receiver_account"]}
                    style="font-size:12px;padding:6px 8px;font-weight:400"
                  />
                </label>
                <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
                  Vendor routing
                  <input
                    type="text"
                    name="receiver_dfi"
                    value={@ach["receiver_dfi"]}
                    placeholder="9 digits"
                    style="font-size:12px;padding:6px 8px;font-weight:400"
                  />
                </label>
                <label style="display:flex;flex-direction:column;gap:4px;font-size:12px;font-weight:600">
                  Account type
                  <select name="account_type" style="font-size:12px;padding:6px 8px;font-weight:400">
                    <option value="checking" selected={@ach["account_type"] in [nil, "checking"]}>
                      Checking
                    </option>
                    <option value="savings" selected={@ach["account_type"] == "savings"}>
                      Savings
                    </option>
                  </select>
                </label>
              </div>

              <div
                :if={@ach_error}
                id="ach-file-error"
                style="color:var(--bad, #b91c1c);font-size:12px;margin-bottom:8px"
              >
                {@ach_error}
              </div>

              <div style="display:flex;gap:12px;align-items:center;justify-content:flex-end">
                <a
                  :if={@ach_file}
                  id="download-ach"
                  download={@ach_name}
                  href={"data:application/octet-stream;base64," <> Base.encode64(@ach_file)}
                  style="font-size:13px"
                >
                  Download ACH file
                </a>
                <.button type="submit" id="build-ach">Build ACH file</.button>
              </div>
            </form>
          </div>

          <form id="ap-payment-run" phx-change="select" phx-submit="pay">
            <div
              class="card"
              style="padding:12px 16px;margin-bottom:10px;display:flex;gap:10px;flex-wrap:wrap;align-items:end"
            >
              <div style="display:flex;flex-direction:column;gap:4px">
                <label for="payment-date" class="field-label" style="font-size:12px;font-weight:600">
                  Payment date
                </label>
                <input
                  type="date"
                  id="payment-date"
                  name="payment_date"
                  value={Date.to_iso8601(@payment_date)}
                  style="font-size:12px;padding:6px 8px"
                />
              </div>
              <div style="display:flex;flex-direction:column;gap:4px;flex:1;min-width:180px">
                <label for="payment-reference" class="field-label" style="font-size:12px;font-weight:600">
                  Remittance reference
                </label>
                <input
                  type="text"
                  id="payment-reference"
                  name="reference"
                  value={@reference}
                  placeholder="Optional — generated when blank"
                  style="font-size:12px;padding:6px 8px"
                />
              </div>
              <div style="display:flex;flex-direction:column;gap:4px;flex:1;min-width:180px">
                <label for="payment-memo" class="field-label" style="font-size:12px;font-weight:600">
                  Memo
                </label>
                <input
                  type="text"
                  id="payment-memo"
                  name="memo"
                  value={@memo}
                  placeholder="Optional note on every payment entry"
                  style="font-size:12px;padding:6px 8px"
                />
              </div>
            </div>

            <table style="width:100%;border-collapse:collapse;font-size:13px">
              <thead>
                <tr>
                  <th scope="col" style="width:28px;text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)"></th>
                  <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Bill</th>
                  <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Vendor</th>
                  <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Due</th>
                  <th scope="col" style="text-align:right;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Amount</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={bill <- @bills} id={"ap-bill-#{bill.id}"}>
                  <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                    <input
                      type="checkbox"
                      name="bill_ids[]"
                      value={bill.id}
                      checked={bill.id in @selected_ids}
                      aria-label={"Select bill #{bill.number}"}
                    />
                  </td>
                  <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                    <a
                      href={"/erp/ap_invoices/#{bill.id}?org=#{@org_id}"}
                      style="color:inherit;text-decoration:underline;text-underline-offset:2px"
                    >
                      {bill.number}
                    </a>
                    <span
                      :if={MapSet.member?(@duplicate_ids, bill.id)}
                      id={"ap-bill-duplicate-#{bill.id}"}
                      style="margin-left:6px;font-size:10px;font-weight:700;text-transform:uppercase;letter-spacing:.04em;color:var(--warn, #b45309);border:1px solid currentColor;border-radius:999px;padding:1px 6px"
                    >
                      possible duplicate
                    </span>
                  </td>
                  <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                    {short(bill.vendor_id)}
                  </td>
                  <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                    {if bill.due_date, do: Date.to_iso8601(bill.due_date), else: "—"}
                  </td>
                  <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6);text-align:right">
                    {money(bill_total(bill))}
                  </td>
                </tr>

                <tr :if={@bills == []}>
                  <td colspan="5" style="padding:16px 8px;color:var(--muted)">
                    No approved bills are waiting for payment.
                  </td>
                </tr>
              </tbody>
            </table>

            <div
              style="display:flex;gap:14px;align-items:center;justify-content:flex-end;padding:10px 8px"
            >
              <span id="ap-payment-selection" style="font-size:12px;color:var(--muted)">
                {length(@selected_ids)} selected · {money(selected_total(@bills, @selected_ids))}
              </span>
              <label
                id="ap-payment-allow-duplicates"
                title="Pay bills flagged as possible duplicates — only when they are separate documents"
                style="display:flex;align-items:center;gap:6px;font-size:12px;color:var(--muted)"
              >
                <input
                  type="checkbox"
                  name="allow_duplicates"
                  value="1"
                  checked={@allow_duplicates}
                />
                Pay anyway
              </label>
              <.button variant="primary" type="submit" id="run-payment">
                Run payment
              </.button>
            </div>
          </form>

          <%= if not writable?(@samen_mount) do %>
            <p id="ap-payment-read-only" style="margin:8px 0 0;font-size:12px;color:var(--muted)">
              Read-only on this plane.
            </p>
          <% end %>
        <% end %>
      <% end %>
    </div>
    </div>
    """
  end
end
