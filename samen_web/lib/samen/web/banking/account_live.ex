defmodule Samen.Web.Banking.AccountLive do
  @moduledoc """
  Framework Banking / account detail — one bank account, its bounded statement-line
  ledger, and the guarded MATCH action (WS-ERP E9), host-agnostic (ADR-009).

  ## The match path is the guard path

  "Match to journal entry" opens an inline `AshPhoenix.Form` over the resource's OWN
  governed `:create_match` action — never a surface-local write. Every invariant
  lives in the kernel blueprint changes and its error renders here verbatim:

    * `ReconcileGuard` — no double-match (a `:matched`/`:reconciled` line refuses a
      second match) and no match to a voided entry (voided entries are also never
      OFFERED in the picker);
    * `MatchAmountGuard` — amount-strict: Σ(entry lines debit−credit) must equal
      the statement-line amount within ±1¢. The picker shows each candidate's
      total so the expectation is visible BEFORE submit.

  The statement-line id is a SERVER-side fact merged in at submit (never client
  input — the `org_id` idiom). NON-PII: the Banking PII map is EMPTY (INV-1).
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Banking.Live, only: [assign_mount: 2, banking_sidebar: 1, writable?: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.Crumbs
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  alias Samen.Web.Banking.Reads

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)

    socket =
      socket
      |> assign(org_id: org_id, match_line_id: nil, match_form: nil, match_error: nil)
      |> assign_new(:return_to, fn -> nil end)

    {:ok, load(socket, org_id, params["id"])}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Samen.Web.CurrentOrg.reresolve(socket, params)

    socket =
      socket
      |> assign(org_id: org_id, return_to: return_path(uri))
      |> load(org_id, params["id"])

    {:noreply, socket}
  end

  @doc false
  def load(socket, nil, _id) do
    socket
    |> assign(
      no_org: CurrentOrg.no_org?(socket.assigns[:samen_mount], nil),
      org_id: nil,
      account: nil,
      lines: [],
      candidates: [],
      gl_accounts: [],
      match_line_id: nil,
      match_form: nil
    )
  end

  def load(socket, org_id, id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    socket
    |> assign(
      no_org: false,
      org_id: org_id,
      account: Reads.account(mount, scope, id),
      lines: Reads.statement_lines(mount, scope, id),
      candidates: Reads.journal_candidates(mount, scope),
      gl_accounts: Reads.gl_accounts(mount, scope)
    )
    |> assign_new(:match_line_id, fn -> nil end)
    |> assign_new(:match_form, fn -> nil end)
  end

  @impl true
  def handle_event("open_match", %{"id" => line_id}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    scope = Mount.scope(mount, org_id)

    form =
      Mount.resource(mount, Match)
      |> AshPhoenix.Form.for_create(:create_match, scope: scope)
      |> to_form()

    {:noreply, assign(socket, match_line_id: line_id, match_form: form, match_error: nil)}
  end

  def handle_event("cancel_match", _params, socket) do
    {:noreply, assign(socket, match_line_id: nil, match_form: nil, match_error: nil)}
  end

  def handle_event("validate_match", %{"form" => params}, socket) do
    form = AshPhoenix.Form.validate(socket.assigns.match_form, merge_line(params, socket))
    {:noreply, assign(socket, match_form: form)}
  end

  def handle_event("save_match", %{"form" => params}, socket) do
    case AshPhoenix.Form.submit(socket.assigns.match_form, params: merge_line(params, socket)) do
      {:ok, _match} ->
        %{org_id: org_id, account: account} = socket.assigns
        socket =
          socket
          |> assign(match_line_id: nil, match_form: nil, match_error: nil)
          |> load(org_id, account && account.id)

        {:noreply, socket}

      {:error, form} ->
        {:noreply, assign(socket, match_form: form, match_error: match_error(form))}
    end
  end

  # The statement-line id is THIS page's server-side fact (never client input);
  # org_id likewise comes from the mounted session, never the form.
  defp merge_line(params, socket) do
    params
    |> Map.put("statement_line_id", socket.assigns.match_line_id)
    |> Map.put("org_id", socket.assigns.org_id)
  end

  defp match_error(form) do
    case AshPhoenix.Form.errors(form, flatten: true) do
      [] -> "Could not create this match."
      errors -> errors |> Enum.map_join(" ", &to_string(&1)) |> String.slice(0, 300)
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="banking-account">
      <.app_shell>
        <:sidebar>
          <.banking_sidebar mount={@samen_mount} org_id={@org_id} active={:banking_accounts} return_to={@return_to} />
        </:sidebar>

        <.topbar title={@account && @account.name || "Bank account"} crumbs={crumbs(@samen_mount, @org_id, @account && @account.name)}>
        </.topbar>

        <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

        <%= if @no_org do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <span id="org-banner" style="display:none">Banking org: {@org_id}</span>

          <%= if @account == nil do %>
            <div class="wrap">
              <div class="card" id="account-not-found" style="padding:24px">
                <h3 style="margin-bottom:6px">Bank account not found.</h3>
                <p style="color:var(--muted);font-size:13px">
                  It does not exist in this organization, or it was archived.
                </p>
                <.button variant="secondary" type="button" navigate={accounts_path(@samen_mount, @org_id)}>
                  Back to accounts
                </.button>
              </div>
            </div>
          <% else %>
            <div class="wrap">
              <div class="card" id="account-facts" style="padding:18px 20px;margin-bottom:14px">
                <div style="display:flex;justify-content:space-between;align-items:center;gap:12px;flex-wrap:wrap">
                  <div>
                    <div style="font-weight:600;font-size:16px">{@account.name}</div>
                    <div style="color:var(--muted);font-size:12px">
                      {@account.currency} · GL {gl_label(@gl_accounts, @account.account_id)} · statement balance {cents(@account.statement_balance_cents)}
                    </div>
                  </div>
                  <div style="display:flex;gap:8px;align-items:center">
                    <.pill variant={if @account.is_active, do: "ok", else: "mut"}>{if @account.is_active, do: "active", else: "inactive"}</.pill>
                    <.button variant="secondary" type="button" navigate={accounts_path(@samen_mount, @org_id)}>
                      Back to accounts
                    </.button>
                  </div>
                </div>
              </div>

              <div id="statement-lines">
                <div class="gtitle">
                  <h3>Statement lines</h3>
                  <span class="n">{length(@lines)}</span>
                  <span class="lane">· org-scoped · append-only · no PII</span>
                </div>

                <div :if={@match_error} class="card form-error" id="match-error" style="padding:10px 14px;margin-bottom:8px;color:var(--bad, #b91c1c);font-size:12px">
                  {@match_error}
                </div>

                <div :if={@lines == []} class="card" id="lines-empty" style="padding:22px;text-align:center">
                  <div style="font-weight:600">No statement lines yet.</div>
                  <p style="color:var(--muted);font-size:13px;margin-top:4px">
                    Lines arrive with a statement import — the import action ships with the CSV
                    import surface; until then this ledger stays honestly empty.
                  </p>
                </div>

                <table :if={@lines != []} id="lines-table" style="width:100%;border-collapse:collapse">
                  <thead>
                    <tr style="text-align:left;font-size:12px;color:var(--muted);border-bottom:1px solid var(--line, #e5e7eb)">
                      <th scope="col" style="padding:8px 6px;width:14%">Posted</th>
                      <th scope="col" style="padding:8px 6px;width:14%">Amount</th>
                      <th scope="col" style="padding:8px 6px;width:30%">Description</th>
                      <th scope="col" style="padding:8px 6px;width:16%">Counterparty</th>
                      <th scope="col" style="padding:8px 6px;width:12%">Status</th>
                      <th scope="col" style="padding:8px 6px;width:14%"><span class="sr-only">Actions</span></th>
                    </tr>
                  </thead>
                  <tbody>
                    <tr :for={l <- @lines} id={"line-#{l.id}"} style="border-bottom:1px solid var(--line, #f3f4f6);font-size:13px">
                      <td style="padding:8px 6px">{date(l.posted_at)}</td>
                      <td style={"padding:8px 6px;font-variant-numeric:tabular-nums;color:#{amount_color(l.amount_cents)}"}>
                        {signed_cents(l.amount_cents)}
                      </td>
                      <td style="padding:8px 6px">{l.description}</td>
                      <td style="padding:8px 6px;color:var(--muted)">{l.counterparty || "—"}</td>
                      <td style="padding:8px 6px"><.pill variant={status_variant(l.status)}>{l.status}</.pill></td>
                      <td style="padding:8px 6px">
                        <.button
                          :if={writable?(@samen_mount) and l.status == :unmatched}
                          variant="secondary"
                          type="button"
                          phx-click="open_match"
                          phx-value-id={l.id}
                          id={"match-#{l.id}"}
                        >
                          Match
                        </.button>
                      </td>
                    </tr>
                  </tbody>
                </table>

                <div :if={@match_line_id != nil and @match_form != nil} class="card" id="match-form-card" style="padding:14px 16px;margin-top:10px">
                  <div style="font-weight:600;font-size:13px;margin-bottom:8px">Match this statement line to a journal entry</div>
                  <.simple_form :let={f} for={@match_form} id="match-form" phx-change="validate_match" phx-submit="save_match">
                    <.form_field
                      field={f[:entry_id]}
                      label="Journal entry"
                      type="select"
                      prompt="Choose a journal entry"
                      options={entry_options(@candidates)}
                    />
                    <p style="color:var(--muted);font-size:12px">
                      Amount-strict: the entry's total (Σ debit − credit) must equal the statement
                      line within 1¢ — voided entries are not offered.
                    </p>
                    <:actions>
                      <.button variant="primary" type="submit">Create match</.button>
                      <.button type="button" phx-click="cancel_match">Cancel</.button>
                    </:actions>
                  </.simple_form>
                </div>
              </div>
            </div>
          <% end %>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  defp crumbs(mount, org_id, leaf) do
    [Crumbs.org(mount, org_id), "Banking", leaf || "Account"]
  end

  defp accounts_path(mount, org_id),
    do: "#{Mount.label(mount, :banking_path, "/banking")}?org=#{org_id}"

  defp entry_options(candidates) do
    Enum.map(candidates, fn e ->
      {"#{date(e.entry_date)} · #{e.memo || "(no memo)"} · #{signed_cents(e.total_cents)} (#{e.status})", e.id}
    end)
  end

  defp amount_color(cents) when is_integer(cents) and cents < 0, do: "#b91c1c"
  defp amount_color(_cents), do: "#065f46"

  defp status_variant(:reconciled), do: "ok"
  defp status_variant(:matched), do: "info"
  defp status_variant(:categorized), do: "info"
  defp status_variant(_), do: "mut"

  defp gl_label(gl_accounts, id) do
    Enum.find_value(gl_accounts, "—", fn %{id: gid, label: label} -> if gid == id, do: label end)
  end

  defp date(nil), do: "—"

  defp date(%Date{} = d), do: Calendar.strftime(d, "%b %d, %Y")

  defp date(%DateTime{} = d), do: Calendar.strftime(d, "%b %d, %Y")

  defp date(_), do: "—"

  defp signed_cents(cents) when is_integer(cents) do
    abs_cents = abs(cents)
    dollars = div(abs_cents, 100)
    remainder = rem(abs_cents, 100)
    sign = if cents < 0, do: "-", else: "+"
    "#{sign}$#{dollars}.#{String.pad_leading(Integer.to_string(remainder), 2, "0")}"
  end

  defp signed_cents(_), do: "—"

  defp cents(cents) when is_integer(cents) do
    dollars = div(cents, 100)
    remainder = cents |> rem(100) |> abs()
    "$#{dollars}.#{String.pad_leading(Integer.to_string(remainder), 2, "0")}"
  end

  defp cents(_), do: "$0.00"
end
