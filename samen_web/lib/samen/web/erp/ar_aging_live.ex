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

  Delivery and collections write only Finance audit/workflow records: a
  statement send goes through `Samen.Delivery.Chokepoint`, and a collection
  action appends one timeline event. Neither posts a journal entry. Writes are
  offered on the tenant plane only.

  `org_id` is the server-side fact and the scope is the mount plane's, so an
  operator-plane mount reads masked and every caller is pinned to its own org.
  """

  use Samen.Web.Tenant.Live

  require Ash.Query

  import Samen.UI
  import Samen.Web.Erp.Live, only: [assign_mount: 2, erp_sidebar: 1, writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Scopes.Finance.ArAging
  alias Samen.Scopes.Finance.ArCollections
  alias Samen.Scopes.Finance.ArStatementDelivery
  alias Samen.Scopes.Finance.CollectionCadence, as: CadenceSettings
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
       statement_deliveries: [],
       collection_cases: [],
       cadence: nil,
       work_notice: nil,
       work_error: nil,
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
    |> assign_new(:statement_deliveries, fn -> [] end)
    |> assign_new(:collection_cases, fn -> [] end)
    |> assign_new(:cadence, fn -> CadenceSettings.defaults() end)
    |> assign_new(:work_notice, fn -> nil end)
    |> assign_new(:work_error, fn -> nil end)
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
      statement_deliveries: [],
      collection_cases: [],
      cadence: CadenceSettings.defaults(),
      work_notice: nil,
      work_error: nil
    )
  end

  defp do_load(socket) do
    %{samen_mount: mount, org_id: org_id, as_of: as_of} = socket.assigns

    with invoice when not is_nil(invoice) <- Erp.billing_invoice(mount),
         receipt when not is_nil(receipt) <- Erp.payment_receipt(mount) do
      scope = TenantRole.authenticated_scope(mount, org_id)
      cadence = effective_cadence(mount, org_id)

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
            cadence: cadence,
            missing: nil
          )

        {:error, _reason} ->
          assign(socket, aging: nil, customers: [], cadence: cadence, missing: :unreadable)
      end
    else
      _not_mounted ->
        assign(socket,
          aging: nil,
          customers: [],
          cadence: CadenceSettings.defaults(),
          missing: :unmounted
        )
    end
  end

  defp effective_cadence(mount, org_id) do
    case Erp.collection_cadence(mount) do
      nil ->
        CadenceSettings.defaults()

      resource ->
        resource
        |> Ash.Query.filter(org_id == ^org_id)
        |> Ash.Query.limit(1)
        |> Ash.read_one(scope: TenantRole.authenticated_scope(mount, org_id))
        |> case do
          {:ok, nil} -> CadenceSettings.defaults()
          {:ok, cadence} -> cadence
          {:error, _reason} -> CadenceSettings.defaults()
        end
    end
  end

  defp cadence_rows(cadence) do
    [
      {:notice, "Notice", cadence.notice_enabled, cadence.notice_days},
      {:final_notice, "Final notice", cadence.final_notice_enabled, cadence.final_notice_days},
      {:collections, "Collections", cadence.collections_enabled, cadence.collections_days}
    ]
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
         |> assign(
           as_of: date,
           statement: nil,
           statement_error: nil,
           statement_deliveries: [],
           collection_cases: [],
           work_notice: nil,
           work_error: nil
         )
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
           statement_error: "Choose a customer.",
           statement_deliveries: [],
           collection_cases: [],
           work_notice: nil,
           work_error: nil
         )}

      org_id == nil ->
        {:noreply, assign(socket, statement: nil, statement_error: "No workspace selected.")}

      true ->
        {:noreply, read_statement(socket, mount, org_id, customer_id, as_of)}
    end
  end

  def handle_event("send_statement", %{"currency" => currency}, socket) do
    %{samen_mount: mount, org_id: org_id, selected_customer: customer_id, statement: statement} =
      socket.assigns

    cond do
      not writable?(mount) ->
        {:noreply,
         assign(socket,
           work_error: "Statement delivery is read-only on this plane.",
           work_notice: nil
         )}

      org_id == nil ->
        {:noreply, assign(socket, work_error: "No workspace selected.", work_notice: nil)}

      is_nil(Erp.statement_delivery(mount)) ->
        {:noreply,
         assign(socket, work_error: "Statement delivery is not mounted.", work_notice: nil)}

      is_nil(statement) or customer_id in [nil, ""] ->
        {:noreply,
         assign(socket, work_error: "Open the customer statement first.", work_notice: nil)}

      true ->
        {:noreply, send_statement(socket, mount, org_id, customer_id, currency)}
    end
  end

  def handle_event("open_collection_case", params, socket) do
    %{samen_mount: mount, org_id: org_id, selected_customer: customer_id, statement: statement} =
      socket.assigns

    cond do
      not writable?(mount) ->
        {:noreply,
         assign(socket, work_error: "Collections are read-only on this plane.", work_notice: nil)}

      org_id == nil ->
        {:noreply, assign(socket, work_error: "No workspace selected.", work_notice: nil)}

      is_nil(Erp.collection_case(mount)) ->
        {:noreply, assign(socket, work_error: "Collections are not mounted.", work_notice: nil)}

      is_nil(statement) or customer_id in [nil, ""] ->
        {:noreply,
         assign(socket, work_error: "Open the customer statement first.", work_notice: nil)}

      true ->
        {:noreply,
         open_collection_case(
           socket,
           mount,
           org_id,
           customer_id,
           params["currency"],
           params["notes"]
         )}
    end
  end

  def handle_event("collection_action", params, socket) do
    %{samen_mount: mount, org_id: org_id, selected_customer: customer_id} = socket.assigns

    with true <- writable?(mount),
         false <- is_nil(Erp.collection_case(mount)),
         {:ok, kind} <- collection_kind(params["kind"]),
         {:ok, promise_on} <- parse_optional_date(params["promise_to_pay_on"]),
         {:ok, promised_cents} <- parse_optional_cents(params["promised_cents"]) do
      case ArCollections.record_action(
             collection_case: Erp.collection_case(mount),
             case_id: params["case_id"],
             kind: kind,
             note: params["note"],
             promise_to_pay_on: promise_on,
             promised_cents: promised_cents,
             org_id: org_id,
             scope: TenantRole.authenticated_scope(mount, org_id)
           ) do
        {:ok, collection_case} ->
          socket =
            socket
            |> assign(
              work_error: nil,
              work_notice: "Collection action logged: #{stage_text(collection_case.stage)}."
            )
            |> load_customer_work(mount, org_id, customer_id)

          {:noreply, socket}

        {:error, reason} ->
          {:noreply,
           socket
           |> assign(work_error: collection_error(reason), work_notice: nil)
           |> load_customer_work(mount, org_id, customer_id)}
      end
    else
      false ->
        {:noreply,
         assign(socket, work_error: "Collections are read-only on this plane.", work_notice: nil)}

      true ->
        {:noreply, assign(socket, work_error: "Collections are not mounted.", work_notice: nil)}

      {:error, message} ->
        {:noreply, assign(socket, work_error: message, work_notice: nil)}
    end
  end

  defp send_statement(socket, mount, org_id, customer_id, currency) do
    case ArStatementDelivery.deliver(
           statement_delivery: Erp.statement_delivery(mount),
           invoice: Erp.billing_invoice(mount),
           receipt: Erp.payment_receipt(mount),
           receipt_allocation: Erp.receipt_allocation(mount),
           credit_note: Erp.credit_note(mount),
           org_id: org_id,
           scope: TenantRole.authenticated_scope(mount, org_id),
           customer_id: customer_id,
           as_of: socket.assigns.as_of,
           currency: blank_to_nil(currency)
         ) do
      {:ok, delivery} ->
        socket
        |> assign(work_error: nil, work_notice: delivery_notice(delivery))
        |> load_customer_work(mount, org_id, customer_id)

      {:error, reason} ->
        socket
        |> assign(work_error: delivery_error(reason), work_notice: nil)
        |> load_customer_work(mount, org_id, customer_id)
    end
  end

  defp open_collection_case(socket, mount, org_id, customer_id, currency, notes) do
    case ArCollections.open_case(
           collection_case: Erp.collection_case(mount),
           invoice: Erp.billing_invoice(mount),
           receipt: Erp.payment_receipt(mount),
           receipt_allocation: Erp.receipt_allocation(mount),
           credit_note: Erp.credit_note(mount),
           org_id: org_id,
           scope: TenantRole.authenticated_scope(mount, org_id),
           customer_id: customer_id,
           as_of: socket.assigns.as_of,
           currency: blank_to_nil(currency),
           notes: notes
         ) do
      {:ok, collection_case} ->
        socket
        |> assign(
          work_error: nil,
          work_notice: "Collection case opened at #{stage_text(collection_case.stage)}."
        )
        |> load_customer_work(mount, org_id, customer_id)

      {:error, reason} ->
        socket
        |> assign(work_error: collection_error(reason), work_notice: nil)
        |> load_customer_work(mount, org_id, customer_id)
    end
  end

  # -- helpers ----------------------------------------------------------------

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
        socket
        |> assign(
          statement: statement,
          selected_customer: customer_id,
          statement_error: nil,
          work_notice: nil,
          work_error: nil
        )
        |> load_customer_work(mount, org_id, customer_id)

      {:error, _reason} ->
        assign(socket,
          statement: nil,
          selected_customer: customer_id,
          statement_error: "The statement could not be read. Try again.",
          statement_deliveries: [],
          collection_cases: [],
          work_error: nil,
          work_notice: nil
        )
    end
  end

  defp load_customer_work(socket, mount, org_id, customer_id) do
    scope = TenantRole.authenticated_scope(mount, org_id)

    assign(socket,
      statement_deliveries:
        customer_rows(Erp.statement_delivery(mount), org_id, scope, customer_id),
      collection_cases: customer_rows(Erp.collection_case(mount), org_id, scope, customer_id)
    )
  end

  defp customer_rows(nil, _org_id, _scope, _customer_id), do: []

  defp customer_rows(resource, org_id, scope, customer_id) do
    resource
    |> Ash.Query.filter(org_id == ^org_id and customer_id == ^customer_id)
    |> Ash.Query.ensure_selected([:inserted_at, :updated_at])
    |> Ash.Query.sort(inserted_at: :desc)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, rows} -> rows
      {:error, _reason} -> []
    end
  end

  defp collection_kind(value) when is_binary(value) do
    Enum.find_value(ArCollections.kinds(), {:error, "Choose a collection action."}, fn kind ->
      if Atom.to_string(kind) == value, do: {:ok, kind}
    end)
  end

  defp collection_kind(_value), do: {:error, "Choose a collection action."}

  defp parse_optional_date(nil), do: {:ok, nil}
  defp parse_optional_date(""), do: {:ok, nil}
  defp parse_optional_date(%Date{} = date), do: {:ok, date}

  defp parse_optional_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      {:error, _reason} -> {:error, "Choose a valid promise date."}
    end
  end

  defp parse_optional_date(_value), do: {:error, "Choose a valid promise date."}

  defp parse_optional_cents(nil), do: {:ok, nil}
  defp parse_optional_cents(""), do: {:ok, nil}
  defp parse_optional_cents(cents) when is_integer(cents) and cents > 0, do: {:ok, cents}

  defp parse_optional_cents(value) when is_binary(value) do
    case Integer.parse(String.trim(value)) do
      {cents, ""} when cents > 0 -> {:ok, cents}
      _other -> {:error, "Enter a positive promised amount in cents."}
    end
  end

  defp parse_optional_cents(_value), do: {:error, "Enter a positive promised amount in cents."}

  defp delivery_notice(%{status: :sent}), do: "Statement sent."
  defp delivery_notice(%{status: :captured}), do: "Statement captured by the delivery sink."
  defp delivery_notice(%{status: status}), do: "Statement delivery #{status}."

  defp delivery_error(:adapter_unconfigured),
    do: "Statement delivery is not configured for this workspace."

  defp delivery_error(:suppressed), do: "The customer is suppressed from delivery."
  defp delivery_error(:currency_required), do: "Choose a statement currency."
  defp delivery_error(:unknown_currency), do: "That currency is not on the statement."
  defp delivery_error(:nothing_to_deliver), do: "There is no statement to deliver."

  defp delivery_error({:audit_failed, _reason}),
    do: "The statement sent but its audit row failed."

  defp delivery_error(_reason), do: "The statement could not be sent. Try again."

  defp collection_error(:active_case_exists),
    do: "An active case already covers this customer/currency."

  defp collection_error(:nothing_outstanding),
    do: "There is no positive outstanding balance to collect."

  defp collection_error(:currency_required), do: "Choose a currency for the collection case."
  defp collection_error(:case_resolved), do: "This collection case is resolved."
  defp collection_error(:timeline_full), do: "This case's action timeline is full."
  defp collection_error(:note_required), do: "Enter a note."
  defp collection_error(:promise_required), do: "Enter a promise date or amount."
  defp collection_error(:invalid_promised_cents), do: "Enter a positive promised amount."
  defp collection_error(:title_too_long), do: "That note is too long."
  defp collection_error(:note_too_long), do: "That note is too long."
  defp collection_error(_reason), do: "The collection action could not be saved."

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp blank_to_nil(value), do: value

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

  defp stage_text(:reminder), do: "Reminder"
  defp stage_text(:notice), do: "Notice"
  defp stage_text(:final_notice), do: "Final notice"
  defp stage_text(:collections), do: "Collections"
  defp stage_text(other), do: to_string(other)

  defp status_text(:open), do: "Open"
  defp status_text(:paused), do: "Paused"
  defp status_text(:resolved), do: "Resolved"
  defp status_text(:sent), do: "Sent"
  defp status_text(:captured), do: "Captured"
  defp status_text(:blocked), do: "Blocked"
  defp status_text(:suppressed), do: "Suppressed"
  defp status_text(:failed), do: "Failed"
  defp status_text(:queued), do: "Queued"
  defp status_text(other), do: to_string(other)

  defp collection_events(%{actions: actions}) when is_map(actions) do
    case Map.get(actions, "events") do
      events when is_list(events) -> events
      _other -> []
    end
  end

  defp collection_events(_collection_case), do: []

  defp collection_actions(:paused), do: [note: "Note", resume: "Resume", resolve: "Resolve"]
  defp collection_actions(_status), do: Erp.collection_actions()

  defp date_text(nil), do: "—"
  defp date_text(%Date{} = date), do: Date.to_iso8601(date)
  defp date_text(other), do: to_string(other)

  defp event_next_action_text(%{"next_action_on" => next} = event)
       when is_binary(next) and next != "" do
    with {:ok, at, _offset} <- DateTime.from_iso8601(event["at"] || ""),
         {:ok, next_on} <- Date.from_iso8601(next) do
      "next action #{next} (#{Date.diff(next_on, DateTime.to_date(at))}d)"
    else
      _other -> "next action #{next}"
    end
  end

  defp event_next_action_text(_event), do: nil

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

              <div
                :if={@work_notice}
                id="ar-work-notice"
                style="font-size:12px;color:var(--good, #047857);margin-top:10px"
              >
                {@work_notice}
              </div>

              <div
                :if={@work_error}
                id="ar-work-error"
                style="font-size:12px;color:var(--bad, #b91c1c);margin-top:10px"
              >
                {@work_error}
              </div>

              <div
                id="statement-delivery-panel"
                class="card"
                style="padding:12px;margin-top:12px;border:1px solid var(--border, #e5e7eb)"
              >
                <div style="font-size:12px;font-weight:700;margin-bottom:8px">Statement delivery</div>

                <form
                  :if={writable?(@samen_mount)}
                  id="send-statement-form"
                  phx-submit="send_statement"
                  style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-bottom:8px"
                >
                  <select name="currency" id="statement-currency" style="font-size:12px;padding:6px 8px">
                    <option :for={currency <- @statement.currencies} value={currency}>{currency}</option>
                  </select>
                  <.button type="submit" id="send-statement-button">Send statement</.button>
                </form>

                <table
                  :if={@statement_deliveries != []}
                  id="statement-deliveries"
                  style="width:100%;border-collapse:collapse;font-size:12px"
                >
                  <thead>
                    <tr>
                      <th scope="col" style="text-align:left;padding:4px 6px;color:var(--muted)">Attempted</th>
                      <th scope="col" style="text-align:left;padding:4px 6px;color:var(--muted)">Status</th>
                      <th scope="col" style="text-align:left;padding:4px 6px;color:var(--muted)">Currency</th>
                      <th scope="col" style="text-align:right;padding:4px 6px;color:var(--muted)">Outstanding</th>
                      <th scope="col" style="text-align:left;padding:4px 6px;color:var(--muted)">Provider ref</th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={delivery <- @statement_deliveries} id={"statement-delivery-#{delivery.id}"}>
                      <td style="padding:4px 6px">{date_text(date_of(delivery.inserted_at))}</td>
                      <td style="padding:4px 6px">{status_text(delivery.status)}</td>
                      <td style="padding:4px 6px">{delivery.currency}</td>
                      <td style="padding:4px 6px;text-align:right">{money(delivery.outstanding_cents)}</td>
                      <td style="padding:4px 6px">{delivery.provider_message_id || "—"}</td>
                    </tr>
                  </tbody>
                </table>

                <div
                  :if={@statement_deliveries == []}
                  id="statement-deliveries-empty"
                  style="font-size:12px;color:var(--muted)"
                >
                  No statement delivery attempts yet.
                </div>
              </div>

              <div
                id="collections-panel"
                class="card"
                style="padding:12px;margin-top:12px;border:1px solid var(--border, #e5e7eb)"
              >
                <div
                  style="display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap;margin-bottom:8px"
                >
                  <div style="font-size:12px;font-weight:700">Collections</div>
                  <a
                    id="ar-cadence-settings-link"
                    href={"#{Samen.Web.Mount.label(@samen_mount, :erp_path, "/erp")}/ar-settings?org=#{@org_id}"}
                    style="font-size:12px"
                  >
                    Cadence settings
                  </a>
                </div>

                <div
                  id="ar-cadence-summary"
                  style="padding:8px 10px;margin-bottom:10px;background:var(--surface-2, #f9fafb);border-radius:6px"
                >
                  <div style="font-size:11px;font-weight:700;color:var(--muted);margin-bottom:4px">
                    Scheduled dunning
                  </div>
                  <div style="display:flex;gap:12px;flex-wrap:wrap;font-size:12px">
                    <span :for={{key, label, enabled, days} <- cadence_rows(@cadence)} id={"ar-cadence-#{key}"}>
                      <b>{label}:</b>
                      {if enabled, do: "every #{days} days", else: "disabled"}
                    </span>
                  </div>
                </div>

                <%= if not Enum.any?(@collection_cases, &(&1.status != :resolved)) do %>
                  <form
                    :if={writable?(@samen_mount)}
                    id="open-collection-case"
                    phx-submit="open_collection_case"
                    style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-bottom:8px"
                  >
                    <select name="currency" id="collection-currency" style="font-size:12px;padding:6px 8px">
                      <option :for={currency <- @statement.currencies} value={currency}>{currency}</option>
                    </select>
                    <input
                      type="text"
                      name="notes"
                      id="collection-notes"
                      placeholder="Opening note (optional)"
                      style="font-size:12px;padding:6px 8px;min-width:200px"
                    />
                    <.button type="submit" id="open-collection-case-button">Open collection case</.button>
                  </form>
                  <div
                    :if={@collection_cases == []}
                    style="font-size:12px;color:var(--muted)"
                  >
                    No collection case for this customer.
                  </div>
                <% end %>

                <div
                  :for={collection_case <- @collection_cases}
                    id={"collection-case-#{collection_case.id}"}
                    style="padding:10px 0;border-top:1px solid var(--border, #f3f4f6)"
                  >
                    <div style="display:flex;gap:12px;align-items:center;flex-wrap:wrap;font-size:12px">
                      <b>{collection_case.currency}</b>
                      <span>Status: <b>{status_text(collection_case.status)}</b></span>
                      <span>Stage: <b>{stage_text(collection_case.stage)}</b></span>
                      <span>Outstanding: <b>{money(collection_case.outstanding_cents)}</b></span>
                      <span :if={collection_case.next_action_on}>Next: {date_text(collection_case.next_action_on)}</span>
                      <span :if={collection_case.promise_to_pay_on}>
                        Promise: {date_text(collection_case.promise_to_pay_on)}
                        <span :if={collection_case.promised_cents}>({money(collection_case.promised_cents)})</span>
                      </span>
                    </div>

                    <div :if={collection_events(collection_case) != []} style="margin-top:6px;font-size:12px">
                      <div
                        :for={event <- collection_events(collection_case)}
                        style="color:var(--muted);padding:2px 0"
                      >
                        <b>{event["kind"]}</b>
                        <span> · {event["at"]}</span>
                        <span :if={event_next_action_text(event)}>
                          · {event_next_action_text(event)}
                        </span>
                        <span :if={event["note"]}> · {event["note"]}</span>
                      </div>
                    </div>

                    <form
                      :if={writable?(@samen_mount) and collection_case.status != :resolved}
                      id={"collection-action-form-#{collection_case.id}"}
                      phx-submit="collection_action"
                      style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;margin-top:8px"
                    >
                      <input type="hidden" name="case_id" value={collection_case.id} />
                      <select
                        name="kind"
                        id={"collection-action-kind-#{collection_case.id}"}
                        style="font-size:12px;padding:6px 8px"
                      >
                        <option :for={{kind, label} <- collection_actions(collection_case.status)} value={kind}>
                          {label}
                        </option>
                      </select>
                      <input
                        type="text"
                        name="note"
                        id={"collection-action-note-#{collection_case.id}"}
                        placeholder="Note"
                        style="font-size:12px;padding:6px 8px;min-width:180px"
                      />
                      <input
                        type="date"
                        name="promise_to_pay_on"
                        id={"collection-action-promise-date-#{collection_case.id}"}
                        style="font-size:12px;padding:5px 7px"
                      />
                      <input
                        type="number"
                        name="promised_cents"
                        id={"collection-action-promised-cents-#{collection_case.id}"}
                        min="1"
                        placeholder="Promised cents"
                        style="font-size:12px;padding:6px 8px;width:130px"
                      />
                      <.button type="submit" id={"log-collection-action-#{collection_case.id}"}>
                        Log action
                      </.button>
                    </form>
                </div>
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
