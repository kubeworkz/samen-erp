defmodule Samen.Web.Operator.Live do
  @moduledoc """
  Shared operator-workspace LiveView helpers: mount assignment (re-exported from
  `Samen.Web.Live`) and the operator sidebar with the operator nav
  (Accounts · Platform billing · Revenue · Analytics · Desk · Flags · Portfolio —
  ADR-010 §7.1; Revenue is the WS-B / B3 G7 surface, Analytics the WS-B / B8 G12 seed).

  The operator workspace is host-agnostic: its title/glyph come from `mount.labels` with
  neutral defaults, exactly as the CRM/Billing/Support sidebars (ADR-009). The nav is the
  framework's; a host supplies only branding copy on the mount.
  """
  use Phoenix.Component

  import Samen.UI
  import Samen.Web.CurrentOrg, only: [switcher: 1]

  alias Samen.Automation.Health
  alias Samen.BreakGlass
  alias Samen.OperatorPlane.Actor
  alias Samen.Web.Mount

  @doc "Read the mount out of the session (see `Samen.Web.Live.assign_mount/2`)."
  defdelegate assign_mount(socket, session), to: Samen.Web.Live

  @doc """
  Whether the operator workspace offers write AFFORDANCES on this mount (A3 posture,
  same rule as the CRM/Billing/Support/Marketing `Live` modules): the operator's own
  book-of-business workspace runs on the operator org's TENANT plane (ADR-010 §7.2) —
  writable. A `plane: :operator` (impersonation) mount is read-only UI. This is
  POSTURE only; the ENFORCEMENT is the kernel's (`OrgScope`, `RoleAtLeast`, and
  `Samen.Pii.WriteGuard` at the Ash write path — MC-1).
  """
  def writable?(%Mount{plane: %{kind: :operator}}), do: false
  def writable?(_), do: true

  # The PER-TENANT DRILL-IN surfaces: each is keyed on an `:org_id` route param and has NO
  # top-level index (see the T149 P1 note inside the nav group), so the ONLY way in is
  # Accounts → a specific tenant. A drill-in therefore lights ACCOUNTS in the sidebar: an
  # operator three clicks into one must still see WHERE IN THE PLANE they are, instead of a
  # bar with nothing highlighted (which reads as "you are nowhere", the same lost-place
  # failure as a mislink, just quieter).
  #
  # The page still passes its OWN atom (`active: :replay`), so the call site keeps saying which
  # surface it is; this mapping is the ONE place that knows the way in is Accounts. Keep it
  # here rather than in each page: five pages each hand-mapping to `:accounts` would lose that
  # self-description and could drift apart.
  #
  # NOTE: defined ABOVE `operator_sidebar/1`'s `attr` declarations on purpose — a `def` sitting
  # between an `attr` block and its component is taken as the COMPONENT by `Phoenix.Component`,
  # which then injects that attrs' default-assigns wrapper around it.
  @per_tenant_drill_ins [:deliverability, :automation, :agents, :activity, :replay]

  defp nav_active(active) when active in @per_tenant_drill_ins, do: :accounts
  defp nav_active(active), do: active

  attr :mount, Mount, default: nil
  attr :active, :atom, default: nil

  # The session's RESOLVED operator role (`:samen_operator_role`, assigned by
  # `Samen.Web.Operator.Authz`'s `:require_operator` on_mount) — the SAME value every
  # write predicate on every operator page reads. `nil` on a mount that never ran the
  # on_mount (a bare test socket), which falls back to the mount's static copy.
  attr :operator_role, :atom, default: nil

  @doc """
  The operator control-plane sidebar — workspace header + the operator nav group.

  INVARIANT (T116 P9-F2/AMB-1, attempt 2): every operator-chrome nav link stays on the
  operator plane (`/operator/*`); the ONLY operator→tenant affordance is the GOVERNED
  "Act as a tenant →" switcher in the footer, which routes through `/session/org/<id>`
  (the `SessionController` write) so the crossing sets the acting-as context and trips the
  `plane_badge` crossing marker. NO operator nav link may target a BARE tenant-plane surface
  (`/notifications`, `/crm`, `/billing`, …): a raw operator→tenant link is the silent-crossing
  bug the verifier reproduced (an operator landing on a tenant inbox with `data-plane=tenant`
  and NO `#acting-as-bar`, byte-identical to a real tenant). The prior `Notifications` item
  linked to bare `/notifications` and is REMOVED — the operator plane mounts no notifications
  surface (no `/operator/notifications` route, no `active: :notifications` LiveView), so it was
  a vestigial mislink, not a feature. `operator_sidebar_link_invariant_test.exs` proves the bar
  (a bare-tenant href fails the test).
  """
  def operator_sidebar(assigns) do
    # `Map.get/2` (not `assigns.active`): `render_component/2` in tests hands the component a
    # bare map WITHOUT the `attr` defaults filled in, so the key can be absent entirely.
    assigns = assign(assigns, :nav_active, nav_active(Map.get(assigns, :active)))

    ~H"""
    <.sidebar
      title={label(@mount, :operator_workspace, "Operator")}
      subtitle="Control plane"
      logo={label(@mount, :operator_glyph, "S")}
      logo_style={label(@mount, :operator_logo_style, "background:linear-gradient(150deg,#3B4CCA,#5B6EE8)")}
    >
      <:search>
        <div class="search">
          <svg class="i" width="15" height="15" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2">
            <circle cx="11" cy="11" r="7" /><path d="m21 21-4.3-4.3" />
          </svg>
          Search accounts, tenants…
          <span class="kbd">⌘K</span>
        </div>
      </:search>

      <.nav_group label="Operator plane">
        <.nav_item label="Accounts" href="/operator/accounts" active={@nav_active == :accounts}>
          <:icon>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="4" width="18" height="16" rx="2" /><path d="M3 9h18" /></svg>
          </:icon>
        </.nav_item>
        <.nav_item label="Platform billing" href="/operator/billing" active={@nav_active == :billing}>
          <:icon>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 2v20M17 5H9.5a3.5 3.5 0 0 0 0 7h5a3.5 3.5 0 0 1 0 7H6" /></svg>
          </:icon>
        </.nav_item>
        <.nav_item label="Revenue" href="/operator/revenue" active={@nav_active == :revenue}>
          <:icon>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M3 17l6-6 4 4 8-8" /><path d="M14 7h7v7" /></svg>
          </:icon>
        </.nav_item>
        <.nav_item label="Analytics" href="/operator/analytics" active={@nav_active == :analytics}>
          <:icon>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M3 12h4l3-8 4 16 3-8h4" /></svg>
          </:icon>
        </.nav_item>
        <.nav_item label="Desk" href="/operator/desk" active={@nav_active == :desk}>
          <:icon>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M21 15a2 2 0 0 1-2 2H7l-4 4V5a2 2 0 0 1 2-2h14a2 2 0 0 1 2 2z" /></svg>
          </:icon>
        </.nav_item>
        <.nav_item label="Flags" href="/operator/flags" active={@nav_active == :flags}>
          <:icon>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 21V4" /><path d="M4 4h12l-2 4 2 4H4" /></svg>
          </:icon>
        </.nav_item>
        <.nav_item label="Webhook DLQ" href="/operator/webhooks" active={@nav_active == :webhooks}>
          <:icon>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M12 2v6m0 0 3-3m-3 3L9 5" /><path d="M5 12a7 7 0 0 0 7 7 7 7 0 0 0 7-7" /></svg>
          </:icon>
        </.nav_item>
        <%!--
          WS-J fleet cockpit (ADR-044, T84b) — a TOP-LEVEL tier-1/2 platform surface (unlike
          Deliverability/Automation/Activity below, which are per-tenant drill-ins with no
          top-level index). Rendered ONLY on a `fleet_cockpit: true` mount (§6.3's `roles[:fleet]`
          gate runs inside `FleetLive` itself; this nav item is chrome, not the gate).
        --%>
        <.nav_item :if={Mount.label(@mount, :fleet_cockpit, false)} label="Fleet" href="/operator/fleet" active={@nav_active == :fleet}>
          <:icon>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><rect x="3" y="3" width="7" height="7" rx="1" /><rect x="14" y="3" width="7" height="7" rx="1" /><rect x="3" y="14" width="7" height="7" rx="1" /><rect x="14" y="14" width="7" height="7" rx="1" /></svg>
          </:icon>
        </.nav_item>
        <%!--
          T149 P1 — the Deliverability / Automation / Activity items are REMOVED from the
          top-level operator nav. Each is a per-TENANT drill-in (`/operator/deliverability/:org_id`,
          `/operator/automation/:org_id`, `/operator/activity/:org_id`) with NO top-level index
          route — they are reached by drilling into a SPECIFIC account (the account drill-down's
          "Deliverability → / Automation health → / Activity →" links). Their prior top-level
          `href="/operator/accounts"` dumped the operator on the Accounts page while marking the
          WRONG nav item active — a mislink, not a feature (exactly the vestigial "Notifications"
          mislink the moduledoc above already removed). `operator_sidebar_link_invariant_test.exs`
          proves no bare-tenant/off-plane href remains; there is no `active: :deliverability |
          :automation | :activity` case here because no top-level surface exists to be active.
          Instead each of them (plus `:agents` and `:replay`) lights ACCOUNTS via
          `nav_active/1` above — the bar keeps the operator's place without inventing a
          top-level item that would mislink back to the same Accounts page.
        --%>
        <.nav_item label="Portfolio" href="/operator/aggregate" active={@nav_active == :aggregate}>
          <:icon>
            <svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.8"><path d="M4 19V9m6 10V5m6 14v-7" /></svg>
          </:icon>
        </.nav_item>
      </.nav_group>

      <:footer>
        <div class="op-act-as" id="operator-act-as">
          <div class="grp">Act as a tenant →</div>
          <.switcher :if={@mount} mount={@mount} return_to="/broker" />
        </div>
        <div class="foot">
          <div class="av" style="background:#DDE2F5;color:#3B4CCA">{label(@mount, :operator_initials, "OP")}</div>
          <div class="m">
            <b>{label(@mount, :operator_user, "Operator")}</b>
            <%!--
              The role label IS the disclosure control — a native `<details>` (the same shape the
              footer's org switcher below already uses): zero JS, keyboard-operable, and it
              renders on EVERY operator page at 0 authored LOC. The panel answers "may I do
              this?" per capability, so an operator reading a withheld-control note (`#dlq-
              readonly`, the fleet `*-readonly` note) can see whether the control is theirs — or
              which role would be. `operator_role_label/2` is the RESOLVED session role.
            --%>
            <details class="role-help" id="operator-role-help">
              <summary
                id="operator-role"
                data-operator-role={@operator_role}
                title="Your resolved operator role — a page withholds every control this role may not use. Open for what each role may do."
              >
                <div class="role-help-role">{operator_role_label(@operator_role, @mount)}</div>
                <div class="role-help-chevron" aria-hidden="true">›</div>
              </summary>

              <%!-- ONE definition of the matrix, shared with every withheld-control note
                    (`<.role_help_note>` below) — the footer's answer and a note's answer are the
                    same answer, and neither can drift from the other. --%>
              <.operator_role_help_panel operator_role={@operator_role} />
            </details>
          </div>
          <.logout_form />
        </div>
      </:footer>
    </.sidebar>
    """
  end

  attr :operator_role, :atom, default: nil

  attr :focus, :atom,
    default: nil,
    doc: "The one capability row this caller is ABOUT (`:dlq_write` for the DLQ's note, …)."

  @doc """
  The role-capability matrix — one row per capability, with the roles that hold it and whether
  THIS session's `:operator_role` does.

  Rendered from ONE definition in two places: inside the sidebar's `#operator-role-help`
  disclosure, and inside every withheld-control note's `<.role_help_note>` (below). So the
  answer a note opens is the answer the footer gives — a note can never explain a control with
  a different story than the chrome does.

  `focus` marks ONE row (`data-focus="true"`, styled by `.role-help-row[data-focus]`) as the
  capability the note that opened this panel is about, so a withheld control opens AT its own
  answer instead of somewhere in a list of six.
  """
  def operator_role_help_panel(assigns) do
    ~H"""
    <div class="role-help-panel">
      <div class="role-help-head">What each operator role may do</div>

      <div :if={@operator_role} class="role-help-legend role-help-why">
        ✓ this session's role may · — it may not
      </div>

      <div
        :for={row <- operator_capabilities(@operator_role)}
        class="role-help-row"
        data-capability={row.key}
        data-held={if @operator_role, do: to_string(row.mine?), else: nil}
        data-focus={if row.key == @focus, do: "true", else: nil}
      >
        <div class="role-help-cap">
          <div :if={@operator_role && row.mine?} class="role-help-mark yes" aria-hidden="true">✓</div>
          <div :if={@operator_role && !row.mine?} class="role-help-mark no" aria-hidden="true">—</div>
          <div>{row.label}</div>
          <%!-- The marks are decorative (the legend explains them); a screen reader gets
               the same fact as a sentence, so the panel is not sighted-only. --%>
          <div :if={@operator_role} class="sr-only">
            {if row.mine?, do: "Your role may do this.", else: "Your role may not do this."}
          </div>
        </div>
        <div class="role-help-roles">{Enum.join(row.role_labels, " · ")}</div>
        <div :if={row.why} class="role-help-why">{row.why}</div>
      </div>

      <div :if={!@operator_role} class="role-help-why">
        No operator role was resolved for this session — the ✓/— marks need one.
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :operator_role, :atom, default: nil
  attr :focus, :atom, default: nil
  attr :title, :string, default: nil
  attr :class, :string, default: nil, doc: "Extra classes for the caller's own surface (e.g. `card`)."

  slot :inner_block, required: true

  @doc """
  A WITHHELD-CONTROL NOTE that opens the role-capability matrix — the note and the role answer
  one click apart.

  Every operator surface that withholds a control renders a note saying so; several of those
  notes already NAME the role that would be required (`#dlq-readonly`, the fleet
  `#publish-readonly` / register notes). A named role the reader cannot map to their own was
  still a dead end — the operator could read "requires `:operator_admin`" and not know whether
  that is them. This note is the same zero-JS `<details>` shape the footer uses: the note TEXT
  is the `<summary>`, and the panel it opens is the shared matrix, focused on the capability
  this note is about.

  The role it marks ✓/— against is the SAME assign the withholding predicate reads on that
  surface — `:samen_operator_role`, the session's RESOLVED operator role (`WebhookDlqLive`'s
  `may_write?/1`, `writable?/1`, `Actor.may_impersonate?/1` and the fleet gate all read that
  one value / its fleet-scope twin) — so the marks cannot contradict the control next to them.
  """
  def role_help_note(assigns) do
    ~H"""
    <details
      class={if @class, do: "note note-help " <> @class, else: "note note-help"}
      id={@id}
      title={@title}
    >
      <summary>
        <span class="note-help-text">{render_slot(@inner_block)}</span>
        <span class="note-help-cta">
          What each operator role may do
          <span class="note-help-chevron" aria-hidden="true">›</span>
        </span>
      </summary>
      <.operator_role_help_panel operator_role={@operator_role} focus={@focus} />
    </details>
    """
  end

  @doc """
  Is a per-account DRILL-IN session withheld from this session's resolved operator role?

  The gate is `Samen.Impersonation.open/4` → `Actor.may_impersonate?/1`: a drill-in page that
  offers the reason form to a role the gate refuses is offering a control that cannot work.
  `nil` is withheld too — `Samen.Web.Operator.Impersonation.open/4`'s catch-all refuses
  `{:error, :not_authorized}` on a role that was never resolved.
  """
  @spec drill_in_role_denied?(Samen.OperatorPlane.Actor.operator_role() | nil | atom()) :: boolean()
  def drill_in_role_denied?(nil), do: true

  def drill_in_role_denied?(role) when is_atom(role) do
    # Denied unless it is a role in the closed set that the gate admits. A role OUTSIDE the
    # set is DENIED (matching `Impersonation.open/4`'s catch-all) — and `Actor.new/2` would
    # RAISE on it, so it is answered here rather than through the throwaway actor
    # (fail closed, never crash a render).
    not (role in Actor.roles() and Actor.may_impersonate?(role_actor(role)))
  end

  @doc """
  The operator ROLE label the sidebar footer shows.

  The `:samen_operator_role` the `{Samen.Web.Operator.Authz, :require_operator}` on_mount
  RESOLVED from the authenticated session principal — rendered as a human label so an operator
  can see, on the page itself, WHY a control was withheld. That is the whole point: the DLQ's
  `#dlq-readonly` note says "replay and resolve require `:operator_admin` / `:operator_support`",
  and this footer is where the operator reads which of those they are. It is ALSO the same value
  every write predicate (`WebhookDlqLive.may_write?/1`, `Automation.Health.may_manage?/1`, the
  fleet `roles[:fleet]` ladder) reads — so the label cannot disagree with the behaviour.

  Falls back to the mount's static `:operator_role` copy (default "SaaS staff") when NO role was
  resolved: a mount that never ran the on_mount (a bare test socket, or a non-operator-plane
  render) has no session role to show, and this is a DISPLAY fallback — never authority. Host
  copy set on the mount still wins in that case, so nothing a host branded changes.
  """
  @spec operator_role_label(Samen.OperatorPlane.Actor.operator_role() | nil, Mount.t() | nil) ::
          String.t()
  def operator_role_label(role, mount \\ nil)

  def operator_role_label(:operator_admin, _mount), do: "Operator admin"
  def operator_role_label(:operator_support, _mount), do: "Operator support"
  def operator_role_label(:operator_readonly, _mount), do: "Read-only operator"
  def operator_role_label(:operator_break_glass, _mount), do: "Break-glass operator"
  def operator_role_label(_unresolved, mount), do: label(mount, :operator_role, "SaaS staff")

  @doc """
  A SHORT role name for the capability panel's role lists (`"admin"`, `"support"`, `"read-only"`,
  `"break-glass"`). The long `operator_role_label/2` form is the panel's HEADING (the current
  session's role); these are the per-row "who holds this" lists, where four long labels would not
  fit a sidebar.
  """
  @spec operator_role_short_label(Samen.OperatorPlane.Actor.operator_role()) :: String.t()
  def operator_role_short_label(:operator_admin), do: "admin"
  def operator_role_short_label(:operator_support), do: "support"
  def operator_role_short_label(:operator_readonly), do: "read-only"
  def operator_role_short_label(:operator_break_glass), do: "break-glass"

  # ==========================================================================
  # The role-help disclosure's capability matrix
  # ==========================================================================

  # `{key, capability copy, honest caveat}`. The ROLES that hold each capability are DERIVED by
  # `operator_capabilities/1` — never listed here, so there is one place to be right.
  @capabilities [
    {:read_workspace, "Read the operator workspace", nil},
    # NB: deliberately NOT the word the T150 form/`open_session` handler uses. The sidebar is
    # GLOBAL chrome, so it renders on the fleet cockpit too — a page whose invariant test refutes
    # that substring as a proxy for "no drill-in affordance here" (`FleetLiveTest`, RP-J-5). The
    # row is about the ROLE's reach, not an affordance on the page under it, so it must not read
    # as one. "acting-as" is the operator-facing term the footer's own switcher already uses.
    {:tenant_drill_in, "Open a tenant drill-in (a per-account acting-as session)",
     "Also needs that session opened for the account, and the account in scope."},
    {:automation_manage, "Kill or re-arm a workflow or an agent",
     "Only reachable INSIDE an open tenant drill-in, so it needs the drill-in above too."},
    {:dlq_write, "Replay / resolve the webhook DLQ", nil},
    {:fleet_publish, "Publish a product on the fleet status page",
     "Also needs the fleet (`:fleet`) scope granted by the host."},
    # The register/enroll controls (`FleetRegisterLive`'s `with_admin/1`) are gated by the
    # SAME rule as publish (`@fleet_admin_roles`), but they are a DIFFERENT control on a
    # DIFFERENT page — `#register-not-admin` withholds THEM, so they get their own row
    # rather than pointing the reader at the status-page row and calling it an answer.
    {:fleet_register, "Register an app / mint an enrollment token",
     "Also needs the fleet (`:fleet`) scope granted by the host."},
    {:break_glass, "Emergency break-glass reveal", nil}
  ]

  # The ONLY two role sets this module RESTATES. Every other row is answered by CALLING the
  # capability's own predicate, so the panel cannot disagree with the enforcement. These two
  # have no pure role -> boolean predicate to call:
  #
  #   * the DLQ write set is private to `Samen.Web.Operator.WebhookDlqLive` (`@write_roles`),
  #     whose handler gate governs this surface and must not be re-located (a sabotage patch
  #     pins those lines);
  #   * the fleet ADMIN rule (`roles[:fleet] == :operator_admin`) lives inside
  #     `Samen.Web.Operator.Fleet` (`gate/2`'s `admin?`), reachable only through `gate/2` with
  #     a mount AND a session — and it gates BOTH fleet writes this panel names (the status
  #     page opt-in and register/enroll), which is why one set serves two rows.
  #
  # `operator_sidebar_role_test.exs` PINS them: it drives the REAL DLQ page, the REAL
  # `Fleet.gate/2` and the REAL register page for every operator role, and fails if either
  # restated set stops matching what those surfaces actually allow. Drift is caught by the
  # gate, not by review.
  @dlq_write_roles [:operator_admin, :operator_support]
  @fleet_admin_roles [:operator_admin]

  @doc """
  The capability matrix the role-help disclosure renders: one row per capability an operator role
  can hold, with the roles that hold it and whether THIS session's role does.

  Each row is:

      %{key: atom, label: String.t, why: String.t | nil,
        roles: [operator_role], role_labels: [String.t], mine?: boolean}

  `mine?` is false when no role was resolved for the session (a mount that never ran the
  on_mount) — the panel then renders the rows WITHOUT ✓/— marks rather than implying the
  session's role lacks everything.
  """
  @spec operator_capabilities(Samen.OperatorPlane.Actor.operator_role() | nil) :: [map()]
  def operator_capabilities(role \\ nil) do
    for {key, label, why} <- @capabilities do
      roles = Enum.filter(Actor.roles(), &holds_capability?(key, &1))

      %{
        key: key,
        label: label,
        why: why,
        roles: roles,
        role_labels: Enum.map(roles, &operator_role_short_label/1),
        mine?: is_atom(role) and role in roles
      }
    end
  end

  # The capability predicates — CALLED wherever one exists (so the panel is derived from the
  # enforcement, not a second opinion about it): `Actor.may_impersonate?/1` is exactly the gate
  # `Samen.Impersonation.open/4` applies before minting a session, `Health.may_manage?/1` is the
  # gate `Health.kill/3` + `Health.rearm/3` apply (`Samen.AI.Agent.Health.may_manage?/1` carries
  # the same set, and the test pins the two together), and `BreakGlass.authorized?/1` is the gate
  # `BreakGlass.reveal/1` applies. The remaining two rows are the restated-upstream pair
  # documented above.
  defp holds_capability?(:read_workspace, _role), do: true
  defp holds_capability?(:tenant_drill_in, role), do: Actor.may_impersonate?(role_actor(role))
  defp holds_capability?(:automation_manage, role), do: Health.may_manage?(role_actor(role))
  defp holds_capability?(:dlq_write, role), do: role in @dlq_write_roles
  defp holds_capability?(:fleet_publish, role), do: role in @fleet_admin_roles
  defp holds_capability?(:fleet_register, role), do: role in @fleet_admin_roles
  defp holds_capability?(:break_glass, role), do: BreakGlass.authorized?(role_actor(role))

  # A throwaway operator actor for a role probe. The id is inert — every predicate above reads
  # `operator_role` only (no routing/audit identifier is touched).
  defp role_actor(role), do: Actor.new("role-help", role)

  @doc "Dollars from cents, for the operator money columns."
  def dollars(cents) when is_integer(cents),
    do: "$#{:erlang.float_to_binary(cents / 100, decimals: 2)}"

  def dollars(_), do: "$0.00"

  @doc "Render a resolved PII value (plaintext string or `%Samen.Masked{}`) — NEVER unwraps."
  def render_name(%Samen.Masked{} = masked), do: masked

  def render_name(name) when is_binary(name) do
    case Jason.decode(name) do
      {:ok, %{"first" => first, "last" => last}} -> String.trim("#{first} #{last}")
      _ -> name
    end
  end

  def render_name(%Samen.Type.FullName{first: first, last: last}),
    do: String.trim("#{first} #{last}")

  def render_name(nil), do: "—"
  def render_name(other), do: other

  @doc "Render the first email of a resolved emails value — NEVER unwraps a `%Masked{}`."
  def render_email(%Samen.Masked{} = masked), do: masked
  def render_email(%Samen.Type.Emails{entries: entries}), do: render_email(entries)

  def render_email(json) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, list} when is_list(list) -> render_email(list)
      {:ok, %{"address" => addr}} -> addr
      _ -> json
    end
  end

  def render_email(list) when is_list(list) do
    case List.first(list) do
      %{"address" => addr} -> addr
      %{address: addr} -> addr
      _ -> "—"
    end
  end

  def render_email(_), do: "—"

  defp label(nil, _key, default), do: default
  defp label(%Mount{} = mount, key, default), do: Mount.label(mount, key, default)
end
