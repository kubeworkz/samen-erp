defmodule Samen.Web.Billing.PlanLive do
  @moduledoc """
  Framework Billing / Plan detail (`/billing/plans/:id`) — the record page behind
  the plans list (ADR-009, host-agnostic). Plans are Tier-0 config rows: no PII on
  either plane.

  ## Page shape

  Header (name · enabled pill · interval · primary price) → bounded facts `<dl>` →
  the plan's feature map as chips (REAL granted keys only — the detail page never
  fabricates a default feature) → its price rows (`Reads.prices_by_plan/3`) → a
  Status-actions card carrying the enable/disable toggle.

  ## Writes — sanctioned `:update` / archivable destroy, admin-gated by the kernel

  * **Edit** opens a `modal/1` hosting an `AshPhoenix.Form.for_update/3` over the
    blueprint's `update: :*` (name / label / description / interval).
  * **Enable/disable** rides `Reads.toggle_plan/3` (the same sanctioned toggle the
    list row offers).
  * **Archive** carries the `delete_confirm/1` interlock: Plan is E6-archivable
    (`archivable: true`), so the destroy SOFT-ARCHIVES — the row disappears from
    the live list and can be restored from the plans list's archived view. Success
    navigates back to the plans list.

  Writes go through `Reads.write_scope/2` (same-org role elevation, plane-
  preserving), so the kernel's `OrgScope` + `RoleAtLeast :admin` govern them
  exactly as a direct API call would. All write affordances are TENANT-plane only
  (`Samen.Web.Billing.Live.writable?/1`).
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Billing.Live, only: [assign_mount: 2, billing_sidebar: 1, writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.Crumbs
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  alias Samen.Web.Billing.Reads

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    plan_id = Map.get(params, "id")

    {:ok,
     load(
       assign(socket, org_id: org_id, plan_id: plan_id, return_to: nil),
       org_id,
       plan_id
     )}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Samen.Web.CurrentOrg.reresolve(socket, params)
    plan_id = Map.get(params, "id") || socket.assigns.plan_id

    {:noreply,
     load(
       assign(socket, org_id: org_id, plan_id: plan_id, return_to: return_path(uri)),
       org_id,
       plan_id
     )}
  end

  @doc false
  def load(socket, nil, _plan_id) do
    socket
    |> ensure_return_to()
    |> assign(
      no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil),
      org_id: nil,
      plan_id: nil,
      plan: nil,
      prices: [],
      show_edit: false,
      edit_form: nil,
      action_error: nil,
      delete_error: nil
    )
  end

  def load(socket, org_id, plan_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    plan =
      if plan_id do
        case Reads.get_plan(mount, scope, plan_id) do
          {:ok, p} -> p
          :error -> nil
        end
      end

    prices = if plan, do: Map.get(Reads.prices_by_plan(mount, scope), plan.id, []), else: []

    socket
    |> ensure_return_to()
    |> assign(
      no_org: false,
      org_id: org_id,
      plan_id: plan_id,
      plan: plan,
      prices: prices,
      show_edit: false,
      edit_form: nil,
      action_error: nil,
      delete_error: nil
    )
  end

  # -- writes (tenant posture in the render; kernel governs the write path) ----

  @impl true
  def handle_event("edit_plan", _params, socket) do
    %{samen_mount: mount, org_id: org_id, plan: plan} = socket.assigns

    if is_binary(org_id) and plan != nil do
      {:noreply, assign(socket, show_edit: true, edit_form: edit_form(mount, org_id, plan))}
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
      {:ok, _plan} ->
        {:noreply, load(socket, socket.assigns.org_id, socket.assigns.plan_id)}

      {:error, form} ->
        {:noreply, assign(socket, edit_form: form)}
    end
  end

  # The sanctioned enable/disable toggle (the same `Reads.toggle_plan/3` the list
  # row offers) through the admin write scope.
  def handle_event("toggle_enabled", _params, socket) do
    %{samen_mount: mount, org_id: org_id, plan: plan} = socket.assigns

    if is_binary(org_id) and plan != nil do
      case Reads.toggle_plan(mount, Reads.write_scope(mount, org_id), plan.id) do
        {:ok, _plan} ->
          {:noreply, load(socket, org_id, socket.assigns.plan_id)}

        {:error, _reason} ->
          {:noreply, assign(socket, action_error: "Could not update this plan.")}
      end
    else
      {:noreply, socket}
    end
  end

  # Archive — E6 soft-delete: the destroy archives (the plan leaves the live list
  # and can be restored from the plans list's archived view). Success navigates
  # back to the list; a refusal is surfaced, never swallowed.
  def handle_event("delete", %{"id" => id}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    if is_binary(org_id) do
      case Reads.delete_plan(mount, Reads.write_scope(mount, org_id), id) do
        :ok ->
          {:noreply, push_navigate(socket, to: plans_path(org_id))}

        {:error, _reason} ->
          {:noreply, assign(socket, delete_error: "Could not archive this plan.")}
      end
    else
      {:noreply, socket}
    end
  end

  def handle_event("dismiss_error", _params, socket) do
    {:noreply, assign(socket, action_error: nil, delete_error: nil)}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="billing-plan">
      <.app_shell>
        <:sidebar>
          <.billing_sidebar mount={@samen_mount} org_id={@org_id} active={:billing_plans} return_to={@return_to} />
        </:sidebar>

        <.topbar title={plan_label(@plan)} crumbs={crumbs(@samen_mount, @org_id, plan_label(@plan))}>
          <:actions>
            <a href={plans_path(@org_id)} class="btn" style="text-decoration:none">
              <span class="i">
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M19 12H5M12 5l-7 7 7 7" />
                </svg>
              </span>
              Back to plans
            </a>
            <.button :if={writable?(@samen_mount) and @plan != nil} phx-click="edit_plan" id="edit-plan">
              Edit plan
            </.button>
            <.delete_confirm
              :if={writable?(@samen_mount) and @plan != nil}
              id="archive-plan"
              label="Archive"
              message="Archive this plan? It can be restored from the plans list's archived view."
              phx-click="delete"
              phx-value-id={@plan && @plan.id}
            />
          </:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">Billing plan org: {@org_id}</span>

          <div :if={@action_error} class="wrap" style="margin-bottom:0">
            <div class="card form-error" id="action-error" style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px;display:flex;gap:10px;align-items:center">
              <span>{@action_error}</span>
              <button type="button" class="btn" phx-click="dismiss_error" style="font-size:12px">Dismiss</button>
            </div>
          </div>

          <div :if={@delete_error} class="wrap" style="margin-bottom:0">
            <div class="card form-error" id="delete-error" style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px">
              {@delete_error}
            </div>
          </div>

          <%= if @plan == nil do %>
            <div class="wrap">
              <div class="card" style="padding:22px 20px;color:var(--muted)">Plan not found.</div>
            </div>
          <% else %>
            <div class="wrap" style="margin-bottom:0">
              <div class="card" id="plan-header" style="padding:18px 20px;display:flex;align-items:center;gap:14px;flex-wrap:wrap">
                <div class="av" style={"width:46px;height:46px;border-radius:8px;background:#{plan_bg(@plan.name)};color:#{plan_fg(@plan.name)};font-size:15px;font-weight:700;display:flex;align-items:center;justify-content:center;flex-shrink:0"}>
                  {String.slice(@plan.label || @plan.name || "?", 0, 1) |> String.upcase()}
                </div>
                <div style="flex:1;min-width:0">
                  <h1 style="font-weight:600;font-size:18px;color:#2a2b35;margin:0 0 4px">{plan_label(@plan)}</h1>
                  <div style="display:flex;gap:8px;flex-wrap:wrap;align-items:center">
                    <.pill variant={if @plan.enabled, do: "ok", else: "mut"}>
                      {if @plan.enabled, do: "active", else: "disabled"}
                    </.pill>
                    <span style="font-size:12px;color:var(--muted)">{interval_label(@plan.interval)}</span>
                    <span style="font-size:13px;font-weight:500;color:#3a3b45">{primary_price(@prices)}</span>
                    <span style="font-size:12px;color:var(--muted)">· Tier-0 config · admin-gated writes · no PII</span>
                  </div>
                </div>
              </div>
            </div>

            <div class="wrap" style="margin-bottom:0;padding-top:10px">
              <div class="card" id="plan-facts" style="padding:16px 18px">
                <dl style="display:grid;grid-template-columns:minmax(140px,220px) 1fr;gap:8px 16px;margin:0">
                  <div style="display:contents">
                    <dt style="font-size:12px;font-weight:600;color:var(--muted)">Name</dt>
                    <dd style="margin:0;font-size:13px;font-family:monospace">{@plan.name || "—"}</dd>
                  </div>
                  <div style="display:contents">
                    <dt style="font-size:12px;font-weight:600;color:var(--muted)">Label</dt>
                    <dd style="margin:0;font-size:13px">{@plan.label || "—"}</dd>
                  </div>
                  <div style="display:contents">
                    <dt style="font-size:12px;font-weight:600;color:var(--muted)">Description</dt>
                    <dd style="margin:0;font-size:13px">{@plan.description || "—"}</dd>
                  </div>
                  <div style="display:contents">
                    <dt style="font-size:12px;font-weight:600;color:var(--muted)">Interval</dt>
                    <dd style="margin:0;font-size:13px">{interval_label(@plan.interval)}</dd>
                  </div>
                  <div style="display:contents">
                    <dt style="font-size:12px;font-weight:600;color:var(--muted)">Status</dt>
                    <dd style="margin:0;font-size:13px">
                      <.pill variant={if @plan.enabled, do: "ok", else: "mut"}>
                        {if @plan.enabled, do: "active", else: "disabled"}
                      </.pill>
                    </dd>
                  </div>
                  <div style="display:contents">
                    <dt style="font-size:12px;font-weight:600;color:var(--muted)">Provider ref</dt>
                    <dd style="margin:0;font-size:13px;font-family:monospace;word-break:break-all">
                      {@plan.provider_plan_ref || "—"}
                    </dd>
                  </div>
                  <div style="display:contents">
                    <dt style="font-size:12px;font-weight:600;color:var(--muted)">Inserted at</dt>
                    <dd style="margin:0;font-size:13px;font-family:monospace">{format_ts(@plan.inserted_at)}</dd>
                  </div>
                </dl>
              </div>

              <div class="card" id="plan-features" style="padding:16px 18px;margin-top:10px">
                <div class="gtitle" style="margin-bottom:6px">
                  <h3 style="font-size:13px">Entitlements</h3>
                  <span class="n">{length(granted_features(@plan))}</span>
                  <span class="lane">· feature map · fail-closed allowlist</span>
                </div>
                <div :if={granted_features(@plan) != []} style="display:flex;flex-wrap:wrap;gap:6px">
                  <span
                    :for={feat <- granted_features(@plan)}
                    style="display:inline-block;font-size:11px;padding:3px 8px;background:#F3F4F6;border-radius:4px;color:#374151"
                  >
                    {humanize_feature(feat)}
                  </span>
                </div>
                <p :if={granted_features(@plan) == []} style="margin:0;font-size:12px;color:var(--muted)">
                  No features granted on this plan.
                </p>
              </div>

              <div class="card" id="plan-prices" style="padding:16px 18px;margin-top:10px">
                <div class="gtitle" style="margin-bottom:6px">
                  <h3 style="font-size:13px">Prices</h3>
                  <span class="n">{length(@prices)}</span>
                </div>
                <table :if={@prices != []} style="width:100%;border-collapse:collapse;font-size:13px">
                  <thead>
                    <tr>
                      <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">
                        Price
                      </th>
                      <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">
                        Interval
                      </th>
                      <th scope="col" style="text-align:left;padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">
                        Active
                      </th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={price <- @prices} class="plan-price-row">
                      <td style="padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);font-family:monospace">
                        {dollars(price.unit_amount)}
                      </td>
                      <td style="padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb);color:var(--muted)">
                        {interval_label(price.interval)}
                      </td>
                      <td style="padding:6px 8px;border-bottom:1px solid var(--border, #e5e7eb)">
                        <.pill variant={if price.active, do: "ok", else: "mut"}>
                          {if price.active, do: "active", else: "inactive"}
                        </.pill>
                      </td>
                    </tr>
                  </tbody>
                </table>
                <p :if={@prices == []} style="margin:0;font-size:12px;color:var(--muted)">No prices yet.</p>
              </div>

              <div class="wrap" style="margin-bottom:0;padding-top:10px" id="plan-status-actions-wrap">
                <div class="card" id="plan-status-actions" style="padding:16px 18px">
                  <div class="gtitle" style="margin-bottom:8px">
                    <h3 style="font-size:13px">Status actions</h3>
                    <span class="lane">· admin-gated · subscriptions keep their own state</span>
                  </div>
                  <div :if={writable?(@samen_mount)} style="display:flex;gap:8px;flex-wrap:wrap">
                    <.button phx-click="toggle_enabled" id="toggle-enabled">
                      {if @plan.enabled, do: "Disable plan", else: "Enable plan"}
                    </.button>
                    <p style="margin:0;font-size:12px;color:var(--muted);align-self:center">
                      Disabling stops NEW sign-ups; existing subscriptions keep their state.
                    </p>
                  </div>
                  <p :if={!writable?(@samen_mount)} style="margin:0;font-size:12px;color:var(--muted)">
                    Plan is {if @plan.enabled, do: "active", else: "disabled"} · no write affordance on this plane.
                  </p>
                </div>
              </div>
            </div>

            <.modal
              :if={@show_edit and @edit_form != nil and writable?(@samen_mount)}
              id="edit-plan-modal"
              title="Edit plan"
              on_cancel="cancel_edit"
            >
              <.simple_form
                :let={f}
                for={@edit_form}
                id="edit-plan-form"
                phx-change="validate_edit"
                phx-submit="save_edit"
              >
                <.form_field field={f[:name]} label="Name" />
                <.form_field field={f[:label]} label="Label" />
                <.form_field field={f[:description]} label="Description" />
                <.form_field
                  field={f[:interval]}
                  label="Interval"
                  type="select"
                  options={[
                    {"monthly", "monthly"},
                    {"annual", "annual"},
                    {"weekly", "weekly"},
                    {"daily", "daily"},
                    {"one-time", "one_time"}
                  ]}
                />
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

  defp edit_form(plan, scope) do
    plan
    |> AshPhoenix.Form.for_update(:update, scope: scope)
    |> to_form()
  end

  defp edit_form(mount, org_id, plan), do: edit_form(plan, Reads.write_scope(mount, org_id))

  defp crumbs(mount, org_id, leaf),
    do: [Crumbs.org(mount, org_id), Crumbs.section(mount, org_id, :billing), {"Plans", plans_path(org_id)}, leaf]

  defp plans_path(nil), do: "/billing/plans"
  defp plans_path(org_id), do: "/billing/plans?org=#{org_id}"

  defp plan_label(nil), do: "Plan"
  defp plan_label(plan), do: plan.label || plan.name || "Plan"

  # REAL granted keys only — the detail page never fabricates a default chip.
  defp granted_features(%{features: features}) when is_map(features) do
    features
    |> Enum.filter(fn {_k, v} -> v in [true, "true"] end)
    |> Enum.map(fn {k, _v} -> k end)
    |> Enum.sort()
  end

  defp granted_features(_), do: []

  defp humanize_feature(key) when is_binary(key), do: String.replace(key, "_", " ")
  defp humanize_feature(key) when is_atom(key), do: key |> to_string() |> String.replace("_", " ")
  defp humanize_feature(other), do: to_string(other)

  defp primary_price([]), do: "—"
  defp primary_price([price | _]), do: dollars(price.unit_amount)

  defp interval_label(:monthly), do: "monthly"
  defp interval_label(:annual), do: "annual"
  defp interval_label(:weekly), do: "weekly"
  defp interval_label(:daily), do: "daily"
  defp interval_label(:one_time), do: "one-time"
  defp interval_label(other), do: to_string(other)

  defp plan_bg("starter"), do: "#F0FDF4"
  defp plan_bg("growth"), do: "#EFF6FF"
  defp plan_bg("scale"), do: "#F5F3FF"
  defp plan_bg(_), do: "#F3F4F6"

  defp plan_fg("starter"), do: "#16A34A"
  defp plan_fg("growth"), do: "#2563EB"
  defp plan_fg("scale"), do: "#7C3AED"
  defp plan_fg(_), do: "#6B7280"

  # ADR-036 §4.5(3): unit_amount is the Money composite — a plain integer cents
  # count is no longer the sole call shape.
  defp dollars(%Money{} = money), do: dollars(Samen.Type.Money.cents(money))
  defp dollars(cents) when is_integer(cents),
    do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"

  defp dollars(_), do: "—"

  defp format_ts(nil), do: "—"
  defp format_ts(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp format_ts(other), do: to_string(other)

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to),
      do: socket,
      else: assign(socket, return_to: nil)
  end
end
