defmodule Samen.Web.Finance.CloseDashboard.Live do
  @moduledoc """
  The monthly close dashboard (`/close`) — the DOM egress of
  `Samen.Scopes.Finance.CloseBoard` for the CURRENT cycle.

  The page picks the cycle the way an operator reads one (see
  `Samen.Web.Finance.CloseDashboard`): the newest in-progress run, else the
  newest run, else the newest declared period. The period header always names
  which one is showing, so an empty month is honest about being empty.

  A phase row shows BOTH facts the status is derived from — the sign-off stamp
  and the anchored Work task — so a disagreement is visible where it happens:
  the row reads `open`, the discrepancy list names the phase, and the board's
  progress never counts it. The page never prints `done` for a phase whose task
  is open, even if a sign-off exists.

  ## Governed commands

  The page can START a period's close and SIGN OFF an open phase. Neither
  command is implemented here: the page calls the host's OWN `CloseRun`
  `:start` / `:complete_phase` actions with `Samen.Web.TenantRole.admin_scope/2`
  (the disarmed dev posture's `:admin`, or the authenticated principal's REAL
  membership role on an armed host). The kernel's `OrgScope` + `RoleAtLeast
  :admin` are the final authority, and a refusal (an open Work task, a
  completed run) is shown in the banner verbatim. The buttons are offered on
  the tenant plane to a derived admin only; a crafted event still runs through
  the same governed action.

  A sign-off is written with `TenantRole.attributed_admin_scope/2`, so the
  kernel's `done_by` stamp names the authenticated principal when the host can
  resolve one. The row renders that identity as `you` (the current principal),
  `the workspace` (the dev posture's pseudo-principal), or a short admin id —
  never an invented name, because the close read carries no user directory.
  """

  use Samen.Web.Tenant.Live

  import Samen.UI
  import Samen.Web.Erp.Live, only: [assign_mount: 2, erp_sidebar: 1, writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.Crumbs
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Finance.CloseDashboard
  alias Samen.Web.Mount
  alias Samen.Web.TenantRole

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)

    {:ok,
     socket
     |> assign(
       org_id: org_id,
       state: nil,
       error: nil,
       can_admin?: false,
       actor_id: nil,
       action_error: nil,
       action_notice: nil,
       return_to: nil
     )
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
    do: assign(socket, state: nil, error: :no_org, can_admin?: false, actor_id: nil)

  defp load(socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    can_admin? = writable?(mount) and TenantRole.admin_scope(mount, org_id).actor.role == :admin
    actor_id = TenantRole.principal_actor_id(mount, org_id)

    case CloseDashboard.load(mount, org_id) do
      {:ok, state} ->
        assign(socket, state: state, error: nil, can_admin?: can_admin?, actor_id: actor_id)

      {:error, reason} ->
        assign(socket, state: nil, error: reason, can_admin?: false, actor_id: nil)
    end
  end

  # -- governed commands ------------------------------------------------------

  @impl true
  def handle_event("start_run", _params, socket) do
    %{samen_mount: mount, org_id: org_id, state: state, can_admin?: can_admin?} = socket.assigns

    if can_admin? and state && state.period && is_nil(state.run) do
      case CloseDashboard.start_run(mount, org_id, state.period.id) do
        {:ok, _run} ->
          {:noreply,
           socket
           |> assign(
             action_error: nil,
             action_notice: "Close started for #{period_label(state.period)}."
           )
           |> load()}

        {:error, error} ->
          {:noreply,
           assign(socket,
             action_error: CloseDashboard.error_message(error),
             action_notice: nil
           )}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("complete_phase", %{"phase" => key}, socket) do
    %{samen_mount: mount, org_id: org_id, state: state, can_admin?: can_admin?} = socket.assigns

    if can_admin? and state && state.run do
      case CloseDashboard.complete_phase(mount, org_id, state.run.id, key) do
        {:ok, _run} ->
          {:noreply,
           socket
           |> assign(
             action_error: nil,
             action_notice: "Signed off #{phase_label(state, key)}."
           )
           |> load()}

        {:error, error} ->
          {:noreply,
           assign(socket,
             action_error: CloseDashboard.error_message(error),
             action_notice: nil
           )}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("dismiss_action", _params, socket) do
    {:noreply, assign(socket, action_error: nil, action_notice: nil)}
  end

  @impl Samen.Web.Tenant.Live
  def tenant_sidebar(assigns) do
    ~H"""
    <.erp_sidebar
      mount={@samen_mount}
      org_id={@org_id}
      active={:erp_close}
      return_to={@return_to}
    />
    """
  end

  @impl Samen.Web.Tenant.Live
  def tenant_page(assigns) do
    ~H"""
    <div id="close-dashboard">
      <.topbar title="Monthly close" crumbs={crumbs(@samen_mount, @org_id)}>
        <:actions>
          <a class="button" id="close-dashboard-refresh" href={close_href(@samen_mount, @org_id)}>
            Refresh
          </a>
        </:actions>
      </.topbar>

      <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

      <div class="wrap">
        <%= if @org_id == nil do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <%= if @error != nil do %>
            <div
              class="card"
              id="close-dashboard-unavailable"
              style="padding:16px;color:var(--muted)"
            >
              {error_text(@error)}
            </div>
          <% else %>
            <.close_board
              state={@state}
              mount={@samen_mount}
              org_id={@org_id}
              can_admin?={@can_admin?}
              actor_id={@actor_id}
              action_error={@action_error}
              action_notice={@action_notice}
            />
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  attr :state, :map, required: true
  attr :mount, Mount, required: true
  attr :org_id, :string, required: true
  attr :can_admin?, :boolean, required: true
  attr :actor_id, :string, default: nil
  attr :action_error, :string, default: nil
  attr :action_notice, :string, default: nil

  defp close_board(assigns) do
    ~H"""
    <div
      :if={@action_error}
      id="close-action-error"
      class="card form-error"
      style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px;margin-bottom:10px"
    >
      {@action_error}
      <button
        type="button"
        class="button"
        phx-click="dismiss_action"
        id="close-dismiss-action"
        style="margin-left:10px"
      >
        Dismiss
      </button>
    </div>

    <div
      :if={@action_notice}
      id="close-action-notice"
      class="card"
      style="padding:10px 14px;color:var(--muted);font-size:12px;margin-bottom:10px"
    >
      {@action_notice}
    </div>

    <div class="gtitle">
      <h3>Monthly close</h3>
      <span class="n">{summary(@state.report)}</span>
      <span class="lane">· org-scoped · sign-off and Work task must agree</span>
    </div>

    <.period_card state={@state} />

    <%= if @state.report == nil do %>
      <div class="card" id="close-dashboard-no-run" style="padding:16px;color:var(--muted)">
        <%= if @state.period do %>
          <div>
            No close run has been started for {period_label(@state.period)}.
            <%= if @can_admin? do %>
              Start it here — the ten phases become anchored Work tasks.
            <% else %>
              Only an admin can start the close.
            <% end %>
          </div>
          <button
            :if={@can_admin?}
            type="button"
            class="button"
            id="close-start-run"
            phx-click="start_run"
            data-confirm={"Start the close for #{period_label(@state.period)}? This creates the ten checklist tasks."}
            style="margin-top:10px"
          >
            Start close
          </button>
        <% else %>
          No fiscal period has been declared yet, so there is no close to show.
        <% end %>
      </div>
    <% else %>
      <div class="card" id="close-dashboard-progress" style="padding:12px 16px;margin-bottom:12px">
        <div style="display:flex;gap:14px;flex-wrap:wrap;align-items:baseline">
          <b>{@state.report.completeness.percent}% complete</b>
          <span style="color:var(--muted)">
            {@state.report.completeness.done} of {@state.report.completeness.total} phases signed
            and closed
          </span>
          <span :if={@state.report.completeness.complete?} class="pill ok">completed</span>
        </div>
        <div style="margin-top:8px;height:8px;background:#E5E7EB;border-radius:999px;overflow:hidden">
          <div style={"width:#{@state.report.completeness.percent}%;height:100%;background:#0A5C42"}>
          </div>
        </div>
      </div>

      <div
        :if={@state.report.next_phase}
        class="card"
        id="close-dashboard-next"
        style="padding:12px 16px;margin-bottom:12px"
      >
        <span style="color:var(--muted)">Next up</span>
        <b>{@state.report.next_phase.label}</b>
        <span style="color:var(--muted)">
          · {@state.report.next_phase.days} · lead {@state.report.next_phase.role || "unassigned"}
        </span>
      </div>

      <div class="card" id="close-dashboard-tasks" style="padding:12px 16px;margin-bottom:12px">
        <%= if @state.task_wired? do %>
          <b>{@state.report.tasks.completed}/{@state.report.tasks.total} Work tasks completed</b>
          <span :if={@state.report.tasks.open > 0} style="color:var(--muted)">
            · {@state.report.tasks.open} open
          </span>
          <span :if={@state.report.tasks.missing > 0} style="color:var(--muted)">
            · {@state.report.tasks.missing} phase(s) have no anchored task
          </span>
        <% else %>
          <span id="close-dashboard-work-unwired" style="color:var(--muted)">
            Work is not wired on this host, so task state is not read. The board shows the
            governed sign-off only.
          </span>
        <% end %>
      </div>

      <div
        :if={@state.report.discrepancies != []}
        class="card"
        id="close-dashboard-discrepancies"
        style="padding:12px 16px;margin-bottom:12px;border-left:3px solid #B45309"
      >
        <b>Discrepancies</b>
        <ul style="margin:6px 0 0 18px;color:var(--muted)">
          <li :for={discrepancy <- @state.report.discrepancies}>
            {discrepancy.phase}: {discrepancy.reason}
          </li>
        </ul>
      </div>

      <table style="width:100%;border-collapse:collapse;font-size:13px">
        <thead>
          <tr>
            <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted);width:3%">
              #
            </th>
            <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted);width:26%">
              Phase
            </th>
            <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted);width:12%">
              Window
            </th>
            <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted);width:19%">
              Lead / supporting
            </th>
            <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted);width:10%">
              Signed off
            </th>
            <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted);width:11%">
              Work task
            </th>
            <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted);width:7%">
              Status
            </th>
            <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted);width:12%">
              Action
            </th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={{phase, index} <- Enum.with_index(@state.report.phases)}
            id={"close-phase-#{phase.key}"}
          >
            <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6);color:var(--muted)">
              {index + 1}
            </td>
            <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
              <b>{phase.label}</b>
              <div style="color:var(--muted);font-size:12px">{phase.output}</div>
            </td>
            <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6);color:var(--muted)">
              {phase.days}
            </td>
            <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
              {phase.role || "—"}
              <div :if={supporting(phase) != ""} style="color:var(--muted);font-size:12px">
                {supporting(phase)}
              </div>
            </td>
            <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6);color:var(--muted)">
              {stamp(phase.done_at)}
              <div :if={phase.done_by} style="font-size:11px">
                {signer_label(phase.done_by, @actor_id)}
              </div>
            </td>
            <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
              <%= cond do %>
                <% @state.task_wired? and phase.task == nil -> %>
                  <span style="color:var(--muted)">no task</span>
                <% phase.task == nil -> %>
                  <span style="color:var(--muted)">not read</span>
                <% true -> %>
                  {task_label(phase.task)}
              <% end %>
            </td>
            <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
              <span id={"close-phase-status-#{phase.key}"} data-status={phase.status}>
                <.pill variant={status_variant(phase.status)}>{phase.status}</.pill>
              </span>
            </td>
            <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
              <%= if @state.run && @state.run.status == :in_progress && @can_admin? do %>
                <%= cond do %>
                  <% phase.signed? -> %>
                    <span style="font-size:11px;color:var(--muted)">signed</span>
                  <% @state.task_wired? && phase.task && phase.task.status != :completed -> %>
                    <span style="font-size:11px;color:var(--muted)">
                      Complete the Work task first
                    </span>
                  <% true -> %>
                    <button
                      type="button"
                      class="button"
                      id={"close-sign-#{phase.key}"}
                      phx-click="complete_phase"
                      phx-value-phase={phase.key}
                      data-confirm={"Sign off #{phase.label}? A sign-off cannot be undone."}
                    >
                      Sign off
                    </button>
                <% end %>
              <% else %>
                <span style="font-size:11px;color:var(--muted)">—</span>
              <% end %>
            </td>
          </tr>
        </tbody>
      </table>
    <% end %>
    """
  end

  attr :state, :map, required: true

  defp period_card(assigns) do
    ~H"""
    <div class="card" id="close-dashboard-period" style="padding:12px 16px;margin-bottom:12px">
      <%= if @state.period do %>
        <b>{period_label(@state.period)}</b>
        <span style="color:var(--muted)">· period {@state.period.status}</span>
        <span :if={@state.run} style="color:var(--muted)">· close run {@state.run.status}</span>
      <% else %>
        <span style="color:var(--muted)">No fiscal period declared.</span>
      <% end %>
    </div>
    """
  end

  defp crumbs(mount, org_id), do: [Crumbs.org(mount, org_id), "ERP", "Close"]

  defp close_href(mount, org_id) do
    "#{Mount.label(mount, :close_path, "/close")}?org=#{org_id}"
  end

  defp summary(nil), do: "—"
  defp summary(report), do: "#{report.completeness.done}/#{report.completeness.total}"

  defp phase_label(%{report: %{phases: phases}}, key) do
    case Enum.find(phases, &(&1.key == key)) do
      %{label: label} -> label
      nil -> key
    end
  end

  defp phase_label(_state, key), do: key

  defp period_label(%{year: year, month: month}) when is_integer(year) and is_integer(month) do
    Calendar.strftime(Date.new!(year, month, 1), "%B %Y")
  end

  defp period_label(_period), do: "Current period"

  defp status_variant(:done), do: "ok"
  defp status_variant(_), do: "warn"

  defp supporting(%{roles: roles, role: lead}) when is_list(roles) do
    roles
    |> Enum.reject(&(&1 == lead))
    |> Enum.join(", ")
  end

  defp supporting(_phase), do: ""

  defp task_label(%{status: status, completed_at: completed_at}) do
    case completed_at do
      nil -> to_string(status)
      at -> "#{status} · #{stamp(at)}"
    end
  end

  defp stamp(nil), do: "—"
  defp stamp(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d")
  defp stamp(%NaiveDateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d")

  defp stamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> Calendar.strftime(at, "%Y-%m-%d")
      _ -> value
    end
  end

  defp stamp(value), do: to_string(value)

  defp signer_label("broker:" <> _, _current), do: "the workspace"
  defp signer_label(id, id) when is_binary(id), do: "you"
  defp signer_label(id, _current) when is_binary(id), do: "admin " <> String.slice(id, 0, 8)
  defp signer_label(_other, _current), do: "—"

  defp error_text(:finance_not_mounted),
    do: "This workspace has no Finance mount, so there is no close to show."

  defp error_text(_reason),
    do: "This close dashboard is not available on this workspace's mounted modules."
end
