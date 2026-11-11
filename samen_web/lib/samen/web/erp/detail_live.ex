defmodule Samen.Web.Erp.DetailLive do
  @moduledoc """
  The generic ERP record page (`/erp/:surface/:id`) — the detail twin of
  `Samen.Web.Erp.SurfaceLive` (WS-ERP E8).

  One LiveView serves every surface, addressed through the CLOSED
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
  use Samen.Web.Tenant.Live

  require Ash.Query

  import Samen.UI
  import Samen.Web.Erp.Live, only: [assign_mount: 2, erp_sidebar: 1, writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Approvals
  alias Samen.Web.Crumbs
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Erp
  alias Samen.Web.Mount
  alias Samen.Web.TenantRole
  alias Samen.Scopes.Finance.ApInvoiceMatch

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
       ap_match: nil,
       pending_approval: nil,
       approval_error: nil,
       approval_notice: nil,
       decider_id: nil,
       decider_role: nil,
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
  defp load(%{assigns: %{org_id: nil}} = socket) do
    socket
    |> assign(record: nil, missing: :no_org, resource: nil, ap_match: nil)
    |> clear_approval()
  end

  defp load(%{assigns: %{surface: nil}} = socket) do
    socket
    |> assign(record: nil, missing: :unknown_surface, resource: nil, ap_match: nil)
    |> clear_approval()
  end

  defp load(socket) do
    %{samen_mount: mount, surface: surface, org_id: org_id, record_id: record_id} = socket.assigns

    case Erp.resource(mount, surface) do
      nil ->
        socket
        |> assign(record: nil, missing: :unmounted, resource: nil, ap_match: nil)
        |> clear_approval()

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

        # The AP match panel reads the embedded lines even though they are not
        # a fact-grid field. Select them explicitly for this surface.
        selected = if surface == :ap_invoices, do: Enum.uniq([:lines | selected]), else: selected

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
        |> load_pending_approval()
    end
  end

  defp assign_record(socket, nil) do
    socket
    |> assign(record: nil, missing: :not_found, ap_match: nil)
    |> clear_approval()
  end

  defp assign_record(socket, record) do
    socket =
      assign(socket, record: record, missing: nil, show_edit: false, action_error: nil)

    assign(socket, ap_match: ap_match(socket, record))
  end

  defp ap_match(
         %{assigns: %{surface: :ap_invoices, org_id: org_id, samen_mount: mount}},
         bill
       ) do
    case ApInvoiceMatch.match(bill, org_id, mount.repo) do
      {:ok, result} ->
        lines = Enum.reject(result.lines, &(&1.status == :not_matched))

        state =
          cond do
            lines == [] -> :none
            result.flagged? -> :variance
            true -> :matched
          end

        %{state: state, result: result, lines: lines}

      {:error, reason} ->
        %{state: :error, message: ApInvoiceMatch.error_message(reason)}
    end
  end

  defp ap_match(_socket, _bill), do: nil

  # The bounded per-surface loads — only what the detail page renders.
  defp maybe_load(query, :entries), do: Ash.Query.load(query, :lines)
  defp maybe_load(query, :purchase_orders), do: Ash.Query.load(query, :lines)
  defp maybe_load(query, :goods_receipts), do: Ash.Query.load(query, :lines)
  defp maybe_load(query, _surface), do: query

  # -- events -----------------------------------------------------------------

  @impl true
  def handle_event("edit_record", _params, socket) do
    %{samen_mount: mount, org_id: org_id, record: record} = socket.assigns

    if writable?(mount) and record != nil and Erp.edit_fields(socket.assigns.surface) != [] do
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
      scope =
        if surface == :ap_invoices,
          do: TenantRole.identity_scope(mount, org_id),
          else: Mount.scope(mount, org_id)

      case record |> Ash.Changeset.for_update(action, %{}, scope: scope) |> Ash.update() do
        {:ok, _updated} ->
          {:noreply, load(socket)}

        {:error, error} ->
          socket = load(socket)
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

  def handle_event("decide_approval", %{"decision" => decision}, socket)
      when decision in ["approve", "reject"] do
    %{samen_mount: mount, pending_approval: approval, decider_id: user_id, decider_role: role} =
      socket.assigns

    cond do
      not writable?(mount) ->
        {:noreply,
         assign(socket, approval_error: "Approval decisions are a tenant-plane action.")}

      is_nil(approval) ->
        {:noreply, assign(socket, approval_error: "That approval is no longer pending.")}

      is_nil(user_id) ->
        {:noreply,
         assign(socket,
           approval_error: "Sign in as an organization member to decide this approval."
         )}

      true ->
        decide_approval(socket, approval, decision, user_id, role)
    end
  end

  def handle_event("decide_approval", _params, socket), do: {:noreply, socket}

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

  defp line_anchor(:purchase_orders, %{id: id}) when is_binary(id), do: "po-line-#{id}"
  defp line_anchor(:goods_receipts, %{id: id}) when is_binary(id), do: "receipt-line-#{id}"
  defp line_anchor(_surface, _line), do: nil

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

  @impl Samen.Web.Tenant.Live
  def tenant_sidebar(assigns) do
    ~H"""
    <.erp_sidebar
      mount={@samen_mount}
      org_id={@org_id}
      active={@surface && :"erp_#{@surface}"}
      return_to={@return_to}
    />
    """
  end

  @impl Samen.Web.Tenant.Live
  def tenant_page(assigns) do
    ~H"""
    <div id="erp-detail">
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
          :if={
            writable?(@samen_mount) and @record != nil and @missing == nil and
              Erp.edit_fields(@surface) != []
          }
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
                  <tr :for={line <- lines_of(@record)} id={line_anchor(@surface, line)}>
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

            <.ap_match_panel
              :if={@ap_match}
              match={@ap_match}
              samen_mount={@samen_mount}
              org_id={@org_id}
            />

            <.ap_approval_panel
              :if={@pending_approval}
              approval={@pending_approval}
              samen_mount={@samen_mount}
              decider_id={@decider_id}
              decider_role={@decider_role}
              error={@approval_error}
              notice={@approval_notice}
            />

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
    </div>
    """
  end

  attr(:approval, :map, required: true)
  attr(:samen_mount, :map, required: true)
  attr(:decider_id, :string, default: nil)
  attr(:decider_role, :atom, default: :member)
  attr(:error, :string, default: nil)
  attr(:notice, :string, default: nil)

  defp ap_approval_panel(assigns) do
    steps = approval_steps(assigns.approval)
    current = pending_approval_step(steps)

    assigns =
      assign(assigns,
        steps: steps,
        current: current,
        requester?: requester?(assigns.approval, assigns.decider_id),
        can_decide:
          writable?(assigns.samen_mount) and
            can_decide?(assigns.approval, current, assigns.decider_id, assigns.decider_role)
      )

    ~H"""
    <div id="erp-ap-approval-decision" class="card" style="padding:16px 18px;margin-top:10px">
      <div class="gtitle" style="margin-bottom:6px">
        <h3 style="font-size:13px">Pending AP approval</h3>
        <span class="lane">· {chain_position(@approval, @current)}</span>
      </div>

      <p style="margin:6px 0 10px;font-size:12px;color:var(--muted)">
        A distinct organization member must decide this bill. Role-filtered steps are checked
        against that member's actual role.
      </p>

      <ol :if={@steps != []} id="ap-approval-chain" style="margin:0 0 10px 18px;padding:0;font-size:12px">
        <li
          :for={{step, index} <- Enum.with_index(@steps)}
          id={"ap-approval-step-#{index}"}
          style="padding:2px 0"
        >
          <b>Step {index + 1}</b>
          <span> · {step_label(step)}</span>
          <span> · {step_state(step)}</span>
        </li>
      </ol>

      <p :if={@steps == []} style="margin:6px 0 10px;font-size:12px;color:var(--muted)">
        Single decision — no chain steps.
      </p>

      <p :if={@notice} id="ap-approval-notice" style="margin:6px 0;font-size:12px;color:var(--ok, #047857)">
        {@notice}
      </p>

      <p :if={@error} id="ap-approval-error" style="margin:6px 0;font-size:12px;color:var(--bad, #b91c1c)">
        {@error}
      </p>

      <p :if={is_nil(@decider_id)} id="ap-approval-signed-out" style="margin:6px 0;font-size:12px;color:var(--muted)">
        Sign in as an organization member to decide this approval.
      </p>

      <p :if={@requester?} id="ap-approval-requester" style="margin:6px 0;font-size:12px;color:var(--muted)">
        The requester cannot decide their own approval.
      </p>

      <p
        :if={not is_nil(@decider_id) and not @requester? and not @can_decide}
        id="ap-approval-waiting"
        style="margin:6px 0;font-size:12px;color:var(--muted)"
      >
        Waiting for the member assigned to the current step.
      </p>

      <div :if={@can_decide} style="display:flex;gap:8px;margin-top:10px">
        <.button
          id="approve-ap-approval"
          type="button"
          phx-click="decide_approval"
          phx-value-decision="approve"
        >
          Approve step
        </.button>
        <.button
          id="reject-ap-approval"
          type="button"
          phx-click="decide_approval"
          phx-value-decision="reject"
        >
          Reject
        </.button>
      </div>
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

  defp erp_path(mount), do: Mount.label(mount, :erp_path, "/erp")

  defp ap_match_panel(assigns) do
    ~H"""
    <div id="erp-ap-match" class="card" style="padding:16px 18px;margin-top:10px">
      <div style="display:flex;justify-content:space-between;align-items:baseline;gap:12px">
        <h3 style="font-size:13px">Three-way match</h3>
        <span id="ap-match-status" style={"font-size:12px;font-weight:700;color:#{match_color(@match.state)}"}>
          {match_label(@match.state)}
        </span>
      </div>

      <%= if @match.state == :error do %>
        <div id="ap-match-error" style="margin-top:10px;font-size:12px;color:var(--bad, #b91c1c)">
          Three-way match could not be computed: {@match.message}
        </div>
      <% else %>
        <p id="ap-match-tolerance" style="margin:6px 0 10px;font-size:12px;color:var(--muted)">
          Bill tolerance: {money(@match.result.tolerance_cents)} or {@match.result.tolerance_pct}% of received value.
        </p>

        <div :if={@match.state == :none} id="ap-match-none" style="font-size:13px;color:var(--muted)">
          No PO/receipt references on this bill, so no three-way match applies.
        </div>

        <%= if @match.state != :none do %>
          <div
            :if={@match.state == :variance}
            id="ap-match-variance"
            style="padding:8px 10px;margin-bottom:10px;font-size:12px;color:var(--bad, #b91c1c);border:1px solid currentColor;border-radius:6px"
          >
            One or more referenced lines exceed tolerance. Approval will be refused until the receipt or tolerance changes.
          </div>
          <div
            :if={@match.state == :matched}
            id="ap-match-matched"
            style="padding:8px 10px;margin-bottom:10px;font-size:12px;color:var(--ok, #047857);border:1px solid currentColor;border-radius:6px"
          >
            All referenced lines are within tolerance.
          </div>

          <table id="ap-match-lines" style="width:100%;border-collapse:collapse;font-size:12px">
            <thead>
              <tr>
                <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Line</th>
                <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">PO line</th>
                <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Receipt line</th>
                <th scope="col" style="text-align:right;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Billed</th>
                <th scope="col" style="text-align:right;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Received</th>
                <th scope="col" style="text-align:right;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Variance</th>
                <th scope="col" style="text-align:right;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Tolerance</th>
                <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">Status</th>
              </tr>
            </thead>
            <tbody>
              <tr :for={line <- @match.lines} id={"ap-match-line-#{line.line}"}>
                <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">{line.line}</td>
                <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6);font-family:monospace;word-break:break-all">
                  <a
                    :if={line.purchase_order_id && line.po_line_id}
                    href={"#{erp_path(@samen_mount)}/purchase_orders/#{line.purchase_order_id}?org=#{@org_id}#po-line-#{line.po_line_id}"}
                    style="color:var(--accent, #2563eb)"
                  >
                    {line_value(line, :po_line_id)}
                  </a>
                  <span :if={!(line.purchase_order_id && line.po_line_id)}>
                    {line_value(line, :po_line_id)}
                  </span>
                </td>
                <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6);font-family:monospace;word-break:break-all">
                  <a
                    :if={line.goods_receipt_id && line.receipt_line_id}
                    href={"#{erp_path(@samen_mount)}/goods_receipts/#{line.goods_receipt_id}?org=#{@org_id}#receipt-line-#{line.receipt_line_id}"}
                    style="color:var(--accent, #2563eb)"
                  >
                    {line.receipt_line_id}
                  </a>
                  <span :if={!(line.goods_receipt_id && line.receipt_line_id)}>
                    {if line.receipt_line_id, do: line.receipt_line_id, else: "All receipts"}
                  </span>
                </td>
                <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6);text-align:right">{money(line.billed_cents)}</td>
                <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6);text-align:right">{money(line.received_cents)}</td>
                <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6);text-align:right">{money(line.variance_cents)}</td>
                <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6);text-align:right">{money(line.tolerance_cents)}</td>
                <td style={"padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6);color:#{match_color(line.status)}"}>
                  {line_status_label(line.status)}
                </td>
              </tr>
            </tbody>
          </table>
        <% end %>
      <% end %>
    </div>
    """
  end

  defp match_label(:matched), do: "Within tolerance"
  defp match_label(:variance), do: "Variance"
  defp match_label(:none), do: "No match references"
  defp match_label(:error), do: "Unavailable"

  defp match_color(:matched), do: "var(--ok, #047857)"
  defp match_color(:variance), do: "var(--bad, #b91c1c)"
  defp match_color(:error), do: "var(--bad, #b91c1c)"
  defp match_color(_state), do: "var(--muted)"

  defp line_status_label(:matched), do: "Within tolerance"
  defp line_status_label(:variance), do: "Over tolerance"
  defp line_status_label(_status), do: "Not matched"

  defp money(cents) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    cents = abs(cents)

    "#{sign}$#{div(cents, 100)}.#{cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp money(other), do: to_string(other)

  defp load_pending_approval(
         %{
           assigns: %{
             surface: :ap_invoices,
             org_id: org_id,
             record: %{id: bill_id} = bill,
             samen_mount: mount
           }
         } = socket
       )
       when is_binary(org_id) and is_binary(bill_id) do
    {decider_id, decider_role} = decider(mount, org_id)
    approval_kind = Samen.Approvals.Gate.kind_for(bill.__struct__, :approve)

    pending_approval =
      case Approvals.list_pending(org_id, approval_kind) do
        {:ok, approvals} -> Enum.find(approvals, &approval_for_bill?(&1, bill_id))
        {:error, _reason} -> nil
      end

    assign(socket,
      pending_approval: pending_approval,
      approval_error: nil,
      approval_notice: nil,
      decider_id: decider_id,
      decider_role: decider_role
    )
  end

  defp load_pending_approval(socket), do: clear_approval(socket)

  defp clear_approval(socket) do
    assign(socket,
      pending_approval: nil,
      approval_error: nil,
      approval_notice: nil,
      decider_id: nil,
      decider_role: nil
    )
  end

  defp decider(%Mount{} = mount, org_id) do
    principal = Mount.label(mount, TenantRole.principal_label(), nil)

    {
      TenantRole.principal_actor_id(mount, org_id),
      TenantRole.membership_role(mount, org_id, principal)
    }
  end

  defp decider(_mount, _org_id), do: {nil, :member}

  defp approval_for_bill?(%{subject_ref: ref}, bill_id) when is_binary(ref),
    do: String.ends_with?(ref, ":" <> bill_id)

  defp approval_for_bill?(_approval, _bill_id), do: false

  defp decide_approval(socket, approval, "approve", user_id, role) do
    case Approvals.approve(approval.id, user_id, role: role) do
      {:ok, decided, _meta} ->
        socket = load(socket)

        notice =
          if decided.state == :pending,
            do: "Step approved. The bill is waiting for the next step.",
            else: "Bill approved and posted."

        {:noreply, assign(socket, approval_notice: notice)}

      {:error, reason} ->
        {:noreply, assign(socket, approval_error: approval_error(reason))}
    end
  end

  defp decide_approval(socket, approval, "reject", user_id, role) do
    case Approvals.reject(approval.id, user_id, role: role) do
      {:ok, _decided} ->
        socket = load(socket)
        {:noreply, assign(socket, approval_notice: "Approval rejected. The bill remains draft.")}

      {:error, reason} ->
        {:noreply, assign(socket, approval_error: approval_error(reason))}
    end
  end

  defp approval_error(:self_approval),
    do: "The approver must be a different party than the requester."

  defp approval_error(:step_approver_mismatch),
    do: "This step is assigned to a different member or role."

  defp approval_error(:not_pending), do: "That approval has already been decided."
  defp approval_error(:not_found), do: "That approval no longer exists."
  defp approval_error(:no_approver), do: "A signed-in organization member is required."

  defp approval_error(:no_approvals_module),
    do: "The approvals engine is not configured for this workspace."

  defp approval_error({:gate_action_failed, _reason}),
    do: "The bill action failed; the approval is still pending."

  defp approval_error({:subject_unavailable, _reason}),
    do: "The bill is no longer available; the approval is still pending."

  defp approval_error(_reason), do: "Could not record that approval decision."

  defp approval_steps(%{steps: steps}) when is_list(steps), do: steps
  defp approval_steps(_approval), do: []

  defp pending_approval_step([]), do: nil
  defp pending_approval_step(steps), do: Enum.find(steps, &(step_state(&1) == "pending"))

  defp chain_position(%{steps: []}, _current), do: "single decision"

  defp chain_position(%{steps: steps}, current) when is_map(current) do
    index = Enum.find_index(steps, &(&1 == current))
    "Step #{index + 1} of #{length(steps)}"
  end

  defp chain_position(_approval, _current), do: "all steps decided"

  defp step_label(%{"approver_type" => "role", "approver" => role}), do: "Role · #{role}"

  defp step_label(%{"approver_type" => "user", "approver" => user, "role" => role}),
    do: "User · #{user} · #{role} only"

  defp step_label(%{"approver_type" => "user", "approver" => user}), do: "User · #{user}"
  defp step_label(_step), do: "Unassigned"

  defp step_state(%{"state" => state}) when is_binary(state), do: state
  defp step_state(_step), do: "pending"

  defp requester?(%{requested_by: requested_by}, decider_id) when is_binary(decider_id),
    do: to_string(requested_by) == decider_id

  defp requester?(_approval, _decider_id), do: false

  defp can_decide?(_approval, _current, nil, _role), do: false

  defp can_decide?(approval, current, decider_id, decider_role) do
    not requester?(approval, decider_id) and
      actor_matches_step?(current, decider_id, decider_role)
  end

  defp actor_matches_step?(nil, _decider_id, _decider_role), do: true

  defp actor_matches_step?(
         %{"approver_type" => "user", "approver" => approver} = step,
         decider_id,
         decider_role
       ) do
    approver == decider_id and step_role_matches?(step, decider_role)
  end

  defp actor_matches_step?(
         %{"approver_type" => "role", "approver" => role},
         _decider_id,
         decider_role
       ) do
    to_string(decider_role) == role
  end

  defp actor_matches_step?(_step, _decider_id, _decider_role), do: false

  defp step_role_matches?(%{"role" => role}, decider_role),
    do: to_string(decider_role) == role

  defp step_role_matches?(_step, _decider_role), do: true
end
