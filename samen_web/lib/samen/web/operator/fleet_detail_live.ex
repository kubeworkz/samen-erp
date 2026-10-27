defmodule Samen.Web.Operator.FleetDetailLive do
  @moduledoc """
  The WS-J fleet cockpit's TIER-2 surface (`/operator/fleet/:app_id`, ADR-044
  §5.3/§5.4/§16, T84b) — the merged T156 per-tenant cohort rows
  (deliverability/automation/activity), each keyed by an opaque `fleet_handle`
  and, per Amendment 1, a MASKED-BY-DEFAULT tenant display name resolved
  per-viewer.

  ## Gating (§5.4 tier 2)

  `roles[:fleet] != nil` **and** `roles[app_id] != nil` for THIS row —
  `Samen.Web.Operator.Fleet.gate/2` + `app_role/2`. No role in FLEET at all ⇒
  redirect (RP-J-5, same as `FleetLive`). A role in fleet but NOT in this
  specific product ⇒ this page renders "not in your product scope" — the
  ROW-counts are still gated per-app even though the container page rendered.

  ## Name resolution — the amendment's core obligation (§16.2/§16.3, RP-J-14)

  A row's *counts* are gated by `roles[app_id]` (above); that SAME row's tenant
  NAME is additionally gated by `handle ∈ scope_of(principal, app_id)`
  (`Samen.Fleet.Resolution.resolve/3`, T84a's `scope_of/2` under the hood via
  the host's `:fleet_name_resolver` seam). **Mask by omission**: the resolver
  returns `%{handle => name}` containing ONLY resolvable handles; every OTHER
  handle in the cohort renders with **no name, no `org_id`, no deep link, and
  no handle in any DOM attribute** (§16.4a) — the `masked?` branch below never
  emits a `data-*`/`href` carrying the raw handle.

  This is what makes the `Samen.ScopeMaskCase` 3-proof (green/red/sabotage) +
  the mixed-render case (named + masked rows, ONE table, ONE viewer — "the
  salesperson case") assertable directly against this LiveView's rendered HTML.

  ## The one WRITE on this surface: the public status page opt-in (ADR-050 §4.3)

  This page carries the operator action that flips `flt_app.publish_status` — the
  per-app OPT-IN to `GET /status` — through
  `Samen.Fleet.Registry.set_publish_status/4`. Until an operator publishes an app,
  the public page is empty, so this is the affordance that makes the feature
  reachable at all; it is reversible in both directions (`false` takes the app off
  the page on the next read).

  The UI gate is `roles[:fleet] == :operator_admin` (`@fleet_ctx.admin?`) AND a role
  in THIS product (`@in_product_scope?`) — publication is an act on one product, so
  a fleet-admin with no role in it does not get it. That is a NARROWER UI posture
  than the kernel's: the mutation itself is admitted by
  `Samen.Policy.FleetAdminOnly`, which refuses a `HeartbeatActor` — the reporting app
  can never publish itself (ADR-044 §4.5's "never app-initiated" lesson applied to
  visibility). The kernel is the enforcement; this gate is the affordance.

  The action also STATES ITS CONSEQUENCE in the page's own words: the status the app
  would appear as comes from `Samen.Fleet.PublicStatus.preview/1` and the wording
  from `Samen.Web.Fleet.PublicStatus.label/1` — the same renderer and the same
  vocabulary the public page itself uses, so the cockpit cannot promise a state the
  page does not report (ADR-050 §1: no second notion of "up").
  """
  use Phoenix.LiveView

  import Samen.UI
  import Samen.Web.Operator.Live,
    only: [assign_mount: 2, operator_sidebar: 1, role_help_note: 1]

  alias Samen.Fleet.{AdminActor, Handle, PublicStatus, Registry, Resolution}
  alias Samen.Web.Crumbs
  alias Samen.Web.Fleet.PublicStatus, as: PageStatus
  alias Samen.Web.Operator.Fleet, as: FleetHelpers

  @cohort_families [
    {"deliverability", :deliverability, "/operator/deliverability/resolve"},
    {"automation", :automation, "/operator/automation/resolve"},
    {"activity", :activity, "/operator/activity/resolve"}
  ]

  @impl true
  def mount(%{"app_id" => app_id}, session, socket) do
    socket = assign_mount(socket, session)

    case FleetHelpers.gate(socket.assigns[:samen_mount], session) do
      {:ok, ctx} ->
        {:ok,
         socket
         |> assign(fleet_ctx: ctx, app_id: app_id, publish_error: nil, publish_note: nil)
         |> load()}

      :denied ->
        {:ok, redirect(socket, to: FleetHelpers.login_path(socket.assigns[:samen_mount]))}
    end
  end

  @doc false
  def load(socket) do
    %{otp_app: otp_app, namespace: namespace, roles: roles, principal_id: principal_id} = socket.assigns.fleet_ctx
    app_id = socket.assigns.app_id

    case Samen.Fleet.read(otp_app, namespace: namespace) do
      {:ok, %{rows: rows}} ->
        case Enum.find(rows, &(&1.app_id == app_id)) do
          nil ->
            assign(socket,
              app: nil,
              in_product_scope?: false,
              publish_status: nil,
              publish_preview: :excluded,
              cohorts: %{},
              resolved: %{},
              name_seam_reachable?: false
            )

          row ->
            in_scope? = FleetHelpers.app_role(roles, row.slug) != nil
            report = row.report || %{}

            all_handles =
              @cohort_families
              |> Enum.flat_map(fn {key, _kind, _resolve} -> Map.get(report, key) || [] end)
              |> Enum.filter(&is_map/1)
              |> Enum.map(& &1["handle"])
              |> Enum.filter(&is_binary/1)
              |> Enum.uniq()

            resolved = if in_scope?, do: Resolution.resolve(otp_app, principal_id, all_handles), else: %{}

            cohorts =
              for {key, kind, resolve_path} <- @cohort_families, into: %{} do
                {kind, cohort_rows(report, key, kind, row.slug, resolve_path, resolved, in_scope?)}
              end

            assign(socket,
              app: row,
              in_product_scope?: in_scope?,
              # ADR-050 §4.3 — the opt-in state, read from the SAME registry row, plus
              # the projection's own consequence preview (never a second mapping).
              publish_status: row.publish_status,
              publish_preview: unwrap_preview(PublicStatus.preview(row)),
              cohorts: cohorts,
              resolved: resolved,
              # P16 (phase6-punchlist / ADR-044 §16.2) — is the NAME-resolution seam
              # even wired in THIS deployment? A separately-deployed / cross-origin
              # cockpit with no `:fleet_name_resolver` masks every name; that is a
              # whole-page "seam not reachable" condition, NOT per-row out-of-scope.
              name_seam_reachable?: Resolution.name_resolver_configured?(otp_app)
            )
        end

      {:error, reason} ->
        assign(socket,
          app: nil,
          not_configured: reason,
          in_product_scope?: false,
          publish_status: nil,
          publish_preview: :excluded,
          cohorts: %{},
          resolved: %{},
          name_seam_reachable?: false
        )
    end
  end

  # ---------------------------------------------------------------------------
  # The public status page OPT-IN (ADR-050 §4.3) — the only mutation on this page.
  # ---------------------------------------------------------------------------

  @impl true
  def handle_event("publish_status", %{"publish" => value}, socket) do
    publish? = value == "true"
    %{admin?: admin?, namespace: namespace, principal_id: principal_id} = socket.assigns.fleet_ctx

    cond do
      # Belt-and-braces: `samen_operator_routes(..., fleet_cockpit: true)` REFUSES a nil
      # `:fleet_namespace` at compile time (`__require_fleet_namespace__!/1`), so this is
      # the runtime layer that keeps a directly-built `%Mount{}` honest too — the mirror
      # of `Samen.Fleet.read/2`'s own `{:missing_namespace, mode}` fail-closed arm.
      is_nil(namespace) ->
        {:noreply,
         assign(socket,
           publish_error:
             "No fleet_namespace is configured on this mount, so there is no registry to publish into."
         )}

      not socket.assigns.in_product_scope? ->
        {:noreply,
         assign(socket,
           publish_error:
             "You hold a fleet role but no role in this product, so its public visibility is not yours to change."
         )}

      # Fail closed on BOTH halves: a non-admin, and a session with no principal to
      # attribute the write to (a permissive `:fleet_authority` seam must not turn an
      # anonymous request into an admin one).
      not (admin? and is_binary(principal_id)) ->
        {:noreply,
         assign(socket,
           publish_error:
             "Only roles[:fleet] == :operator_admin may publish a product on the public status page."
         )}

      true ->
        case Registry.set_publish_status(
               namespace,
               socket.assigns.app_id,
               publish?,
               AdminActor.new(principal_id)
             ) do
          # Re-`load/1` rather than trusting the returned struct: the rendered state
          # must be the one the registry now holds, not the one we asked for.
          {:ok, app} ->
            {:noreply,
             socket
             |> assign(publish_error: nil, publish_note: publish_note(app.publish_status))
             |> load()}

          {:error, reason} ->
            {:noreply,
             assign(socket,
               publish_error: "The registry refused the change: #{inspect(reason)}"
             )}
        end
    end
  end

  defp publish_note(true),
    do: "Published — this product now appears on the public status page."

  defp publish_note(false),
    do: "Unpublished — this product no longer appears on the public status page."

  # `Samen.Fleet.PublicStatus.preview/1` returns `{:ok, entry} | :excluded`; the assign
  # holds the unwrapped pair so the template cannot mistake the tuple for an entry.
  defp unwrap_preview({:ok, entry}), do: entry
  defp unwrap_preview(:excluded), do: :excluded

  # The page's OWN display strings (`Samen.Web.Fleet.PublicStatus.label/1`), so this
  # surface names the public vocabulary exactly as `GET /status` renders it. Deliberately
  # NO catch-all clause: a caller that hands this something other than a projected entry
  # has a bug, and a fallback would render a plausible-but-possibly-wrong status — which
  # is how a cockpit ends up promising "Down" for a product the page reports as
  # operational. Fail loudly instead.
  defp preview_label(%PublicStatus.Entry{status: status}), do: PageStatus.label(status)

  defp cohort_rows(report, key, _kind, _slug, resolve_path, resolved, in_scope?) do
    (Map.get(report, key) || [])
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn item ->
      handle = item["handle"]
      name = in_scope? && is_binary(handle) && Map.get(resolved, handle)

      %{
        handle: handle,
        masked?: !name,
        name: name,
        resolve_href: name && Handle.well_formed?(handle) && "#{resolve_path}?fleet_handle=#{handle}",
        item: item
      }
    end)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div id="fleet-detail">
      <.app_shell>
        <:sidebar>
          <.operator_sidebar mount={@samen_mount} active={:fleet} operator_role={assigns[:samen_operator_role]} />
        </:sidebar>

        <.topbar title="Fleet" crumbs={[Crumbs.operator(), Crumbs.operator_section(:fleet), @app_id]} />

        <div :if={assigns[:not_configured]} class="wrap">
          <.empty_state class="fleet-not-configured" icon="⛴" title="Fleet not configured." body={inspect(@not_configured)} />
        </div>

        <div :if={!assigns[:not_configured] and @app == nil} class="wrap">
          <.empty_state class="fleet-unknown-app" icon="?" title="Unknown app." body="This product is not registered in the fleet, or was deregistered." />
        </div>

        <div :if={@app != nil and !@in_product_scope?} class="wrap">
          <.empty_state
            class="fleet-out-of-product-scope"
            icon="🔒"
            title="Not in your product scope."
            body="You hold a fleet role but no role in this specific product — this row's counts are hidden."
          />
        </div>

        <div :if={@app != nil and @in_product_scope?} class="wrap">
          <div class="gtitle" id="fleet-detail-header">
            <h3>{@app.display_name || @app.slug}</h3>
            <span class="lane">· {@app.slug} · {@app.mode} · {@app.status}</span>
          </div>

          <%!-- P16 (ADR-044 §16.2) — whole-page attribution when the NAME-resolution
                seam is not wired in this (separately-deployed) cockpit: names are
                withheld for a reason unrelated to per-viewer scope. Counts still show. --%>
          <.empty_state
            :if={not @name_seam_reachable?}
            class="fleet-name-seam-unreachable"
            icon="⚠"
            title="Names unavailable — resolution seam not reachable."
            body="This cockpit deployment has no fleet name-resolution seam wired for this product (a separately-deployed / cross-origin composition). Tenant names cannot be resolved here — cohort counts remain visible, names are withheld fail-closed."
          />

          <%!-- ADR-050 §4.3 — the public status page OPT-IN, per app. The consequence
                line speaks the page's own vocabulary (`preview/1` + `label/1`), so what
                an operator reads here is what `GET /status` will say. --%>
          <div class="card" id="publish-status-card" style="padding:14px 18px;margin-top:18px">
            <div class="gtitle">
              <h3>Public status page</h3>
              <span class="lane">· operator opt-in, per app</span>
            </div>

            <p id="publish-state">
              <%= if @publish_status do %>
                Published — this product appears on the public status page.
              <% else %>
                Not published — this product does not appear on the public status page.
              <% end %>
            </p>

            <p :if={@publish_preview != :excluded} id="publish-preview" class="note">
              <%= if @publish_status do %>
                The page reports it as {preview_label(@publish_preview)}.
              <% else %>
                Publishing would list {@app.slug} as {preview_label(@publish_preview)}.
              <% end %>
            </p>

            <p :if={@publish_preview == :excluded} id="publish-preview-excluded" class="note">
              This product is deregistered, so the public page omits it entirely — publishing it would change nothing.
            </p>

            <button
              :if={@fleet_ctx.admin?}
              class="btn"
              id="publish-toggle"
              phx-click="publish_status"
              phx-value-publish={if @publish_status, do: "false", else: "true"}
            >
              {if @publish_status, do: "Unpublish", else: "Publish on the status page"}
            </button>

            <%!-- The withheld control's note IS the disclosure control: it names the role the
                  publish gate needs (`@fleet_ctx.admin?`), and opening it shows WHAT EACH ROLE MAY
                  DO, focused on `fleet_publish`. The ✓/— marks come from the same session role the
                  footer renders — in the shipped fleet host (`Samenerp.FleetAuthz`) the
                  `:fleet_authority` seam DELEGATES to the operator resolver, so the role that
                  gates this control and the role this panel marks are one value, never two. --%>
            <.role_help_note
              :if={!@fleet_ctx.admin?}
              id="publish-readonly"
              focus={:fleet_publish}
              operator_role={assigns[:samen_operator_role]}
            >
              Read-only — publishing a product on the public status page requires roles[:fleet] == :operator_admin.
            </.role_help_note>

            <p :if={@publish_error} id="publish-error" style="color:var(--bad,#b91c1c)">{@publish_error}</p>
            <p :if={@publish_note} id="publish-note" class="note">{@publish_note}</p>
          </div>

          <div :for={{kind, rows} <- @cohorts} id={"cohort-#{kind}"} style="margin-top:18px">
            <div class="gtitle">
              <h3>{Phoenix.Naming.humanize(kind)}</h3>
              <span class="n">{length(rows)}</span>
              <span class="lane">· k-anon floored at source · names resolved per-viewer scope</span>
            </div>

            <.empty_state
              :if={rows == []}
              class={"cohort-#{kind}-empty"}
              icon="⊘"
              title="No cohort data reported."
              body="This product has not opted into tier-2 cohort reporting for this section."
            />

            <table :if={rows != []} class="tbl" id={"cohort-#{kind}-table"}>
              <thead>
                <tr>
                  <th scope="col">Tenant</th>
                  <th scope="col">Metrics</th>
                </tr>
              </thead>
              <tbody>
                <%= for {row, idx} <- Enum.with_index(rows) do %>
                  <%= if row.masked? do %>
                    <tr id={"cohort-#{kind}-row-#{idx}-masked"} class="cohort-row cohort-row-masked">
                      <td class="cohort-name-masked">
                        <span class="masked-affordance">{if @name_seam_reachable?, do: "not in your scope", else: "name unavailable"}</span>
                      </td>
                      <td>{cohort_metrics_text(row.item)}</td>
                    </tr>
                  <% else %>
                    <tr id={"cohort-#{kind}-row-#{idx}-named"} class="cohort-row cohort-row-named">
                      <td class="cohort-name">
                        <.link :if={row.resolve_href} navigate={row.resolve_href} class="cohort-name-link">
                          {row.name}
                        </.link>
                        <span :if={!row.resolve_href}>{row.name}</span>
                      </td>
                      <td>{cohort_metrics_text(row.item)}</td>
                    </tr>
                  <% end %>
                <% end %>
              </tbody>
            </table>
          </div>
        </div>
      </.app_shell>
    </div>
    """
  end

  defp cohort_metrics_text(item) when is_map(item) do
    item
    |> Map.drop(["handle"])
    |> Enum.map_join(" · ", fn {k, v} -> "#{k}: #{suppressed_or(v)}" end)
  end

  defp suppressed_or(%{"suppressed" => true}), do: "⊘"
  defp suppressed_or(v), do: to_string(v)
end
