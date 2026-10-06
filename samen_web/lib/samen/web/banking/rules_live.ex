defmodule Samen.Web.Banking.RulesLive do
  @moduledoc """
  Framework Banking / Rules page — the auto-categorization patterns (WS-ERP E9,
  `Samen.Scopes.Banking.Rule`) rendered as real UI, host-agnostic (ADR-009).

  A Tier-0 config row: pattern (substring/regex over a statement-line description)
  → GL account, optional amount bounds, priority (higher wins), scoped to one bank
  account or all of them. Evaluated by `Samen.Scopes.Banking.RuleEngine` on import.
  NON-PII (the Banking PII map is EMPTY, INV-1). List rides the A2 `ListLive`
  contract over the BOUNDED `Reads.rules_page/3`; create is an `AshPhoenix.Form`
  over the resource's OWN `:create` action, tenant plane only.
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
    resource: Rule,
    reads: &Samen.Web.Banking.Reads.rules_page/3,
    sortable: [:pattern, :priority],
    filter_fields: [:pattern],
    default_sort: {:priority, :desc}

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
    |> assign(show_new: false, new_form: nil, gl_accounts: [], bank_accounts: [])
  end

  def load(socket, org_id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    socket
    |> ensure_return_to()
    |> assign(no_org: false, org_id: org_id)
    |> assign_new(:show_new, fn -> false end)
    |> assign(
      new_form: new_rule_form(mount, scope),
      gl_accounts: gl_options(mount, scope),
      bank_accounts: bank_options(mount, scope)
    )
    |> init_list(mount, scope)
  end

  @impl true
  def handle_event("new_rule", _params, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    scope = Mount.scope(mount, org_id)

    {:noreply,
     assign(socket,
       show_new: true,
       new_form: new_rule_form(mount, scope),
       gl_accounts: gl_options(mount, scope),
       bank_accounts: bank_options(mount, scope)
     )}
  end

  def handle_event("cancel_new", _params, socket) do
    {:noreply, assign(socket, show_new: false)}
  end

  def handle_event("validate_new", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.new_form, with_org(params, socket))
    {:noreply, assign(socket, new_form: form)}
  end

  def handle_event("save_new", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.new_form, params: with_org(params, socket)) do
      {:ok, _rule} ->
        {:noreply, socket |> assign(show_new: false) |> load(socket.assigns.org_id)}

      {:error, form} ->
        {:noreply, assign(socket, new_form: form)}
    end
  end

  defp new_rule_form(mount, scope) do
    Mount.resource(mount, Rule)
    |> AshPhoenix.Form.for_create(:create, scope: scope)
    |> to_form()
  end

  defp gl_options(mount, scope) do
    Reads.gl_accounts(mount, scope) |> Enum.map(&{&1.id, &1.label})
  end

  defp bank_options(mount, scope) do
    Reads.accounts_page(mount, scope, %Samen.Web.ListState{page_size: 100})
    |> Map.get(:items, [])
    |> Enum.map(&{&1.id, &1.name})
  end

  defp with_org(params, socket), do: Map.put(params, "org_id", socket.assigns.org_id)

  defp ensure_return_to(socket) do
    if Map.has_key?(socket.assigns, :return_to), do: socket, else: assign(socket, return_to: nil)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="banking-rules">
      <.app_shell>
        <:sidebar>
          <.banking_sidebar mount={@samen_mount} org_id={@org_id} active={:banking_rules} return_to={@return_to} />
        </:sidebar>

        <.topbar title="Rules" crumbs={crumbs(@samen_mount, @org_id, "Rules")}>
          <:actions>
            <.button
              :if={writable?(@samen_mount) and not @no_org}
              variant="primary"
              phx-click="new_rule"
              id="new-rule"
            >
              <:icon>
                <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8">
                  <path d="M12 3v18M3 12h18" />
                </svg>
              </:icon>
              New rule
            </.button>
          </:actions>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">Banking org: {@org_id}</span>

          <div class="wrap">
            <div id="rules">
              <div class="gtitle">
                <h3>Auto-categorization rules</h3>
                <span class="n">{length(@page.items)}</span>
                <span class="lane">· org-scoped · no PII</span>
              </div>
              <.list_view
                id="rules-list"
                page={@page}
                state={@list_state}
                row_class="rule-row"
                filter_placeholder="Filter rules…"
                empty_text="No rules yet."
                empty_icon="⌁"
                empty_body="Rules auto-categorize imported statement lines: a pattern over the description, a GL account to post into, optional amount bounds, highest priority wins."
              >
                <:empty_actions :if={writable?(@samen_mount)}>
                  <.button variant="primary" phx-click="new_rule" id="empty-new-rule">New rule</.button>
                </:empty_actions>
                <:head>
                  <.sort_header field={:pattern} label="Pattern" sort={@list_state.sort} width="34%" />
                  <th scope="col" style="width:22%">GL account</th>
                  <th scope="col" style="width:16%">Amount bounds</th>
                  <.sort_header field={:priority} label="Priority" sort={@list_state.sort} width="12%" />
                  <th scope="col" style="width:16%">Status</th>
                </:head>
                <:row :let={r}>
                  <td style="font-weight:500;font-family:var(--mono, monospace);font-size:12.5px">{r.pattern}</td>
                  <td style="color:var(--muted);font-size:12px">{gl_label(@gl_accounts, r.account_id)}</td>
                  <td style="color:var(--muted);font-size:12px">{bounds(r.min_amount_cents, r.max_amount_cents)}</td>
                  <td style="font-variant-numeric:tabular-nums">{r.priority}</td>
                  <td>
                    <.pill variant={if r.is_active, do: "ok", else: "mut"}>{if r.is_active, do: "active", else: "paused"}</.pill>
                  </td>
                </:row>
              </.list_view>
            </div>
          </div>

          <.modal :if={@show_new and @new_form != nil and writable?(@samen_mount)} id="new-rule-modal" title="New rule" on_cancel="cancel_new">
            <.simple_form :let={f} for={@new_form} id="new-rule-form" phx-change="validate_new" phx-submit="save_new">
              <.form_field field={f[:pattern]} label="Pattern" />
              <.form_field
                field={f[:account_id]}
                label="GL account"
                type="select"
                prompt="Choose a GL account"
                options={@gl_accounts}
              />
              <.form_field
                field={f[:bank_account_id]}
                label="Scope to one bank account"
                type="select"
                prompt="All bank accounts"
                options={@bank_accounts}
              />
              <.form_field field={f[:min_amount_cents]} label="Min amount (cents)" type="number" />
              <.form_field field={f[:max_amount_cents]} label="Max amount (cents)" type="number" />
              <.form_field field={f[:priority]} label="Priority (higher wins)" type="number" />
              <:actions>
                <.button variant="primary" type="submit">Save rule</.button>
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

  defp bounds(nil, nil), do: "—"
  defp bounds(min, nil), do: "≥ #{cents(min)}"
  defp bounds(nil, max), do: "≤ #{cents(max)}"
  defp bounds(min, max), do: "#{cents(min)} – #{cents(max)}"

  # `@gl_accounts` holds the SELECT options ({id, label} tuples).
  defp gl_label(gl_accounts, id) do
    Enum.find_value(gl_accounts, "—", fn {gid, label} -> if gid == id, do: label end)
  end

  defp cents(cents) when is_integer(cents) do
    dollars = div(cents, 100)
    remainder = cents |> rem(100) |> abs()
    "$#{dollars}.#{String.pad_leading(Integer.to_string(remainder), 2, "0")}"
  end

  defp cents(_), do: "—"
end
