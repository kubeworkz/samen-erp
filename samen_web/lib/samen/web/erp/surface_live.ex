defmodule Samen.Web.Erp.SurfaceLive do
  @moduledoc """
  The ONE generic ERP tenant surface (WS-ERP E8; design §6.4): a read-only,
  org-scoped, bounded list over a host's mounted ERP resources, addressed as
  `<path>/<surface>` where `<surface>` is validated against the CLOSED
  `Samen.Web.Erp` allowlist.

  A host mounts all six surfaces with ONE router line:

      samen_erp_routes(:erp, MyApp.Erp, repo: MyApp.Repo)

  Boundary summary (why this cannot become a leak or an unbounded read):

    * the surface name comes from the URL and is resolved through
      `Samen.Web.Erp.surface/1` — a closed allowlist; an unknown name renders
      the not-found state and names NO module;
    * the resource is DERIVED from the host's mounted namespace
      (`Samen.Web.Erp.resource/2`), never from caller input;
    * the rendered columns are the registry's `columns/1` list — the row
      renderer walks that list, so a surface cannot render a column it does
      not declare (mask-by-omission, generalized; no PII column exists on any
      ERP surface);
    * the read is `Samen.Web.Reads.page!/3` — always `limit(page_size + 1)`,
      clamped page size, `scope:`-pinned (the OrgScope POLICY is the org
      boundary; `page!/3` structurally refuses `authorize?: false`);
    * no write affordance exists: writes ride the resources' governed actions
      elsewhere (the E1–E7 red paths), never this surface.
  """

  use Phoenix.LiveView

  import Samen.Web.Live, only: [assign_mount: 2]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.CurrentOrg
  alias Samen.Web.Erp
  alias Samen.Web.ListState
  alias Samen.Web.Mount
  alias Samen.Web.Reads

  @impl true
  def mount(%{"surface" => raw} = params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)

    surface = Erp.surface(raw)

    {:ok,
     socket
     |> assign(surface: surface, org_id: org_id, list_state: %ListState{}, page: %Samen.Web.Page{})
     |> load()}
  end

  @impl true
  def handle_params(%{"surface" => raw} = params, uri, socket) do
    org_id = CurrentOrg.reresolve(socket, params)

    {:noreply,
     socket
     |> assign(surface: Erp.surface(raw), org_id: org_id, return_to: return_path(uri))
     |> load()}
  end

  # The bounded read: the SAME `page!/3` primitive every mounted list uses.
  # `Erp.resource/2` returning nil (an unmounted surface) reads nothing.
  defp load(%{assigns: %{surface: nil}} = socket), do: socket

  defp load(%{assigns: %{surface: _surface, org_id: nil}} = socket), do: socket

  defp load(socket) do
    %{samen_mount: mount, surface: surface, org_id: org_id, list_state: state} = socket.assigns

    case Erp.resource(mount, surface) do
      nil ->
        assign(socket, page: %Samen.Web.Page{}, unmounted: true)

      resource ->
        scope = Mount.scope(mount, org_id)

        page =
          resource
          |> Ash.Query.sort({:inserted_at, :desc})
          |> Reads.page!(state, scope: scope)

        assign(socket, page: page, unmounted: false, resource: resource)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="wrap">
      <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />
      <%= if is_nil(@org_id) do %>
        <.no_org_card mount={@samen_mount} />
      <% else %>
        <div class="gtitle">
          <h3>{Erp.label(@surface)}</h3>
          <span class="n">{length(@page.items)}</span>
          <span class="lane">· org-scoped · read-only</span>
        </div>
        <%= if @surface == nil or Map.get(@assigns, :unmounted, false) do %>
          <div class="card" style="padding:16px;color:var(--muted)">
            This surface is not available on this workspace's mounted modules.
          </div>
        <% else %>
          <table style="width:100%;border-collapse:collapse;font-size:13px">
            <thead>
              <tr>
                <th :for={col <- Erp.columns(@surface)} scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">
                  {col |> Atom.to_string() |> String.replace("_", " ")}
                </th>
              </tr>
            </thead>
            <tbody>
              <tr :for={row <- @page.items}>
                <td :for={col <- Erp.columns(@surface)} style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                  {render_cell(row, col)}
                </td>
              </tr>
              <tr :if={@page.items == []}>
                <td colspan={length(Erp.columns(@surface))} style="padding:16px 8px;color:var(--muted)">
                  Nothing here yet.
                </td>
              </tr>
            </tbody>
          </table>
        <% end %>
      <% end %>
    </div>
    """
  end

  # The cell renderer walks the REGISTRY's column list (the row loop's `col`
  # is drawn from `Erp.columns/1`, never from client input). Values render as
  # plain text — atoms humanized, binaries truncated, nils as an em dash. No
  # `raw/1`, no HTML from data.
  defp render_cell(row, col) do
    case Map.get(row, col) do
      nil -> "—"
      v when is_atom(v) -> Atom.to_string(v)
      v when is_binary(v) -> if String.length(v) > 40, do: String.slice(v, 0, 37) <> "…", else: v
      v -> to_string(v)
    end
  end
end
