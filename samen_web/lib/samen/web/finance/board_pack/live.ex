defmodule Samen.Web.Finance.BoardPack.Live do
  @moduledoc """
  The board reporting package (`/board`) — the DOM egress of
  `Samen.Scopes.Finance.BoardPack` for the newest declared fiscal period.

  The page is a read-only package: exec snapshot, traffic lights, condensed
  statements, KPI/variance bridge and the variance appendix. Every number is
  shown with the read that produced it in the trace block; no figure is
  computed by the view. Narrative pages (risks, opportunities, board asks,
  resolutions) are authored documents by ADR-054 D12 and are deliberately
  absent.

  Absences are explicit: an unmapped `:cash` posting account says so, a month
  with no close run says so, and a host without the variance resource says
  the variance section is unavailable instead of rendering a green zero.
  """

  use Samen.Web.Tenant.Live

  import Samen.UI
  import Samen.Web.Erp.Live, only: [assign_mount: 2, erp_sidebar: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.Crumbs
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Finance.BoardPack
  alias Samen.Web.Mount

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)

    {:ok,
     socket
     |> assign(org_id: org_id, state: nil, error: nil, return_to: nil)
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

  defp load(%{assigns: %{org_id: nil}} = socket),
    do: assign(socket, state: nil, error: :no_org)

  defp load(socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    case BoardPack.load(mount, org_id) do
      {:ok, state} -> assign(socket, state: state, error: nil)
      {:error, reason} -> assign(socket, state: nil, error: reason)
    end
  end

  @impl Samen.Web.Tenant.Live
  def tenant_sidebar(assigns) do
    ~H"""
    <.erp_sidebar
      mount={@samen_mount}
      org_id={@org_id}
      active={:erp_board}
      return_to={@return_to}
    />
    """
  end

  @impl Samen.Web.Tenant.Live
  def tenant_page(assigns) do
    ~H"""
    <div id="board-pack">
      <.topbar title="Board pack" crumbs={crumbs(@samen_mount, @org_id)}>
        <:actions>
          <a :if={@state} class="button" href={export_href(@samen_mount, @org_id)}>
            Export CSV
          </a>
        </:actions>
      </.topbar>

      <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

      <div class="wrap">
        <%= if is_nil(@org_id) do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <%= if @error do %>
            <div class="card" style="padding:16px;color:var(--muted)">
              {error_text(@error)}
            </div>
          <% else %>
            <.board_body state={@state} />
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  attr(:state, :map, required: true)

  defp board_body(assigns) do
    ~H"""
    <div class="gtitle">
      <h3>{period_label(@state.period)}</h3>
      <span class="lane">· board reporting package · read-only</span>
    </div>

    <div class="card" id="board-exec" style="padding:12px 16px;margin-bottom:12px">
      <b>Exec snapshot</b>
      <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;margin-top:10px">
        <.metric_card label="Revenue" value={money(@state.report.exec.revenue_cents)} />
        <.metric_card label="Expenses" value={money(@state.report.exec.expenses_cents)} />
        <.metric_card label="Net income" value={money(@state.report.exec.net_income_cents)} />
        <.metric_card label="Closing cash" value={money(@state.report.exec.cash_cents)} />
        <.metric_card label="Assets" value={money(@state.report.exec.assets_cents)} />
        <.metric_card label="Liabilities" value={money(@state.report.exec.liabilities_cents)} />
        <.metric_card label="Equity" value={money(@state.report.exec.equity_cents)} />
        <.metric_card label="Close" value={close_label(@state.report.exec)} />
      </div>

      <div style="display:flex;gap:14px;flex-wrap:wrap;margin-top:12px;font-size:12px;color:var(--muted)">
        <span :for={light <- @state.report.traffic_lights} id={"board-light-#{light.key}"}>
          <span style={"display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:5px;background:#{light_color(light.status)}"}>
          </span>
          <b>{light.label}</b> — {light.detail}
        </span>
      </div>
    </div>

    <.statements report={@state.report} />
    <.runway report={@state.report} />
    <.variance report={@state.report} />
    <.trace report={@state.report} />
    """
  end

  attr(:label, :string, required: true)
  attr(:value, :string, required: true)

  defp metric_card(assigns) do
    ~H"""
    <div style="border:1px solid var(--border,#e5e7eb);border-radius:8px;padding:10px">
      <div style="font-size:11px;color:var(--muted)">{@label}</div>
      <div style="font-size:18px;font-weight:600;margin-top:2px">{@value}</div>
    </div>
    """
  end

  attr(:report, :map, required: true)

  defp statements(assigns) do
    ~H"""
    <div class="card" id="board-statements" style="padding:12px 16px;margin-bottom:12px">
      <b>Condensed statements</b>
      <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(280px,1fr));gap:18px;margin-top:10px">
        <div>
          <h4>Profit &amp; loss</h4>
          <table style="width:100%;border-collapse:collapse;font-size:12px">
            <tbody>
              <tr :for={row <- @report.statements.profit_loss.revenue}>
                <td style="padding:3px 0;color:var(--muted)">{row.code} · {row.name}</td>
                <td style="padding:3px 0;text-align:right">{money(abs(row.balance))}</td>
              </tr>
              <tr :for={row <- @report.statements.profit_loss.expenses}>
                <td style="padding:3px 0;color:var(--muted)">{row.code} · {row.name}</td>
                <td style="padding:3px 0;text-align:right">{money(abs(row.balance))}</td>
              </tr>
              <tr style="border-top:1px solid var(--border,#e5e7eb)">
                <td style="padding:5px 0"><b>Net income</b></td>
                <td style="padding:5px 0;text-align:right"><b>{money(@report.statements.profit_loss.net_income)}</b></td>
              </tr>
            </tbody>
          </table>
        </div>

        <div>
          <h4>Balance sheet</h4>
          <table style="width:100%;border-collapse:collapse;font-size:12px">
            <tbody>
              <tr :for={row <- @report.statements.balance_sheet.assets}>
                <td style="padding:3px 0;color:var(--muted)">{row.code} · {row.name}</td>
                <td style="padding:3px 0;text-align:right">{money(abs(row.balance))}</td>
              </tr>
              <tr :for={row <- @report.statements.balance_sheet.liabilities}>
                <td style="padding:3px 0;color:var(--muted)">{row.code} · {row.name}</td>
                <td style="padding:3px 0;text-align:right">{money(abs(row.balance))}</td>
              </tr>
              <tr :for={row <- @report.statements.balance_sheet.equity}>
                <td style="padding:3px 0;color:var(--muted)">{row.code} · {row.name}</td>
                <td style="padding:3px 0;text-align:right">{money(abs(row.balance))}</td>
              </tr>
              <tr style="border-top:1px solid var(--border,#e5e7eb)">
                <td style="padding:5px 0"><b>Assets = liabilities + equity</b></td>
                <td style="padding:5px 0;text-align:right">
                  <b>{money(@report.statements.balance_sheet.total_assets)}</b>
                </td>
              </tr>
            </tbody>
          </table>
          <div style="color:var(--muted);font-size:11px;margin-top:4px">
            {if @report.statements.balance_sheet.balanced, do: "balanced", else: "NOT balanced"}
          </div>
        </div>

        <div>
          <h4>Cash flow</h4>
          <%= if @report.statements.cash_flow.mapped? do %>
            <table style="width:100%;border-collapse:collapse;font-size:12px">
              <tbody>
                <tr>
                  <td style="padding:3px 0;color:var(--muted)">Opening cash</td>
                  <td style="padding:3px 0;text-align:right">{money(@report.statements.cash_flow.opening_cents)}</td>
                </tr>
                <tr>
                  <td style="padding:3px 0;color:var(--muted)">Inflows</td>
                  <td style="padding:3px 0;text-align:right">{money(@report.statements.cash_flow.inflows_cents)}</td>
                </tr>
                <tr>
                  <td style="padding:3px 0;color:var(--muted)">Outflows</td>
                  <td style="padding:3px 0;text-align:right">{money(@report.statements.cash_flow.outflows_cents)}</td>
                </tr>
                <tr style="border-top:1px solid var(--border,#e5e7eb)">
                  <td style="padding:5px 0"><b>Closing cash</b></td>
                  <td style="padding:5px 0;text-align:right"><b>{money(@report.statements.cash_flow.closing_cents)}</b></td>
                </tr>
              </tbody>
            </table>
          <% else %>
            <p style="color:var(--muted);font-size:12px">
              No <code>:cash</code> posting account is mapped on this workspace, so cash movement is unavailable. The statement is not estimated.
            </p>
          <% end %>
        </div>
      </div>
    </div>
    """
  end

  attr(:report, :map, required: true)

  defp runway(assigns) do
    ~H"""
    <div class="card" id="board-runway" style="padding:12px 16px;margin-bottom:12px">
      <b>Runway</b>
      <%= if @report.runway do %>
        <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;margin-top:10px">
          <.metric_card label="Cash on hand" value={money(@report.runway.cash_on_hand_cents)} />
          <.metric_card label="Average monthly burn" value={money(@report.runway.avg_monthly_burn_cents)} />
          <.metric_card label="Runway" value={runway_label(@report.runway)} />
          <.metric_card label="Forecast" value={forecast_label(@report.runway)} />
        </div>
        <p style="color:var(--muted);font-size:12px;margin-top:10px">
          {runway_detail(@report.runway)}
        </p>
      <% else %>
        <p style="color:var(--muted);font-size:12px;margin-top:8px">
          No published forecast version covers this period, so runway is unavailable. The board pack does not estimate it.
        </p>
      <% end %>
    </div>
    """
  end

  attr(:report, :map, required: true)

  defp variance(assigns) do
    ~H"""
    <div class="card" id="board-variance" style="padding:12px 16px;margin-bottom:12px">
      <b>KPI &amp; variance bridge</b>
      <div style="display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:10px;margin-top:10px">
        <.metric_card label="Operating margin" value={pct(@report.kpis.operating_margin_pct)} />
        <.metric_card label="EBITDA" value={money(@report.kpis.ebitda_cents)} />
        <.metric_card label="EBITDA basis" value={basis_label(@report.kpis.ebitda_basis)} />
        <.metric_card label="Net cash movement" value={money(@report.kpis.cash_net_cents)} />
      </div>

      <%= if @report.variance_bridge.rows == [] do %>
        <p style="color:var(--muted);font-size:12px;margin-top:12px">
          No variance rows are recorded for this period.
        </p>
      <% else %>
        <table style="width:100%;border-collapse:collapse;font-size:12px;margin-top:12px">
          <thead>
            <tr>
              <th style="text-align:left;padding:4px 0;color:var(--muted)">Class</th>
              <th style="text-align:right;padding:4px 0;color:var(--muted)">Variance</th>
              <th style="text-align:left;padding:4px 0;color:var(--muted)">Favourability</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @report.variance_bridge.rows}>
              <td style="padding:3px 0">{row.type}</td>
              <td style="padding:3px 0;text-align:right">{money(row.variance_cents)}</td>
              <td style="padding:3px 0;color:var(--muted)">{row.favourability}</td>
            </tr>
          </tbody>
        </table>
      <% end %>

      <div style="color:var(--muted);font-size:11px;margin-top:6px">
        Labour basis: {labour_basis(@report.variance_bridge.labour_basis)}
      </div>

      <h4 style="margin-top:16px">Variance appendix</h4>
      <%= if @report.variance_appendix == [] do %>
        <p style="color:var(--muted);font-size:12px">No variance rows recorded.</p>
      <% else %>
        <table style="width:100%;border-collapse:collapse;font-size:12px">
          <thead>
            <tr>
              <th style="text-align:left;padding:4px 0;color:var(--muted)">Class</th>
              <th style="text-align:left;padding:4px 0;color:var(--muted)">Cost object</th>
              <th style="text-align:right;padding:4px 0;color:var(--muted)">Actual</th>
              <th style="text-align:right;padding:4px 0;color:var(--muted)">Standard</th>
              <th style="text-align:right;padding:4px 0;color:var(--muted)">Variance</th>
              <th style="text-align:left;padding:4px 0;color:var(--muted)">Disposition</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={row <- @report.variance_appendix}>
              <td style="padding:3px 0">{row.type}</td>
              <td style="padding:3px 0;color:var(--muted)">{row.cost_object_id}</td>
              <td style="padding:3px 0;text-align:right">{money(row.actual_cents)}</td>
              <td style="padding:3px 0;text-align:right">{money(row.standard_cents)}</td>
              <td style="padding:3px 0;text-align:right">{money(row.variance_cents)}</td>
              <td style="padding:3px 0;color:var(--muted)">{row.disposition}</td>
            </tr>
          </tbody>
        </table>
      <% end %>
    </div>
    """
  end

  attr(:report, :map, required: true)

  defp trace(assigns) do
    ~H"""
    <div class="card" id="board-trace" style="padding:12px 16px;margin-bottom:12px">
      <b>Trace</b>
      <ul style="margin:8px 0 0;padding-left:18px;font-size:12px;color:var(--muted)">
        <li :for={source <- @report.sources}>{source.section} ← <code>{source.read}</code></li>
      </ul>
      <p style="color:var(--muted);font-size:11px;margin-top:8px">
        Generated {stamp(@report.generated_at)}. Every figure is a read over the posted ledger;
        narrative pages and board resolutions are authored documents, not generated here.
      </p>
    </div>
    """
  end

  defp crumbs(mount, org_id), do: [Crumbs.org(mount, org_id), "ERP", "Board pack"]

  defp export_href(mount, org_id) do
    "#{Mount.label(mount, :board_path, "/board")}/export.csv?org=#{org_id}"
  end

  defp period_label(%{year: year, month: month}) when is_integer(year) and is_integer(month) do
    Calendar.strftime(Date.new!(year, month, 1), "%B %Y")
  end

  defp period_label(_period), do: "Current period"

  defp close_label(%{close_complete?: true}), do: "complete"
  defp close_label(%{close_percent: percent}) when is_integer(percent), do: "#{percent}%"
  defp close_label(_exec), do: "not started"

  defp runway_label(%{mapped?: false}), do: "unavailable"

  defp runway_label(%{status: :runway, runway_months: months}) when is_float(months),
    do: "#{months} months"

  defp runway_label(%{status: :not_burning}), do: "not burning"
  defp runway_label(%{status: :no_forecast}), do: "no drivers"
  defp runway_label(_runway), do: "unavailable"

  defp forecast_label(%{version_name: name, version_number: number}),
    do: "#{name} · v#{number}"

  defp forecast_label(_runway), do: "—"

  defp runway_detail(%{mapped?: false}),
    do: "No :cash posting account is mapped, so no runway is quoted."

  defp runway_detail(%{status: :no_forecast}),
    do: "The published forecast has no monthly drivers."

  defp runway_detail(%{status: :not_burning}),
    do: "The forecast is not burning cash, so a runway multiple is not meaningful."

  defp runway_detail(%{status: :runway, reconciled?: true, ends_on: ends_on}),
    do:
      "Weighted burn through #{Calendar.strftime(ends_on, "%B %Y")}; reconciled to the mapped cash accounts."

  defp runway_detail(%{status: :runway}),
    do: "Weighted burn over the published forecast; the cash read is not reconciled."

  defp runway_detail(_runway), do: "Runway is unavailable for this forecast."

  defp pct(nil), do: "—"
  defp pct(value) when is_float(value), do: :erlang.float_to_binary(value, decimals: 1) <> "%"
  defp pct(value), do: "#{value}%"

  defp basis_label(:mapped_addbacks), do: "net income + addbacks"
  defp basis_label(:no_mapped_addbacks), do: "net income (no addbacks)"
  defp basis_label(other), do: to_string(other)

  defp labour_basis(:declared_pending_driver),
    do: "declared actuals (the variance layer has not adopted the timesheet driver yet)"

  defp labour_basis(:unavailable), do: "variance resource not mounted"
  defp labour_basis(other), do: to_string(other)

  defp money(nil), do: "—"

  defp money(cents) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    absolute = abs(cents)
    whole = div(absolute, 100)
    fraction = absolute |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{sign}$#{whole}.#{fraction}"
  end

  defp light_color(:green), do: "#0A5C42"
  defp light_color(:amber), do: "#B45309"
  defp light_color(:red), do: "#B91C1C"
  defp light_color(_), do: "#9CA3AF"

  defp stamp(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M UTC")
  defp stamp(%NaiveDateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")
  defp stamp(value), do: to_string(value)

  defp error_text(:no_org), do: "Select an org to read its board pack."
  defp error_text(:no_period), do: "No fiscal period is declared on this workspace."

  defp error_text(:finance_not_mounted),
    do: "This workspace has no Finance mount, so there is no board pack to show."

  defp error_text(reason),
    do:
      "This board pack is not available on this workspace's mounted modules (#{inspect(reason)})."
end
