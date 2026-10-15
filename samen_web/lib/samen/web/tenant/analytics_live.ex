defmodule Samen.Web.Tenant.AnalyticsLive do
  @moduledoc """
  P17 (ADR-045 §3) — the framework TENANT own-org analytics surface: a floored, org-scoped
  activation view a tenant sees over its OWN org, inherited by any vertical at ≈0 LOC by
  mounting this LiveView under a tenant `live_session` (the `{Samen.Web.TenantAuthz,
  :require_tenant}` on_mount + `Samen.Web.CurrentOrg` org resolution — the same seam the
  flags/billing/crm tenant surfaces mount through).

  It reads ONLY through `Samen.Web.Tenant.AnalyticsReads`, so every property proven there
  holds here: org-scoped from the AUTHENTICATED scope (never `?org=`), the shipped
  k-anonymity floor REUSED (a below-floor stage renders `⊘`, never a raw count), role-gated
  (`queryable_roles/0` read off the caller's REAL membership role via
  `Samen.Web.TenantRole.authenticated_scope/2` — never a fabricated `:member`).
  Token-blind by construction — every rendered value is a bounded stage label or a count /
  `⊘`; no vault field, no `Samen.Vault`/`PiiResolution` call, no `%Masked{}` branch.

  ## One state per fact — the page never says "no data yet" for a read it did not make

  The answer (`analytics-empty`: the rollup read RAN and this org has no rows) is ONE state out
  of five, and this page renders each of the other four as itself (`<.unread_state>`, carrying
  the read's bounded reason token):

    * `no_org`         — no org resolved for this session (nothing to scope the read to);
    * `not_authorized` — an org is resolved, but the caller's real role is outside
      `queryable_roles/0`;
    * `not_configured` — this session carries no mount, so there is no rollup seam to read;
    * `read_failed`    — the rollup read raised / answered an error (absent table, unusable repo).

  Collapsing those into "No own-org activation data yet, or analytics is not available for your
  role" asserted a fact about the org's data that the page never observed (ADR-014/024/026) — and
  made the withheld states unactionable: an operator reading the screenshot cannot tell a
  never-emitted event from an unmigrated table.

  ## Every silence names the step that clears it

  Knowing WHY nothing was read is half the fix; the other half is what the reader can do about it.
  Each silent state therefore renders the ONE next step available for it, through
  `<.unread_state>`'s `:actions` slot:

    * `not_authorized` — the org's team settings, where an owner raises the caller's role;
    * `not_configured` — THIS reader's host mount docs (the mount macro + the two config links);
    * `read_failed`    — the operator runbook (rollups queue, `/readyz`, pool saturation — the
      three ways this read stops answering);
    * `no_org`         — none, deliberately: there is no org to act on, and inventing a link would
      be a second unobserved claim in a page whose whole job is not to make one.

  A step is a LINK only to a destination that PROVABLY exists on this host: the team-settings
  route appears exactly when the host declares `:settings_path`, and a doc reference becomes an
  href only under a declared `:docs_base` — otherwise the doc PATH is named in a `code` element
  and left unlinked. Defaulting either to a plausible path would have manufactured a 404 on every
  host that mounts this page and not that one — the same class of lie as an empty list for a read
  that never ran, one link over.

  ## Chrome — the message belongs to the PAGE, not to the viewport

  Every state renders inside the shared shell (`Samen.UI.app_shell/1` + `<.topbar>` + a `.wrap`
  main panel): the same chrome every other tenant surface mounts, with the workspace sidebar
  beside it and the Insights group marking where the reader is. A silence is a state OF a page —
  a heading, a scope note and a card in the main panel — not a stray sentence floating on an
  unstyled viewport. The answered empty state is the kit's `empty_state/1` (a measured zero) and
  every silence is `unread_state/1` (a read that did not happen); the two are never swapped.

  ## Copy — plain words for the reader, the token for the bug report

  The titles/bodies below say what happened in the words a tenant would use ("Your role doesn't
  include activation analytics", "Activation analytics isn't set up on this app") rather than in
  framework vocabulary — a state the reader cannot parse is only half-fixed. The bounded REASON
  TOKEN (`data-unread-reason="…"`, rendered by `unread_state/1`) is unchanged and stays in the
  DOM, so support can quote a machine-readable reason without the page having to speak jargon.
  """
  use Phoenix.LiveView

  import Samen.UI,
    only: [
      app_shell: 1,
      empty_state: 1,
      host_nav_extra: 1,
      logout_form: 1,
      module_nav: 1,
      sidebar: 1,
      topbar: 1,
      unread_state: 1
    ]

  import Samen.Web.CurrentOrg, only: [acting_as_banner: 1, switcher: 1]

  alias Samen.Aggregate.Suppressed
  alias Samen.Web.{Crumbs, CurrentOrg, Mount, TenantRole}
  alias Samen.Web.Tenant.AnalyticsReads

  @impl true
  def mount(params, session, socket) do
    socket = Samen.Web.Live.assign_mount(socket, session)
    org_id = CurrentOrg.resolve(socket.assigns[:samen_mount], params, session)
    {:ok, load(socket, org_id)}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    org_id = CurrentOrg.reresolve(socket, params)
    {:noreply, load(socket, org_id)}
  end

  @doc false
  # No org resolved at all — NOT an empty result. The read is never attempted: there is no
  # own-org scope to bind it to, and an unanswered read is not a measurement.
  def load(socket, nil), do: assign_surface(socket, %{funnel: [], unread: :no_org}, nil)

  def load(socket, org_id) do
    mount = socket.assigns[:samen_mount]

    read =
      if mount do
        AnalyticsReads.read(mount, TenantRole.authenticated_scope(mount, org_id))
      else
        # A session with no mount has no rollup seam to read through — the read layer's
        # `:not_configured` silence, reached here without calling it (there is no mount to
        # derive the scope from). Never a crash on a cold render, never "no data yet".
        %{funnel: [], unread: :not_configured}
      end

    assign_surface(socket, read, org_id)
  end

  defp assign_surface(socket, read, org_id) do
    funnel = Map.get(read, :funnel, [])
    unread = Map.get(read, :unread)

    assign(socket,
      funnel: funnel,
      suppressed_count: AnalyticsReads.suppressed_count(funnel),
      unread: unread,
      next_step: unread_next_step(unread, socket.assigns[:samen_mount], org_id),
      org_id: org_id,
      # The shell's impersonation banner asks for this unconditionally. A session that carried NO
      # mount never went through `assign_mount/2`'s acting-as read, so it is defaulted here
      # (idempotent when it IS set) — a missing assign is a crash on a cold render, which is the
      # one thing this page must never do.
      samen_acting_as: Map.get(socket.assigns, :samen_acting_as, false)
    )
  end

  @impl true
  def render(assigns) do
    ~H"""
    <.app_shell>
      <:sidebar>
        <.sidebar
          title={CurrentOrg.name(@samen_mount, @org_id)}
          subtitle="Insights"
          logo={glyph(@samen_mount)}
        >
          <:switcher>
            <.switcher :if={@samen_mount} mount={@samen_mount} org_id={@org_id} compact />
          </:switcher>

          <%!-- The INHERITED nav, resolved off THIS host's own path labels — the page links
                exactly the modules the host mounted and nothing more (the X1 dead-link guard,
                the same `nav_paths/1` seam every other framework sidebar renders through). --%>
          <.module_nav
            :if={@samen_mount}
            {nav_paths(@samen_mount)}
            org_id={@org_id}
            active={:analytics}
          >
            <:extra><.host_nav_extra mount={@samen_mount} org_id={@org_id} /></:extra>
          </.module_nav>

          <:footer>
            <div :if={@samen_mount} class="foot">
              <div class="av" style="background:#DDE2F5;color:#3B4CCA">
                {Mount.label(@samen_mount, :user_initials, "S")}
              </div>
              <div class="m">
                <b>{Mount.label(@samen_mount, :user_name, "Signed in")}</b>
                <span>{Mount.label(@samen_mount, :user_role, "admin")}</span>
              </div>
              <.logout_form />
            </div>
          </:footer>
        </.sidebar>
      </:sidebar>

      <.topbar title="Activation" crumbs={crumbs(@samen_mount, @org_id)} />

      <.acting_as_banner mount={@samen_mount} org_id={@org_id} acting_as={@samen_acting_as} />

      <div class="wrap">
        <div id="tenant-analytics">
          <div class="gtitle">
            <h3>Your organization</h3>
            <span class="lane">activation funnel · your own organization only</span>
          </div>

          <p class="scope-note" id="activation-scope-note">
            Counts cover your own organization only. A stage reached by fewer people than the
            privacy floor is shown as <span class="mono">⊘</span> instead of a number, so nobody
            can be identified from it — we never show an individual person.
          </p>

          <%!-- FAIL-HONEST: `analytics-empty` is an ANSWER, so it renders ONLY when the read
                answered. Every other outcome says which one it is — a caller with no org, a role
                the gate refuses, an unmounted seam, or a failed rollup read each get their own
                statement (with the reason token), never a claim about the org's data. --%>
          <div :if={@unread} id="analytics-unread">
            <.unread_state
              class="analytics-unread"
              reason={@unread}
              title={unread_title(@unread)}
              body={unread_body(@unread)}
            >
              <%!-- THE NEXT STEP for this reason — a link only where the destination provably
                    exists on this host, the doc path NAMED (never a dead href) where it does
                    not, and nothing at all for a state with no honest step (`no_org`). --%>
              <:actions :if={@next_step}>
                <a
                  :if={@next_step.href}
                  href={@next_step.href}
                  id={"unread-next-#{@unread}"}
                  class="unread-next-step"
                  target={@next_step.kind == :doc && "_blank"}
                  rel={@next_step.kind == :doc && "noopener noreferrer"}
                >{@next_step.label} →</a>
                <span :if={!@next_step.href} id={"unread-next-#{@unread}"} class="unread-next-step">
                  {@next_step.label}<span :if={@next_step.path}>: <code class="mono">{@next_step.path}</code></span>
                </span>
              </:actions>
            </.unread_state>
          </div>

          <div :if={!@unread and @funnel == []} id="analytics-empty">
            <.empty_state
              icon="📈"
              title="No activation data yet."
              body="We read the activation rollup for your organization and it came back with no rows — nobody in this organization has completed a signup, a first run or a first record yet."
            />
          </div>

          <div :if={!@unread and @funnel != []} class="card">
            <table id="funnel-table">
              <thead>
                <tr>
                  <th>Stage</th>
                  <th>People reached</th>
                </tr>
              </thead>
              <tbody>
                <tr :for={row <- @funnel} id={"stage-#{row.stage}"} class="funnel-row">
                  <td class="f-stage">{stage_label(row.stage)}</td>
                  <td class="f-count">{cell(row.actor_count)}</td>
                </tr>
              </tbody>
            </table>
          </div>

          <p :if={!@unread and @suppressed_count > 0} id="supp-note" class="supp">
            {@suppressed_count} stage(s) below the k-anonymity floor — suppressed to prevent re-identification.
          </p>
        </div>
      </div>
    </.app_shell>
    """
  end

  # One title per silence — the read layer's bounded vocabulary, in the words a tenant would use.
  #
  # NO APOSTROPHES, deliberately: `Phoenix.HTML.Safe` escapes `'` as `&#39;`, so a contraction
  # here would land in the DOM (and in the assertions over it) as an entity. `does not` reads
  # plainly at this size and keeps the markup — what a reader copies out of a bug report — clean.
  defp unread_title(:no_org), do: "No organization is selected."
  defp unread_title(:not_authorized), do: "Your role does not include activation analytics."
  defp unread_title(:not_configured), do: "Activation analytics is not set up on this app."
  defp unread_title(_), do: "We could not read your activation data."

  # ...and one honest body, each saying WHAT happened and WHY it is not a "no data" result.
  defp unread_body(:no_org),
    do:
      "This page shows activation for your own organization. No organization was selected for " <>
        "this session, so nothing was read — that is not the same as your organization having no data."

  defp unread_body(:not_authorized),
    do:
      "Activation analytics is open to the owners, admins and members of an organization. Your " <>
        "role in this organization is not one of those, so nothing was read for this request — not " <>
        "an empty result."

  defp unread_body(:not_configured),
    do:
      "This app has not connected the activation rollup yet, so there is nothing to read here. " <>
        "Nothing was queried and nothing is being withheld from you."

  defp unread_body(_),
    do:
      "The activation rollup did not answer, so we cannot tell whether your organization has " <>
        "data. Treat it as unknown rather than empty, and try again in a moment."

  # -- the page chrome ---------------------------------------------------------------

  # The sidebar's workspace glyph — `nil` stands for "no mount at all" (a session that carries no
  # seam still renders a page; it simply has nothing host-specific to name it with).
  defp glyph(%Mount{} = mount), do: Mount.label(mount, :glyph, "S")
  defp glyph(_no_mount), do: "S"

  # The inherited nav's paths, resolved off the mount's own path labels: this page's sidebar links
  # exactly the modules THIS host mounted (X1 dead-link guard) and nothing at all without a mount.
  defp nav_paths(%Mount{} = mount), do: Samen.UI.nav_paths(mount)
  defp nav_paths(_no_mount), do: []

  # The breadcrumb trail: the workspace crumb every tenant page opens with, then the section and
  # the leaf (a plain string — the page never links to itself).
  defp crumbs(%Mount{} = mount, org_id), do: [Crumbs.org(mount, org_id), "Insights", "Activation"]
  defp crumbs(_no_mount, _org_id), do: ["Insights", "Activation"]

  # -- the next step, one silence at a time ------------------------------------------

  # The framework docs a silent state points at, as REPO-RELATIVE paths — the same spelling the
  # guides use to reference one another, so a host can serve them (or prefix them with its
  # declared `:docs_base`) without this module guessing a URL shape.
  @mount_doc "docs/ws-analytics/p17-tenant-analytics-design.md"
  @runbook_doc "docs/runbooks/alerts.md"

  @doc """
  The ONE next step for `reason` on `mount`, or `nil` when this state has no honest step.

  Returns `%{label:, kind:, href:, path:}` (only the relevant fields are present):

    * `kind: :link` — an in-app destination the host DECLARES (its team settings), so the href
      exists by construction;
    * `kind: :doc`  — a repo-relative doc reference. `href` is set ONLY when the host declares a
      `:docs_base`; without one the reference is still returned — with `path` and no `href` — so
      the reader is told WHICH doc to open rather than handed a dead link.

  Public (and pure) so the mapping is assertable without rendering, and so a second surface can
  reuse the vocabulary: this is presentation (`AnalyticsReads` owns the reasons, the page owns
  what to do about them).
  """
  @spec unread_next_step(atom() | nil, Samen.Web.Mount.t() | nil, String.t() | nil) ::
          %{atom() => term()} | nil
  def unread_next_step(:not_authorized, mount, org_id), do: role_request(mount, org_id)

  def unread_next_step(:not_configured, mount, _org_id),
    do: doc_step(mount, "Read the setup docs for this page", @mount_doc)

  def unread_next_step(:read_failed, mount, _org_id),
    do: doc_step(mount, "Work the operator runbook (rollups queue, readiness, pool)", @runbook_doc)

  # `:no_org` (and anything a future read layer adds): no step. There is no org to act on, so
  # every "fix" would be a fact about a session this page never resolved.
  def unread_next_step(_reason, _mount, _org_id), do: nil

  # A role request goes to the org's TEAM settings — the one page where access is granted. The
  # link exists only when the host declares `:settings_path` (a mount label's PRESENCE is the
  # dead-link guard; a host that mounted this page without its settings routes must not be handed
  # a href to a route it does not serve). Without the label the step is still stated, unlinked.
  defp role_request(mount, org_id) when is_binary(org_id) do
    case label(mount, :settings_path) do
      nil ->
        step(:link, "Ask an owner of this org to raise your role")

      base ->
        step(:link, "Ask an owner to raise your role in team settings",
          href: "#{base}/invitations?org=#{org_id}"
        )
    end
  end

  defp role_request(_mount, _org_id), do: nil

  # A DOC reference: linked when the host declares where its docs live, NAMED when it does not.
  defp doc_step(mount, label, path) do
    case label(mount, :docs_base) do
      nil -> step(:doc, label, path: path)
      base -> step(:doc, label, path: path, href: doc_href(base, path))
    end
  end

  # Every step carries the SAME shape: `href` nil means NAMED-but-unlinked, `path` nil means the
  # destination is an in-app route rather than a doc. One shape keeps the render free of
  # key-presence branching — a missing key could otherwise read as an absent destination.
  defp step(kind, label, opts \\ []) do
    %{kind: kind, label: label, href: Keyword.get(opts, :href), path: Keyword.get(opts, :path)}
  end

  # A mount label — with `nil` standing for "no mount at all": a session that carries no seam has
  # DECLARED nothing (not "declared a default"), and asking it must not crash a cold render.
  defp label(%Samen.Web.Mount{} = mount, key), do: Samen.Web.Mount.label(mount, key, nil)
  defp label(_no_mount, _key), do: nil

  # Join a docs base with a repo-relative path without doubling the slash — a host may declare
  # either shape (`https://…/blob/main/` or `/docs`).
  defp doc_href(base, path) do
    base = String.trim_trailing(base, "/")
    path = String.trim_leading(path, "/")
    "#{base}/#{path}"
  end

  defp stage_label("signup"), do: "Signed up"
  defp stage_label("first_run"), do: "First run completed"
  defp stage_label("first_record"), do: "First record created"
  defp stage_label(other), do: to_string(other)

  # Token-blind cell: a %Suppressed{} renders ⊘, NEVER the withheld value.
  defp cell(%Suppressed{}), do: "⊘"
  defp cell(n) when is_integer(n), do: Integer.to_string(n)
  defp cell(other), do: to_string(other)
end
