defmodule Samen.Web.Marketing.SegmentLive do
  @moduledoc """
  Framework Marketing / Segment detail (`/marketing/segments/:id`) — the record page
  behind the segments list (ADR-011 §8). Segments are non-PII audience config rows
  (name / description / filter criteria / subscriber count); the audience preview is
  🔒 PII-resolved through `Reads.segment_audience/3` (tenant clear / operator ••••).

  ## Page shape

  Header (name · subscriber count · plane note) → bounded facts `<dl>` → the
  segment's audience preview (first bounded page, `PiiResolution` chokepoint) →
  topbar Edit + Archive affordances.

  ## Writes — sanctioned `:update` / archivable destroy, admin-gated by the kernel

  * **Edit** opens a `modal/1` hosting an `AshPhoenix.Form.for_update/3` over the
    blueprint's `update: :*` (name / description).
  * **Archive** carries the `delete_confirm/1` interlock: Segment is E6-archivable
    (`archivable: true`), so the destroy SOFT-ARCHIVES — the row leaves the live list
    and can be restored from the segments list's archived view. Success navigates
    back to the segments list.

  Writes go through `Reads.write_scope/2` (same-org role elevation, plane-preserving),
  so the kernel's `OrgScope` + `RoleAtLeast :admin` govern them exactly as a direct API
  call would. All write affordances are TENANT-plane only
  (`Samen.Web.Marketing.Live.writable?/1`).
  """
  use Phoenix.LiveView

  import Samen.UI

  import Samen.Web.Marketing.Live,
    only: [assign_mount: 2, marketing_sidebar: 1, marketing_path: 1, marketing_plane_note: 1, writable?: 1]

  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.Crumbs
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  alias Samen.Web.Marketing.Reads

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    segment_id = Map.get(params, "id")

    {:ok,
     load(
       assign(socket, org_id: org_id, segment_id: segment_id, return_to: nil),
       org_id,
       segment_id
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Samen.Web.CurrentOrg.reresolve(socket, params)
    segment_id = Map.get(params, "id") || socket.assigns.segment_id

    {:noreply,
     load(
       assign(socket, org_id: org_id, segment_id: segment_id, return_to: return_path(uri)),
       org_id,
       segment_id
     )}
  end

  @doc false
  def load(socket, nil, _segment_id) do
    socket
    |> ensure_return_to()
    |> assign(
      no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil),
      org_id: nil,
      segment_id: nil,
      segment: nil,
      audience: [],
      show_edit: false,
      edit_form: nil,
      delete_error: nil
    )
  end

  def load(socket, org_id, segment_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    segment =
      if segment_id do
        case Reads.get_segment(mount, scope, segment_id) do
          {:ok, s} -> s
          :error -> nil
        end
      end

    # The bounded audience preview (first `@detail_limit` rows), PII-resolved through
    # the same chokepoint the segments list's subscribers panel rides.
    audience = if segment, do: Reads.segment_audience(mount, scope, segment), else: []

    socket
    |> ensure_return_to()
    |> assign(
      no_org: false,
      org_id: org_id,
      segment_id: segment_id,
      segment: segment,
      audience: audience,
      show_edit: false,
      edit_form: nil,
      delete_error: nil
    )
  end

  # -- writes (tenant posture in the render; kernel governs the write path) ----

  @impl true
  def handle_event("edit_segment", _params, socket) do
    %{samen_mount: mount, org_id: org_id, segment: segment} = socket.assigns

    if is_binary(org_id) and segment != nil do
      {:noreply, assign(socket, show_edit: true, edit_form: edit_form(mount, org_id, segment))}
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

  def handle_event("save_edit", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.edit_form, params: params) do
      {:ok, _segment} ->
        {:noreply, load(socket, socket.assigns.org_id, socket.assigns.segment_id)}

      {:error, form} ->
        {:noreply, assign(socket, edit_form: form)}
    end
  end

  # Archive — E6 soft-delete: the destroy archives (the segment leaves the live list
  # and can be restored from the segments list's archived view). Success navigates
  # back to the list; a refusal is surfaced, never swallowed.
  def handle_event("delete", %{"id" => id}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    if is_binary(org_id) do
      case Reads.delete_segment(mount, Reads.write_scope(mount, org_id), id) do
        :ok ->
          {:noreply, push_navigate(socket, to: segments_path(mount, org_id))}

        {:error, _reason} ->
          {:noreply, assign(socket, delete_error: "Could not archive this segment.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("dismiss_error", _params, socket) do
    {:noreply, assign(socket, delete_error: nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="mkt-segment">
      <.app_shell>
        <:sidebar>
          <.marketing_sidebar mount={@samen_mount} org_id={@org_id} active={:marketing_segments} return_to={@return_to} />
        </:sidebar>

        <.topbar title={segment_label(@segment)} crumbs={crumbs(@samen_mount, @org_id, segment_label(@segment))}>
          <:actions>
            <a href={segments_path(@samen_mount, @org_id)} class="btn" style="text-decoration:none">
              <span class="i">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M19 12H5M12 5l-7 7 7 7" />
                </svg>
              </span>
              Back to segments
            </a>
            <.button :if={writable?(@samen_mount) and @segment != nil} phx-click="edit_segment" id="edit-segment">
              Edit segment
            </.button>
            <.delete_confirm
              :if={writable?(@samen_mount) and @segment != nil}
              id="archive-segment"
              label="Archive"
              message="Archive this segment? It can be restored from the segments list's archived view."
              phx-click="delete"
              phx-value-id={@segment && @segment.id}
            />
          </:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">Marketing org: {@org_id}</span>

          <div :if={@delete_error} class="wrap" style="margin-bottom:0">
            <div class="card form-error" id="delete-error" style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px;display:flex;gap:10px;align-items:center">
              <span>{@delete_error}</span>
              <button type="button" class="btn" phx-click="dismiss_error" style="font-size:12px">Dismiss</button>
            </div>
          </div>

          <%= if @segment == nil do %>
            <div class="wrap">
              <div class="card" style="padding:22px 20px;color:var(--muted)">Segment not found.</div>
            </div>
          <% else %>
            <div class="wrap" style="margin-bottom:0">
              <div class="card" id="segment-header" style="padding:18px 20px;display:flex;align-items:center;gap:14px;flex-wrap:wrap">
                <div class="av" style={"width:46px;height:46px;border-radius:8px;background:#EFF6FF;color:#3B4CCA;font-size:15px;font-weight:700;display:flex;align-items:center;justify-content:center;flex-shrink:0"}>
                  {String.slice(@segment.name || "?", 0, 1) |> String.upcase()}
                </div>
                <div style="flex:1;min-width:0">
                  <h1 style="font-weight:600;font-size:18px;color:#2a2b35;margin:0 0 4px">{segment_label(@segment)}</h1>
                  <div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center">
                    <.pill variant="mut">{@segment.subscriber_count} subscribers</.pill>
                    <span style="font-size:12px;color:var(--muted)">· non-PII audience config · admin-gated writes · {marketing_plane_note(@samen_mount)}</span>
                  </div>
                </div>
              </div>
            </div>

            <div class="wrap" style="margin-bottom:0;padding-top:10px">
              <div class="card" id="segment-facts" style="padding:16px 18px">
                <dl style="display:grid;grid-template-columns:minmax(140px,220px) 1fr;gap:8px 16px;margin:0">
                  <div style="display:contents">
                    <dt style="font-size:12px;font-weight:600;color:var(--muted)">Name</dt>
                    <dd style="margin:0;font-size:13px;font-family:monospace">{@segment.name || "—"}</dd>
                  </div>
                  <div style="display:contents">
                    <dt style="font-size:12px;font-weight:600;color:var(--muted)">Description</dt>
                    <dd style="margin:0;font-size:13px">{@segment.description || "—"}</dd>
                  </div>
                  <div style="display:contents">
                    <dt style="font-size:12px;font-weight:600;color:var(--muted)">Filter criteria</dt>
                    <dd style="margin:0;font-size:13px;font-family:monospace">{filter_summary(@segment.filter_criteria)}</dd>
                  </div>
                  <div style="display:contents">
                    <dt style="font-size:12px;font-weight:600;color:var(--muted)">Subscribers</dt>
                    <dd style="margin:0;font-size:13px">{@segment.subscriber_count}</dd>
                  </div>
                  <div style="display:contents">
                    <dt style="font-size:12px;font-weight:600;color:var(--muted)">Inserted at</dt>
                    <dd style="margin:0;font-size:13px;font-family:monospace">{format_ts(@segment.inserted_at)}</dd>
                  </div>
                </dl>
              </div>

              <div class="card" id="segment-audience" style="padding:16px 18px;margin-top:10px">
                <div class="gtitle" style="margin-bottom:6px">
                  <h3 style="font-size:13px">Audience</h3>
                  <span class="n">{length(@audience)}</span>
                  <span class="lane">· status-filtered preview · email via PiiResolution · first {length(@audience)} rows</span>
                </div>
                <%= if @audience == [] do %>
                  <p style="margin:0;font-size:12px;color:var(--muted)">No matching subscribers yet.</p>
                <% else %>
                  <table style="width:100%;border-collapse:collapse;font-size:13px">
                    <thead>
                      <tr>
                        <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">
                          Email
                        </th>
                        <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">
                          Status
                        </th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={sub <- @audience} class="audience-row" id={"audience-#{sub.id}"}>
                        <td style="padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);font-size:12px;color:var(--muted)">{sub.email}</td>
                        <td style="padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb)">
                          <.pill variant={sub_status_variant(sub.status)}>{sub.status}</.pill>
                        </td>
                      </tr>
                    </tbody>
                  </table>
                <% end %>
              </div>
            </div>

            <.modal
              :if={@show_edit and @edit_form != nil and writable?(@samen_mount)}
              id="edit-segment-modal"
              title="Edit segment"
              on_cancel="cancel_edit"
            >
              <.simple_form
                :let={f}
                for={@edit_form}
                id="edit-segment-form"
                phx-change="validate_edit"
                phx-submit="save_edit"
              >
                <.form_field field={f[:name]} label="Name" />
                <.form_field field={f[:description]} label="Description" type="textarea" />
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

  defp edit_form(mount, org_id, segment) do
    segment
    |> AshPhoenix.Form.for_update(:update, scope: Reads.write_scope(mount, org_id))
    |> to_form()
  end

  defp crumbs(mount, org_id, leaf),
    do: [Crumbs.org(mount, org_id), Crumbs.section(mount, org_id, :marketing), {"Segments", segments_path(mount, org_id)}, leaf]

  defp segments_path(mount, org_id), do: "#{marketing_path(mount)}/segments?org=#{org_id}"

  defp segment_label(nil), do: "Segment"
  defp segment_label(segment), do: segment.name || "Segment"

  defp filter_summary(criteria) when is_map(criteria) and map_size(criteria) > 0 do
    criteria
    |> Enum.map(fn {k, v} -> "#{k}: #{inspect(v)}" end)
    |> Enum.join(", ")
  end

  defp filter_summary(_), do: "all active subscribers"

  defp sub_status_variant(:active), do: "ok"
  defp sub_status_variant(:unsubscribed), do: "bad"
  defp sub_status_variant(:bounced), do: "warn"
  defp sub_status_variant(:complained), do: "bad"
  defp sub_status_variant(_), do: "mut"

  defp format_ts(nil), do: "—"
  defp format_ts(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_ts(other), do: to_string(other)

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to),
      do: socket,
      else: assign(socket, return_to: nil)
  end
end
