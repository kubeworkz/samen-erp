defmodule Samen.Web.Erp.DetailLive do
  @moduledoc """
  The generic ERP record page (`/erp/:surface/:id`) — the detail twin of
  `Samen.Web.Erp.SurfaceLive` (WS-ERP E8).

  One LiveView serves all six surfaces, addressed through the CLOSED
  `Samen.Web.Erp` allowlist exactly like the list: the surface name resolves
  through `Erp.surface/1`, the record's resource through `Erp.resource/2`
  (never caller input), and the single read is org-scope-pinned
  (`Samen.Web.Mount.scope/2` → the kernel's `OrgScope` policy) with the
  bounded `Erp.detail_fields/1` facts rendered — mask-by-omission one level
  deeper than the table's `columns/1`.

  ## Write side (the resources' OWN governed actions)

    * **Edit** — `AshPhoenix.Form.for_update(record, :update, …)` over the
      bounded `Erp.edit_fields/1` list (exactly the action's `accept`);
      inline errors ride the kit's `form_field/1`.
    * **Transitions** — `Erp.transitions/1` names only `accept([])` state
      actions (`:post`/`:void`/`:approve`/`:release`/`:complete`/`:cancel`/
      `:close`), offered when the record's status is in the action's
      `from_statuses` — re-checked SERVER-side against the registry, never
      trusting the click. A Gate-guarded `:approve` that opens an approval is
      surfaced honestly as the inline banner (the approval id included), not
      as a silent success.
    * **Posture** — buttons/forms render only under
      `Samen.Web.Erp.Live.writable?/1` (tenant plane); the kernel's
      `OrgScope` + `RoleAtLeast :member` govern the write regardless. There
      is NO destroy action anywhere here (the surfaces' documented posture:
      retire/archive lives with the resource, never a surface button).

  Detail loads are bounded per surface: journal lines, the PO's lines, and
  the work order's item (the facts a reader needs to act); the AP bill's
  lines are an embedded attribute, read with the row.
  """
  use Phoenix.LiveView

  require Ash.Query

  import Samen.UI
  import Samen.Web.Erp.Live, only: [assign_mount: 2, erp_sidebar: 1, writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.Crumbs
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Erp
  alias Samen.Web.Mount

  @impl true
  def mount(%{"surface" => raw, "id" => id} = params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)

    {:ok,
     socket
     |> assign(
       surface: Erp.surface(raw),
       record_id: id,
       org_id: org_id,
       record: nil,
       missing: :unknown_surface,
       show_edit: false,
       edit_form: nil,
       action_error: nil,
       return_to: nil
     )
     |> load()}
  end

  @impl true
  def handle_params(%{"surface" => raw, "id" => id} = params, uri, socket) do
    org_id = CurrentOrg.reresolve(socket, params)

    {:noreply,
     socket
     |> assign(
       surface: Erp.surface(raw),
       record_id: id,
       org_id: org_id,
       return_to: return_path(uri)
     )
     |> load()}
  end

  # Every path assigns `:record` and `:missing` — the render branches read
  # them directly (the class of bug the old surface's `Map.get(@assigns, …)`
  # idiom raised on every real render).
  defp load(%{assigns: %{org_id: nil}} = socket),
    do: assign(socket, record: nil, missing: :no_org, resource: nil)

  defp load(%{assigns: %{surface: nil}} = socket),
    do: assign(socket, record: nil, missing: :unknown_surface, resource: nil)

  defp load(socket) do
    %{samen_mount: mount, surface: surface, org_id: org_id, record_id: record_id} = socket.assigns

    case Erp.resource(mount, surface) do
      nil ->
        assign(socket, record: nil, missing: :unmounted, resource: nil)

      resource ->
        scope = Mount.scope(mount, org_id)

        # The Samen core columns (`org_id`/`inserted_at`) are NOT
        # select-by-default — the house idiom is an explicit select: the
        # bounded detail facts UNION the edit form's prefill needs, nothing
        # more (mask-by-omission holds at the column level too).
        selected =
          Enum.uniq(
            Erp.detail_fields(surface) ++
              Enum.map(Erp.edit_fields(surface), fn {field, _, _} -> field end)
          )

        record =
          resource
          |> Ash.Query.filter(id == ^record_id)
          |> Ash.Query.select(selected)
          |> Ash.Query.limit(1)
          |> maybe_load(surface)
          |> Ash.read(scope: scope)
          |> case do
            {:ok, [rec | _]} -> rec
            {:ok, []} -> nil
            {:error, _} -> nil
          end

        socket
        |> assign(resource: resource)
        |> assign_record(record)
    end
  end

  defp assign_record(socket, nil), do: assign(socket, record: nil, missing: :not_found)

  defp assign_record(socket, record),
    do: assign(socket, record: record, missing: nil, show_edit: false, action_error: nil)

  # The bounded per-surface loads — only what the detail page renders.
  defp maybe_load(query, :entries), do: Ash.Query.load(query, :lines)
  defp maybe_load(query, :purchase_orders), do: Ash.Query.load(query, :lines)
  defp maybe_load(query, _surface), do: query

  # -- events -----------------------------------------------------------------

  @impl true
  def handle_event("edit_record", _params, socket) do
    %{samen_mount: mount, org_id: org_id, record: record} = socket.assigns

    if writable?(mount) and record do
      scope = Mount.scope(mount, org_id)

      form =
        record
        |> AshPhoenix.Form.for_update(:update, scope: scope)
        |> to_form()

      {:noreply, assign(socket, show_edit: true, edit_form: form)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, show_edit: false)}
  end

  def handle_event("validate_edit", %{"form" => params}, socket) do
    {:noreply,
     assign(socket, edit_form: AshPhoenix.Form.validate(socket.assigns.edit_form, params))}
  end

  def handle_event("save_edit", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.edit_form, params: params) do
      {:ok, _record} ->
        socket = assign(socket, show_edit: false)
        {:noreply, load(socket)}

      {:error, form} ->
        {:noreply, assign(socket, edit_form: form)}
    end
  end

  # A governed state transition — `accept([])`, no caller inputs. The action
  # and its pre-state are re-checked against the REGISTRY server-side (the
  # client's phx-value is only a hint); the resource's own state machine
  # guard is the final word, and its refusal lands in the honest banner.
  def handle_event("transition", %{"action" => action}, socket) do
    %{samen_mount: mount, org_id: org_id, surface: surface, record: record} = socket.assigns
    action = String.to_existing_atom(action)

    with true <- writable?(mount),
         true <- record != nil,
         {^action, _label, from} <-
           Enum.find(Erp.transitions(surface), fn {a, _, _} -> a == action end),
         true <- Map.get(record, :status) in from do
      scope = Mount.scope(mount, org_id)

      case record |> Ash.Changeset.for_update(action, %{}, scope: scope) |> Ash.update() do
        {:ok, _updated} ->
          {:noreply, load(socket)}

        {:error, error} ->
          {:noreply, assign(socket, action_error: error_message(error))}
      end
    else
      _ -> {:noreply, socket}
    end
  rescue
    ArgumentError -> {:noreply, socket}
  end

  def handle_event("dismiss_error", _params, socket) do
    {:noreply, assign(socket, action_error: nil)}
  end

  # -- helpers ----------------------------------------------------------------

  defp crumbs(mount, org_id, surface, record) do
    base = [Crumbs.org(mount, org_id), "ERP"]
    base = if surface, do: base ++ [Erp.label(surface)], else: base
    if record, do: base ++ [record_title(surface, record)], else: base
  end

  defp record_title(surface, record) do
    case {surface, record} do
      {:coa, r} -> r.name
      {:stock, r} -> r.name
      {:entries, r} -> "#{r.entry_date}"
      {:ap_invoices, r} -> r.number
      {:purchase_orders, r} -> r.number
      {:work_orders, r} -> r.number
      {_, r} -> Map.get(r, :id, "Record") |> to_string()
    end
  end

  # The fact grid's value rendering — plain text, no `raw/1`: atoms humanized,
  # dates/datetimes as ISO, uuids full (copy-able), nils (and an un-selected
  # core column) as an em dash.
  defp fact_value(record, field) do
    case Map.get(record, field) do
      nil -> "—"
      %Ash.NotLoaded{} -> "—"
      v when is_atom(v) -> Atom.to_string(v)
      %Date{} = d -> Date.to_iso8601(d)
      %DateTime{} = dt -> DateTime.to_iso8601(dt)
      v when is_binary(v) -> v
      v -> to_string(v)
    end
  end

  # A line row cell: JournalLine/PoLine structs (atom keys) or the AP bill's
  # embedded jsonb maps (string keys) — one accessor, nil/blank/unselected
  # honest.
  defp line_value(row, field) do
    case Map.get(row, field) || Map.get(row, Atom.to_string(field)) do
      nil -> "—"
      "" -> "—"
      %Ash.NotLoaded{} -> "—"
      v when is_atom(v) and not is_boolean(v) -> Atom.to_string(v)
      v when is_binary(v) -> v
      v -> to_string(v)
    end
  end

  defp lines_of(record) do
    case Map.get(record, :lines) do
      lines when is_list(lines) -> lines
      _ -> []
    end
  end

  defp humanize(field),
    do: field |> Atom.to_string() |> String.replace("_", " ") |> String.capitalize()

  defp input_type(:text), do: "text"
  defp input_type(:number), do: "number"
  defp input_type(:date), do: "date"
  defp input_type(:select), do: "select"

  defp allowed_transitions(record, surface) do
    status = record && Map.get(record, :status)

    Enum.filter(Erp.transitions(surface), fn {_action, _label, from} ->
      status != nil and status in from
    end)
  end

  # Surface the first leaf error's message (Ash errors nest; a Gate-guarded
  # action's `ApprovalRequired` carries the pending approval id — keep it).
  defp error_message(error) do
    error
    |> leaf_message()
    |> String.replace(~r/\s+/, " ")
    |> String.slice(0, 240)
  rescue
    _ -> "Could not apply that change."
  end

  defp leaf_message(%{errors: [first | _]}), do: leaf_message(first)
  defp leaf_message(%{message: message}) when is_binary(message), do: message
  defp leaf_message(other), do: Exception.message(other)

  @impl true
  def render(assigns) do
    ~H"""
    <div id="erp-detail">
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
          title={topbar_title(@surface, @record)}
          crumbs={crumbs(@samen_mount, @org_id, @surface, @record)}
        >
          <:actions>
            <a href={list_href(@surface, @org_id)} class="btn" style="text-decoration:none">
              <span class="i">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M19 12H5M12 5l-7 7 7 7" />
                </svg>
              </span>
              Back to {if(@surface, do: Erp.label(@surface), else: "ERP")}
            </a>
            <.button
              :if={writable?(@samen_mount) and @record != nil and @missing == nil}
              phx-click="edit_record"
              id="edit-record"
            >
              Edit {if(@surface, do: Erp.record_label(@surface), else: "record")}
            </.button>
          </:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <div class="wrap">
          <%= if @missing == :no_org do %>
            <.no_org_card mount={@samen_mount} />
          <% else %>
            <div :if={@action_error} id="action-error" class="card form-error" style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px;margin-bottom:10px">
              {@action_error}
              <.button type="button" phx-click="dismiss_error" id="dismiss-error" style="margin-left:10px">
                Dismiss
              </.button>
            </div>

            <%= if @missing in [:unknown_surface, :unmounted] do %>
              <div class="card" style="padding:16px;color:var(--muted)">
                This surface is not available on this workspace's mounted modules.
              </div>
            <% else %>
              <div :if={@missing == :not_found} class="card" style="padding:16px;color:var(--muted)">
                {if(@surface, do: Erp.record_label(@surface), else: "Record")} not found.
              </div>

              <div :if={@missing == nil} id="erp-detail-body">
                <div class="gtitle">
                  <h3>{record_title(@surface, @record)}</h3>
                  <span class="lane">· org-scoped · governed writes</span>
                </div>

                <div class="card" id="erp-facts" style="padding:16px 18px">
                  <dl style="display:grid;grid-template-columns:minmax(140px,220px) 1fr;gap:8px 16px;margin:0">
                    <div :for={field <- Erp.detail_fields(@surface)} style="display:contents">
                      <dt style="font-size:12px;font-weight:600;color:var(--muted)">{humanize(field)}</dt>
                      <dd style="margin:0;font-size:13px;font-family:monospace;word-break:break-all">
                        {fact_value(@record, field)}
                      </dd>
                    </div>
                  </dl>
                </div>

                <div :if={Erp.line_fields(@surface) != []} class="card" id="erp-lines" style="padding:16px 18px;margin-top:10px">
                  <div class="gtitle" style="margin-bottom:6px">
                    <h3 style="font-size:13px">Lines</h3>
                    <span class="n">{length(lines_of(@record))}</span>
                  </div>
                  <table :if={lines_of(@record) != []} style="width:100%;border-collapse:collapse;font-size:13px">
                    <thead>
                      <tr>
                        <th
                          :for={{field, _type, _opts} <- Erp.line_fields(@surface)}
                          scope="col"
                          style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)"
                        >
                          {humanize(field)}
                        </th>
                      </tr>
                    </thead>
                    <tbody>
                      <tr :for={line <- lines_of(@record)}>
                        <td
                          :for={{field, _type, _opts} <- Erp.line_fields(@surface)}
                          style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6);font-family:monospace"
                        >
                          {line_value(line, field)}
                        </td>
                      </tr>
                    </tbody>
                  </table>
                  <div :if={lines_of(@record) == []} style="color:var(--muted);font-size:13px;padding:8px 0">
                    No lines.
                  </div>
                </div>

                <div
                  :if={writable?(@samen_mount) and allowed_transitions(@record, @surface) != []}
                  id="erp-transitions"
                  class="card"
                  style="padding:12px 16px;margin-top:10px;display:flex;gap:8px;align-items:center;flex-wrap:wrap"
                >
                  <span style="font-size:12px;font-weight:600;color:var(--muted)">Status actions</span>
                  <.button
                    :for={{action, label, _from} <- allowed_transitions(@record, @surface)}
                    id={"transition-#{action}"}
                    type="button"
                    phx-click="transition"
                    phx-value-action={action}
                  >
                    {label}
                  </.button>
                </div>
              </div>
            <% end %>
          <% end %>
        </div>

        <.modal :if={@show_edit and @edit_form != nil} id="erp-edit-modal" title={"Edit " <> Erp.record_label(@surface)} on_cancel="cancel_edit">
          <.simple_form :let={f} for={@edit_form} id="erp-edit-form" phx-change="validate_edit" phx-submit="save_edit">
            <.form_field
              :for={{field, type, opts} <- Erp.edit_fields(@surface)}
              field={f[field]}
              label={humanize(field)}
              type={input_type(type)}
              options={opts[:options] || []}
              placeholder={opts[:placeholder]}
            />
            <:actions>
              <.button variant="primary" type="submit">Save changes</.button>
              <.button type="button" phx-click="cancel_edit">Cancel</.button>
            </:actions>
          </.simple_form>
        </.modal>
      </.app_shell>
    </div>
    """
  end

  defp topbar_title(surface, record) do
    cond do
      surface == nil -> "Not found"
      record != nil -> record_title(surface, record)
      true -> Erp.label(surface)
    end
  end

  defp list_href(nil, _org_id), do: "/erp"
  defp list_href(surface, nil), do: "/erp/#{surface}"
  defp list_href(surface, org_id), do: "/erp/#{surface}?org=#{org_id}"
end
