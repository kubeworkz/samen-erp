defmodule Samen.Web.Operator.AutomationHealthLive do
  @moduledoc """
  Framework OPERATOR / Automation health view at `/operator/automation/:org_id`
  (ADR-039 §8.3/§8.4; WS-E E8; T42) — the run log + per-workflow health
  aggregates + the operator kill-switch, inherited by every vertical at 0 LOC
  via `samen_operator_routes/2`. Reached from the account drill-down
  (`Samen.Web.Operator.AccountDetailLive`'s "Automation health →" link) — the
  route param IS the tenant org being inspected (ADR-039 §8.3's "per-org...
  aggregates"), mirroring the single-org drill-down shape
  `Samen.OperatorPlane`/`AccountDetailLive` already use.

  ## Token-blind by construction (INV-1/INV-2)

  Every value rendered here comes from `Samen.Automation.Health`, which reads
  ONLY `Automation.Workflow` (bounded ids/enums/name + jsonb CONFIGS, never
  subject values) and `Automation.Run` (bounded ids/enums/timestamps/bounded
  outcome jsonb — passes the `no_pii_columns` bar, `define_run/5`). There is no
  `%Masked{}` branch and no reveal path anywhere on this page because there is
  no PII column to reach in the first place — the SAME posture
  `Samen.Web.Operator.WebhookDlqLive` documents for the webhook DLQ.

  ## The kill-switch is a CROSS-ORG operator action (ADR-039 §8.4)

  Unlike every other operator-workspace surface (which reads/writes the
  OPERATOR org's own tenant-plane rows, ADR-010 §7.2), killing a workflow acts
  on ANY tenant org's `Workflow` row — the whole point of an operator
  emergency-stop. `Samen.Automation.Health` enforces this with its own
  application-code RBAC gate (`may_manage?/1`) before `authorize?: false`,
  exactly the `Samen.OperatorPlane` idiom — never a tenant-scoped Ash policy
  (which cannot express "any org, gated by operator role instead").

  `Samen.OperatorPlane.Actor` is the actor type that gate expects, but the
  operator WORKSPACE mount (ADR-010 §7.2) carries a tenant-shaped
  `Samen.Scope` actor (the operator org's OWN membership role) — `operator_role/1`
  bridges the two: `owner`/`admin` -> `:operator_admin`, `member` ->
  `:operator_support`, anything else -> `:operator_readonly` (view-only, matching
  `Health.may_manage?/1`'s readonly exclusion).

  ## ADR-042 Class B — reads render JS-off; the kill-switch write needs the socket

  The workflow list, health aggregates, and run log all render fully from
  `mount`/`load` — no `phx-click` required to SEE any of it (asserted by test
  with no connected socket). Kill/re-arm are `phx-click` writes and, per
  ADR-042, may depend on the live client.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Operator.Live

  alias Samen.Automation.Health
  alias Samen.OperatorPlane.Actor
  alias Samen.Web.Mount
  alias Samen.Web.Operator
  alias Samen.Web.Operator.Impersonation

  @impl true
  def mount(params, session, socket) do
    socket =
      socket
      |> assign_mount(session)
      |> Impersonation.assign_identity(session, params)

    {:ok, load(socket, Map.get(params, "org_id"))}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply, load(socket, Map.get(params, "org_id") || socket.assigns[:target_org_id])}
  end

  @doc false
  def load(socket, target_org_id) do
    mount = socket.assigns[:samen_mount]
    operator_org_id = mount && Operator.org_id(mount)
    operator = mount && operator_actor(mount)

    cond do
      is_nil(operator_org_id) ->
        assign(socket,
          no_org: true,
          impersonation: :none,
          target_org_id: target_org_id,
          operator: nil,
          summary: [],
          runs: [],
          unread: nil,
          runs_unread: nil,
          action_error: nil,
          session_info: nil,
          open_error: nil
        )

      is_nil(target_org_id) ->
        assign(socket,
          no_org: false,
          impersonation: :none,
          target_org_id: nil,
          operator: operator,
          summary: [],
          runs: [],
          unread: nil,
          runs_unread: nil,
          action_error: nil,
          session_info: nil,
          open_error: nil
        )

      true ->
        # R-B scope conjunct + T150 — a per-tenant automation drill-in requires the account be
        # in the operator's scope (§16.4a, checked before the reason form) AND a REAL
        # impersonation session for the target org (accountability: an operator inspecting/killing
        # ONE tenant's workflows is recorded in that tenant's ledger). Deny-on-read when missing.
        case Impersonation.gate_socket(socket, socket.assigns[:samen_operator_id], target_org_id) do
          {:ok, _actor, info} ->
            {summary, runs, unread, runs_unread} = readings(operator, target_org_id)

            assign(socket,
              no_org: false,
              impersonation: :active,
              target_org_id: target_org_id,
              operator: operator,
              summary: summary,
              runs: runs,
              unread: unread,
              runs_unread: runs_unread,
              action_error: nil,
              session_info: info,
              open_error: nil
            )

          :out_of_scope ->
            assign(socket,
              no_org: false,
              impersonation: :out_of_scope,
              target_org_id: target_org_id,
              operator: operator,
              summary: [],
              runs: [],
              unread: nil,
              action_error: nil,
              session_info: nil,
              open_error: nil
            )

          :denied ->
            assign(socket,
              no_org: false,
              impersonation: :denied,
              target_org_id: target_org_id,
              operator: operator,
              summary: [],
              runs: [],
              unread: nil,
              action_error: nil,
              session_info: nil,
              open_error: nil
            )
        end
    end
  end

  @impl true
  def handle_event("open_session", %{"reason" => reason}, socket) do
    target_org_id = socket.assigns[:target_org_id]

    case Impersonation.open_from_socket(socket, target_org_id, reason) do
      {:ok, _session} -> {:noreply, load(socket, target_org_id)}
      {:error, reason} -> {:noreply, assign(socket, open_error: open_error_copy(reason))}
    end
  end

  def handle_event("kill", %{"id" => workflow_id}, socket), do: switch(socket, :kill, workflow_id)
  def handle_event("rearm", %{"id" => workflow_id}, socket), do: switch(socket, :rearm, workflow_id)

  defp open_error_copy(:reason_required), do: "A reason for access is required."
  defp open_error_copy(:not_authorized), do: "Your operator role may not open an impersonation session."
  defp open_error_copy({:pii_shaped_reason, _}), do: "The reason must name the ticket, not the person."
  defp open_error_copy(_), do: "The impersonation session could not be opened."

  defp switch(socket, action, workflow_id) do
    target_org_id = socket.assigns[:target_org_id]

    # T154 — a kill/rearm WRITE on a SPECIFIC tenant's workflow now requires an ACTIVE, audited
    # impersonation session for that org (deny-on-WRITE), the same accountability floor T150 put
    # on the read path — so the emergency-stop lands in the tenant's ledger, not just the audit
    # log. Deny-on-write independently of the rendered button: the write handler is reachable via
    # a crafted `phx-click` on the `:denied` state, so the gate is re-consulted HERE, not trusted
    # from the last render. Belt-and-suspenders: `Health.may_manage?` role gate + the `aud_event`
    # audit still apply on the allowed path (authorized + attributable AND ledger-recorded).
    # The scope conjunct (§16.4a) re-composes on the WRITE path too: a scoped-out operator
    # (:out_of_scope) is refused the kill/rearm exactly like a session-less one (:denied) —
    # scope subtracts on writes as on reads.
    case Impersonation.gate_socket(socket, socket.assigns[:samen_operator_id], target_org_id) do
      denied when denied in [:denied, :out_of_scope] ->
        {:noreply, load(socket, target_org_id)}

      {:ok, _actor, _info} ->
        operator = socket.assigns[:operator]

        result = if action == :kill, do: Health.kill(operator, workflow_id), else: Health.rearm(operator, workflow_id)

        case result do
          {:ok, _wf} ->
            {:noreply, load(socket, target_org_id)}

          {:error, reason} ->
            {:noreply, assign(socket, action_error: error_copy(reason))}
        end
    end
  end

  defp error_copy(:not_authorized), do: "You do not have permission to manage automation for this org."
  defp error_copy(:no_automation_module), do: "Automation is not configured on this host."
  defp error_copy(_other), do: "That action could not be completed."

  # ---------------------------------------------------------------------------

  # Returns `{summary, runs, wf_unread, runs_unread}` — the two lists carry their OWN
  # silence: `nil` when that read ANSWERED (only an answered read may be printed as "none"),
  # `:unavailable` when this host wired no such seam at all, `:read_failed` when a wired read
  # did not answer. `[]` alone would make "No workflows for this org." an assertion about a
  # tenant's data over a query that never returned (ADR-014/024/026 — the rule the agent
  # plane's `:unavailable` branch keeps too).
  defp readings(operator, org_id) do
    summary = Health.summary(operator, org_id)
    runs = Health.runs(operator, org_id, limit: 50)

    {fetch_summary(summary), fetch_runs(runs), silence(summary), silence(runs)}
  end

  defp silence({:error, :unavailable}), do: :unavailable
  defp silence({:error, _}), do: :read_failed
  defp silence(_answered), do: nil

  defp wf_unread_title(:unavailable), do: "Automation is not configured on this host."
  defp wf_unread_title(_), do: "Workflows could not be read."

  defp wf_unread_body(:unavailable),
    do:
      "This host has not wired the automation engine's workflow module (config :samen_core, Samen.Automation, workflow_module: ...), so no tenant's workflows can be read here. That is a fact about this host, not about this account's automations."

  defp wf_unread_body(_),
    do:
      "The automation read did not answer, so this page cannot tell you whether this org has any workflows — that is not the same as having none."

  defp runs_unread_title(:unavailable), do: "The run log is not wired on this host."
  defp runs_unread_title(_), do: "Workflow runs could not be read."

  defp runs_unread_body(:unavailable),
    do:
      "This host wired the automation engine but no run module (run_module), so no workflow's runs can be read here — the run log is unreadable, not empty."

  defp runs_unread_body(_),
    do:
      "The run log did not answer, so no statement about this org's executions can be made here."

  # A row whose run side could not be read says so in every run-derived cell — a `0`,
  # `—` or blank there would be a measurement this host never made.
  defp runs_count_cell(_value, false), do: "unreadable"
  defp runs_count_cell(value, true), do: counts_str(value)

  defp runs_total_cell(_total, false), do: "unreadable"
  defp runs_total_cell(total, true), do: total

  defp last_failure_cell(_ts, false), do: "unreadable"
  defp last_failure_cell(ts, true), do: ts(ts)

  defp fetch_summary({:ok, summary}), do: summary
  defp fetch_summary(_), do: []

  defp fetch_runs({:ok, runs}), do: runs
  defp fetch_runs(_), do: []

  # Bridges ADR-010's tenant-shaped operator-workspace actor to the
  # `Samen.OperatorPlane.Actor` `Samen.Automation.Health` expects — see
  # moduledoc. `:owner`/`:admin` may kill; `:member` reads + escalation-only
  # ("support"); anything else is view-only.
  defp operator_actor(%Mount{} = mount) do
    scope = Operator.scope(mount)
    role = scope.actor[:role]
    id = scope.actor[:id] || "operator"

    op_role =
      case role do
        r when r in [:owner, :admin] -> :operator_admin
        :member -> :operator_support
        _ -> :operator_readonly
      end

    Actor.new(to_string(id), op_role)
  end

  defp operator_actor(_), do: nil

  defp ts(nil), do: "—"
  defp ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M:%S")
  defp ts(other), do: to_string(other)

  defp counts_str(map) when map == %{}, do: "—"

  defp counts_str(map) when is_map(map) do
    map
    |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
    |> Enum.map_join(" · ", fn {k, v} -> "#{k}: #{v}" end)
  end

  defp counts_str(_), do: "—"

  @impl true
  def render(assigns) do
    ~H"""
    <div id="operator-automation-health">
      <.app_shell>
        <:sidebar>
          <.operator_sidebar mount={@samen_mount} active={:automation} operator_role={assigns[:samen_operator_role]} />
        </:sidebar>

        <.topbar title="Automation health" crumbs={["Operator plane", "Automation"]}>
          <:actions>
            <a
              :if={@target_org_id}
              href="/operator/accounts"
              id="back-to-accounts-from-automation"
              style="font-size:12px;color:#3B4CCA"
            >
              ← Accounts
            </a>
          </:actions>
        </.topbar>

        <div class="wrap">
          <%= cond do %>
            <% @no_org -> %>
              <div class="card" id="no-org" style="padding:22px 20px;color:var(--muted)">
                No operator org resolved.
              </div>
            <% is_nil(@target_org_id) -> %>
              <div class="card" id="no-target-org" style="padding:22px 20px;color:var(--muted)">
                Open an account (Operator plane → Accounts) and follow "Automation health →"
                to inspect a tenant's workflows.
              </div>
            <% @impersonation == :out_of_scope -> %>
              <div class="card" id="out-of-scope" style="padding:22px 20px">
                <div style="color:var(--red);font-weight:600" id="not-in-scope">
                  This account is not in your scope.
                </div>
                <p style="color:var(--muted);margin:10px 0 0;font-size:13px">
                  Your operator assignment does not cover this tenant, so its automation health is
                  not available to you and no impersonation session can be opened for it.
                </p>
              </div>
            <% @impersonation == :denied -> %>
              <div class="card" id="impersonation-required" style="padding:22px 20px">
                <div style="color:var(--red);font-weight:600" id="no-session">
                  Access denied — no active impersonation session for this tenant.
                </div>
                <p style="color:var(--muted);margin:10px 0 14px;font-size:13px">
                  Inspecting (and killing) one tenant's workflows is a per-tenant drill-in: it
                  requires a short-TTL, reason-required impersonation session, recorded in the
                  tenant's audit ledger.
                </p>
                <div :if={@open_error} id="open-error" style="color:#B42318;font-size:12px;margin-bottom:8px">
                  {@open_error}
                </div>
                <%!-- A session whose role may NOT open a drill-in is still OFFERED the reason form
                      below, and every submit is refused `:not_authorized`. The withheld control's
                      note is this disclosure: it answers which roles CAN open one, from the same
                      predicate the gate applies (`Actor.may_impersonate?/1`). --%>
                <.role_help_note
                  :if={drill_in_role_denied?(assigns[:samen_operator_role])}
                  id="drill-in-role-denied"
                  focus={:tenant_drill_in}
                  operator_role={assigns[:samen_operator_role]}
                >
                  Opening a per-account drill-in session requires an operator role that may
                  impersonate; this session's role may not.
                </.role_help_note>
                <form phx-submit="open_session" id="open-session-form" style="display:flex;gap:8px;align-items:flex-start">
                  <input type="text" name="reason" id="session-reason-input"
                    placeholder="Reason (e.g. ticket #1234: runaway workflow)"
                    style="flex:1;padding:8px 10px;border:1px solid #D0D5DD;border-radius:8px;font-size:13px" />
                  <button type="submit" id="start-session-btn" style="padding:8px 14px;border-radius:8px;background:#3B4CCA;color:#fff;font-size:13px">
                    Start session
                  </button>
                </form>
              </div>
            <% true -> %>
              <div :if={@session_info} id="session-accountability" class="card" style="padding:10px 14px;margin-bottom:12px;font-size:12px;color:var(--muted)">
                <b style="color:inherit">Impersonation session.</b>
                operator <span class="mono">{@session_info.operator_id}</span>
                · reason: <span id="session-reason">{@session_info.reason}</span>
                · expires <span id="session-expiry">{@session_info.expires_at}</span>
              </div>
              <.token_blind_bar chip="run log + health are bounded ids/enums only · no vault token">
                <b>Token-blind observability.</b>
                The run log carries only ids, enums, timestamps, and a bounded per-action
                outcome list — never a subject attribute value, never a vault-routed
                token (ADR-039 §8.1/INV-1).
              </.token_blind_bar>

              <div :if={@action_error} id="action-error" class="card" style="padding:12px 16px;margin-top:12px;color:#B42318;border-color:#F4B4AC">
                {@action_error}
              </div>

              <div id="workflow-health" style="margin-top:14px">
                <div class="gtitle">
                  <h3>Workflows</h3>
                  <span class="n">{length(@summary)}</span>
                </div>

                <%!-- FAIL-HONEST: a page with no workflows must say WHICH silence that is —
                      this host wired no engine, a wired read did not answer, or the read
                      genuinely answered "none". --%>
                <.unread_state
                  :if={@summary == [] and @unread}
                  class="wf-unread"
                  reason={@unread}
                  title={wf_unread_title(@unread)}
                  body={wf_unread_body(@unread)}
                />
                <.empty_state
                  :if={@summary == [] and is_nil(@unread)}
                  class="wf-empty"
                  icon="⚙"
                  title="No workflows for this org."
                  body="Nothing to observe yet — a tenant-authored workflow will show up here once created."
                />

                <.data_table :if={@summary != []}>
                  <:head>
                    <th>Workflow</th>
                    <th>Status</th>
                    <th>Kill switch</th>
                    <th>Runs</th>
                    <th>By state</th>
                    <th>Error kinds</th>
                    <th>Last failure</th>
                    <th></th>
                  </:head>
                  <tr :for={w <- @summary} class="wf-row" id={"wf-#{w.workflow_id}"}>
                    <td class="w-name">{w.name}</td>
                    <td class="w-status"><span class={"pill pill-#{w.status}"}>{w.status}</span></td>
                    <td class="w-killed">
                      <span :if={w.killed} class="pill pill-killed" id={"killed-badge-#{w.workflow_id}"}>
                        killed ({w.disabled_reason})
                      </span>
                      <span :if={!w.killed}>active</span>
                    </td>
                    <%!-- A string, not a boolean: Phoenix omits a `data-*` attribute whose value
                          is `false`, which would erase the very marker this row is here to
                          carry. --%>
                    <td class="w-total" data-runs-readable={to_string(Map.get(w, :runs_readable, true))}>
                      {runs_total_cell(w.total_runs, Map.get(w, :runs_readable, true))}
                    </td>
                    <td class="w-by-state">{runs_count_cell(w.run_counts, Map.get(w, :runs_readable, true))}</td>
                    <td class="w-by-error">{runs_count_cell(w.error_kind_counts, Map.get(w, :runs_readable, true))}</td>
                    <td class="w-last-failure" style="color:var(--muted)">
                      {last_failure_cell(w.last_failure_at, Map.get(w, :runs_readable, true))}
                    </td>
                    <td class="w-actions">
                      <button
                        :if={!w.killed}
                        class="btn-kill"
                        id={"kill-#{w.workflow_id}"}
                        phx-click="kill"
                        phx-value-id={w.workflow_id}
                        data-confirm="Kill this workflow? It will stop firing until re-armed."
                      >
                        Kill
                      </button>
                      <button
                        :if={w.killed}
                        class="btn-rearm"
                        id={"rearm-#{w.workflow_id}"}
                        phx-click="rearm"
                        phx-value-id={w.workflow_id}
                      >
                        Re-arm
                      </button>
                    </td>
                  </tr>
                </.data_table>
              </div>

              <div id="run-log" style="margin-top:22px">
                <div class="gtitle">
                  <h3>Recent runs</h3>
                  <span class="n">{length(@runs)}</span>
                </div>

                <%!-- FAIL-HONEST: the run LOG has its own seam (`run_module`) and therefore its
                      own silence — never the workflow section's. --%>
                <.unread_state
                  :if={@runs == [] and @runs_unread}
                  class="run-unread"
                  reason={@runs_unread}
                  title={runs_unread_title(@runs_unread)}
                  body={runs_unread_body(@runs_unread)}
                />
                <.empty_state
                  :if={@runs == [] and is_nil(@runs_unread)}
                  class="run-empty"
                  icon="✓"
                  title="No runs recorded."
                  body="Fired, skipped, and failed executions will appear here as workflows dispatch."
                />

                <.data_table :if={@runs != []}>
                  <:head>
                    <th>State</th>
                    <th>Workflow id</th>
                    <th>Trigger</th>
                    <th>Reason</th>
                    <th>Subject ref</th>
                    <th>Started</th>
                    <th>Duration (ms)</th>
                  </:head>
                  <tr :for={r <- @runs} class="run-row" id={"run-#{r.id}"}>
                    <td class="r-state"><span class={"pill pill-#{r.state}"}>{r.state}</span></td>
                    <td class="r-workflow mono">{r.workflow_id}</td>
                    <td class="r-trigger">{r.trigger_kind}</td>
                    <td class="r-error" style="color:#B42318">{r.error_kind}</td>
                    <td class="r-subject mono" style="max-width:220px;overflow:auto">{r.subject_ref}</td>
                    <td class="r-started" style="color:var(--muted)">{ts(r.started_at)}</td>
                    <td class="r-duration">{r.duration_ms}</td>
                  </tr>
                </.data_table>
              </div>
          <% end %>
        </div>
      </.app_shell>
    </div>
    """
  end
end
