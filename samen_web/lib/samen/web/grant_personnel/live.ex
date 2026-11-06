defmodule Samen.Web.GrantPersonnel.Live do
  @moduledoc """
  The grant personnel report page (`/grants/:id`) — the DOM egress of
  `Samen.Web.GrantPersonnel`.

  The page reads through the SAME projection as the CSV and JSON downloads:
  tenant names are clear, operator names render `••••`, and both the table and
  the download links stay inside the grant's org scope. When the host has not
  wired an HR namespace the page says so and shows only the bounded
  employment facts (employee id, effort, effective date).
  """

  use Samen.Web.Tenant.Live

  import Samen.UI
  import Samen.Web.Erp.Live, only: [assign_mount: 2, erp_sidebar: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.Crumbs
  alias Samen.Web.CurrentOrg
  alias Samen.Web.GrantPersonnel
  alias Samen.Web.Mount

  @impl true
  def mount(%{"id" => id} = params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)

    {:ok,
     socket
     |> assign(
       grant_id: id,
       org_id: org_id,
       report: nil,
       missing: nil,
       return_to: nil
     )
     |> load()}
  end

  @impl true
  def handle_params(%{"id" => id} = params, uri, socket) do
    org_id = CurrentOrg.reresolve(socket, params)

    {:noreply,
     socket
     |> assign(grant_id: id, org_id: org_id, return_to: return_path(uri))
     |> load()}
  end

  defp load(%{assigns: %{org_id: nil}} = socket),
    do: assign(socket, report: nil, missing: :no_org)

  defp load(socket) do
    %{samen_mount: mount, org_id: org_id, grant_id: grant_id} = socket.assigns

    case GrantPersonnel.load(mount, org_id, grant_id) do
      {:ok, report} -> assign(socket, report: report, missing: nil)
      {:error, reason} -> assign(socket, report: nil, missing: reason)
    end
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
    <div id="grant-personnel-report">
      <.topbar title="Grant personnel" crumbs={crumbs(@samen_mount, @org_id, @report)}>
        <:actions>
          <%= if @report do %>
            <a
              class="button"
              id="grant-personnel-csv"
              href={csv_href(@samen_mount, @grant_id, @org_id)}
            >
              Download CSV
            </a>
            <a
              class="button"
              id="grant-personnel-json"
              href={json_href(@samen_mount, @grant_id, @org_id)}
            >
              API JSON
            </a>
          <% end %>
        </:actions>
      </.topbar>

      <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

      <div class="wrap">
        <%= if is_nil(@org_id) do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <%= cond do %>
            <% @missing == :not_found -> %>
              <div class="card" style="padding:16px;color:var(--muted)" id="grant-personnel-missing">
                Grant not found in this org.
              </div>
            <% @missing != nil -> %>
              <div class="card" style="padding:16px;color:var(--muted)" id="grant-personnel-missing">
                This grant personnel report is not available on this workspace's mounted modules.
              </div>
            <% true -> %>
              <div class="gtitle">
                <h3>Grant personnel report</h3>
                <span class="n">{length(@report.rows)}</span>
                <span class="lane">· org-scoped · resolved on the acting plane</span>
              </div>

              <div class="card" style="padding:12px 16px;margin-bottom:12px">
                <b>{@report.grant.award_ref}</b>
                <span style="color:var(--muted)">
                  · {@report.grant.funder} · {@report.grant.program}
                </span>
              </div>

              <div
                :if={not @report.personnel_wired?}
                class="card"
                id="grant-personnel-unwired"
                style="padding:12px 16px;margin-bottom:12px;color:var(--muted)"
              >
                Personnel names are not wired on this workspace; showing employee ids and effort only.
              </div>

              <table style="width:100%;border-collapse:collapse;font-size:13px">
                <thead>
                  <tr>
                    <th
                      :for={col <- GrantPersonnel.columns()}
                      scope="col"
                      style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)"
                    >
                      {col |> Atom.to_string() |> String.replace("_", " ")}
                    </th>
                  </tr>
                </thead>
                <tbody>
                  <tr :for={row <- @report.rows} id={"grant-personnel-#{row.employee_id}"}>
                    <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                      {row.employee_id}
                    </td>
                    <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                      {name_cell(row.name)}
                    </td>
                    <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                      {row.effort_pct}%
                    </td>
                    <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                      {Date.to_iso8601(row.effective_on)}
                    </td>
                  </tr>

                  <tr :if={@report.rows == []}>
                    <td colspan={length(GrantPersonnel.columns())} style="padding:16px 8px;color:var(--muted)">
                      No personnel effort recorded for this grant.
                    </td>
                  </tr>
                </tbody>
              </table>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  defp crumbs(mount, org_id, report) do
    base = [Crumbs.org(mount, org_id), "ERP"]

    case report do
      nil -> base ++ ["Grants"]
      report -> base ++ [{"Grants", index_href(mount, org_id)}, report.grant.award_ref]
    end
  end

  defp index_href(mount, org_id) do
    "#{Mount.label(mount, :grants_path, "/grants")}?org=#{org_id}"
  end

  defp name_cell(nil), do: "—"
  defp name_cell(name), do: name

  defp csv_href(mount, grant_id, org_id) do
    "#{Mount.label(mount, :grants_path, "/grants")}/#{grant_id}/personnel.csv?org=#{org_id}"
  end

  defp json_href(mount, grant_id, org_id) do
    "#{Mount.label(mount, :grants_path, "/grants")}/#{grant_id}/personnel.json?org=#{org_id}"
  end
end
