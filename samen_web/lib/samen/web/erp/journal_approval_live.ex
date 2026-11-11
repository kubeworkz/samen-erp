defmodule Samen.Web.Erp.JournalApprovalLive do
  @moduledoc """
  The journal-approval control page (`<erp>/journal-approval`) — the admin
  settings surface over one org's `JournalApprovalPolicy` row.

  The control answers two questions:

    * `enabled` — must a HUMAN journal `:post`/`:void` be approved by a
      principal other than the entry's preparer?
    * `threshold_cents` — only entries whose debit total is at least this
      amount are gated. `0` means every manual entry.
    * `account_ids` — optional account scope. Empty means all accounts;
      otherwise at least one line must touch a listed account.
    * `period_keys` — optional `"YYYY-MM"` periods. Empty means all periods;
      otherwise the entry date must fall in a listed month.

  A missing row means the control is not configured, which leaves historical
  posting behavior intact. The page therefore offers CREATE when the org has no
  row and UPDATE when it has one. It never deletes: disabling is an auditable
  update, exactly as the resource documents.

  ## Authorization (kernel, not posture)

  The read uses `Samen.Web.TenantRole.authenticated_scope/2` (any member of the
  org may see the control; the kernel's `OrgScope` pins the org). Every write is
  submitted with `TenantRole.attributed_admin_scope/2`, so the resource's OWN
  `OrgScope` + `RoleAtLeast :admin` policies decide: a member's save is refused
  even if a crafted event reaches this module. The form is OFFERED only on the
  tenant plane (`Samen.Web.Erp.Live.writable?/1`) and only when that admin scope
  really resolves to `:admin` — on an armed host with a member principal the
  page is read-only.

  A host that never materialized `JournalApprovalPolicy` (no Finance mount)
  renders the honest not-mounted state. No PII: a tenant id, a boolean and an
  integer.
  """

  use Samen.Web.Tenant.Live

  require Ash.Query

  import Samen.UI

  import Samen.Web.Erp.Live, only: [assign_mount: 2, erp_sidebar: 1, writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.Crumbs
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Erp
  alias Samen.Web.TenantRole

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)

    {:ok,
     socket
     |> assign(
       org_id: org_id,
       return_to: nil,
       resource: nil,
       policy: nil,
       form: nil,
       account_scope_text: "",
       period_scope_text: "",
       admin?: false,
       missing: nil,
       save_error: nil,
       saved: false
     )
     |> load()}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = CurrentOrg.reresolve(socket, params)

    {:noreply,
     socket
     |> assign(org_id: org_id, return_to: return_path(uri), saved: false)
     |> load()}
  end

  @doc false
  def load(socket) do
    socket
    |> assign_new(:saved, fn -> false end)
    |> assign_new(:save_error, fn -> nil end)
    |> assign_new(:return_to, fn -> nil end)
    |> do_load()
  end

  defp do_load(%{assigns: %{org_id: nil}} = socket) do
    assign(socket,
      org_id: nil,
      missing: :no_org,
      resource: nil,
      policy: nil,
      form: nil,
      admin?: false
    )
  end

  defp do_load(socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    case Erp.journal_approval_policy(mount) do
      nil ->
        assign(socket,
          missing: :unmounted,
          resource: nil,
          policy: nil,
          form: nil,
          admin?: false
        )

      resource ->
        case read_policy(resource, mount, org_id) do
          {:ok, policy} ->
            socket
            |> assign(resource: resource, policy: policy, missing: nil, save_error: nil)
            |> assign_form()

          {:error, _reason} ->
            assign(socket,
              resource: resource,
              policy: nil,
              form: nil,
              admin?: false,
              missing: :unreadable
            )
        end
    end
  end

  defp read_policy(resource, mount, org_id) do
    scope = TenantRole.authenticated_scope(mount, org_id)

    resource
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.Query.limit(1)
    |> Ash.read_one(scope: scope)
  end

  # The form is built from the host's OWN governed action and an admin scope.
  # It is only OFFERED when this caller's derived role is really `:admin` (and
  # the mount is writable); a member gets the read-only view, and a crafted
  # event is refused below.
  defp assign_form(socket) do
    %{samen_mount: mount, org_id: org_id, policy: policy, resource: resource} = socket.assigns

    scope = TenantRole.attributed_admin_scope(mount, org_id)
    admin? = writable?(mount) and Map.get(scope.actor, :role) == :admin

    form =
      if admin? do
        case policy do
          nil ->
            resource
            |> AshPhoenix.Form.for_create(:create,
              scope: scope,
              params: %{
                org_id: org_id,
                enabled: true,
                threshold_cents: 0,
                account_ids: [],
                period_keys: []
              }
            )
            |> to_form()

          policy ->
            policy
            |> AshPhoenix.Form.for_update(:update, scope: scope)
            |> to_form()
        end
      end

    account_ids = if policy, do: Map.get(policy, :account_ids, []), else: []
    period_keys = if policy, do: Map.get(policy, :period_keys, []), else: []

    assign(socket,
      form: form,
      admin?: admin?,
      account_scope_text: scope_text(account_ids),
      period_scope_text: scope_text(period_keys)
    )
  end

  # -- events -----------------------------------------------------------------

  @impl true
  def handle_event("validate", %{"form" => params}, socket) do
    params = normalize_scope_params(params)

    case socket.assigns.form do
      nil ->
        {:noreply, socket}

      form ->
        {:noreply,
         assign(socket,
           form: AshPhoenix.Form.validate(form, params),
           account_scope_text: scope_text(params["account_ids"]),
           period_scope_text: scope_text(params["period_keys"]),
           save_error: nil,
           saved: false
         )}
    end
  end

  def handle_event("save", %{"form" => params}, socket) do
    %{samen_mount: mount, org_id: org_id, policy: policy, form: form} = socket.assigns
    params = normalize_scope_params(params)

    if form != nil and socket.assigns.admin? and writable?(mount) and org_id != nil do
      # `org_id` is the server-side fact for CREATE; UPDATE does not accept it.
      params = if policy == nil, do: Map.put(params, "org_id", org_id), else: params

      case AshPhoenix.Form.submit(form, params: params) do
        {:ok, _policy} ->
          {:noreply, socket |> assign(form: nil, policy: nil, saved: true) |> load()}

        {:error, form} ->
          {:noreply,
           assign(socket,
             form: form,
             account_scope_text: scope_text(params["account_ids"]),
             period_scope_text: scope_text(params["period_keys"]),
             save_error: form_error(form),
             saved: false
           )}
      end
    else
      {:noreply,
       assign(socket,
         save_error: "Only an organization admin can change the journal approval policy.",
         saved: false
       )}
    end
  end

  # -- helpers ----------------------------------------------------------------

  defp status_text(nil), do: "Not configured"
  defp status_text(%{enabled: true}), do: "Enabled"
  defp status_text(%{enabled: false}), do: "Disabled"
  defp status_text(_), do: "Not configured"

  defp status_variant(nil), do: "mut"
  defp status_variant(%{enabled: true}), do: "ok"
  defp status_variant(_), do: "mut"

  defp normalize_scope_params(params) do
    params
    |> Map.put("account_ids", split_scope(params["account_ids"]))
    |> Map.put("period_keys", split_scope(params["period_keys"]))
  end

  defp split_scope(value) do
    value
    |> List.wrap()
    |> Enum.flat_map(fn item -> String.split(to_string(item), ~r/[\s,]+/, trim: true) end)
  end

  defp scope_text(value) when is_list(value), do: Enum.join(value, ", ")
  defp scope_text(_), do: ""

  defp scope_summary(nil, _all), do: "All"
  defp scope_summary([], all), do: all
  defp scope_summary(list, _all) when is_list(list), do: "#{length(list)} scoped"
  defp scope_summary(_, all), do: all

  defp threshold_text(nil), do: "not set — a disabled/missing policy gates nothing"
  defp threshold_text(%{threshold_cents: 0}), do: "0 cents — every manual posting"
  defp threshold_text(%{threshold_cents: cents}), do: "#{cents} cents (#{dollars(cents)})"
  defp threshold_text(_), do: "—"

  defp dollars(cents) when is_integer(cents) and cents >= 0 do
    "$#{div(cents, 100)}.#{cents |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")}"
  end

  defp dollars(_), do: "—"

  defp form_error(form) do
    case Enum.reject(form.errors, &(&1 in [nil, ""])) do
      [] -> "Could not save the journal approval policy."
      errors -> errors |> Enum.map(&error_text/1) |> Enum.uniq() |> Enum.join(" ")
    end
  rescue
    _ -> "Could not save the journal approval policy."
  end

  defp error_text({msg, opts}) when is_binary(msg) do
    Enum.reduce(opts, msg, fn {key, value}, acc ->
      String.replace(acc, "%{#{key}}", fn _ -> to_string(value) end)
    end)
  end

  defp error_text(msg) when is_binary(msg), do: msg
  defp error_text(other), do: to_string(other)

  defp crumbs(mount, org_id) do
    [Crumbs.org(mount, org_id), "ERP", Erp.journal_approval_label()]
  end

  @impl Samen.Web.Tenant.Live
  def tenant_sidebar(assigns) do
    ~H"""
    <.erp_sidebar
      mount={@samen_mount}
      org_id={@org_id}
      active={:erp_journal_approval}
      return_to={@return_to}
    />
    """
  end

  @impl Samen.Web.Tenant.Live
  def tenant_page(assigns) do
    ~H"""
    <div id="erp-journal-approval">
    <.topbar
      title={Erp.journal_approval_label()}
      crumbs={crumbs(@samen_mount, @org_id)}
    />

    <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

    <div class="wrap">
      <%= if @missing == :no_org do %>
        <.no_org_card mount={@samen_mount} />
      <% else %>
        <%= if @missing in [:unmounted, :unreadable] do %>
          <div class="card" style="padding:16px;color:var(--muted)">
            <%= if @missing == :unreadable do %>
              The journal approval policy could not be read. Try again.
            <% else %>
              The journal approval control is not available on this workspace's mounted modules.
            <% end %>
          </div>
        <% else %>
          <div class="gtitle">
            <h3>{Erp.journal_approval_label()}</h3>
            <span class="lane">· one control per org · admin-gated writes</span>
          </div>

          <div
            :if={@save_error}
            id="policy-error"
            class="card form-error"
            style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px;margin-bottom:10px"
          >
            {@save_error}
          </div>

          <div
            :if={@saved}
            id="policy-saved"
            class="card"
            style="padding:10px 14px;color:var(--ok, #047857);font-size:12px;margin-bottom:10px"
          >
            Saved. The next manual posting follows this control immediately.
          </div>

          <div
            id="policy-state"
            class="card"
            style="padding:14px 18px;margin-bottom:10px;display:flex;gap:14px;align-items:center;flex-wrap:wrap"
          >
            <.pill variant={status_variant(@policy)}>{status_text(@policy)}</.pill>
            <span style="font-size:13px"><b>Threshold:</b> {threshold_text(@policy)}</span>
            <span style="font-size:13px">
              <b>Accounts:</b> {scope_summary(@policy && @policy.account_ids, "All accounts")}
            </span>
            <span style="font-size:13px">
              <b>Periods:</b> {scope_summary(@policy && @policy.period_keys, "All periods")}
            </span>
          </div>

          <div class="card" id="policy-body" style="padding:16px 18px">
            <p style="margin:0 0 14px;font-size:13px;color:var(--muted)">
              When enabled, a human journal entry at or above the threshold must be posted or
              voided by a principal other than the person who prepared it. System postings (AP,
              AR, inventory, depreciation, accruals, reversals) are outside this human control.
            </p>

            <%= cond do %>
              <% @form != nil -> %>
                <.simple_form
                  :let={f}
                  for={@form}
                  id="journal-approval-form"
                  phx-change="validate"
                  phx-submit="save"
                >
                  <div class="field" style="display:flex;flex-direction:column;gap:4px;margin-bottom:10px">
                    <label for={f[:enabled].id} class="field-label" style="font-size:12px;font-weight:600">
                      Require a distinct approver
                    </label>
                    <input type="hidden" name={f[:enabled].name} value="false" />
                    <label style="display:flex;align-items:center;gap:8px;font-size:13px">
                      <input
                        type="checkbox"
                        id={f[:enabled].id}
                        name={f[:enabled].name}
                        value="true"
                        checked={f[:enabled].value in [true, "true", "on", "1"]}
                      />
                      <span>Enabled — manual postings need approval</span>
                    </label>
                  </div>

                  <.form_field
                    field={f[:threshold_cents]}
                    label="Threshold (cents)"
                    type="number"
                    min="0"
                    step="1"
                  />

                  <p style="margin:0 0 14px;font-size:12px;color:var(--muted)">
                    Entries whose debit total is at least this amount need approval.
                    <b>0</b> means every manual entry.
                  </p>

                  <div class="field" style="display:flex;flex-direction:column;gap:4px;margin-bottom:10px">
                    <label for={f[:account_ids].id} class="field-label" style="font-size:12px;font-weight:600">
                      Scoped accounts (optional)
                    </label>
                    <input
                      type="text"
                      id={f[:account_ids].id}
                      name={f[:account_ids].name}
                      value={@account_scope_text}
                      placeholder="Empty means all accounts"
                    />
                    <span style="font-size:12px;color:var(--muted)">
                      Comma-separated account UUIDs. The policy applies when at least one line
                      touches one of them.
                    </span>
                  </div>

                  <div class="field" style="display:flex;flex-direction:column;gap:4px;margin-bottom:10px">
                    <label for={f[:period_keys].id} class="field-label" style="font-size:12px;font-weight:600">
                      Scoped periods (optional)
                    </label>
                    <input
                      type="text"
                      id={f[:period_keys].id}
                      name={f[:period_keys].name}
                      value={@period_scope_text}
                      placeholder="Empty means all periods"
                    />
                    <span style="font-size:12px;color:var(--muted)">
                      Comma-separated fiscal months in <code>YYYY-MM</code> form, for example
                      <code>2026-11, 2026-12</code>.
                    </span>
                  </div>

                  <:actions>
                    <.button variant="primary" type="submit" id="save-policy">
                      Save policy
                    </.button>
                  </:actions>
                </.simple_form>
              <% not writable?(@samen_mount) -> %>
                <p id="policy-read-only" style="margin:0;font-size:13px;color:var(--muted)">
                  Read-only on this plane.
                </p>
              <% true -> %>
                <p id="policy-admin-only" style="margin:0;font-size:13px;color:var(--muted)">
                  Only an organization admin can change this control.
                </p>
            <% end %>
          </div>
        <% end %>
      <% end %>
    </div>
    </div>
    """
  end
end
