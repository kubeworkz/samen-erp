defmodule Samen.Web.Settings.ApprovalsLive do
  @moduledoc """
  The tenant AP APPROVAL POLICY QUEUE (`/settings/approvals`) — the org-scoped list of
  PENDING `ApprovalPolicy` changes a tenant admin can act on.

  ## Why this surface exists

  `Samen.Approvals` already stores the pending request and a registered handler performs the
  approved action. The AP approval policy settings page opens a gated update, so its pending
  card needs a decision surface; without one the request is discoverable only from the
  settings page that opened it. This surface lists those policy-update approvals so a
  distinct admin can decide them.

  ## Scope and plane

  The read is `Samen.Approvals.list_pending_for_org/2`, which pins every row to the resolved
  org; a cross-org request never appears. The queue deliberately includes ONLY kinds handled
  by `Samen.Scopes.Finance.ApprovalPolicyApproval` — the AP policy update control this page
  serves. Other tenant approvals (bills, journals, AI writes, …) have their own decision
  surfaces with the subject context needed for that decision, and are not decidable here.

  Each row renders the proposed policy snapshot decoded from the approval's `subject_ref`
  (threshold, auto-approval flag, chain step count, account/period scope) so the admin knows
  WHAT they are approving, not just that a policy update exists.

  Deciding requires the tenant plane and an `:admin`+ membership, resolved from the
  authenticated principal's real `Membership` row. The engine itself still refuses a
  self-decision and any request outside this org's pending list; the checks here are the
  surface's own defence in depth, never the security boundary.
  """
  use Samen.Web.Tenant.Live

  import Samen.Web.Settings.Live, only: [settings_sidebar: 1, operator_plane?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Approvals
  alias Samen.Approvals.Registry
  alias Samen.Scopes.Finance.ApprovalPolicyApproval
  alias Samen.Web.Crumbs
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount
  alias Samen.Web.Settings.Reads

  @impl true
  def mount(params, session, socket) do
    socket = Samen.Web.Live.assign_mount(socket, session)
    mount = socket.assigns[:samen_mount]
    org_id = CurrentOrg.resolve(mount, params, session)
    user_id = Reads.current_user_id(mount, params, session)

    {:ok,
     socket
     |> assign(return_to: nil, decision_notice: nil, highlight_id: params["approval"])
     |> load(org_id, user_id)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Samen.Web.CurrentOrg.reresolve(socket, params)
    user_id = Samen.Web.Settings.Reads.reresolve_user(socket, params)

    {:noreply,
     socket
     |> assign(return_to: return_path(uri), highlight_id: params["approval"])
     |> load(org_id, user_id)}
  end

  @doc false
  def load(socket, org_id, user_id) do
    mount = socket.assigns.samen_mount

    socket =
      assign(socket,
        org_id: org_id,
        user_id: user_id,
        pending: [],
        can_approve?: false,
        approver_role: nil
      )

    if is_nil(org_id) do
      socket
    else
      role = approver_role(mount, org_id, user_id)

      assign(socket,
        pending: pending_approvals(mount, org_id),
        approver_role: role,
        can_approve?: can_approve?(mount, role)
      )
    end
  end

  @impl true
  def handle_event("approve", %{"approval" => approval_id}, socket) do
    decide(socket, approval_id, :approve)
  end

  def handle_event("reject", %{"approval" => approval_id}, socket) do
    decide(socket, approval_id, :reject)
  end

  # The decide chokepoint: every conjunct is re-checked SERVER-SIDE. The row must be in THIS
  # org's pending list, the caller must be a tenant admin, and the plane must be tenant.
  # Distinct-party is enforced by the engine (and mirrored here for a clear message).
  defp decide(socket, approval_id, action) do
    %{
      samen_mount: mount,
      org_id: org_id,
      user_id: user_id,
      can_approve?: can_approve?,
      pending: pending,
      approver_role: role
    } = socket.assigns

    approval = Enum.find(pending, &(to_string(&1.id) == to_string(approval_id)))

    cond do
      operator_plane?(mount) ->
        {:noreply, notice(socket, "Approving and rejecting are tenant-plane actions.")}

      not can_approve? ->
        {:noreply, notice(socket, "An admin role is required to decide approvals.")}

      is_nil(approval) ->
        {:noreply, notice(socket, "That approval is not in this org's pending queue.")}

      user_id == approval.requested_by ->
        {:noreply, notice(socket, "Self-approval is refused — a distinct admin must decide.")}

      action == :approve ->
        run_decision(socket, org_id, user_id, role, approval)

      true ->
        run_rejection(socket, org_id, user_id, role, approval)
    end
  end

  defp run_decision(socket, org_id, user_id, role, approval) do
    case Approvals.approve(approval.id, user_id, role: role) do
      {:ok, decided, _meta} ->
        notice =
          if decided.state == :pending,
            do: "Approval recorded. The request is waiting for another step.",
            else: "Approval recorded and applied."

        {:noreply, socket |> load(org_id, user_id) |> notice(notice)}

      {:error, reason} ->
        {:noreply, notice(socket, approval_error(reason))}
    end
  end

  defp run_rejection(socket, org_id, user_id, role, approval) do
    case Approvals.reject(approval.id, user_id, role: role) do
      {:ok, _rejected} ->
        {:noreply,
         socket
         |> load(org_id, user_id)
         |> notice("Approval rejected. The request was not applied.")}

      {:error, reason} ->
        {:noreply, notice(socket, approval_error(reason))}
    end
  end

  defp notice(socket, message), do: assign(socket, decision_notice: message)

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
    do: "The approved action failed; the approval is still pending."

  defp approval_error({:subject_unavailable, _reason}),
    do: "The subject is no longer available; the approval is still pending."

  defp approval_error(_reason), do: "Could not record that approval decision."

  # Read the org's pending decisions and keep ONLY the AP approval-policy updates this
  # surface serves. Filtering by the registered handler (rather than a resource-name prefix)
  # follows the host's own registry wiring; a different tenant approval kind never appears
  # here, so an admin cannot approve it without its proper subject context.
  defp pending_approvals(mount, org_id) do
    case Approvals.list_pending_for_org(org_id, repo: mount.repo) do
      {:ok, approvals} -> Enum.filter(approvals, &policy_approval?/1)
      {:error, _reason} -> []
    end
  rescue
    _ -> []
  end

  defp policy_approval?(approval) do
    Registry.plane(approval.kind) == :tenant and
      Registry.handler(approval.kind) == ApprovalPolicyApproval
  end

  # The approver's REAL tenant role, resolved from the authenticated principal's Membership.
  # Fail-closed: no membership → nil → not an approver.
  defp approver_role(mount, org_id, user_id) when is_binary(org_id) and is_binary(user_id) do
    scope = Mount.scope(mount, org_id)

    case Reads.current_membership(mount, scope, user_id, org_id) do
      {:ok, %{role: role}} -> role
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp approver_role(_mount, _org_id, _user_id), do: nil

  defp can_approve?(mount, role) do
    not operator_plane?(mount) and Samen.Scope.Role.at_least?(role, :admin)
  end

  # -- render ------------------------------------------------------------------

  @impl Samen.Web.Tenant.Live
  def tenant_assigns(assigns) do
    assigns
    |> assign_new(:decision_notice, fn -> nil end)
    |> assign_new(:highlight_id, fn -> nil end)
  end

  @impl Samen.Web.Tenant.Live
  def tenant_sidebar(assigns) do
    ~H"""
    <.settings_sidebar mount={@samen_mount} org_id={@org_id} user_id={@user_id} active={:approvals} />
    """
  end

  @impl Samen.Web.Tenant.Live
  def tenant_page(assigns) do
    ~H"""
    <div id="settings-approvals">
      <.topbar
        title="AP policy approvals"
        crumbs={[Crumbs.org(@samen_mount, @org_id), Crumbs.section(@samen_mount, @org_id, :settings), "AP policy approvals"]}
      />

      <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

      <%= if is_nil(@org_id) do %>
        <.no_org_card mount={@samen_mount} />
      <% else %>
        <div class="wrap">
          <div id="approvals-panel">
            <div class="gtitle">
              <h3>Pending AP policy changes</h3>
              <span class="lane">
                each row shows the proposed threshold, auto-approval, chain and scope. Approve to
                apply the policy; reject to leave the current policy in effect.
              </span>
            </div>

            <p :if={@decision_notice} id="approvals-notice" style="color:#26307a">
              {@decision_notice}
            </p>

            <p
              :if={operator_plane?(@samen_mount)}
              id="approvals-operator-note"
              style="color:var(--muted)"
            >
              Approving and rejecting are tenant-plane actions.
            </p>

            <p
              :if={not operator_plane?(@samen_mount) and not @can_approve?}
              id="approvals-role-note"
              style="color:var(--muted)"
            >
              Deciding an approval requires an admin role — this is a read-only view for your
              role.
            </p>

            <table id="approvals-table" class="tbl">
              <thead>
                <tr>
                  <th scope="col">Request</th>
                  <th scope="col">Proposed change</th>
                  <th scope="col">Requested by</th>
                  <th scope="col">Requested</th>
                  <th scope="col"></th>
                </tr>
              </thead>
              <tbody>
                <tr
                  :for={approval <- @pending}
                  class="approval-row"
                  id={"approval-#{approval.id}"}
                  style={row_style(@highlight_id, approval.id)}
                >
                  <td>
                    <code>{kind_label(approval.kind)}</code>
                  </td>
                  <td id={"approval-context-#{approval.id}"} style="font-size:12px">
                    {policy_context(approval.subject_ref)}
                  </td>
                  <td>{approval.requested_by}</td>
                  <td>{fmt(approval.requested_at)}</td>
                  <td>
                    <%= if @can_approve? and @user_id != approval.requested_by do %>
                      <button
                        type="button"
                        phx-click="approve"
                        phx-value-approval={approval.id}
                        class="btn"
                        id={"approve-approval-#{approval.id}"}
                      >
                        Approve
                      </button>
                      <button
                        type="button"
                        phx-click="reject"
                        phx-value-approval={approval.id}
                        class="btn"
                        id={"reject-approval-#{approval.id}"}
                      >
                        Reject
                      </button>
                    <% else %>
                      <span
                        :if={@can_approve? and @user_id == approval.requested_by}
                        style="color:var(--muted);font-size:12px"
                      >
                        Awaiting another admin
                      </span>
                    <% end %>
                  </td>
                </tr>
                <tr :if={@pending == []}>
                  <td colspan="5" id="approvals-empty" style="color:var(--muted)">
                    No pending AP policy changes for this org.
                  </td>
                </tr>
              </tbody>
            </table>
          </div>
        </div>
      <% end %>
    </div>
    """
  end

  defp kind_label(kind), do: kind |> to_string() |> String.replace_prefix("Elixir.", "")

  defp policy_context(subject_ref) do
    case ApprovalPolicyApproval.proposed_change(subject_ref) do
      {:ok, %{attrs: attrs}} -> proposed_policy_text(attrs)
      {:error, _reason} -> "Proposed AP approval policy update"
    end
  end

  defp proposed_policy_text(attrs) do
    "Threshold: #{money(Map.get(attrs, :threshold_cents))} · " <>
      "Auto-approve below: #{yes_no(Map.get(attrs, :auto_approve_below))} · " <>
      "Chain: #{step_count(Map.get(attrs, :steps))} · " <>
      "Accounts: #{scope_count(Map.get(attrs, :account_ids), "account")} · " <>
      "Periods: #{scope_count(Map.get(attrs, :period_keys), "period")}"
  end

  defp money(cents) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    cents = abs(cents)

    "#{sign}$#{div(cents, 100)}.#{cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp money(_cents), do: "—"

  defp yes_no(true), do: "yes"
  defp yes_no(false), do: "no"
  defp yes_no(_), do: "—"

  defp step_count([]), do: "none"
  defp step_count([_step]), do: "1 step"
  defp step_count(steps) when is_list(steps), do: "#{length(steps)} steps"
  defp step_count(_), do: "—"

  defp scope_count([], _noun), do: "all"
  defp scope_count([_value], noun), do: "1 #{noun}"
  defp scope_count(values, noun) when is_list(values), do: "#{length(values)} #{noun}s"
  defp scope_count(_value, _noun), do: "all"

  defp row_style(approval_id, approval_id),
    do: "background:var(--accent-soft, #eef2ff)"

  defp row_style(_highlight_id, _approval_id), do: nil

  defp fmt(%DateTime{} = at), do: Calendar.strftime(at, "%Y-%m-%d %H:%M")
  defp fmt(_), do: "—"
end
