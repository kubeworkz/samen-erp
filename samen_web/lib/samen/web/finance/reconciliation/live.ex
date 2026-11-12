defmodule Samen.Web.Finance.Reconciliation.Live do
  @moduledoc """
  The reconciliation workbench (`/erp/reconciliation`) — a read-only view over
  the ledger's posted lines.

  The page has three parts, all derived at request time:

    * the org-wide `Reconcile.org_balance/3` verdict, so a broken R1 is visible
      before anyone reads a row;
    * every account's posted debit, credit and signed balance, with a
      drill-down into that account's most recent posted lines;
    * the `FluxRead` month-over-month movement for the selected period.

  There is no reconciliation table, no checklist and no write affordance. A
  stale or malformed period selector falls back to the current month rather
  than blanking the page.
  """

  use Samen.Web.Tenant.Live

  import Samen.UI
  import Samen.Web.Erp.Live, only: [assign_mount: 2, erp_sidebar: 1]
  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Web.Crumbs
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Finance.Reconciliation
  alias Samen.Web.Mount

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)

    {:ok,
     socket
     |> assign(org_id: org_id, state: nil, error: nil, return_to: nil)
     |> load(params)}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = CurrentOrg.reresolve(socket, params)

    {:noreply,
     socket
     |> assign(org_id: org_id, return_to: return_path(uri))
     |> load(params)}
  end

  defp load(socket, params) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns

    case Reconciliation.load(mount, org_id,
           period: params["period"],
           account_id: params["account"]
         ) do
      {:ok, state} -> assign(socket, state: state, error: nil)
      {:error, reason} -> assign(socket, state: nil, error: reason)
    end
  end

  @impl Samen.Web.Tenant.Live
  def tenant_sidebar(assigns) do
    ~H"""
    <.erp_sidebar
      mount={@samen_mount}
      org_id={@org_id}
      active={:erp_reconciliation}
      return_to={@return_to}
    />
    """
  end

  @impl Samen.Web.Tenant.Live
  def tenant_page(assigns) do
    ~H"""
    <div id="reconciliation-workbench">
      <.topbar title="Reconciliation" crumbs={crumbs(@samen_mount, @org_id)}>
        <:actions>
          <.period_form mount={@samen_mount} org_id={@org_id} state={@state} />
        </:actions>
      </.topbar>

      <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

      <div class="wrap">
        <%= if is_nil(@org_id) do %>
          <.no_org_card mount={@samen_mount} />
        <% else %>
          <%= if @error do %>
            <div class="card" id="reconciliation-unavailable" style="padding:16px;color:var(--muted)">
              {error_text(@error)}
            </div>
          <% else %>
            <.workbench_body state={@state} mount={@samen_mount} org_id={@org_id} />
          <% end %>
        <% end %>
      </div>
    </div>
    """
  end

  attr(:mount, Mount, required: true)
  attr(:org_id, :string, required: true)
  attr(:state, :map, default: nil)

  defp period_form(assigns) do
    ~H"""
    <form method="get" action={page_href(@mount, @org_id)} class="row" style="gap:6px">
      <input
        type="month"
        name="period"
        value={period_value(@state && @state.period)}
        aria-label="Flux period"
        style="max-width:150px"
      />
      <input type="hidden" name="org" value={@org_id} />
      <button type="submit" class="button" id="reconciliation-period-apply">Apply</button>
    </form>
    """
  end

  attr(:state, :map, required: true)
  attr(:mount, Mount, required: true)
  attr(:org_id, :string, required: true)

  defp workbench_body(assigns) do
    ~H"""
    <div class="gtitle">
      <h3>Reconciliation workbench</h3>
      <span class="n">{@state.workbench.account_count} accounts</span>
      <span class="lane">· posted lines only · read-only</span>
    </div>

    <div
      class="card"
      id="reconciliation-summary"
      style="padding:12px 16px;margin-bottom:12px;display:flex;gap:18px;align-items:center;flex-wrap:wrap"
    >
      <div>
        <div style="font-size:11px;color:var(--muted)">Org balance (R1)</div>
        <div style="font-size:20px;font-weight:600">{money(@state.workbench.org_balance_cents)}</div>
      </div>
      <span
        id="reconciliation-r1-status"
        class={"pill #{if @state.workbench.balanced?, do: "ok", else: "bad"}"}
      >
        {if @state.workbench.balanced?, do: "balanced", else: "mismatch"}
      </span>
      <span style="color:var(--muted)">
        {@state.workbench.posted_line_count} posted lines across
        {@state.workbench.account_count} accounts
      </span>
    </div>

    <div class="card" id="reconciliation-accounts" style="padding:12px 16px;margin-bottom:12px">
      <b>Account balances</b>
      <div style="color:var(--muted);font-size:12px;margin-top:2px">
        Select an account to see the posted entries that make up its balance.
      </div>

      <table style="width:100%;border-collapse:collapse;font-size:13px;margin-top:10px">
        <thead>
          <tr>
            <th scope="col" style={th()}>Code</th>
            <th scope="col" style={th()}>Account</th>
            <th scope="col" style={th(:right)}>Debits</th>
            <th scope="col" style={th(:right)}>Credits</th>
            <th scope="col" style={th(:right)}>Balance</th>
            <th scope="col" style={th(:right)}>Lines</th>
            <th scope="col" style={th()}>Last posted</th>
          </tr>
        </thead>
        <tbody>
          <tr
            :for={account <- @state.workbench.accounts}
            id={"reconciliation-account-#{account.id}"}
            class={if @state.selected_account && @state.selected_account.id == account.id, do: "selected", else: nil}
          >
            <td style={td()}>{account.code}</td>
            <td style={td()}>
              <a href={account_href(@mount, @org_id, @state.period, account.id)}>
                <b>{account.name}</b>
              </a>
              <div style="color:var(--muted);font-size:11px">{kind_label(account.kind)}</div>
            </td>
            <td style={td(:right)}>{money(account.debit_cents)}</td>
            <td style={td(:right)}>{money(account.credit_cents)}</td>
            <td style={td(:right)}><b>{money(account.balance_cents)}</b></td>
            <td style={td(:right)}>{account.posted_line_count}</td>
            <td style={td()}>{date_label(account.last_entry_date)}</td>
          </tr>
        </tbody>
      </table>

      <div :if={@state.workbench.accounts == []} id="reconciliation-no-accounts" style="color:var(--muted);padding-top:10px">
        No accounts are declared on this workspace yet.
      </div>
    </div>

    <.selected_lines state={@state} mount={@mount} org_id={@org_id} />

    <.flux state={@state} />
    """
  end

  attr(:state, :map, required: true)
  attr(:mount, Mount, required: true)
  attr(:org_id, :string, required: true)

  defp selected_lines(assigns) do
    ~H"""
    <div class="card" id="reconciliation-lines" style="padding:12px 16px;margin-bottom:12px">
      <%= if @state.selected_account do %>
        <div style="display:flex;justify-content:space-between;gap:10px;align-items:baseline;flex-wrap:wrap">
          <div>
            <b>Posted lines — {@state.selected_account.code} {@state.selected_account.name}</b>
            <div style="color:var(--muted);font-size:12px">
              Balance {money(@state.selected_account.balance_cents)} · newest first
            </div>
          </div>
          <a href={page_href(@mount, @org_id, period: period_value(@state.period))}>All accounts</a>
        </div>

        <table style="width:100%;border-collapse:collapse;font-size:13px;margin-top:10px">
          <thead>
            <tr>
              <th scope="col" style={th()}>Date</th>
              <th scope="col" style={th()}>Entry</th>
              <th scope="col" style={th()}>Source</th>
              <th scope="col" style={th(:right)}>Debit</th>
              <th scope="col" style={th(:right)}>Credit</th>
            </tr>
          </thead>
          <tbody>
            <tr :for={line <- @state.lines} id={"reconciliation-line-#{line.line_id}"}>
              <td style={td()}>{date_label(line.entry_date)}</td>
              <td style={td()}>
                <a href={entry_href(@mount, @org_id, line.entry_id)}>
                  {line.entry_memo || "(no memo)"}
                </a>
                <div :if={line.line_memo} style="color:var(--muted);font-size:11px">
                  {line.line_memo}
                </div>
              </td>
              <td style={td()}>{source_label(line)}</td>
              <td style={td(:right)}>{money(line.debit_cents)}</td>
              <td style={td(:right)}>{money(line.credit_cents)}</td>
            </tr>
          </tbody>
        </table>

        <div :if={@state.lines == []} id="reconciliation-no-lines" style="color:var(--muted);padding-top:10px">
          This account has no posted lines.
        </div>
      <% else %>
        <span style="color:var(--muted)">
          Select an account above to inspect its posted lines.
        </span>
      <% end %>
    </div>
    """
  end

  attr(:state, :map, required: true)

  defp flux(assigns) do
    ~H"""
    <div class="card" id="reconciliation-flux" style="padding:12px 16px;margin-bottom:12px">
      <div style="display:flex;justify-content:space-between;gap:10px;align-items:baseline;flex-wrap:wrap">
        <div>
          <b>Flux</b>
          <span style="color:var(--muted);font-size:12px">
            {period_label(@state.flux.period)} vs {period_label(@state.flux.prior_period)}
          </span>
        </div>
        <span style="color:var(--muted);font-size:12px">
          {@state.flux.moved_account_count} accounts with movement
        </span>
      </div>

      <table :if={@state.flux.rows != []} style="width:100%;border-collapse:collapse;font-size:13px;margin-top:10px">
        <thead>
          <tr>
            <th scope="col" style={th()}>Account</th>
            <th scope="col" style={th(:right)}>Current activity</th>
            <th scope="col" style={th(:right)}>Prior activity</th>
            <th scope="col" style={th(:right)}>Change</th>
            <th scope="col" style={th(:right)}>Change %</th>
          </tr>
        </thead>
        <tbody>
          <tr :for={row <- @state.flux.rows} id={"reconciliation-flux-#{row.id}"}>
            <td style={td()}>
              <b>{row.code}</b> · {row.name}
              <div style="color:var(--muted);font-size:11px">{kind_label(row.kind)}</div>
            </td>
            <td style={td(:right)}>{money(row.current_net_cents)}</td>
            <td style={td(:right)}>{money(row.prior_net_cents)}</td>
            <td style={td(:right)} class={"flux-#{row.direction}"}>{signed_money(row.delta_cents)}</td>
            <td style={td(:right)}>{percent_label(row.delta_pct)}</td>
          </tr>
        </tbody>
      </table>

      <div :if={@state.flux.rows == []} id="reconciliation-no-flux" style="color:var(--muted);padding-top:10px">
        No posted activity in either month.
      </div>
    </div>
    """
  end

  defp th(), do: th(:left)

  defp th(:right),
    do:
      "text-align:right;padding:6px 8px;border-bottom:1px solid var(--border,#e5e7eb);color:var(--muted)"

  defp th(_),
    do:
      "text-align:left;padding:6px 8px;border-bottom:1px solid var(--border,#e5e7eb);color:var(--muted)"

  defp td(), do: td(:left)

  defp td(:right),
    do: "text-align:right;padding:6px 8px;border-bottom:1px solid var(--border,#f3f4f6)"

  defp td(_), do: "padding:6px 8px;border-bottom:1px solid var(--border,#f3f4f6)"

  defp crumbs(mount, org_id), do: [Crumbs.org(mount, org_id), "ERP", "Reconciliation"]

  defp page_href(mount, org_id, opts \\ []) do
    query =
      [org: org_id]
      |> maybe_put(:period, Keyword.get(opts, :period))
      |> maybe_put(:account, Keyword.get(opts, :account))

    "#{Mount.label(mount, :erp_path, "/erp")}/reconciliation?#{URI.encode_query(query)}"
  end

  defp account_href(mount, org_id, period, account_id) do
    page_href(mount, org_id, period: period_value(period), account: account_id) <>
      "#reconciliation-lines"
  end

  defp entry_href(mount, org_id, entry_id) do
    "#{Mount.label(mount, :erp_path, "/erp")}/entries/#{entry_id}?org=#{org_id}"
  end

  defp maybe_put(query, _key, nil), do: query
  defp maybe_put(query, key, value), do: Keyword.put(query, key, value)

  defp period_value(%{year: year, month: month}) when is_integer(year) and is_integer(month),
    do: "#{year}-#{String.pad_leading(to_string(month), 2, "0")}"

  defp period_value(_period), do: nil

  defp period_label(%{year: year, month: month} = period)
       when is_integer(year) and is_integer(month) do
    case Map.get(period, :from_date) || Map.get(period, :to_date) do
      %Date{} = date -> Calendar.strftime(date, "%B %Y")
      _ -> "#{year}-#{String.pad_leading(to_string(month), 2, "0")}"
    end
  end

  defp period_label(_period), do: "—"

  defp kind_label(kind) when is_atom(kind), do: kind |> to_string() |> String.capitalize()
  defp kind_label(kind) when is_binary(kind), do: String.capitalize(kind)
  defp kind_label(_kind), do: "—"

  defp date_label(%Date{} = date), do: Calendar.strftime(date, "%Y-%m-%d")
  defp date_label(%DateTime{} = date), do: Calendar.strftime(date, "%Y-%m-%d")
  defp date_label(value) when is_binary(value), do: value
  defp date_label(_value), do: "—"

  defp percent_label(nil), do: "—"
  defp percent_label(value) when is_float(value), do: "#{value}%"
  defp percent_label(value) when is_integer(value), do: "#{value}%"

  defp signed_money(value) when value > 0, do: "+" <> money(value)
  defp signed_money(value), do: money(value)

  defp money(nil), do: "—"

  defp money(cents) when is_integer(cents) do
    sign = if cents < 0, do: "-", else: ""
    absolute = abs(cents)
    whole = div(absolute, 100)
    fraction = absolute |> rem(100) |> Integer.to_string() |> String.pad_leading(2, "0")
    "#{sign}$#{whole}.#{fraction}"
  end

  defp money(other), do: to_string(other)

  defp source_label(%{source_key: nil}), do: "—"
  defp source_label(%{source_key: key, source_id: id}) when is_binary(id), do: "#{key}:#{id}"
  defp source_label(%{source_key: key}), do: key

  defp error_text(:finance_not_mounted),
    do: "This workspace has no Finance mount, so there is no reconciliation workbench to show."

  defp error_text(_reason),
    do: "This reconciliation workbench is not available on this workspace's mounted modules."
end
