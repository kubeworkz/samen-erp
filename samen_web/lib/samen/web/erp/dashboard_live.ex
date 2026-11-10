defmodule Samen.Web.Erp.DashboardLive do
  @moduledoc """
  The ERP landing dashboard (`<erp>`).

  A READ-ONLY overview: the hosted-OCR budget and one-click routes into the ERP
  pages. The budget is the lead fact because an exhausted budget is a dead end
  for PDF/image capture — surfacing it here means an operator learns before they
  reach the uploader, not after a refused document.

  The budget is read through `Samen.Web.Erp.OcrQuota.budget/2`; rendering this
  page never consumes it. Every state is named honestly:

    * available — remaining out of the configured limit in the current window;
    * exhausted — `0` left, hosted OCR is paused until the window resets, with
      the free paste path called out;
    * unreadable — the durable counter cannot be read, so documents cannot be
      read either (no implied fresh allowance);
    * no adapter — hosted OCR is not configured on this host; pasted text is
      unaffected.

  ## Live refresh

  The budget is shared, so another session (or another tab) can spend it while
  this page is open. On a connected mount the page subscribes to the org's
  `Samen.Web.Erp.OcrQuota.PubSub` topic; an allowed charge publishes an id-only
  `{:ocr_quota_changed, org_id}`, and the page re-reads the budget through its
  own mount. The message never carries a pushed count, and without a running
  PubSub server the page still renders — it just refreshes on navigation.

  The clock is scheduled too: on a connected mount the page asks the database
  clock how long the current window has left, refreshes once a minute (so the
  "Resets in 42m" label keeps counting down), and re-reads promptly after the
  boundary — so an exhausted card does not outlive the window that caused it.
  The timer is replaced when the page switches orgs.

  The page performs no writes and has no export path. Its route is mounted only
  by `samen_erp_routes/3`, so a host that never mounts ERP never links it.
  """

  use Samen.Web.Tenant.Live

  import Samen.Web.Erp.Live, only: [assign_mount: 2, erp_sidebar: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Scopes.Finance.InvoiceOcr
  alias Samen.Web.Crumbs
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Erp
  alias Samen.Web.Erp.OcrQuota
  alias Samen.Web.Erp.OcrQuota.PubSub, as: OcrQuotaPubSub
  alias Samen.Web.Mount

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)

    {:ok,
     socket
     |> assign(
       org_id: org_id,
       return_to: nil,
       ocr_configured: InvoiceOcr.configured?(),
       ocr_budget: budget(socket, org_id)
     )
     |> subscribe(org_id)
     |> schedule_window_refresh(org_id)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = CurrentOrg.reresolve(socket, params)

    {:noreply,
     socket
     |> resubscribe(org_id)
     |> assign(
       org_id: org_id,
       return_to: return_path(uri),
       ocr_budget: budget(socket, org_id)
     )}
  end

  @impl true
  def handle_info(:ocr_quota_refresh, socket) do
    org_id = socket.assigns.org_id

    {:noreply,
     socket
     |> assign(ocr_budget: budget(socket, org_id))
     |> schedule_window_refresh(org_id)}
  end

  def handle_info({:ocr_quota_changed, org_id}, socket) do
    if org_id == socket.assigns.org_id do
      {:noreply, assign(socket, ocr_budget: budget(socket, org_id))}
    else
      {:noreply, socket}
    end
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  # Subscribe only on the connected mount: a dead render's process is about to
  # die, so the topic would have no listener left. The id-only envelope makes
  # the subscription safe to share across every session viewing this org.
  defp subscribe(socket, org_id) do
    if connected?(socket), do: OcrQuotaPubSub.subscribe(socket.assigns.samen_mount, org_id)
    socket
  end

  # The current-org selector can move the page to another org; follow it so the
  # page never reacts to (or misses) the wrong org's charges.
  defp resubscribe(%{assigns: %{org_id: org_id}} = socket, org_id), do: socket

  defp resubscribe(socket, org_id) do
    if connected?(socket) do
      OcrQuotaPubSub.unsubscribe(socket.assigns.samen_mount, socket.assigns[:org_id])
      OcrQuotaPubSub.subscribe(socket.assigns.samen_mount, org_id)
    end

    # The reset label is needed on the dead render too; only the timer is
    # connected-only.
    schedule_window_refresh(socket, org_id)
  end

  defp budget(socket, org_id) do
    OcrQuota.budget(org_id, repo: socket.assigns.samen_mount.repo)
  end

  # The window is a DATABASE-clock fact (the same clock `Store` charges
  # against), so the page asks it when the boundary is instead of guessing from
  # the node clock. A short grace past the boundary keeps the read out of the
  # window that just ended.
  defp schedule_window_refresh(socket, org_id) do
    cancel_window_refresh(socket)
    remaining_ms = window_remaining_ms(socket, org_id)
    socket = assign(socket, ocr_reset_in: OcrQuota.format_window_remaining(remaining_ms))

    if connected?(socket) and is_binary(org_id) and InvoiceOcr.configured?() do
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

  defp window_remaining_ms(socket, org_id) do
    if is_binary(org_id) and InvoiceOcr.configured?() do
      case OcrQuota.window_remaining_ms(repo: socket.assigns.samen_mount.repo) do
        {:ok, remaining_ms} -> remaining_ms
        {:error, _reason} -> nil
      end
    end
  end

  defp cancel_window_refresh(socket) do
    case socket.assigns[:ocr_window_timer] do
      ref when is_reference(ref) -> Process.cancel_timer(ref)
      _other -> :ok
    end
  end

  defp links(mount, org_id) do
    path = Mount.label(mount, :erp_path, "/erp")

    [
      {Erp.ap_capture_label(), "#{path}/ap-capture?org=#{org_id}"},
      {Erp.ap_payments_label(), "#{path}/ap-payments?org=#{org_id}"},
      {Erp.ap_aging_label(), "#{path}/ap-aging?org=#{org_id}"},
      {Erp.ar_receipts_label(), "#{path}/ar-receipts?org=#{org_id}"},
      {Erp.ar_aging_label(), "#{path}/ar-aging?org=#{org_id}"},
      {Erp.journal_approval_label(), "#{path}/journal-approval?org=#{org_id}"}
    ] ++
      Enum.map(Erp.surfaces(), fn surface ->
        {Erp.label(surface), "#{path}/#{surface}?org=#{org_id}"}
      end)
  end

  defp capture_href(mount, org_id) do
    path = Mount.label(mount, :erp_path, "/erp")
    "#{path}/ap-capture?org=#{org_id}"
  end

  defp crumbs(mount, org_id), do: [Crumbs.org(mount, org_id), "ERP"]

  @impl Samen.Web.Tenant.Live
  def tenant_sidebar(assigns) do
    ~H"""
    <.erp_sidebar
      mount={@samen_mount}
      org_id={@org_id}
      active={:erp_dashboard}
      return_to={@return_to}
    />
    """
  end

  @impl Samen.Web.Tenant.Live
  def tenant_page(assigns) do
    ~H"""
    <div id="erp-dashboard">
      <.topbar title={Erp.dashboard_label()} crumbs={crumbs(@samen_mount, @org_id)} />
      <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

      <div class="wrap">
        <%= if is_nil(@org_id) do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <div class="gtitle">
            <h3>{Erp.dashboard_label()}</h3>
            <span class="lane">· one org's books, AP and AR</span>
          </div>

          <div class="card" id="erp-ocr-card" style="padding:14px 16px;margin-bottom:10px">
            <div style="font-size:13px;font-weight:700;margin-bottom:6px">Hosted OCR budget</div>

            <p
              :if={not @ocr_configured}
              id="erp-ocr-not-configured"
              style="margin:0 0 8px;font-size:12px;color:var(--muted)"
            >
              Hosted OCR is not configured on this host. PDFs and images cannot be read; pasted invoice text still works.
            </p>

            <p
              :if={@ocr_configured and @ocr_budget.remaining == nil}
              id="erp-ocr-unavailable"
              style="margin:0 0 8px;font-size:12px;color:var(--bad, #b91c1c)"
            >
              The hosted OCR budget cannot be read right now, so documents cannot be read either. Paste the invoice text instead.
            </p>

            <p
              :if={@ocr_configured and @ocr_budget.remaining != nil and @ocr_budget.remaining > 0}
              id="erp-ocr-budget"
              style="margin:0 0 8px;font-size:12px;color:var(--muted)"
            >
              {@ocr_budget.remaining} of {@ocr_budget.limit} documents left in this window.
            </p>

            <p
              :if={@ocr_configured and @ocr_budget.remaining == 0}
              id="erp-ocr-exhausted"
              style="margin:0 0 8px;font-size:12px;color:var(--bad, #b91c1c)"
            >
              Hosted OCR is paused: 0 of {@ocr_budget.limit} documents left in this window. Paste the invoice text, or wait for the window to reset.
            </p>

            <p
              :if={@ocr_configured and @ocr_budget.remaining != nil and @ocr_reset_in}
              id="erp-ocr-reset"
              style="margin:0 0 8px;font-size:12px;color:var(--muted)"
            >
              Resets in {@ocr_reset_in}.
            </p>

            <a href={capture_href(@samen_mount, @org_id)} id="erp-ocr-capture-link" style="font-size:12px">
              Open AP capture
            </a>
          </div>

          <div
            class="card"
            id="erp-dashboard-links"
            style="padding:14px 16px;display:flex;flex-wrap:wrap;gap:8px"
          >
            <a :for={{label, href} <- links(@samen_mount, @org_id)} href={href} style="font-size:12px">
              {label}
            </a>
          </div>
        <% end %>
      </div>
    </div>
    """
  end
end
