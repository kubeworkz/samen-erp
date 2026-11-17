defmodule Samen.Web.Finance.CloseDashboard.Live do
  @moduledoc """
  The monthly close dashboard (`/close`) — the DOM egress of
  `Samen.Scopes.Finance.CloseBoard` for the CURRENT cycle.

  The page picks the cycle the way an operator reads one (see
  `Samen.Web.Finance.CloseDashboard`): the newest in-progress run, else the
  newest run, else the newest declared period. The period header always names
  which one is showing, so an empty month is honest about being empty.

  A phase row shows the facts the status is derived from — the sign-off stamp,
  the evidence/reviewer, and the anchored Work task — so a disagreement is
  visible where it happens: the row reads `open`, the discrepancy list names
  the phase, and the board's progress never counts it. The page never prints
  `done` for a phase whose task is open or whose evidence/review is missing.

  ## Governed commands

  The page can START a period's close, RECORD a phase's evidence and independent
  reviewer sign-off, SIGN OFF the phase, COMPLETE the run once every phase is
  done, and HOLD one unresolved imported payroll register with a named
  exception. None of these commands is implemented here: the page calls the
  host's OWN `CloseRun` `:start` / `:review_phase` / `:complete_phase` /
  `:finish` and `PayrollImport` `:hold` actions with
  `Samen.Web.TenantRole.attributed_admin_scope/2` (the disarmed dev posture's
  `:admin`, or the authenticated principal's REAL membership role on an armed
  host, with the actor id naming the principal when one resolves). The kernel's
  `OrgScope` + `RoleAtLeast :admin` are the final authority, and a refusal (an
  open Work task, an open phase, a completed run, a blank or PII-shaped
  exception) is shown in the banner verbatim. The buttons are offered on the
  tenant plane to a derived admin only; a crafted event still runs through the
  same governed action.

  The same scope means the kernel's `started_by`, `done_by` and `completed_by`
  stamps name the authenticated principal when the host can resolve one. The
  period card names the starter and, for a completed run, the finisher; each
  phase row names its signer and reviewer. Each identity renders as `you` (the current
  principal), `the workspace` (the dev posture's pseudo-principal), or a short
  admin id — never an invented name, because the close read carries no user
  directory.
  """

  use Samen.Web.Tenant.Live

  import Samen.UI
  import Samen.Web.Erp.Live, only: [assign_mount: 2, erp_sidebar: 1, writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.Crumbs
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Finance.CloseDashboard
  alias Samen.Web.Finance.PayrollSettlements
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
       write_actor_id: nil,
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
    do:
      assign(socket,
        state: nil,
        error: :no_org,
        can_admin?: false,
        actor_id: nil,
        write_actor_id: nil
      )

  defp load(socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    can_admin? = writable?(mount) and TenantRole.admin_scope(mount, org_id).actor.role == :admin
    actor_id = TenantRole.principal_actor_id(mount, org_id)
    write_actor_id = TenantRole.attributed_admin_scope(mount, org_id).actor.id

    case CloseDashboard.load(mount, org_id) do
      {:ok, state} ->
        assign(socket,
          state: state,
          error: nil,
          can_admin?: can_admin?,
          actor_id: actor_id,
          write_actor_id: write_actor_id
        )

      {:error, reason} ->
        assign(socket,
          state: nil,
          error: reason,
          can_admin?: false,
          actor_id: nil,
          write_actor_id: nil
        )
    end
  end

  # -- governed commands ------------------------------------------------------

  @impl true
  def handle_event("start_run", _params, socket) do
    %{samen_mount: mount, org_id: org_id, state: state, can_admin?: can_admin?} = socket.assigns

    if (can_admin? and state) && state.period && is_nil(state.run) do
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

  def handle_event("review_phase", %{"phase" => key} = params, socket) do
    %{samen_mount: mount, org_id: org_id, state: state, can_admin?: can_admin?} = socket.assigns
    evidence_files = parse_evidence_files(Map.get(params, "evidence_files"))

    if (can_admin? and state) && state.run do
      case CloseDashboard.review_phase(mount, org_id, state.run.id, key, evidence_files) do
        {:ok, _run} ->
          {:noreply,
           socket
           |> assign(
             action_error: nil,
             action_notice:
               "Recorded evidence and reviewer sign-off for #{phase_label(state, key)}."
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

    if (can_admin? and state) && state.run do
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

  def handle_event("hold_payroll", %{"import_id" => import_id, "exception" => exception}, socket)
      when is_binary(import_id) and is_binary(exception) do
    %{samen_mount: mount, org_id: org_id, state: state, can_admin?: can_admin?} = socket.assigns

    if can_admin? and state do
      case CloseDashboard.hold_payroll(mount, org_id, import_id, exception) do
        {:ok, import} ->
          {:noreply,
           socket
           |> assign(
             action_error: nil,
             action_notice:
               "Held #{import.provider}/#{import.external_id} with a named exception."
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

  def handle_event("hold_payroll", _params, socket), do: {:noreply, socket}

  def handle_event("prepare_payroll_settlement", params, socket) do
    %{samen_mount: mount, org_id: org_id, state: state, can_admin?: can_admin?} = socket.assigns

    if can_admin? and state do
      case PayrollSettlements.prepare(mount, org_id, params) do
        {:ok, _settlement} ->
          {:noreply,
           socket
           |> assign(
             action_error: nil,
             action_notice: "Prepared payroll settlement."
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

  def handle_event("post_payroll_settlement", %{"settlement_id" => settlement_id}, socket)
      when is_binary(settlement_id) do
    %{samen_mount: mount, org_id: org_id, state: state, can_admin?: can_admin?} = socket.assigns

    if can_admin? and state do
      case PayrollSettlements.post(mount, org_id, settlement_id) do
        {:ok, _settlement} ->
          {:noreply,
           socket
           |> assign(
             action_error: nil,
             action_notice: "Posted payroll settlement."
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

  def handle_event("post_payroll_settlement", _params, socket), do: {:noreply, socket}

  def handle_event("finish_run", _params, socket) do
    %{samen_mount: mount, org_id: org_id, state: state, can_admin?: can_admin?} = socket.assigns

    if (can_admin? and state) && state.run do
      case CloseDashboard.finish_run(mount, org_id, state.run.id) do
        {:ok, _run} ->
          {:noreply,
           socket
           |> assign(
             action_error: nil,
             action_notice: "Close completed for #{period_label(state.period)}."
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
              write_actor_id={@write_actor_id}
              action_error={@action_error}
              action_notice={@action_notice}
            />
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  attr(:state, :map, required: true)
  attr(:mount, Mount, required: true)
  attr(:org_id, :string, required: true)
  attr(:can_admin?, :boolean, required: true)
  attr(:actor_id, :string, default: nil)
  attr(:write_actor_id, :string, default: nil)
  attr(:action_error, :string, default: nil)
  attr(:action_notice, :string, default: nil)

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
      <span class="lane">
        · org-scoped · task, evidence, independent review and sign-off must agree
      </span>
    </div>

    <.period_card state={@state} actor_id={@actor_id} />

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

        <div
          :if={@can_admin? and @state.run.status == :in_progress and close_ready?(@state.report)}
          style="margin-top:10px;display:flex;gap:10px;align-items:center;flex-wrap:wrap"
        >
          <button
            type="button"
            class="button"
            id="close-finish-run"
            phx-click="finish_run"
            data-confirm={"Complete the close for #{period_label(@state.period)}? This is one-way — a completed close cannot be reopened."}
          >
            Complete close
          </button>
          <span style="color:var(--muted);font-size:12px">
            All {@state.report.completeness.total} phases are signed and closed.
          </span>
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

      <.payroll_card
        :if={@state.report.payroll}
        payroll={@state.report.payroll}
        period={@state.period}
        actor_id={@actor_id}
        can_admin?={@can_admin?}
      />

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
                {actor_label(phase.done_by, @actor_id)}
              </div>
              <div :if={phase.evidence_files != []} style="font-size:11px">
                <%= if @state.docs_wired? do %>
                  <div>Evidence:</div>
                  <div :for={file_id <- phase.evidence_files}>
                    <%= if evidence_href(@mount, @org_id, @state.evidence_titles, @state.evidence_status, file_id) do %>
                      <a
                        href={evidence_href(@mount, @org_id, @state.evidence_titles, @state.evidence_status, file_id)}
                        style="color:inherit;text-decoration:underline"
                      >
                        {evidence_label(@state.evidence_titles, file_id)}
                      </a>
                    <% else %>
                      {evidence_label(@state.evidence_titles, file_id)}
                      <span
                        :if={evidence_flag(@state.evidence_status, file_id)}
                        style="color:#B45309;font-size:10px"
                      >
                        · {evidence_flag(@state.evidence_status, file_id)}
                      </span>
                      <a
                        :if={evidence_trash_href(@mount, @org_id, @state.evidence_status, file_id)}
                        href={evidence_trash_href(@mount, @org_id, @state.evidence_status, file_id)}
                        style="color:#B45309;font-size:10px"
                      >
                        · open trash
                      </a>
                    <% end %>
                  </div>
                <% else %>
                  {length(phase.evidence_files)} evidence file(s)
                <% end %>
              </div>
              <div :if={phase.reviewed_by} style="font-size:11px">
                reviewed by {actor_label(phase.reviewed_by, @actor_id)}
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
                  <% !phase.reviewed? -> %>
                    <form
                      phx-submit="review_phase"
                      id={"close-review-form-#{phase.key}"}
                      style="display:flex;flex-direction:column;gap:4px"
                    >
                      <input type="hidden" name="phase" value={phase.key} />
                      <%= if @state.docs_wired? do %>
                        <div
                          id={"close-evidence-picker-#{phase.key}"}
                          style="display:flex;flex-direction:column;gap:3px;max-height:120px;overflow:auto;border:1px solid var(--border, #e5e7eb);padding:4px;border-radius:4px"
                        >
                          <span style="font-size:10px;color:var(--muted)">Docs evidence</span>
                          <span
                            :if={@state.docs == []}
                            style="font-size:11px;color:var(--muted)"
                          >
                            No live Docs pages in this workspace.
                          </span>
                          <label
                            :for={doc <- @state.docs}
                            style="display:flex;gap:4px;align-items:flex-start;font-size:11px"
                          >
                            <input
                              type="checkbox"
                              name="evidence_files[]"
                              value={doc.id}
                              id={"close-evidence-#{phase.key}-#{doc.id}"}
                            />
                            <span>{doc.title}</span>
                          </label>
                        </div>
                      <% else %>
                        <input
                          type="text"
                          name="evidence_files"
                          placeholder="Doc IDs (comma-separated)"
                          aria-label={"Evidence file IDs for #{phase.label}"}
                          style="font-size:11px;padding:3px 5px"
                        />
                      <% end %>
                      <button
                        type="submit"
                        class="button"
                        id={"close-review-#{phase.key}"}
                        style="font-size:11px"
                      >
                        Record review
                      </button>
                    </form>
                  <% phase.reviewed_by == @write_actor_id -> %>
                    <span style="font-size:11px;color:var(--muted)">
                      reviewed by you — a different admin must sign
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

    <.settlement_card
      :if={@state.settlements}
      settlements={@state.settlements}
      period={@state.period}
      can_admin?={@can_admin?}
      actor_id={@actor_id}
    />
    """
  end

  attr(:state, :map, required: true)
  attr(:actor_id, :string, default: nil)

  defp period_card(assigns) do
    ~H"""
    <div class="card" id="close-dashboard-period" style="padding:12px 16px;margin-bottom:12px">
      <%= if @state.period do %>
        <b>{period_label(@state.period)}</b>
        <span style="color:var(--muted)">· period {@state.period.status}</span>
        <span :if={@state.run} style="color:var(--muted)">
          · close run {@state.run.status}
          <span :if={@state.run.completed_by} id="close-run-completed-by">
            · by {actor_label(@state.run.completed_by, @actor_id)}
          </span>
        </span>
        <div
          :if={@state.run && @state.run.started_at}
          id="close-dashboard-started"
          style="margin-top:4px;color:var(--muted);font-size:12px"
        >
          Started {stamp(@state.run.started_at)}
          <span :if={@state.run.started_by}>
            by {actor_label(@state.run.started_by, @actor_id)}
          </span>
        </div>
      <% else %>
        <span style="color:var(--muted)">No fiscal period declared.</span>
      <% end %>
    </div>
    """
  end

  attr(:payroll, :map, required: true)
  attr(:period, :map, default: nil)
  attr(:actor_id, :string, default: nil)
  attr(:can_admin?, :boolean, default: false)

  defp payroll_card(assigns) do
    ~H"""
    <div
      class="card"
      id="close-payroll-check"
      data-status={@payroll.status}
      style={"padding:12px 16px;margin-bottom:12px;border-left:3px solid #{payroll_border(@payroll.status)}"}
    >
      <div style="display:flex;gap:10px;align-items:baseline;flex-wrap:wrap">
        <b>Imported payroll</b>
        <span id="close-payroll-status" data-status={@payroll.status}>
          <.pill variant={payroll_variant(@payroll.status)}>{payroll_status_label(@payroll.status)}</.pill>
        </span>
        <span style="color:var(--muted);font-size:12px">
          {period_label(@period)} · {@payroll.counts.total} imported register(s)
        </span>
      </div>

      <%= cond do %>
        <% @payroll.status == :unavailable -> %>
          <div id="close-payroll-unavailable" style="margin-top:6px;color:#B45309">
            The payroll check could not be read. The close is blocked rather than certifying
            payroll unseen.
          </div>
        <% @payroll.truncated? -> %>
          <div id="close-payroll-truncated" style="margin-top:6px;color:#B45309">
            More than {@payroll.limit} imported payroll rows fall in this period. The close is
            blocked until the payroll inbox can be read within the bound.
          </div>
        <% @payroll.counts.total == 0 -> %>
          <div id="close-payroll-empty" style="margin-top:6px;color:var(--muted)">
            No imported payroll registers in this period.
          </div>
        <% @payroll.status == :clear -> %>
          <div id="close-payroll-clear" style="margin-top:6px;color:var(--muted)">
            Every imported register is posted, explicitly voided, or held with a named exception.
          </div>
        <% true -> %>
          <div id="close-payroll-blocked" style="margin-top:6px;color:#B45309">
            The close is blocked until every imported payroll entry is posted, explicitly voided,
            or held with a named exception.
          </div>
      <% end %>

      <div :if={@payroll.counts.total > 0} style="margin-top:6px;color:var(--muted);font-size:12px">
        posted {@payroll.counts.posted} · voided {@payroll.counts.voided} · held
        {@payroll.counts.held} · draft {@payroll.counts.draft} · conflict
        {@payroll.counts.conflict} · missing {@payroll.counts.missing}
      </div>

      <div :if={@payroll.unresolved != []} id="close-payroll-unresolved" style="margin-top:8px">
        <b style="font-size:12px">Unresolved</b>
        <ul style="margin:4px 0 0 18px;color:#B45309;font-size:12px">
          <li :for={entry <- Enum.take(@payroll.unresolved, 20)} id={"close-payroll-entry-#{entry.id}"}>
            <div>
              <b>{entry.provider}/{entry.external_id}</b>
              · {payroll_disposition_label(entry.disposition)}
            </div>

            <form
              :if={@can_admin?}
              phx-submit="hold_payroll"
              id={"close-payroll-hold-form-#{entry.id}"}
              style="margin-top:4px;display:flex;gap:4px;align-items:center;flex-wrap:wrap"
            >
              <input type="hidden" name="import_id" value={entry.id} />
              <input
                type="text"
                name="exception"
                required
                maxlength="500"
                placeholder="Named exception (required)"
                aria-label={"Named exception for #{entry.provider}/#{entry.external_id}"}
                style="font-size:11px;padding:3px 5px;min-width:220px"
              />
              <button
                type="submit"
                class="button"
                id={"close-payroll-hold-#{entry.id}"}
                style="font-size:11px"
                data-confirm={"Hold #{entry.provider}/#{entry.external_id}? This is final and lets the close proceed without posting or voiding it."}
              >
                Hold
              </button>
            </form>
          </li>
        </ul>
        <div :if={length(@payroll.unresolved) > 20} style="margin-top:4px;color:var(--muted);font-size:11px">
          and {length(@payroll.unresolved) - 20} more unresolved register(s)
        </div>
      </div>

      <div :if={@payroll.held != []} id="close-payroll-held" style="margin-top:8px">
        <b style="font-size:12px">Held with exception</b>
        <ul style="margin:4px 0 0 18px;color:var(--muted);font-size:12px">
          <li :for={entry <- Enum.take(@payroll.held, 20)} id={"close-payroll-held-#{entry.id}"}>
            <b>{entry.provider}/{entry.external_id}</b>
            · {entry.exception}
            <span :if={entry.held_by}>
              · held by {actor_label(entry.held_by, @actor_id)}
            </span>
          </li>
        </ul>
      </div>
    </div>
    """
  end

  attr(:settlements, :map, required: true)
  attr(:period, :map, default: nil)
  attr(:can_admin?, :boolean, default: false)
  attr(:actor_id, :string, default: nil)

  defp settlement_card(assigns) do
    ~H"""
    <div class="card" id="close-payroll-settlements" style="padding:12px 16px;margin-bottom:12px;border-left:3px solid #0A5C42">
      <div class="gtitle">
        <h3>Payroll settlement &amp; bank tie-out</h3>
        <span class="n">{length(@settlements.rows)}</span>
        <span class="lane">· register → payable/tax → cash → bank</span>
      </div>

      <%= cond do %>
        <% @settlements.wired? == false -> %>
          <div id="close-payroll-settlements-unavailable" style="margin-top:6px;color:#B45309">
            Payroll settlement is not mounted on this host.
          </div>
        <% @settlements.error == :payroll_unavailable -> %>
          <div id="close-payroll-settlements-payroll-unavailable" style="margin-top:6px;color:#B45309">
            The payroll gate could not be read for this period, so this card cannot decide what
            is settleable. Resolve the payroll read above before preparing a settlement.
          </div>
        <% @settlements.error != nil -> %>
          <div id="close-payroll-settlements-error" style="margin-top:6px;color:#B45309">
            The settlement and tie-out read could not be completed. This card does not treat
            an unreadable settlement as reconciled.
          </div>
        <% @settlements.rows == [] -> %>
          <div id="close-payroll-settlements-empty" style="margin-top:6px;color:var(--muted)">
            No settleable posted registers or settlements tied to voided registers in this
            period.
          </div>
        <% true -> %>
          <table style="width:100%;border-collapse:collapse;font-size:13px">
            <thead>
              <tr>
                <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted);width:24%">
                  Register
                </th>
                <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted);width:22%">
                  Settlement
                </th>
                <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted);width:34%">
                  Tie-out
                </th>
                <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted);width:20%">
                  Action
                </th>
              </tr>
            </thead>
            <tbody>
              <tr
                :for={row <- @settlements.rows}
                id={"close-payroll-settlement-#{row.import.id}"}
              >
                <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                  <b>{row.import.provider}/{row.import.external_id}</b>
                  <div style="color:var(--muted);font-size:12px">
                    register {money(row.import.total_cents)} · {date_label(row.import.entry_date)}
                  </div>
                </td>
                <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                  <span
                    id={"close-payroll-settlement-status-#{row.import.id}"}
                    data-status={row.status}
                  >
                    <.pill variant={settlement_variant(row.status)}>
                      {settlement_label(row.status)}
                    </.pill>
                  </span>

                  <div :if={row.settlement} style="color:var(--muted);font-size:12px">
                    {money(row.settlement.total_cents)} · {settlement_entries_label(row.settlement.payment_count)} · {date_label(row.settlement.settlement_date)}
                    <div :if={row.settlement.reference}>{row.settlement.reference}</div>
                    <div :if={row.cash_account}>
                      cash {row.cash_account.code} · {row.cash_account.name}
                    </div>
                    <div :if={row.settlement.prepared_by}>
                      prepared by {actor_label(row.settlement.prepared_by, @actor_id)}
                    </div>
                    <div :if={row.settlement.posted_by}>
                      posted by {actor_label(row.settlement.posted_by, @actor_id)}
                    </div>
                  </div>
                </td>
                <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                  <%= cond do %>
                    <% row.tie_out -> %>
                      <.settlement_tie_out tie_out={row.tie_out} import_id={row.import.id} />
                    <% row.error -> %>
                      <span style="color:#B45309">Tie-out unavailable.</span>
                    <% true -> %>
                      <span style="color:var(--muted)">Not prepared.</span>
                  <% end %>
                </td>
                <td style="padding:6px 8px;border-bottom:1px solid var(--border, #f3f4f6)">
                  <.settlement_action
                    row={row}
                    can_admin?={@can_admin?}
                    accounts={@settlements.accounts}
                    accounts_error?={@settlements.accounts_error?}
                    period={@period}
                  />
                </td>
              </tr>
            </tbody>
          </table>

          <div
            :if={@settlements.accounts_truncated?}
            style="margin-top:6px;color:var(--muted);font-size:11px"
          >
            The cash account picker is capped at 500 asset accounts; only the first 500 are listed.
          </div>
          <div
            :if={@settlements.truncated?}
            style="margin-top:6px;color:var(--muted);font-size:11px"
          >
            Showing up to {@settlements.limit} posted registers and {@settlements.limit} voided
            registers; more exist in this period.
          </div>
      <% end %>
    </div>
    """
  end

  attr(:row, :map, required: true)
  attr(:can_admin?, :boolean, default: false)
  attr(:accounts, :list, default: [])
  attr(:accounts_error?, :boolean, default: false)
  attr(:period, :map, default: nil)

  defp settlement_action(assigns) do
    ~H"""
    <%= cond do %>
      <% @row.status == :unsettled and @can_admin? -> %>
        <%= cond do %>
          <% @accounts_error? -> %>
            <span style="color:#B45309;font-size:11px">
              The cash account picker could not be read.
            </span>
          <% @accounts == [] -> %>
            <span style="color:#B45309;font-size:11px">
              No asset cash account is available to settle against.
            </span>
          <% true -> %>
            <form
              phx-submit="prepare_payroll_settlement"
              id={"close-payroll-settlement-form-#{@row.import.id}"}
              style="display:flex;flex-direction:column;gap:4px"
            >
              <input type="hidden" name="import_id" value={@row.import.id} />
              <select
                name="cash_account_id"
                required
                aria-label={"Cash account for #{@row.import.provider}/#{@row.import.external_id}"}
                id={"close-payroll-settlement-cash-#{@row.import.id}"}
                style="font-size:11px;padding:3px 5px"
              >
                <option value="">Cash account</option>
                <option :for={account <- @accounts} value={account.id}>
                  {account.code} · {account.name}
                </option>
              </select>
              <input
                type="date"
                name="settlement_date"
                required
                value={default_settlement_date(@period)}
                aria-label="Settlement date"
                id={"close-payroll-settlement-date-#{@row.import.id}"}
                style="font-size:11px;padding:3px 5px"
              />
              <input
                type="text"
                name="reference"
                maxlength="200"
                placeholder="Reference (optional)"
                aria-label="Settlement reference"
                id={"close-payroll-settlement-reference-#{@row.import.id}"}
                style="font-size:11px;padding:3px 5px"
              />
              <button
                type="submit"
                class="button"
                id={"close-payroll-settlement-prepare-#{@row.import.id}"}
                style="font-size:11px"
              >
                Prepare settlement
              </button>
            </form>
        <% end %>
      <% @row.status == :unsettled -> %>
        <span style="font-size:11px;color:var(--muted)">Admin required.</span>
      <% @row.settlement != nil and @row.settlement.status == :draft and @row.status == :unposted and @can_admin? -> %>
        <button
          type="button"
          class="button"
          id={"close-payroll-settlement-post-#{@row.import.id}"}
          phx-click="post_payroll_settlement"
          phx-value-settlement_id={@row.settlement.id}
          data-confirm={"Post this payroll settlement? Every settlement entry will ride the journal's posting gate."}
          style="font-size:11px"
        >
          Post settlement
        </button>
      <% @row.settlement != nil and @row.settlement.status == :draft and @row.status == :unposted -> %>
        <span style="font-size:11px;color:var(--muted)">Admin required to post.</span>
      <% @row.status == :voided -> %>
        <span style="font-size:11px;color:var(--muted)">{voided_action_label(@row)}</span>
      <% @row.status == :unavailable -> %>
        <span style="font-size:11px;color:#B45309">Tie-out unavailable.</span>
      <% @row.status == :register_unposted -> %>
        <span style="font-size:11px;color:var(--muted)">Register not posted.</span>
      <% true -> %>
        <span style="font-size:11px;color:var(--muted)">Posted.</span>
    <% end %>
    """
  end

  attr(:tie_out, :map, required: true)
  attr(:import_id, :string, required: true)

  defp settlement_tie_out(assigns) do
    ~H"""
    <div id={"close-payroll-tie-out-#{@import_id}"} data-status={@tie_out.status}>
      <span id={"close-payroll-tie-out-status-#{@import_id}"} data-status={@tie_out.status}>
        <.pill variant={settlement_variant(@tie_out.status)}>
          {settlement_label(@tie_out.status)}
        </.pill>
      </span>

      <div style="color:var(--muted);font-size:11px;margin-top:3px">
        register {money(@tie_out.totals.register_liability_cents)} · settled
        {money(@tie_out.totals.settlement_cents)} · cash {money(@tie_out.totals.cash_cents)} ·
        bank matched {money(@tie_out.totals.matched_cents)}
      </div>

      <div
        :if={@tie_out.totals.variance_cents != 0}
        style="color:#B45309;font-size:11px"
      >
        settlement variance {money(@tie_out.totals.variance_cents)}
      </div>
      <div
        :if={@tie_out.totals.cash_variance_cents != 0}
        style="color:#B45309;font-size:11px"
      >
        cash variance {money(@tie_out.totals.cash_variance_cents)}
      </div>
      <div
        :if={@tie_out.bank_wired? == false}
        style="color:var(--muted);font-size:11px"
      >
        Bank matching is not wired on this host.
      </div>

      <ul
        :if={@tie_out.exceptions != []}
        style="margin:4px 0 0 16px;color:#B45309;font-size:11px"
      >
        <li :for={exception <- Enum.take(@tie_out.exceptions, 6)}>
          {exception_label(exception)}
        </li>
      </ul>
      <div
        :if={length(@tie_out.exceptions) > 6}
        style="color:var(--muted);font-size:11px"
      >
        and {length(@tie_out.exceptions) - 6} more exception(s)
      </div>
    </div>
    """
  end

  defp voided_action_label(%{import: %{entry_status: :void}}), do: "Register voided."
  defp voided_action_label(_row), do: "Settlement entry voided."

  defp settlement_entries_label(1), do: "1 entry"
  defp settlement_entries_label(count), do: "#{count} entries"

  defp date_label(nil), do: "—"
  defp date_label(%Date{} = date), do: Date.to_iso8601(date)
  defp date_label(date), do: to_string(date)

  defp settlement_label(:unsettled), do: "not prepared"
  defp settlement_label(:unposted), do: "draft · not posted"
  defp settlement_label(:unreconciled), do: "posted · bank unreconciled"
  defp settlement_label(:reconciled), do: "reconciled"
  defp settlement_label(:mismatch), do: "mismatch"
  defp settlement_label(:voided), do: "voided"
  defp settlement_label(:register_unposted), do: "register not posted"
  defp settlement_label(:unavailable), do: "unavailable"
  defp settlement_label(status), do: to_string(status)

  defp settlement_variant(:reconciled), do: "ok"
  defp settlement_variant(:mismatch), do: "bad"
  defp settlement_variant(:voided), do: "bad"
  defp settlement_variant(:unavailable), do: "bad"
  defp settlement_variant(_status), do: "warn"

  defp exception_label(:settlement_not_prepared), do: "settlement not prepared"
  defp exception_label(:settlement_not_posted), do: "settlement is still draft"
  defp exception_label(:register_not_posted), do: "payroll register is not posted"
  defp exception_label(:voided_payroll_entry), do: "payroll entry was voided"

  defp exception_label(:settlement_amount_mismatch),
    do: "settlement amount does not match the register"

  defp exception_label(:settlement_entry_missing), do: "a settlement entry is missing"
  defp exception_label(:bank_match_missing), do: "cash movement has no bank match"

  defp exception_label({:liability_variance, code, cents}),
    do: "#{code} liability variance #{money(cents)}"

  defp exception_label({:cash_variance, code, cents}),
    do: "#{code} cash variance #{money(cents)}"

  defp exception_label({:bank_match_missing, code}), do: "#{code} has no bank match"

  defp exception_label({:bank_match_amount_mismatch, code, cents}),
    do: "#{code} bank amount variance #{money(cents)}"

  defp exception_label(exception), do: inspect(exception)

  defp default_settlement_date(%{year: year, month: month})
       when is_integer(year) and is_integer(month) do
    Date.new!(year, month, 1)
    |> Date.end_of_month()
    |> Date.to_iso8601()
  end

  defp default_settlement_date(_period), do: Date.utc_today() |> Date.to_iso8601()

  defp money(nil), do: "—"

  defp money(cents) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    abs_cents = abs(cents)

    "#{sign}$#{div(abs_cents, 100)}.#{abs_cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp money(other), do: to_string(other)

  defp payroll_status_label(:clear), do: "clear"
  defp payroll_status_label(:blocked), do: "blocked"
  defp payroll_status_label(:unavailable), do: "unavailable"
  defp payroll_status_label(status), do: to_string(status)

  defp payroll_variant(:clear), do: "ok"
  defp payroll_variant(_status), do: "warn"

  defp payroll_border(:clear), do: "#0A5C42"
  defp payroll_border(_status), do: "#B45309"

  defp payroll_disposition_label(:draft), do: "unposted draft"
  defp payroll_disposition_label(:conflict), do: "unresolved conflict"
  defp payroll_disposition_label(:missing), do: "missing journal entry"
  defp payroll_disposition_label(:unknown), do: "unknown journal state"
  defp payroll_disposition_label(disposition), do: to_string(disposition)

  defp crumbs(mount, org_id), do: [Crumbs.org(mount, org_id), "ERP", "Close"]

  defp close_href(mount, org_id) do
    "#{Mount.label(mount, :close_path, "/close")}?org=#{org_id}"
  end

  defp summary(nil), do: "—"
  defp summary(report), do: "#{report.completeness.done}/#{report.completeness.total}"

  defp all_phases_done?(%{completeness: %{total: total, done: done}}) when total > 0,
    do: done == total

  defp all_phases_done?(_report), do: false

  # The finish affordance is offered only when the kernel is also prepared to
  # accept it. The `:finish` guard remains the authority; this keeps the page
  # from presenting a button that can only be refused.
  defp close_ready?(%{payroll: %{blocking?: true}}), do: false
  defp close_ready?(report), do: all_phases_done?(report)

  defp parse_evidence_files(value) do
    value
    |> List.wrap()
    |> Enum.flat_map(fn item -> String.split(to_string(item), ~r/[\s,]+/, trim: true) end)
    |> Enum.reject(&(&1 == ""))
  end

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

  defp evidence_label(titles, id) do
    case Map.get(titles, id) do
      title when is_binary(title) -> title
      _ -> "Unavailable document"
    end
  end

  defp evidence_href(mount, org_id, titles, statuses, id) do
    with :live <- Map.get(statuses, id),
         title when is_binary(title) <- Map.get(titles, id),
         path when is_binary(path) and path != "" <- Mount.label(mount, :pages_path, nil) do
      Samen.Web.Notes.Live.page_href(mount, org_id, id)
    else
      _ -> nil
    end
  end

  defp evidence_flag(statuses, id) do
    case Map.get(statuses, id) do
      :archived -> "archived"
      :missing -> "not accessible"
      _ -> nil
    end
  end

  defp evidence_trash_href(mount, org_id, statuses, id) do
    with :archived <- Map.get(statuses, id),
         path when is_binary(path) and path != "" <- Mount.label(mount, :pages_path, nil) do
      Samen.Web.Notes.Live.trash_item_href(mount, org_id, id)
    else
      _ -> nil
    end
  end

  defp actor_label("broker:" <> _, _current), do: "the workspace"
  defp actor_label(id, id) when is_binary(id), do: "you"
  defp actor_label(id, _current) when is_binary(id), do: "admin " <> String.slice(id, 0, 8)
  defp actor_label(_other, _current), do: "—"

  defp error_text(:finance_not_mounted),
    do: "This workspace has no Finance mount, so there is no close to show."

  defp error_text(_reason),
    do: "This close dashboard is not available on this workspace's mounted modules."
end
