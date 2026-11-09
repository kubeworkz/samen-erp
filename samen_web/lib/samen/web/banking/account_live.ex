defmodule Samen.Web.Banking.AccountLive do
  @moduledoc """
  Framework Banking / account detail — one bank account, its bounded statement-line
  ledger, statement import, ranked match suggestions, and the guarded MATCH action
  (WS-ERP E9), host-agnostic (ADR-009).

  ## Import

  CSV and OFX/QFX files are parsed by `Samen.Scopes.Banking.Import` and written
  through the kernel's governed `StatementLine.:import` action in one repo
  transaction with a `StatementImport` audit row. File-level and line-level
  deduplication happen in the core service; this screen only supplies the
  server-side org/account ids and the user's file or pasted text.

  ## The match path is the guard path

  "Match to journal entry" opens an inline `AshPhoenix.Form` over the resource's OWN
  governed `:create_match` action — never a surface-local write. Every invariant
  lives in the kernel blueprint changes and its error renders here verbatim:

    * `ReconcileGuard` — no double-match (a `:matched`/`:reconciled` line refuses a
      second match) and no match to a voided entry (voided entries are also never
      OFFERED in the picker);
    * `MatchAmountGuard` — amount-strict: the cash leg of the entry (debit−credit on
      the bank's GL account) must equal the statement-line amount within ±1¢. The
      picker and suggestions show that cash-leg amount so the expectation is visible
      BEFORE submit.

  Suggestions are ranked by `Recognize` and are advisory only; a user still
  confirms one through the governed match form. The statement-line id is a
  SERVER-side fact merged in at submit (never client input — the `org_id` idiom).
  NON-PII: the Banking PII map is EMPTY (INV-1).
  """
  use Samen.Web.Tenant.Live

  import Samen.UI

  import Samen.Web.Banking.Live,
    only: [assign_mount: 2, banking_sidebar: 1, writable?: 1]

  import Samen.Web.CurrentOrg,
    only: [acting_as_banner: 1, no_org_card: 1, return_path: 1]

  alias Samen.Scopes.Banking.Import
  alias Samen.Web.Banking.Reads
  alias Samen.Web.Crumbs
  alias Samen.Web.CurrentOrg
  alias Samen.Web.Mount

  @upload_accept ~w(.csv .ofx .qfx)
  @max_upload_bytes 5_242_880

  @impl true
  def mount(params, session, socket) do
    socket = assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)

    socket =
      socket
      |> assign(
        org_id: org_id,
        match_line_id: nil,
        match_form: nil,
        match_error: nil,
        import_text: "",
        import_notice: nil,
        import_error: nil
      )
      |> assign_new(:return_to, fn -> nil end)
      |> maybe_allow_upload()

    {:ok, load(socket, org_id, params["id"])}
  end

  @impl true
  def handle_params(params, uri, socket) do
    org_id = Samen.Web.CurrentOrg.reresolve(socket, params)

    socket =
      socket
      |> assign(
        org_id: org_id,
        return_to: return_path(uri),
        import_notice: nil,
        import_error: nil
      )
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
      suggestions: %{},
      gl_accounts: [],
      match_line_id: nil,
      match_form: nil
    )
  end

  def load(socket, org_id, id) do
    mount = socket.assigns.samen_mount
    scope = Mount.scope(mount, org_id)

    account = Reads.account(mount, scope, id)
    lines = Reads.statement_lines(mount, scope, id)

    candidates =
      if account,
        do: Reads.journal_candidates(mount, scope, account.account_id),
        else: []

    socket
    |> assign(
      no_org: false,
      org_id: org_id,
      account: account,
      lines: lines,
      candidates: candidates,
      suggestions: Reads.suggestions(lines, candidates),
      gl_accounts: Reads.gl_accounts(mount, scope)
    )
    |> assign_new(:match_line_id, fn -> nil end)
    |> assign_new(:match_form, fn -> nil end)
  end

  @impl true
  def handle_event("open_match", %{"id" => line_id}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    scope = Mount.scope(mount, org_id)

    {:noreply,
     assign(socket,
       match_line_id: line_id,
       match_form: match_form(mount, scope, nil),
       match_error: nil
     )}
  end

  def handle_event("use_suggestion", %{"line" => line_id, "entry" => entry_id}, socket) do
    %{samen_mount: mount, org_id: org_id} = socket.assigns
    scope = Mount.scope(mount, org_id)

    {:noreply,
     assign(socket,
       match_line_id: line_id,
       match_form: match_form(mount, scope, entry_id),
       match_error: nil
     )}
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

  def handle_event("validate_import", params, socket) do
    {:noreply,
     assign(socket, import_text: Map.get(params, "import_text", socket.assigns.import_text))}
  end

  def handle_event("import", params, socket) do
    %{samen_mount: mount, org_id: org_id, account: account} = socket.assigns
    socket = assign(socket, import_text: Map.get(params, "import_text", ""))

    if account == nil do
      {:noreply, assign(socket, import_error: "Choose a bank account before importing.")}
    else
      case statement_contents(socket, params) do
        {:ok, contents, filename} ->
          result =
            Import.import(contents,
              line_resource: Mount.resource(mount, StatementLine),
              import_resource: Mount.resource(mount, StatementImport),
              repo: mount.repo,
              scope: Mount.scope(mount, org_id),
              org_id: org_id,
              bank_account_id: account.id,
              filename: filename
            )

          case result do
            {:ok, imported} ->
              socket =
                socket
                |> assign(import_notice: import_notice(imported), import_error: nil)
                |> load(org_id, account.id)

              {:noreply, socket}

            {:error, reason} ->
              {:noreply, assign(socket, import_notice: nil, import_error: import_error(reason))}
          end

        {:error, reason} ->
          {:noreply, assign(socket, import_notice: nil, import_error: import_error(reason))}
      end
    end
  end

  # The statement-line id is THIS page's server-side fact (never client input);
  # org_id likewise comes from the mounted session, never the form.
  defp merge_line(params, socket) do
    params
    |> Map.put("statement_line_id", socket.assigns.match_line_id)
    |> Map.put("org_id", socket.assigns.org_id)
  end

  defp match_form(mount, scope, entry_id) do
    opts = [scope: scope]
    opts = if entry_id, do: Keyword.put(opts, :params, %{"entry_id" => entry_id}), else: opts

    Mount.resource(mount, Match)
    |> AshPhoenix.Form.for_create(:create_match, opts)
    |> to_form()
  end

  defp match_error(form) do
    case AshPhoenix.Form.errors(form, flatten: true) do
      [] -> "Could not create this match."
      errors -> errors |> Enum.map_join(" ", &to_string(&1)) |> String.slice(0, 300)
    end
  end

  defp maybe_allow_upload(%{endpoint: nil} = socket) do
    assign(socket, upload_enabled: false)
  end

  defp maybe_allow_upload(socket) do
    socket
    |> assign(upload_enabled: true)
    |> allow_upload(:statement,
      # OFX/QFX have no universal MIME registration; accept at the transport
      # layer and enforce the statement extensions below before parsing.
      accept: :any,
      max_entries: 1,
      max_file_size: @max_upload_bytes
    )
  end

  defp statement_contents(socket, params) do
    uploads = Map.get(socket.assigns, :uploads, %{})
    entries = uploads |> Map.get(:statement, %{}) |> Map.get(:entries, [])

    cond do
      entries != [] ->
        read_uploaded_statement(socket)

      String.trim(Map.get(params, "import_text", "")) != "" ->
        {:ok, Map.get(params, "import_text", ""), "pasted-statement.csv"}

      true ->
        {:error, :no_statement}
    end
  end

  defp read_uploaded_statement(socket) do
    socket
    |> consume_uploaded_entries(:statement, fn %{path: path}, entry ->
      case File.read(path) do
        {:ok, contents} -> {:ok, {contents, entry.client_name}}
        {:error, reason} -> {:ok, {:error, reason}}
      end
    end)
    |> case do
      [{contents, filename}] ->
        if statement_filename?(filename) do
          {:ok, contents, filename}
        else
          {:error, :unsupported_file}
        end

      [{:error, reason}] ->
        {:error, {:upload_read_failed, reason}}

      [] ->
        {:error, :no_statement}
    end
  end

  defp statement_filename?(filename) do
    filename
    |> to_string()
    |> Path.extname()
    |> String.downcase()
    |> then(&(&1 in @upload_accept))
  end

  defp import_notice(%{lines: lines, duplicate_count: duplicate_count}) do
    imported = length(lines)

    base =
      case imported do
        0 -> "No new statement lines."
        1 -> "Imported 1 statement line."
        n -> "Imported #{n} statement lines."
      end

    case duplicate_count do
      0 -> base
      1 -> base <> " 1 duplicate was skipped."
      n -> base <> " #{n} duplicates were skipped."
    end
  end

  defp import_error({:duplicate_file, _id}),
    do: "This file was already imported for this account."

  defp import_error(:no_statement),
    do: "Choose a CSV/OFX file or paste statement text first."

  defp import_error(:empty_statement),
    do: "The statement is empty."

  defp import_error(:no_transactions),
    do: "No transactions were found in this statement."

  defp import_error({:missing_column, :amount_or_debit_credit}),
    do: "The CSV needs an amount column or a debit/credit pair."

  defp import_error({:missing_column, label}),
    do: "The CSV is missing its #{label} column."

  defp import_error({:invalid_row, line, reason}),
    do: "CSV row #{line}: #{import_reason(reason)}"

  defp import_error({:invalid_transaction, index, reason}),
    do: "OFX transaction #{index}: #{import_reason(reason)}"

  defp import_error({:upload_read_failed, _reason}),
    do: "The uploaded file could not be read. Try again."

  defp import_error(:unsupported_file),
    do: "Choose a .csv, .ofx, or .qfx statement file."

  defp import_error({:line_import_failed, _reference, _reason}),
    do: "The statement could not be saved. No lines were imported."

  defp import_error({:import_read_failed, _reason}),
    do: "The import batch could not be checked. Try again."

  defp import_error({:line_read_failed, _reason}),
    do: "Existing statement lines could not be checked. Try again."

  defp import_error(reason), do: "Import failed: #{inspect(reason)}"

  defp import_reason({:missing_value, label}), do: "#{label} is missing"
  defp import_reason({:invalid_date, value}), do: "invalid date #{inspect(value)}"
  defp import_reason({:invalid_amount, value}), do: "invalid amount #{inspect(value)}"

  defp import_reason({:ambiguous_amount, debit, credit}),
    do: "both debit #{inspect(debit)} and credit #{inspect(credit)} are populated"

  defp import_reason(reason), do: inspect(reason)

  @impl Samen.Web.Tenant.Live
  def tenant_sidebar(assigns) do
    ~H"""
    <.banking_sidebar mount={@samen_mount} org_id={@org_id} active={:banking_accounts} return_to={@return_to} />
    """
  end

  @impl Samen.Web.Tenant.Live
  def tenant_page(assigns) do
    ~H"""
    <div id="banking-account">
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

          <div :if={writable?(@samen_mount)} class="card" id="statement-import" style="padding:16px 18px;margin-bottom:14px">
            <div style="font-weight:600;font-size:14px;margin-bottom:4px">Import a statement</div>
            <p style="color:var(--muted);font-size:12px;margin-bottom:10px">
              CSV or OFX/QFX. Duplicate files are refused; duplicate lines are skipped.
            </p>

            <div :if={@import_notice} class="card" id="import-notice" style="padding:8px 12px;margin-bottom:8px;font-size:12px;color:var(--ok, #065f46);background:var(--ok-soft, #ecfdf5)">
              {@import_notice}
            </div>

            <div :if={@import_error} class="card form-error" id="import-error" style="padding:8px 12px;margin-bottom:8px;font-size:12px;color:var(--bad, #b91c1c)">
              {@import_error}
            </div>

            <form id="statement-import-form" phx-change="validate_import" phx-submit="import">
              <div :if={@upload_enabled} style="margin-bottom:10px">
                <label for="statement-file" style="display:block;font-size:12px;font-weight:600;margin-bottom:4px">Statement file</label>
                <.live_file_input upload={@uploads.statement} id="statement-file" />
                <div :for={entry <- @uploads.statement.entries} style="font-size:12px;color:var(--muted);margin-top:4px">
                  {entry.client_name}
                </div>
                <div :for={error <- upload_errors(@uploads.statement)} style="font-size:12px;color:var(--bad, #b91c1c);margin-top:4px">
                  {upload_error_message(error)}
                </div>
              </div>

              <label for="import-text" style="display:block;font-size:12px;font-weight:600;margin-bottom:4px">
                Or paste CSV/OFX
              </label>
              <textarea
                id="import-text"
                name="import_text"
                rows="4"
                placeholder="Date,Amount,Description&#10;2026-10-01,-50.00,Coffee shop"
                style="width:100%;box-sizing:border-box;font:12px/1.4 ui-monospace,monospace;padding:8px;border:1px solid var(--line, #e5e7eb);border-radius:6px"
              >{@import_text}</textarea>

              <div style="margin-top:10px">
                <.button variant="primary" type="submit">Import statement</.button>
              </div>
            </form>
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
                Import a CSV or OFX/QFX statement above to bring in the bank's ledger.
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
                <%= for l <- @lines do %>
                  <tr id={"line-#{l.id}"} style="border-bottom:1px solid var(--line, #f3f4f6);font-size:13px">
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
                  <tr :if={suggestions_for(@suggestions, l.id) != []} id={"suggestions-#{l.id}"} style="border-bottom:1px solid var(--line, #f3f4f6);background:var(--surface-2, #fafafa)">
                    <td colspan="6" style="padding:8px 10px">
                      <div style="font-size:11px;font-weight:600;text-transform:uppercase;letter-spacing:.04em;color:var(--muted);margin-bottom:6px">
                        Suggested matches
                      </div>
                      <div :for={s <- suggestions_for(@suggestions, l.id)} id={"suggestion-#{l.id}-#{s.entry.id}"} style="display:flex;justify-content:space-between;align-items:center;gap:12px;padding:4px 0;font-size:12px">
                        <div>
                          <span style="font-weight:600">{candidate_label(s.entry)}</span>
                          <span style="color:var(--muted);margin-left:8px">{round(s.confidence * 100)}% · {s.reason}</span>
                        </div>
                        <.button
                          :if={writable?(@samen_mount)}
                          variant="secondary"
                          type="button"
                          phx-click="use_suggestion"
                          phx-value-line={l.id}
                          phx-value-entry={s.entry.id}
                        >
                          Use suggestion
                        </.button>
                      </div>
                    </td>
                  </tr>
                <% end %>
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
                  Amount-strict: the entry's cash leg on this bank's GL account must equal the
                  statement line within 1¢ — voided entries are not offered.
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
      {"#{date(e.entry_date)} · #{e.memo || "(no memo)"} · #{signed_cents(e.total_cents)} (#{e.status})",
       e.id}
    end)
  end

  defp candidate_label(entry) do
    "#{date(entry.entry_date)} · #{entry.memo || "(no memo)"} · #{signed_cents(entry.total_cents)}"
  end

  defp suggestions_for(suggestions, line_id), do: Map.get(suggestions, line_id, [])

  defp upload_error_message(:too_large), do: "That file is too large (max 5 MB)."
  defp upload_error_message(:not_accepted), do: "Choose a .csv, .ofx, or .qfx file."
  defp upload_error_message(:too_many_files), do: "Choose one statement file at a time."
  defp upload_error_message(other), do: "Upload error: #{other}"

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
