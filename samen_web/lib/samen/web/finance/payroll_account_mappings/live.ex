defmodule Samen.Web.Finance.PayrollAccountMappings.Live do
  @moduledoc """
  The payroll account mapping admin surface (`/erp/payroll-mappings`).

  Payroll registers carry a provider's stable external account code, never a
  host account UUID. This page lets an organization admin maintain the
  per-provider `external_code -> Finance.Account` map that
  `Samen.Hr.Payroll.JournalProvider` resolves during preflight and import.

  The list is a bounded `ListLive` read over the org's own mapping rows. The
  create form writes the resource's `:create` action and the row editor writes
  its `:update` action (account only; provider/code identify the row). No new
  policy is introduced here:

    * reads use `TenantRole.authenticated_scope/2`, so `OrgScope` shows only the
      caller's organization;
    * every write uses `TenantRole.attributed_admin_scope/2`, so the
      resource's own `OrgScope` + `RoleAtLeast :admin` policies decide, and
      `Samen.Policy.SameOrgFk` refuses an account from another org;
    * write affordances are offered only on the tenant plane to a derived
      admin. A crafted event from a member still reaches the kernel's policy
      and writes nothing.

  No PII: a provider name, an external code, an account UUID and the account's
  code/name (Tier-0 chart-of-accounts configuration).
  """

  use Samen.Web.Tenant.Live

  import Samen.UI
  import Samen.Web.Erp.Live, only: [assign_mount: 2, erp_sidebar: 1, writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.Crumbs
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Erp
  alias Samen.Web.Finance.PayrollAccountMappings
  alias Samen.Web.TenantRole

  use Samen.Web.ListLive,
    reads: &Samen.Web.Finance.PayrollAccountMappings.mappings_page/3,
    sortable: [:provider, :external_code],
    filter_fields: [:provider, :external_code],
    default_sort: {:provider, :asc}

  @admin_only "Only an organization admin can change payroll mappings."

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)

    {:ok,
     socket
     |> assign(
       org_id: org_id,
       return_to: nil,
       mapping_resource: nil,
       accounts: [],
       accounts_truncated?: false,
       accounts_error?: false,
       new_form: nil,
       edit_mapping: nil,
       edit_form: nil,
       show_new: false,
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
    |> assign_new(:return_to, fn -> nil end)
    |> assign_new(:mapping_resource, fn -> nil end)
    |> assign_new(:accounts, fn -> [] end)
    |> assign_new(:accounts_truncated?, fn -> false end)
    |> assign_new(:accounts_error?, fn -> false end)
    |> assign_new(:new_form, fn -> nil end)
    |> assign_new(:edit_mapping, fn -> nil end)
    |> assign_new(:edit_form, fn -> nil end)
    |> assign_new(:show_new, fn -> false end)
    |> assign_new(:admin?, fn -> false end)
    |> assign_new(:missing, fn -> nil end)
    |> assign_new(:save_error, fn -> nil end)
    |> assign_new(:saved, fn -> false end)
    |> do_load()
  end

  defp do_load(%{assigns: %{org_id: nil}} = socket) do
    assign(socket,
      org_id: nil,
      mapping_resource: nil,
      accounts: [],
      accounts_truncated?: false,
      accounts_error?: false,
      new_form: nil,
      edit_mapping: nil,
      edit_form: nil,
      show_new: false,
      admin?: false,
      missing: :no_org
    )
  end

  defp do_load(socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    scope = TenantRole.authenticated_scope(mount, org_id)
    admin_scope = TenantRole.attributed_admin_scope(mount, org_id)
    admin? = writable?(mount) and admin_scope?(admin_scope)

    case PayrollAccountMappings.load(mount, scope) do
      {:ok, resources} ->
        socket
        |> assign(
          mapping_resource: resources.mapping_resource,
          accounts: resources.accounts,
          accounts_truncated?: resources.accounts_truncated?,
          accounts_error?: resources.accounts_error?,
          new_form: if(admin?, do: new_form(resources.mapping_resource, admin_scope)),
          edit_mapping: nil,
          edit_form: nil,
          show_new: false,
          admin?: admin?,
          missing: nil,
          save_error: nil
        )
        |> init_list(mount, scope)

      {:error, _reason} ->
        assign(socket,
          mapping_resource: nil,
          accounts: [],
          accounts_truncated?: false,
          accounts_error?: false,
          new_form: nil,
          edit_mapping: nil,
          edit_form: nil,
          show_new: false,
          admin?: false,
          missing: :unmounted,
          save_error: nil
        )
    end
  end

  # -- events -----------------------------------------------------------------

  @impl true
  def handle_event("new_mapping", _params, socket) do
    if socket.assigns.admin? and socket.assigns.mapping_resource != nil do
      %{samen_mount: mount, org_id: org_id, mapping_resource: resource} = socket.assigns

      {:noreply,
       assign(socket,
         show_new: true,
         new_form: new_form(resource, TenantRole.attributed_admin_scope(mount, org_id)),
         edit_mapping: nil,
         edit_form: nil,
         save_error: nil,
         saved: false
       )}
    else
      {:noreply, assign(socket, save_error: @admin_only, saved: false)}
    end
  end

  def handle_event("cancel_new", _params, socket) do
    {:noreply, assign(socket, show_new: false, save_error: nil)}
  end

  def handle_event("validate_new", %{"form" => params}, socket) do
    case socket.assigns.new_form do
      nil ->
        {:noreply, socket}

      form ->
        {:noreply,
         assign(socket,
           new_form: AshPhoenix.Form.validate(form, with_org(params, socket.assigns.org_id)),
           save_error: nil
         )}
    end
  end

  def handle_event("save_new", %{"form" => params}, socket) do
    %{
      samen_mount: mount,
      org_id: org_id,
      mapping_resource: resource,
      new_form: form
    } = socket.assigns

    if socket.assigns.admin? and writable?(mount) and org_id != nil and resource != nil and
         form != nil do
      case AshPhoenix.Form.submit(form, params: with_org(params, org_id)) do
        {:ok, _mapping} ->
          {:noreply,
           socket
           |> assign(show_new: false, saved: true, save_error: nil)
           |> load()}

        {:error, form} ->
          {:noreply,
           assign(socket,
             new_form: form,
             save_error: form_error(form),
             saved: false
           )}
      end
    else
      {:noreply, assign(socket, save_error: @admin_only, saved: false)}
    end
  end

  def handle_event("edit_mapping", %{"id" => id}, socket) do
    mapping = find_mapping(socket, id)

    if socket.assigns.admin? and mapping != nil do
      %{samen_mount: mount, org_id: org_id} = socket.assigns
      scope = TenantRole.attributed_admin_scope(mount, org_id)

      {:noreply,
       assign(socket,
         show_new: false,
         new_form: nil,
         edit_mapping: mapping,
         edit_form: edit_form(mapping, scope),
         save_error: nil,
         saved: false
       )}
    else
      if socket.assigns.admin? do
        {:noreply, socket}
      else
        {:noreply, assign(socket, save_error: @admin_only, saved: false)}
      end
    end
  end

  def handle_event("cancel_edit", _params, socket) do
    {:noreply, assign(socket, edit_mapping: nil, edit_form: nil, save_error: nil)}
  end

  def handle_event("validate_edit", %{"form" => params}, socket) do
    case socket.assigns.edit_form do
      nil ->
        {:noreply, socket}

      form ->
        {:noreply,
         assign(socket,
           edit_form: AshPhoenix.Form.validate(form, params),
           save_error: nil
         )}
    end
  end

  def handle_event("save_edit", %{"form" => params}, socket) do
    %{samen_mount: mount, org_id: org_id, edit_form: form} = socket.assigns

    if socket.assigns.admin? and writable?(mount) and org_id != nil and form != nil do
      case AshPhoenix.Form.submit(form, params: params) do
        {:ok, _mapping} ->
          {:noreply,
           socket
           |> assign(edit_mapping: nil, edit_form: nil, saved: true, save_error: nil)
           |> load()}

        {:error, form} ->
          {:noreply,
           assign(socket,
             edit_form: form,
             save_error: form_error(form),
             saved: false
           )}
      end
    else
      {:noreply, assign(socket, save_error: @admin_only, saved: false)}
    end
  end

  def handle_event("dismiss_error", _params, socket) do
    {:noreply, assign(socket, save_error: nil)}
  end

  # -- helpers ----------------------------------------------------------------

  defp new_form(resource, scope) do
    resource
    |> AshPhoenix.Form.for_create(:create, scope: scope)
    |> to_form()
  end

  defp edit_form(mapping, scope) do
    mapping
    |> AshPhoenix.Form.for_update(:update, scope: scope)
    |> to_form()
  end

  defp with_org(params, org_id), do: Map.put(params, "org_id", org_id)

  defp find_mapping(%{assigns: %{page: %{items: items}}}, id) do
    Enum.find(items, fn mapping -> to_string(mapping.id) == to_string(id) end)
  end

  defp find_mapping(_socket, _id), do: nil

  defp admin_scope?(%Samen.Scope{actor: actor}) do
    Samen.Scope.Role.at_least?(Map.get(actor, :role), :admin)
  end

  defp account_options(accounts) do
    Enum.map(accounts, fn account ->
      {"#{account.code} — #{account.name}", account.id}
    end)
  end

  defp form_error(form) do
    form
    |> AshPhoenix.Form.errors(format: :plaintext, for_path: :all)
    |> Map.values()
    |> List.flatten()
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.uniq()
    |> Enum.join(" ")
    |> case do
      "" -> "Could not save this payroll mapping."
      message -> message
    end
  rescue
    _ -> "Could not save this payroll mapping."
  end

  defp crumbs(mount, org_id) do
    [Crumbs.org(mount, org_id), "ERP", Erp.payroll_mappings_label()]
  end

  @impl Samen.Web.Tenant.Live
  def tenant_sidebar(assigns) do
    ~H"""
    <.erp_sidebar
      mount={@samen_mount}
      org_id={@org_id}
      active={:erp_payroll_mappings}
      return_to={@return_to}
    />
    """
  end

  @impl Samen.Web.Tenant.Live
  def tenant_page(assigns) do
    ~H"""
    <div id="erp-payroll-mappings">
      <.topbar title={Erp.payroll_mappings_label()} crumbs={crumbs(@samen_mount, @org_id)}>
        <:actions>
          <.button
            :if={@admin?}
            variant="primary"
            phx-click="new_mapping"
            id="new-payroll-mapping"
            disabled={@accounts == []}
          >
            New mapping
          </.button>
        </:actions>
      </.topbar>

      <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

      <div class="wrap">
        <%= if @missing == :no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <%= if @missing in [:unmounted, :unreadable] do %>
            <div class="card" id="payroll-mappings-unavailable" style="padding:16px;color:var(--muted)">
              Payroll account mappings need this workspace's mounted Finance account
              and mapping modules.
            </div>
          <% else %>
            <div class="gtitle">
              <h3>{Erp.payroll_mappings_label()}</h3>
              <span class="n">{length(@page.items)}</span>
              <span class="lane">· per-provider account codes · admin-gated writes</span>
            </div>

            <div
              id="payroll-mappings-description"
              class="card"
              style="padding:12px 16px;margin-bottom:12px;font-size:13px;color:var(--muted)"
            >
              Payroll registers carry a provider's stable external account code. Map each code to
              this organization's chart-of-accounts account; the payroll preflight resolves the
              code through this table before any journal entry or provenance row is written.
            </div>

            <div
              :if={@save_error}
              id="payroll-mappings-error"
              class="card form-error"
              style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px;margin-bottom:10px;display:flex;gap:10px;align-items:center"
            >
              <span>{@save_error}</span>
              <button type="button" class="button" phx-click="dismiss_error" style="font-size:11px">
                Dismiss
              </button>
            </div>

            <div
              :if={@saved}
              id="payroll-mappings-saved"
              class="card"
              style="padding:10px 14px;color:var(--ok, #047857);font-size:12px;margin-bottom:10px"
            >
              Saved. The next payroll preflight uses this mapping.
            </div>

            <div
              :if={@accounts_error?}
              id="payroll-mappings-accounts-error"
              class="card"
              style="padding:10px 14px;color:var(--bad, #b91c1c);font-size:12px;margin-bottom:10px"
            >
              The chart of accounts could not be read, so the account picker is empty. The
              existing mappings are still shown.
            </div>

            <div
              :if={@accounts_truncated?}
              id="payroll-mappings-accounts-truncated"
              class="card"
              style="padding:10px 14px;color:var(--muted);font-size:12px;margin-bottom:10px"
            >
              The chart of accounts exceeds the picker limit, so only the first 500 accounts are
              offered here.
            </div>

            <div
              :if={!@admin?}
              id="payroll-mappings-access-note"
              class="card"
              style="padding:10px 14px;font-size:12px;margin-bottom:10px;color:var(--muted)"
            >
              <%= if writable?(@samen_mount) do %>
                <span id="payroll-mappings-admin-only">
                  Only an organization admin can change payroll mappings.
                </span>
              <% else %>
                <span id="payroll-mappings-read-only">Read-only on this plane.</span>
              <% end %>
            </div>

            <.list_view
              id="payroll-mappings-list"
              page={@page}
              state={@list_state}
              filter_placeholder="Filter provider or account code…"
              empty_text="No payroll account mappings yet."
              empty_icon="⇄"
              empty_body="Map a payroll provider's external account code to a chart-of-accounts account before importing its registers."
            >
              <:head>
                <.sort_header field={:provider} label="Provider" sort={@list_state.sort} width="22%" />
                <.sort_header
                  field={:external_code}
                  label="External code"
                  sort={@list_state.sort}
                  width="22%"
                />
                <th scope="col" style="width:38%">Host account</th>
                <th :if={@admin?} scope="col" style="width:18%">
                  <span class="sr-only">Actions</span>
                </th>
              </:head>
              <:row :let={mapping}>
                <td style="font-weight:600">{mapping.provider}</td>
                <td><code>{mapping.external_code}</code></td>
                <td>
                  <%= if mapping.account do %>
                    <b>{mapping.account.code}</b>
                    <span style="color:var(--muted)"> — {mapping.account.name}</span>
                  <% else %>
                    <span style="color:var(--muted)">Account unavailable</span>
                  <% end %>
                </td>
                <td :if={@admin?}>
                  <.button
                    phx-click="edit_mapping"
                    phx-value-id={mapping.id}
                    id={"edit-payroll-mapping-#{mapping.id}"}
                  >
                    Change account
                  </.button>
                </td>
              </:row>
            </.list_view>

            <.modal
              :if={@show_new and @new_form != nil}
              id="new-payroll-mapping-modal"
              title="New payroll mapping"
              on_cancel="cancel_new"
            >
              <.simple_form
                :let={f}
                for={@new_form}
                id="new-payroll-mapping-form"
                phx-change="validate_new"
                phx-submit="save_new"
              >
                <.form_field
                  field={f[:provider]}
                  label="Provider"
                  placeholder="gusto"
                  required
                />
                <.form_field
                  field={f[:external_code]}
                  label="External account code"
                  placeholder="SALARY"
                  required
                />
                <.form_field
                  field={f[:account_id]}
                  label="Host account"
                  type="select"
                  options={account_options(@accounts)}
                  prompt="Select an account"
                  required
                />
                <p style="margin:0;color:var(--muted);font-size:12px">
                  The account must belong to this organization. A cross-org account is refused by
                  the kernel.
                </p>

                <:actions>
                  <.button variant="primary" type="submit" id="save-payroll-mapping">
                    Save mapping
                  </.button>
                  <.button type="button" phx-click="cancel_new">Cancel</.button>
                </:actions>
              </.simple_form>
            </.modal>

            <.modal
              :if={@edit_mapping != nil and @edit_form != nil}
              id="edit-payroll-mapping-modal"
              title="Change mapped account"
              on_cancel="cancel_edit"
            >
              <.simple_form
                :let={f}
                for={@edit_form}
                id="edit-payroll-mapping-form"
                phx-change="validate_edit"
                phx-submit="save_edit"
              >
                <div
                  id="edit-payroll-mapping-identity"
                  style="margin-bottom:12px;font-size:13px;color:var(--muted)"
                >
                  <b style="color:var(--ink, #111827)">{@edit_mapping.provider}</b>
                  <span> / </span>
                  <code>{@edit_mapping.external_code}</code>
                </div>

                <.form_field
                  field={f[:account_id]}
                  label="Host account"
                  type="select"
                  options={account_options(@accounts)}
                  prompt="Select an account"
                  required
                />
                <p style="margin:0;color:var(--muted);font-size:12px">
                  Only the mapped account changes; the provider and external code identify the
                  row.
                </p>

                <:actions>
                  <.button variant="primary" type="submit" id="update-payroll-mapping">
                    Save account
                  </.button>
                  <.button type="button" phx-click="cancel_edit">Cancel</.button>
                </:actions>
              </.simple_form>
            </.modal>
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end
end
