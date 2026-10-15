defmodule Samen.Web.Operator.WebhookDlqLive do
  @moduledoc """
  Framework OPERATOR / Webhook DLQ page (ADR-038 §5.5; WS-B / B9) — the dead-letter
  view every vertical inherits at 0 LOC via `samen_operator_routes/2`.

  Lists failed/unprocessable webhook envelopes (`:dead` first, then recent
  `:received`/`:processed`) with operator **replay** + **resolve** actions. Reads the
  kernel `Samen.Webhook.Event` store through the mount's repo.

  ## Token-blind by construction (INV-1 / INV-2)

  This is an operator PII surface, so it is masked-by-default — but here masking is by
  CONSTRUCTION, not by a reveal path: the ingress persists envelopes with the payload
  ALREADY redacted (`redact_payload/1`, ADR-038 §5.4), and `whk_event` carries NO
  vault-routed (🔒) column at all. Every rendered value is a bounded provider name,
  event kind, event id, domain, status, timestamp, attempt count, an error SUMMARY
  (message + digest, never a payload echo), or the already-redacted payload map. There
  is NO `%Masked{}` branch and NO `vt_*` token to leak — proven by the no-plaintext /
  no-`vt_`-token DOM probe in `webhook_security_test.exs` (the ADR-038 §5.5 discipline
  for a fully-redacted store, in place of the `Samen.MaskingCase` three-proof used when
  a 🔒 field renders).

  ## Write affordances are role-gated AT THE RENDER (S14 / T146)

  `replay`/`resolve` are OFFERED only to the operator roles that may mutate this store
  (`:operator_admin` / `:operator_support`, read from the AUTHENTICATED principal's
  `:samen_operator_role` — never a param or the mount). An `:operator_readonly` session
  (or one that resolved no role) sees the envelopes plus an explanation and NO control,
  instead of a button whose event the server would refuse. The handlers keep their own
  `authorize_write/1` gate as the AUTHORITY: hiding is posture, never the enforcement —
  a forged `phx-click` from a read-only socket is still refused. Both the render gate and
  the handler read the same `may_write?/1` predicate, so the page can never offer a write
  the server would deny.

  ## Fail-safe

  A host that has not yet run the `whk_event` migration reads zero rows (the query is
  rescued to `[]`) and sees the honest empty state — never a 500.
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Operator.Live

  alias Samen.Web.Mount
  alias Samen.Web.Operator
  alias Samen.Webhook.Event

  # S14 — the operator roles that may MUTATE the webhook store (replay/resolve). The role is
  # ONLY ever read from `:samen_operator_role` — the assign `Samen.Web.Operator.Authz`'s
  # `:require_operator` on_mount derived from the AUTHENTICATED session principal (the T146
  # role-derivation pattern) — never from the mount or a param. `:operator_readonly`'s
  # contract is "read the operator CRM only" (`Samen.OperatorPlane.Actor`): it may render
  # this page, never write through it. `nil`/unknown roles fail closed.
  @write_roles [:operator_admin, :operator_support]

  @impl true
  def mount(_params, session, socket) do
    socket = assign_mount(socket, session)
    {:ok, load(socket)}
  end

  @doc false
  def load(socket) do
    mount = socket.assigns[:samen_mount]

    # The single write-capability predicate, shared with `authorize_write/1`: what the
    # render OFFERS and what the handler ACCEPTS can never disagree.
    can_write = may_write?(socket.assigns)

    case mount && Operator.org_id(mount) do
      nil ->
        assign(socket, no_org: true, envelopes: [], dead_count: 0, can_write: can_write)

      _org_id ->
        envelopes = list_envelopes(mount)

        assign(socket,
          no_org: false,
          envelopes: envelopes,
          dead_count: Enum.count(envelopes, &(&1.status == "dead")),
          can_write: can_write
        )
    end
  end

  @impl true
  def handle_event("replay", %{"id" => id}, socket) do
    with {:ok, repo} <- authorize_write(socket),
         %Event{} = row <- Event.get_dead(repo, id),
         {:ok, row} <- Event.reset_for_replay(repo, row) do
      # Re-enqueue the processing job — safe because processing is idempotent (§5.5).
      _ = safe_enqueue(row, repo)
    end

    {:noreply, load(socket)}
  end

  @impl true
  def handle_event("resolve", %{"id" => id}, socket) do
    with {:ok, repo} <- authorize_write(socket),
         %Event{} = row <- Event.get_dead(repo, id) do
      _ = Event.mark_processed(repo, row)
    end

    {:noreply, load(socket)}
  end

  # The ONE definition of "who may write here" — `:samen_operator_role` ∈ @write_roles, fail
  # closed on a missing/nil/unknown role. Read by `load/1` to decide whether the page RENDERS
  # the replay/resolve controls, and by `authorize_write/1` to decide whether the handler
  # HONOURS them. Takes the assigns map so a plain socket or an unwrapped assigns map both work.
  defp may_write?(assigns), do: assigns[:samen_operator_role] in @write_roles

  # The S14 write gate, three ANDed conjuncts — all strictly narrowing, never widening:
  #   1. ROLE — `may_write?/1` (see above; fail closed on nil) — the SAME predicate the
  #      render-side affordance gate uses, so the UI never offers what this refuses;
  #   2. ORG  — the mount resolves an operator org, the SAME `no_org` fail-secure guard
  #      `load/1` applies to the read path (an org-less mount renders nothing AND writes
  #      nothing — parity, instead of the old write-path bypass);
  #   3. REPO — a usable repo on the mount.
  # The row fetch itself is `Event.get_dead/2` (bounded to the DLQ's actionable set), so
  # even an authorized operator can only ever touch rows this surface actually exposes.
  defp authorize_write(socket) do
    mount = socket.assigns[:samen_mount]

    with true <- may_write?(socket.assigns),
         %Mount{repo: repo} when is_atom(repo) and not is_nil(repo) <- mount,
         org_id when is_binary(org_id) <- Operator.org_id(mount) do
      {:ok, repo}
    else
      _ -> :denied
    end
  end

  # ---------------------------------------------------------------------------

  defp list_envelopes(%Mount{repo: repo}) when is_atom(repo) and not is_nil(repo) do
    Event.list_for_operator(repo, limit: 100)
  rescue
    _ -> []
  end

  defp list_envelopes(_), do: []

  defp safe_enqueue(row, repo) do
    Samen.Webhook.IngestWorker.enqueue(row, repo: repo)
  rescue
    _ -> :ok
  catch
    _, _ -> :ok
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="operator-webhooks">
      <.app_shell>
        <:sidebar>
          <.operator_sidebar mount={@samen_mount} active={:webhooks} operator_role={assigns[:samen_operator_role]} />
        </:sidebar>

        <.topbar title="Webhook DLQ" crumbs={["Operator plane", "Webhook DLQ"]} />

        <%= if @no_org do %>
          <div class="wrap">
            <div class="card" id="no-org" style="padding:22px 20px;color:var(--muted)">
              No operator org resolved.
            </div>
          </div>
        <% else %>
          <div class="wrap">
            <.token_blind_bar chip="payloads redacted at ingress · no vault token">
              <b>Token-blind dead-letter view.</b>
              Envelopes are stored with the vendor payload's PII already pruned
              (<span class="mono">redact_payload/1</span>, ADR-038 §5.4) — this surface
              renders only bounded ids, enums, timestamps, an error summary, and the
              already-redacted payload. No vault token, no plaintext email/name, by
              construction.
            </.token_blind_bar>

            <div id="dlq-envelopes" style="margin-top:14px">
              <div class="gtitle">
                <h3>Webhook envelopes</h3>
                <span class="n">{length(@envelopes)}</span>
                <span class="lane">
                  · {@dead_count} dead · replay is safe (processing is idempotent) · resolve marks handled
                </span>
              </div>

              <%!-- S14 render-side role gate — the affordance explanation, rendered ONLY where the
                    controls are withheld. Hiding is posture; `authorize_write/1` stays the authority.
                    The note IS the disclosure control: it opens WHAT EACH ROLE MAY DO, focused on
                    `dlq_write` — the very capability this note withheld — and marks ✓/— against
                    `:samen_operator_role`, the SAME assign `may_write?/1` reads. A named role the
                    reader cannot map to their own was still a dead end; this closes it. --%>
              <.role_help_note
                :if={!@can_write}
                id="dlq-readonly"
                focus={:dlq_write}
                operator_role={assigns[:samen_operator_role]}
              >
                Read-only — replay and resolve require an operator role that may mutate the webhook
                store (<span class="mono">:operator_admin</span> / <span class="mono">:operator_support</span>).
                Envelopes stay visible; nothing on this page can be replayed or resolved on this role.
              </.role_help_note>

              <.empty_state
                :if={@envelopes == []}
                class="dlq-empty"
                icon="✓"
                title="No webhook envelopes."
                body="Failed or unprocessable webhook deliveries land here for operator replay. An empty queue means nothing has dead-lettered."
              />

              <.data_table :if={@envelopes != []}>
                <:head>
                  <th>Status</th>
                  <th>Provider</th>
                  <th>Domain</th>
                  <th>Org</th>
                  <th>Kind</th>
                  <th>Event id</th>
                  <th>Occurred</th>
                  <th>Attempts</th>
                  <th>Error</th>
                  <th>Payload (redacted)</th>
                  <th></th>
                </:head>
                <tr :for={e <- @envelopes} class="dlq-row" id={"dlq-#{e.id}"}>
                  <td class="d-status"><span class={"pill pill-#{e.status}"}>{e.status}</span></td>
                  <td class="d-provider">{e.provider}</td>
                  <td class="d-domain">{e.domain}</td>
                  <td class="d-org">
                    <a :if={e.org_id} href={"/operator/deliverability/#{e.org_id}"} class="mono" style="font-size:11px;color:#3B4CCA">
                      {short_org(e.org_id)}
                    </a>
                    <span :if={!e.org_id} style="color:var(--muted)">—</span>
                  </td>
                  <td class="d-kind">{e.kind}</td>
                  <td class="d-event-id mono">{e.event_id}</td>
                  <td class="d-occurred" style="color:var(--muted)">{ts(e.occurred_at)}</td>
                  <td class="d-attempts">{e.attempt_count}</td>
                  <td class="d-error" style="color:#B42318;max-width:260px">{e.last_error}</td>
                  <td class="d-payload">
                    <pre class="mono" style="max-width:320px;overflow:auto;white-space:pre-wrap">{payload_json(e.payload)}</pre>
                  </td>
                  <td class="d-actions">
                    <%= if @can_write do %>
                      <button
                        :if={e.status == "dead"}
                        class="btn-replay"
                        phx-click="replay"
                        phx-value-id={e.id}
                      >
                        Replay
                      </button>
                      <button
                        :if={e.status == "dead"}
                        class="btn-resolve"
                        phx-click="resolve"
                        phx-value-id={e.id}
                      >
                        Resolve
                      </button>
                    <% else %>
                      <span
                        :if={e.status == "dead"}
                        class="d-readonly"
                        style="color:var(--muted);font-size:11px"
                      >
                        read-only
                      </span>
                    <% end %>
                  </td>
                </tr>
              </.data_table>
            </div>
          </div>
        <% end %>
      </.app_shell>
    </div>
    """
  end

  # -- helpers -----------------------------------------------------------------

  defp ts(nil), do: "—"
  defp ts(%DateTime{} = dt), do: Calendar.strftime(dt, "%Y-%m-%d %H:%M")
  defp ts(other), do: to_string(other)

  # T114/R5: the org column was stored but unsurfaced (`whk_event.org_id`, nilable
  # until an envelope is processed). A bounded, non-PII id fragment — never the
  # tenant's PII — cross-links to the per-tenant deliverability drill-down. Only
  # ever called from the `:if={e.org_id}` branch (a nil org_id renders the "—"
  # placeholder directly in the template instead), so there is no `nil` clause here.
  defp short_org(id), do: "#{String.slice(to_string(id), 0, 8)}…"

  # The payload is already redacted at ingress — render it verbatim as pretty JSON.
  defp payload_json(payload) when is_map(payload) do
    case Jason.encode(payload, pretty: true) do
      {:ok, json} -> json
      _ -> "{}"
    end
  end

  defp payload_json(_), do: "{}"
end
