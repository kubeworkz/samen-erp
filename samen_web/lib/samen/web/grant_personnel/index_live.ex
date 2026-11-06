defmodule Samen.Web.GrantPersonnel.IndexLive do
  @moduledoc """
  The bounded grant index (`/grants`) — the landing surface for the grant
  personnel report.

  The list rides the `Samen.Web.ListLive` mixin and
  `Samen.Web.GrantPersonnel.Index.grants_page/3`, so pagination, filtering,
  sorting, page-size clamping, and the unread state are inherited rather than
  hand-rolled. Every row links to `/grants/:id`, where the personnel report
  resolves names through `Samen.Web.GrantPersonnel` on the acting plane.

  Grants are non-PII documents; the only PII in this feature is the personnel
  name, which never appears on this index.
  """

  use Samen.Web.Tenant.Live

  use Samen.Web.ListLive,
    resource: nil,
    reads: &Samen.Web.GrantPersonnel.Index.grants_page/3,
    sortable: [:award_ref, :funder, :program, :award_cents, :period_start, :period_end, :status],
    filter_fields: [:award_ref, :funder, :program],
    default_sort: {:award_ref, :asc}

  import Samen.UI
  import Samen.Web.Erp.Live, only: [assign_mount: 2, erp_sidebar: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.Crumbs
  alias Samen.Web.CurrentOrg
  alias Samen.Web.ListState
  alias Samen.Web.Mount
  alias Samen.Web.Page

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)

    {:ok, socket |> assign(org_id: org_id, return_to: nil) |> load()}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = CurrentOrg.reresolve(socket, params)

    {:noreply,
     socket
     |> assign(org_id: org_id, return_to: return_path(uri))
     |> load()}
  end

  defp load(%{assigns: %{org_id: nil}} = socket) do
    assign(socket,
      no_org: true,
      page: %Page{},
      list_state: %ListState{}
    )
  end

  defp load(socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    socket
    |> assign(no_org: false)
    |> init_list(mount, Mount.scope(mount, org_id))
  end

  @impl Samen.Web.Tenant.Live
  def tenant_sidebar(assigns) do
    ~H"""
    <.erp_sidebar
      mount={@samen_mount}
      org_id={@org_id}
      active={:erp_grants}
      return_to={@return_to}
    />
    """
  end

  @impl Samen.Web.Tenant.Live
  def tenant_page(assigns) do
    ~H"""
    <div id="grants-index">
      <.topbar title="Grants" crumbs={crumbs(@samen_mount, @org_id)}>
        <:actions>
          <a class="button" id="grants-index-refresh" href={index_href(@samen_mount, @org_id)}>
            Refresh
          </a>
        </:actions>
      </.topbar>

      <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

      <div class="wrap">
        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <div class="gtitle">
            <h3>Grants</h3>
            <span class="n">{length(@page.items)}</span>
            <span class="lane">· org-scoped · open an award for its personnel report</span>
          </div>

          <.list_view
            id="grants-list"
            page={@page}
            state={@list_state}
            row_class="grant-row"
            filter_placeholder="Filter by award, funder, or program…"
            empty_text="No grants yet."
            empty_icon="🎓"
            empty_body="Grants appear here once an award is recorded in this workspace."
          >
            <:head>
              <.sort_header field={:award_ref} label="Award" sort={@list_state.sort} width="18%" />
              <.sort_header field={:funder} label="Funder" sort={@list_state.sort} width="18%" />
              <.sort_header field={:program} label="Program" sort={@list_state.sort} width="20%" />
              <.sort_header field={:award_cents} label="Award amount" sort={@list_state.sort} width="14%" />
              <.sort_header field={:period_start} label="Period" sort={@list_state.sort} width="16%" />
              <.sort_header field={:status} label="Status" sort={@list_state.sort} width="8%" />
              <th scope="col" style="width:10%">Personnel</th>
            </:head>

            <:row :let={grant}>
              <td>
                <a
                  href={report_href(@samen_mount, @org_id, grant.id)}
                  class="grant-report-link"
                  style="font-weight:500;color:#0A5C42"
                >
                  {grant.award_ref}
                </a>
              </td>
              <td style="color:var(--muted)">{grant.funder}</td>
              <td style="color:var(--muted)">{grant.program}</td>
              <td style="color:var(--muted)">{money(grant.award_cents)}</td>
              <td style="color:var(--muted);font-size:12px">{period(grant)}</td>
              <td>
                <.pill variant={status_variant(grant.status)}>{status_label(grant.status)}</.pill>
              </td>
              <td>
                <a
                  href={report_href(@samen_mount, @org_id, grant.id)}
                  class="grant-personnel-link"
                  style="color:#0A5C42"
                >
                  Open
                </a>
              </td>
            </:row>
          </.list_view>
        <% end %>
      </div>
    </div>
    """
  end

  defp crumbs(mount, org_id), do: [Crumbs.org(mount, org_id), "ERP", "Grants"]

  defp index_href(mount, org_id) do
    "#{Mount.label(mount, :grants_path, "/grants")}?org=#{org_id}"
  end

  defp report_href(mount, org_id, grant_id) do
    "#{Mount.label(mount, :grants_path, "/grants")}/#{grant_id}?org=#{org_id}"
  end

  defp money(cents) when is_integer(cents) do
    dollars = div(abs(cents), 100)
    remainder = cents |> rem(100) |> abs()
    "$#{dollars}.#{String.pad_leading(Integer.to_string(remainder), 2, "0")}"
  end

  defp money(_), do: "—"

  defp period(%{period_start: start, period_end: finish}),
    do: "#{Date.to_iso8601(start)} → #{Date.to_iso8601(finish)}"

  defp period(_), do: "—"

  defp status_variant(:active), do: "ok"
  defp status_variant(:closed), do: "mut"
  defp status_variant(_), do: "warn"

  defp status_label(status) when is_atom(status), do: Atom.to_string(status)
  defp status_label(status), do: to_string(status)
end
