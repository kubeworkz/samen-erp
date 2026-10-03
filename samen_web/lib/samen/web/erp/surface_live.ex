defmodule Samen.Web.Erp.SurfaceLive do
  @moduledoc """
  The generic ERP tenant surface (WS-ERP E8; design §6.4): an org-scoped,
  bounded list over a host's mounted ERP resources, addressed as
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
    * the write side is the bounded create modal over the resource's OWN
      `:create` action (`Erp.create_fields/1` mirrors its `accept`; line-
      bearing surfaces get the bounded line repeater over
      `Erp.line_fields/1`), offered under `writable?/1` (tenant plane) with
      `org_id` merged server-side — the kernel's OrgScope + role gate govern
      the write exactly as a direct API call; edits and the `accept([])`
      state transitions live on `Samen.Web.Erp.DetailLive`, and each row's
      first cell links there;
    * no export path exists on any ERP surface.
  """

  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Erp.Live, only: [assign_mount: 2, erp_sidebar: 1, writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.Crumbs
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
     |> assign(
       surface: surface,
       org_id: org_id,
       list_state: %ListState{},
       page: %Samen.Web.Page{},
       resource: nil,
       return_to: nil,
       show_new: false,
       new_form: nil,
       line_rows: [],
       line_values: [%{}]
     )
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
  # EVERY path assigns `:resource`, `:unmounted` and the modal state — the
  # render branches read them directly (the old `Map.get(@assigns, ...)`
  # idiom raised KeyError the moment a surface resolved).
  defp load(%{assigns: %{surface: nil}} = socket) do
    assign(socket,
      page: %Samen.Web.Page{},
      unmounted: true,
      resource: nil,
      show_new: false,
      new_form: nil
    )
  end

  defp load(%{assigns: %{surface: _surface, org_id: nil}} = socket) do
    assign(socket,
      page: %Samen.Web.Page{},
      unmounted: true,
      resource: nil,
      show_new: false,
      new_form: nil
    )
  end

  defp load(socket) do
    %{samen_mount: mount, surface: surface, org_id: org_id, list_state: state} = socket.assigns

    case Erp.resource(mount, surface) do
      nil ->
        assign(socket,
          page: %Samen.Web.Page{},
          unmounted: true,
          resource: nil,
          show_new: false,
          new_form: nil
        )

      resource ->
        scope = Mount.scope(mount, org_id)

        page =
          resource
          |> Ash.Query.sort({:inserted_at, :desc})
          |> Reads.page!(state, scope: scope)

        assign(socket,
          page: page,
          unmounted: false,
          resource: resource,
          new_form: new_record_form(mount, resource, org_id)
        )
    end
  end

  # -- create events (the bounded write side) --------------------------------

  @impl true
  def handle_event("new_record", _params, socket) do
    %{samen_mount: mount, org_id: org_id, resource: resource, surface: surface} = socket.assigns

    if writable?(mount) and resource != nil and org_id != nil do
      {:noreply,
       assign(socket,
         show_new: true,
         new_form: new_record_form(mount, resource, org_id),
         line_rows: default_line_rows(surface),
         line_values: [%{}]
       )}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_new", _params, socket) do
    {:noreply, assign(socket, show_new: false)}
  end

  def handle_event("add_line", _params, socket) do
    {:noreply, assign(socket, line_rows: socket.assigns.line_rows ++ [nil])}
  end

  def handle_event("validate_new", %{"form" => params}, socket) do
    params = prepare(params, socket)
    form = AshPhoenix.Form.validate(socket.assigns.new_form, params)

    {:noreply, assign(socket, new_form: form, line_values: Map.get(params, "lines", []))}
  end

  # `org_id` is the server-side fact, never client input. The kernel's
  # OrgScope + `RoleAtLeast :member` govern the create exactly as a direct
  # API call would — no LiveView policy here.
  def handle_event("save_new", %{"form" => params}, socket) do
    params = prepare(params, socket)

    case AshPhoenix.Form.submit(socket.assigns.new_form, params: params) do
      {:ok, _record} ->
        socket =
          socket
          |> assign(
            show_new: false,
            line_rows: default_line_rows(socket.assigns.surface),
            line_values: [%{}]
          )
          |> load()

        {:noreply, socket}

      {:error, form} ->
        {:noreply, assign(socket, new_form: form, line_values: Map.get(params, "lines", []))}
    end
  end

  defp new_record_form(mount, resource, org_id) do
    resource
    |> AshPhoenix.Form.for_create(:create, scope: Mount.scope(mount, org_id))
    |> to_form()
  end

  # Server-side org merge + blank-line pruning: a repeater row the user left
  # entirely empty is not a line (submitting it would fail the item's
  # allow_nil fields with a confusing per-row error); a surface whose action
  # REQUIRES lines then fails honestly on the `lines` argument itself.
  defp prepare(params, socket) do
    params
    |> Map.put("org_id", socket.assigns.org_id)
    |> prune_lines()
  end

  defp prune_lines(%{"lines" => lines} = params) when is_list(lines) do
    kept =
      lines
      |> Enum.map(fn row -> Map.reject(row, fn {_k, v} -> is_nil(v) or v == "" end) end)
      |> Enum.reject(&(&1 == %{}))

    if kept == [], do: Map.delete(params, "lines"), else: Map.put(params, "lines", kept)
  end

  defp prune_lines(params), do: params

  defp default_line_rows(surface), do: if(Erp.line_fields(surface) != [], do: [nil], else: [])

  @impl true
  def render(assigns) do
    ~H"""
    <div id="erp-surface">
      <.app_shell>
        <:sidebar>
          <.erp_sidebar
            mount={@samen_mount}
            org_id={@org_id}
            active={@surface && :"erp_#{@surface}"}
            return_to={@return_to}
          />
        </:sidebar>

        <.topbar
          title={if(@surface, do: Erp.label(@surface), else: "Not found")}
          crumbs={crumbs(@samen_mount, @org_id, @surface)}
        >
          <:actions>
            <.button
              :if={writable?(@samen_mount) and @org_id != nil and @resource != nil}
              variant="primary"
              phx-click="new_record"
              id="new-record"
            >
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 3v18M3 12h18" />
                </svg>
              </:icon>
              New {Erp.record_label(@surface)}
            </.button>
          </:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <div class="wrap">
          <%= if is_nil(@org_id) do %>
            <.no_org_card mount={@samen_mount} />
          <% else %>
            <div :if={@surface} class="gtitle">
              <h3>{Erp.label(@surface)}</h3>
              <span class="n">{length(@page.items)}</span>
              <span class="lane">· org-scoped · governed writes</span>
            </div>
            <%= if is_nil(@surface) or @unmounted do %>
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
                    <td
                      :for={{col, index} <- Enum.with_index(Erp.columns(@surface))}
                      style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)"
                    >
                      <%= if index == 0 do %>
                        <a
                          href={detail_href(@surface, row, @org_id)}
                          class="erp-row-link"
                          style="color:inherit;text-decoration:underline;text-underline-offset:2px"
                        >
                          {render_cell(row, col)}
                        </a>
                      <% else %>
                        {render_cell(row, col)}
                      <% end %>
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

        <.modal :if={@show_new and @new_form != nil} id="new-record-modal" title={"New " <> Erp.record_label(@surface)} on_cancel="cancel_new">
          <.simple_form :let={f} for={@new_form} id="new-record-form" phx-change="validate_new" phx-submit="save_new">
            <.form_field
              :for={{field, type, opts} <- Erp.create_fields(@surface)}
              field={f[field]}
              label={humanize(field)}
              type={input_type(type)}
              options={opts[:options] || []}
              placeholder={opts[:placeholder]}
            />

            <div :if={Erp.line_fields(@surface) != []} id="line-rows" style="margin-bottom:4px">
              <div class="field-label" style="font-size:12px;font-weight:600;margin-bottom:6px">Lines</div>
              <div
                :for={{_row, index} <- Enum.with_index(@line_rows)}
                style="display:flex;gap:6px;flex-wrap:wrap;margin-bottom:8px"
              >
                <input
                  :for={{field, type, opts} <- Erp.line_fields(@surface)}
                  type={input_type(type)}
                  name={"#{f.name}[lines][#{index}][#{field}]"}
                  value={line_input_value(@line_values, index, field)}
                  placeholder={opts[:placeholder] || humanize(field)}
                  style="font-size:12px;padding:6px 8px;flex:1;min-width:110px"
                />
              </div>
              <div :if={line_errors(f) != []} class="field-errors" id="lines-errors" style="margin-bottom:6px">
                <p :for={msg <- line_errors(f)} class="field-error" style="margin:0;color:var(--bad, #b91c1c);font-size:12px">
                  {error_text(msg)}
                </p>
              </div>
              <.button type="button" phx-click="add_line" id="add-line" style="margin-bottom:4px">
                Add line
              </.button>
            </div>

            <:actions>
              <.button variant="primary" type="submit" id="save-record">Save</.button>
              <.button type="button" phx-click="cancel_new">Cancel</.button>
            </:actions>
          </.simple_form>
        </.modal>
      </.app_shell>
    </div>
    """
  end

  # The trail every ERP page shares: org (linked back to the workspace) › ERP › surface.
  # The "ERP" middle crumb is inert text (no section route exists to link); a nil surface
  # (unknown URL name) stops at "ERP" — the honest not-found title renders in the topbar.
  defp crumbs(mount, org_id, surface) do
    [Crumbs.org(mount, org_id), "ERP"] ++ if(surface, do: [Erp.label(surface)], else: [])
  end

  defp detail_href(surface, row, org_id), do: "/erp/#{surface}/#{row.id}?org=#{org_id}"

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

  defp humanize(field),
    do: field |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

  defp input_type(:text), do: "text"
  defp input_type(:number), do: "number"
  defp input_type(:date), do: "date"
  defp input_type(:select), do: "select"

  defp line_input_value(line_values, index, field) do
    line_values
    |> Enum.at(index, %{})
    |> Map.get(to_string(field), "")
  end

  defp line_errors(form) do
    case form[:lines] do
      %{errors: errors} -> errors
      _ -> []
    end
  rescue
    _ -> []
  end

  # Phoenix form errors arrive as `{msg, opts}` tuples — the kit's
  # `form_field/1` translates them; the manual repeater does it here.
  defp error_text({msg, _opts}) when is_binary(msg), do: msg
  defp error_text(msg) when is_binary(msg), do: msg
  defp error_text(other), do: to_string(other)
end
