defmodule Samen.Web.Banking.AccountsLive do
  @moduledoc """
  Framework Banking / Accounts page — the host's bank accounts (WS-ERP E9) rendered
  as real UI, host-agnostic (ADR-009). NON-PII (the Banking PII map is EMPTY,
  INV-1): nothing here is vault-routed, so no PiiResolution pass applies.

  List rides the A2 kit contract: `use Samen.Web.ListLive` + the BOUNDED
  `Reads.accounts_page/3` (sort/filter/keyset/empty-state as kit defaults). Write
  side: "New account" opens a `modal/1` hosting an `AshPhoenix.Form` create —
  `name` + the GL cash account (`account_id`, selected from the host's Finance
  accounts via the `:erp_namespace` mount label) are required, so the inline-error
  path is real. Write affordances are tenant-plane only (`writable?/1`); OrgScope +
  `RoleAtLeast` enforce in the kernel regardless.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Banking.Live, only: [assign_mount: 2, banking_sidebar: 1, writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.Crumbs
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  alias Samen.Web.Banking.Reads

  use Samen.Web.ListLive,
    resource: BankAccount,
    reads: &Samen.Web.Banking.Reads.accounts_page/3,
    sortable: [:name],
    filter_fields: [:name],
    default_sort: {:name, :asc}

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    {:ok, load(assign(socket, org_id: org_id), org_id)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Samen.Web.CurrentOrg.reresolve(socket, params)
    {:noreply, load(assign(socket, org_id: org_id, return_to: return_path(uri)), org_id)}
  end

  @doc false
  def load(socket, nil) do
    socket
    |> ensure_return_to()
    |> assign(no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil), org_id: nil)
    |> assign(page: %Samen.Web.Page{}, list_state: %Samen.Web.ListState{})
    |> assign(show_new: false, new_form: nil, gl_accounts: [])
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    socket
    |> ensure_return_to()
    |> assign(no_org: false, org_id: org_id)
    |> assign_new(:show_new, fn -> false end)
    |> assign(new_form: new_account_form(mount, scope), gl_accounts: gl_options(mount, scope))
    |> init_list(mount, scope)
  end

  @impl true
  def handle_event("new_account", _params, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    scope = Mount.scope(mount, org_id)

    {:noreply,
     assign(socket,
       show_new: true,
       new_form: new_account_form(mount, scope),
       gl_accounts: gl_options(mount, scope)
     )}
  end

  def handle_event("cancel_new", _params, socket) do
    {:noreply, assign(socket, show_new: false)}
  end

  def handle_event("validate_new", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.new_form, with_org(params, socket))
    {:noreply, assign(socket, new_form: form)}
  end

  # `org_id` is the server-side fact, never client input. Banking is non-PII; the
  # kernel's OrgScope + RoleAtLeast policies gate the write — this LiveView adds none.
  def handle_event("save_new", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.new_form, params: with_org(params, socket)) do
      {:ok, _account} ->
        {:noreply, socket |> assign(show_new: false) |> load(socket.assigns.org_id)}

      {:error, form} ->
        {:noreply, assign(socket, new_form: form)}
    end
  end

  defp new_account_form(mount, scope) do
    Mount.resource(mount, BankAccount)
    |> AshPhoenix.Form.for_create(:create, scope: scope)
    |> to_form()
  end

  defp gl_options(mount, scope) do
    Reads.gl_accounts(mount, scope)
    |> Enum.map(&{&1.id, &1.label})
  end

  defp with_org(params, socket), do: Map.put(params, "org_id", socket.assigns.org_id)

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to), do: socket, else: assign(socket, return_to: nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="banking-accounts">
      <.app_shell>
        <:sidebar>
          <.banking_sidebar mount={@samen_mount} org_id={@org_id} active={:banking_accounts} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Bank accounts" crumbs={crumbs(@samen_mount, @org_id, "Accounts")}>
          <:actions>
            <.button
              :if={writable?(@samen_mount) and not @no_org}
              variant="primary"
              phx-click="new_account"
              id="new-account"
            >
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 3v18M3 12h18" />
                </svg>
              </:icon>
              New account
            </.button>
          </:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">Banking org: {@org_id}</span>

          <div class="wrap">
            <div id="bank-accounts">
              <div class="gtitle">
                <h3>Bank accounts</h3>
                <span class="n">{length(@page.items)}</span>
                <span class="lane">· org-scoped · no PII</span>
              </div>
              <.list_view
                id="bank-accounts-list"
                page={@page}
                state={@list_state}
                row_class="bank-account-row"
                filter_placeholder="Filter bank accounts…"
                empty_text="No bank accounts yet."
                empty_icon="🏦"
                empty_body="Link each bank or credit-card account to its GL cash account to start importing statements and reconciling."
              >
                <:empty_actions :if={writable?(@samen_mount)}>
                  <.button variant="primary" phx-click="new_account" id="empty-new-account">New account</.button>
                </:empty_actions>
                <:head>
                  <.sort_header field={:name} label="Name" sort={@list_state.sort} width="34%" />
                  <th scope="col" style="width:16%">Currency</th>
                  <th scope="col" style="width:22%">Statement balance</th>
                  <th scope="col" style="width:14%">GL account</th>
                  <th scope="col" style="width:14%">Status</th>
                </:head>
                <:row :let={a}>
                  <td class="c-name">
                    <a href={account_path(@samen_mount, @org_id, a.id)} style="font-weight:500;color:#0A5C42">
                      {a.name}
                    </a>
                  </td>
                  <td style="color:var(--muted)">{a.currency}</td>
                  <td style="color:var(--muted)">{cents(a.statement_balance_cents)}</td>
                  <td style="color:var(--muted);font-size:12px">{gl_label(@gl_accounts, a.account_id)}</td>
                  <td>
                    <.pill variant={if a.is_active, do: "ok", else: "mut"}>{if a.is_active, do: "active", else: "inactive"}</.pill>
                  </td>
                </:row>
              </.list_view>
            </div>
          </div>

          <.modal :if={@show_new and @new_form != nil and writable?(@samen_mount)} id="new-account-modal" title="New bank account" on_cancel="cancel_new">
            <.simple_form :let={f} for={@new_form} id="new-account-form" phx-change="validate_new" phx-submit="save_new">
              <.form_field field={f[:name]} label="Name" />
              <.form_field
                field={f[:account_id]}
                label="GL cash account"
                type="select"
                prompt="Choose a GL account"
                options={@gl_accounts}
              />
              <.form_field field={f[:currency]} label="Currency" />
              <:actions>
                <.button variant="primary" type="submit">Save account</.button>
                <.button type="button" phx-click="cancel_new">Cancel</.button>
              </:actions>
            </.simple_form>
          </.modal>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  defp crumbs(mount, org_id, leaf) do
    [Crumbs.org(mount, org_id), "Banking", leaf]
  end

  defp account_path(mount, org_id, id),
    do: "#{Mount.label(mount, :banking_path, "/banking")}/accounts/#{id}?org=#{org_id}"

  # `@gl_accounts` holds the SELECT options ({id, label} tuples).
  defp gl_label(gl_accounts, id) do
    Enum.find_value(gl_accounts, "—", fn {gid, label} -> if gid == id, do: label end)
  end

  defp cents(cents) when is_integer(cents) do
    dollars = div(cents, 100)
    remainder = cents |> rem(100) |> abs()
    "$#{dollars}.#{String.pad_leading(Integer.to_string(remainder), 2, "0")}"
  end

  defp cents(_), do: "$0.00"
end
