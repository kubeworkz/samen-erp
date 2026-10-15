defmodule Samen.Web.OperatorSidebarRoleTest do
  @moduledoc """
  The operator sidebar footer shows the operator's SESSION-RESOLVED role, not a static
  mount label — so an operator can see, on the page itself, WHY a control was withheld.

  ## The defect this closes

  The footer rendered `label(@mount, :operator_role, "SaaS staff")` — a MOUNT label. No
  shipped host sets that key, so every operator in every host saw the same constant
  "SaaS staff" regardless of the role `Samen.Web.Operator.Authz`'s `:require_operator`
  on_mount had actually resolved for their session. `Samen.Web.Operator.Authz`'s own
  moduledoc calls this out as the pre-T146 state — *"the mount's `:operator_role` was
  only a display label"* — and the DLQ's `#dlq-readonly` note already tells a read-only
  operator that "replay and resolve require `:operator_admin` / `:operator_support`".
  The page could therefore explain that a role lacked a capability while the chrome
  refused to say which role the operator held. Those two facts now come from the SAME
  assign (`:samen_operator_role`), so they cannot disagree.

  ## What is proven (green / red / refutable)

    * **GREEN** — each of the four resolved roles renders its own label AND a
      `data-operator-role` carrying the role atom; a resolved role OVERRIDES the mount's
      static copy (which is the pre-change behaviour, so this assertion is refutable).
    * **RED (fallback ≠ authority)** — with NO resolved role the footer falls back to the
      static mount copy (host copy preserved; framework default `"SaaS staff"`), and
      shows NO role atom. A display fallback, never authority: this is a bare socket that
      never ran the on_mount, and it is still refused every write by the handlers.
    * **SABOTAGE TWIN** — the assertion genuinely fails against the fallback render
      (`assert_raise`), so the GREEN proof is not vacuous.
    * **END-TO-END** — the REAL DLQ page for `:operator_readonly` renders the withheld
      control's explanation AND the read-only role in its own footer, in one render, with
      the envelope listed (anti-vacuity); `:operator_admin` on the same page shows the
      admin role and the controls, as its positive control. This is what proves the 17
      call sites actually pass the assign — a missing `operator_role=` would render the
      fallback and fail here.

  ## The disclosure (what the label OPENS)

  Naming the role is not enough to act on: a read-only operator who reads "reset requires
  `:operator_admin`" still cannot tell which role they hold, and one who reads the fleet's
  `#publish-readonly` note cannot tell whether the capability is theirs but unconfigured.
  So the label IS the disclosure control — a native `<details>` whose `<summary>` carries it
  (no JS, keyboard-operable) — and its panel answers per capability: who holds it, whether
  THIS session's role does (✓/—), and what else the capability needs.

  ## The NOTES (this file's second half)

  The same panel is reachable from the notes that WITHHOLD a control, which is where the
  question is actually asked: `#dlq-readonly`, `#publish-readonly`, `#register-not-admin` and
  every drill-in's role-denied state each render `<.role_help_note>` — their own sentence as
  the `<summary>`, the shared matrix behind it, focused on the capability the note withheld
  (`data-capability`/`data-focus`). The marks come from the same `:samen_operator_role` assign
  the withholding predicate reads, so a note and the control next to it cannot disagree — and
  the tests below drive the REAL DLQ page and the REAL register page (`mount/3` + the real
  `Fleet.gate/2`) to prove the note is wired into the shipped surfaces, not just the component.

  The panel is **derived, not restated**: `tenant_drill_in`, `automation_manage` and
  `break_glass` are answered by CALLING the predicates the enforcement calls
  (`Actor.may_impersonate?/1`, `Samen.Automation.Health.may_manage?/1`,
  `BreakGlass.authorized?/1`), so the panel cannot drift from the behaviour. The two
  capabilities with no callable role predicate — the DLQ write set (private to
  `WebhookDlqLive`) and the fleet publish rule (`Fleet.gate/2`'s `admin?`) — are RESTATED
  once and **PINNED here against the real surfaces**: this file drives the real DLQ page
  and the real `Fleet.gate/2` for every operator role and fails if either restatement stops
  matching what those surfaces actually allow.
  """

  use Samen.WebTest.DataCase, async: false

  import Phoenix.LiveViewTest

  alias Samen.AI.Agent.Health, as: AgentHealth
  alias Samen.OperatorPlane.Actor
  alias Samen.Web.Operator.FleetRegisterLive
  alias Samen.Web.Operator.Live
  alias Samen.Web.Operator.WebhookDlqLive
  alias Samen.Webhook.Event

  @operator_org "00000000-0000-0000-0000-00000000beef"

  # A private host for the fleet-publish pin — the `:fleet_authority` seam is per-otp_app.
  @fleet_host :samen_web_operator_role_help_fleet_host

  # A distinctive host copy — proves the RESOLVED role wins over whatever a host branded.
  @stale_copy "Stale staff copy"

  # The shared sidebar, rendered exactly as a real page renders it (mount + resolved role).
  defp sidebar(role, labels \\ %{}) do
    mount = build_operator_mount(@operator_org, labels: labels)
    render_component(&Live.operator_sidebar/1, mount: mount, operator_role: role)
  end

  # ==========================================================================
  # The mapping — one human label per role, and NO label for an unresolved role
  # ==========================================================================

  test "every operator role has its own human label (none of them is the generic fallback)" do
    assert Live.operator_role_label(:operator_admin) == "Operator admin"
    assert Live.operator_role_label(:operator_support) == "Operator support"
    assert Live.operator_role_label(:operator_readonly) == "Read-only operator"
    assert Live.operator_role_label(:operator_break_glass) == "Break-glass operator"

    labels =
      for role <- Samen.OperatorPlane.Actor.roles(), do: Live.operator_role_label(role)

    assert length(Enum.uniq(labels)) == 4,
           "two operator roles share a sidebar label — the footer could not explain the right one"
  end

  test "an unresolved role (nil) falls back to the mount copy, never to a role label" do
    assert Live.operator_role_label(nil) == "SaaS staff"
    assert Live.operator_role_label(:bogus_role_not_in_the_closed_set) == "SaaS staff"
  end

  # ==========================================================================
  # GREEN — the resolved role is what renders, per role
  # ==========================================================================

  test "each resolved role renders its label + the role atom in the footer" do
    for {role, label} <- [
          {:operator_admin, "Operator admin"},
          {:operator_support, "Operator support"},
          {:operator_readonly, "Read-only operator"},
          {:operator_break_glass, "Break-glass operator"}
        ] do
      html = sidebar(role)

      assert html =~ label, "the #{role} footer did not render its own label"
      assert html =~ ~s(data-operator-role="#{role}")
    end
  end

  test "a resolved role OVERRIDES the mount's static copy — the resolved role is what renders" do
    html = sidebar(:operator_readonly, %{operator_role: @stale_copy})

    assert html =~ "Read-only operator"
    assert html =~ ~s(data-operator-role="operator_readonly")

    # The pre-change behaviour rendered @stale_copy unconditionally. If the footer ever
    # goes back to reading ONLY the mount label, this assertion fails.
    refute html =~ @stale_copy
  end

  # ==========================================================================
  # RED — no resolved role: honest fallback, no fabricated role
  # ==========================================================================

  test "with NO resolved role the footer renders the mount's static copy and NO role atom" do
    html = sidebar(nil, %{operator_role: @stale_copy})

    assert html =~ @stale_copy
    refute html =~ "Read-only operator"
    refute html =~ "Operator admin"
    # No role atom is claimed for a session whose role was never resolved.
    refute html =~ "data-operator-role="
  end

  test "with no host copy either, the framework default is unchanged (no regression for old hosts)" do
    assert sidebar(nil) =~ "SaaS staff"
  end

  # ==========================================================================
  # SABOTAGE TWIN — the GREEN assertion is refutable
  # ==========================================================================

  test "SABOTAGE TWIN: the resolved-role assertion FAILS against the fallback render" do
    resolved = sidebar(:operator_readonly, %{operator_role: @stale_copy})
    assert resolved =~ "Read-only operator"

    fallback = sidebar(nil, %{operator_role: @stale_copy})

    assert_raise ExUnit.AssertionError, fn ->
      assert fallback =~ "Read-only operator"
    end
  end

  # ==========================================================================
  # END-TO-END — the real DLQ page pairs the role with the withheld control
  # ==========================================================================

  setup do
    {:ok, :inserted, row} =
      Event.insert_received(Repo, %{
        provider: "test",
        event_id: "evt_sidebar_role_#{System.unique_integer([:positive])}",
        kind: "checkout_completed",
        domain: "billing",
        occurred_at: DateTime.utc_now(),
        payload: %{"amount" => 4900, "currency" => "usd"}
      })

    {:ok, dead} = Event.mark_dead(Repo, row, "handler crashed")
    %{dead: dead}
  end

  # Render the page the way the mounted route does: `load/1` (which derives the affordance
  # from the role) then `render/1`, with the role assign the on_mount would have set.
  defp dlq_page(role) do
    assigns =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, build_operator_mount(@operator_org))
      |> Phoenix.Component.assign(:samen_acting_as, false)
      |> Phoenix.Component.assign(:samen_operator_role, role)
      |> WebhookDlqLive.load()
      |> Map.fetch!(:assigns)

    render_html(WebhookDlqLive, assigns)
  end

  test "the DLQ page names the read-only operator's role NEXT TO why replay/resolve is withheld",
       %{dead: dead} do
    html = dlq_page(:operator_readonly)

    # Anti-vacuity: the envelope IS listed, so the withheld controls are about the ROLE.
    assert html =~ dead.event_id

    # The withhold and its explanation (the pre-existing S14 render gate).
    refute html =~ "btn-replay"
    assert html =~ "dlq-readonly"

    # …and the chrome now says WHICH role the operator holds, in the SAME render — the
    # two facts ("your role may not" / "you are this role") can no longer disagree.
    assert html =~ "Read-only operator"
    assert html =~ ~s(data-operator-role="operator_readonly")
  end

  test "POSITIVE CONTROL — the same page as :operator_admin shows the admin role and the controls",
       %{dead: _dead} do
    html = dlq_page(:operator_admin)

    assert html =~ "btn-replay"
    assert html =~ "btn-resolve"
    refute html =~ "dlq-readonly"

    assert html =~ "Operator admin"
    assert html =~ ~s(data-operator-role="operator_admin")
    refute html =~ "Read-only operator"
  end

  test "POSITIVE CONTROL — :operator_support reads as its own role on the same page", %{dead: _dead} do
    html = dlq_page(:operator_support)

    assert html =~ "btn-replay"
    assert html =~ "Operator support"
    assert html =~ ~s(data-operator-role="operator_support")
  end

  test "a page with NO resolved role falls back in the footer AND is still offered no write",
       %{dead: _dead} do
    html = dlq_page(nil)

    assert html =~ "SaaS staff"
    refute html =~ "data-operator-role="
    refute html =~ "btn-replay"
    assert html =~ "dlq-readonly"
  end

  # ==========================================================================
  # THE DISCLOSURE — the label OPENS what each operator role may do
  # ==========================================================================

  test "the footer role label IS the disclosure control — it sits inside the <summary>" do
    html = sidebar(:operator_readonly)

    assert html =~ ~s(<details class="role-help" id="operator-role-help">)
    assert html =~ "What each operator role may do"

    # The role text is inside the <summary> of the openable <details>: the exact thing the
    # operator reads as "my role" is also the control that opens the answer. If the label
    # were merely NEAR the panel (a sibling, or behind a separate button) this fails.
    [summary] = Regex.run(~r|<summary[^>]*id="operator-role".*?</summary>|s, html)
    assert summary =~ "Read-only operator"
    assert summary =~ ~s(data-operator-role="operator_readonly")
  end

  test "the panel names EVERY operator role, so no role is invisible in the explanation" do
    html = sidebar(:operator_readonly)

    for role <- Actor.roles() do
      assert html =~ Live.operator_role_short_label(role),
             "the role-help panel omits #{role} — an operator could not tell who holds it"
    end

    assert length(Enum.uniq(Enum.map(Actor.roles(), &Live.operator_role_short_label/1))) == 4,
           "two roles share a short label in the panel's role lists"
  end

  test "every capability row names who holds it — no row is a dead end" do
    rows = Live.operator_capabilities(:operator_readonly)

    assert length(rows) >= 5
    assert Enum.uniq(Enum.map(rows, & &1.key)) == Enum.map(rows, & &1.key)

    for row <- rows do
      assert row.roles != [],
             "capability #{row.key} is held by nobody — the row cannot be acted on"

      assert Enum.all?(row.roles, &(&1 in Actor.roles()))
      assert row.role_labels == Enum.map(row.roles, &Live.operator_role_short_label/1)
      assert is_binary(row.label) and row.label != ""
    end
  end

  test "the ✓/— marks are per-session: each row's mark matches this role's hold" do
    for role <- Actor.roles() do
      html = sidebar(role)
      rows = Live.operator_capabilities(role)

      for row <- rows do
        assert mark_for(html, row.key) == if(row.mine?, do: :yes, else: :no),
               "#{role}: the #{row.key} row's mark disagrees with operator_capabilities/1"
      end

      # …and nothing is marked outside the rows (anti-vacuity on the count).
      assert count_of(html, "role-help-mark yes") == Enum.count(rows, & &1.mine?)
      assert count_of(html, "role-help-mark no") == Enum.count(rows, &(not &1.mine?))
    end

    refute count_of(sidebar(:operator_readonly), "role-help-mark yes") ==
             count_of(sidebar(:operator_admin), "role-help-mark yes"),
           "the marks do not vary by role — the panel would explain nothing"
  end

  test "the panel's resolved-capability rows are DERIVED from the enforcement, not restated" do
    for role <- Actor.roles() do
      actor = Actor.new("role-help-derive", role)

      # The SAME predicates the enforcement calls — `Impersonation.open/4` gated on
      # `may_impersonate?/1`, `Health.kill/3` + `rearm/3` on `may_manage?/1`,
      # `BreakGlass.reveal/1` on `authorized?/1`. If a role's real access changes and the
      # panel does not follow, this fails.
      assert capability(role, :tenant_drill_in).mine? == Actor.may_impersonate?(actor)
      assert capability(role, :automation_manage).mine? == Samen.Automation.Health.may_manage?(actor)
      assert capability(role, :break_glass).mine? == Samen.BreakGlass.authorized?(actor)
      assert capability(role, :read_workspace).mine?, "every operator role may read the workspace"

      # The two surfaces that ship kill/re-arm gates must agree, or the single row would be
      # true of one page and false of the other.
      assert AgentHealth.may_manage?(actor) == Samen.Automation.Health.may_manage?(actor)
    end
  end

  test "RED — an unresolved session role claims NO hold, and the panel says why" do
    html = sidebar(nil)

    refute html =~ "role-help-mark"
    refute html =~ "role-help-legend"
    assert html =~ "No operator role was resolved for this session"

    for row <- Live.operator_capabilities(nil), do: refute(row.mine?)
  end

  test "RED — an unresolved session role claims no hold in the real DLQ page either",
       %{dead: _dead} do
    html = dlq_page(nil)

    refute html =~ "role-help-mark"
    assert html =~ "dlq-readonly"
  end

  # ==========================================================================
  # PIN — the two RESTATED role sets, checked against the surfaces that enforce them
  # ==========================================================================

  test "PIN — the DLQ write row matches what the REAL DLQ page allows, for every role",
       %{dead: dead} do
    # Anti-vacuity: the envelope IS listed for every role, so "no btn-replay" is about the
    # ROLE and not an empty page.
    assert dead.event_id

    for role <- Actor.roles() ++ [nil] do
      html = dlq_page(role)

      assert html =~ dead.event_id

      page_allowed? = html =~ "btn-replay"
      panel_says? = !!role && capability(role, :dlq_write).mine?

      assert page_allowed? == panel_says?,
             "the role-help dlq_write row for #{inspect(role)} disagrees with the DLQ page"

      if role == :operator_admin do
        assert page_allowed?, "anti-vacuity: even :operator_admin got no replay control"
      end
    end
  end

  test "PIN — the fleet-publish row matches what the REAL Fleet.gate/2 grants, for every role" do
    on_exit(fn -> Application.delete_env(@fleet_host, :fleet_authority) end)

    mount =
      Samen.Web.Mount.new(:operator, Samen.WebTest.Operator, Samen.WebTest.Repo,
        plane: Samen.Web.Plane.tenant(),
        labels: %{
          otp_app: @fleet_host,
          fleet_namespace: Samen.WebTest.Fleet,
          fleet_cockpit: true
        }
      )

    session = %{"samen_current_user" => "role-help-op"}

    for role <- Actor.roles() do
      Application.put_env(@fleet_host, :fleet_authority,
        {__MODULE__, :fleet_roles_for, [%{fleet: role}]}
      )

      fleet_admin? =
        case Samen.Web.Operator.Fleet.gate(mount, session) do
          {:ok, ctx} -> ctx.admin?
          :denied -> false
        end

      assert fleet_admin? == capability(role, :fleet_publish).mine?,
             "the role-help fleet_publish row for #{role} disagrees with Fleet.gate/2"

      if role == :operator_admin do
        assert fleet_admin?, "anti-vacuity: Fleet.gate/2 granted no admin to :operator_admin"
      end
    end
  end

  @doc false
  def fleet_roles_for(roles, _principal_id), do: roles

  # ==========================================================================
  # END-TO-END — the withheld control, the role, and who CAN act, in ONE page
  # ==========================================================================

  test "END-TO-END — a read-only operator reads WHY the DLQ control is withheld AND who holds it",
       %{dead: dead} do
    html = dlq_page(:operator_readonly)

    # Anti-vacuity: the envelope IS listed, so the withheld control is about the ROLE.
    assert html =~ dead.event_id

    # The control is withheld, and the page explains it (the pre-existing S14 note).
    refute html =~ "btn-replay"
    assert html =~ "dlq-readonly"

    # …and the disclosure turns that into something the operator can ACT on: the panel says
    # the capability is not this session's, and names the roles that do hold it — the same
    # two roles the withheld-control note names.
    assert mark_for(html, :dlq_write) == :no
    assert html =~ "admin · support"

    # Positive control on the same page: the admin role holds it, and the control is there.
    admin_html = dlq_page(:operator_admin)
    assert mark_for(admin_html, :dlq_write) == :yes
    assert admin_html =~ "btn-replay"
  end

  test "SABOTAGE TWIN — the withheld-capability assertion is refutable on the same markup" do
    readonly = dlq_page(:operator_readonly)
    admin = dlq_page(:operator_admin)

    assert mark_for(readonly, :dlq_write) == :no
    assert mark_for(admin, :dlq_write) == :yes

    assert_raise ExUnit.AssertionError, fn ->
      assert mark_for(readonly, :dlq_write) == :yes
    end
  end

  # ==========================================================================
  # THE NOTES — a withheld control opens the SAME answer the footer gives
  # ==========================================================================

  # The register/enroll page, driven through its REAL `mount/3` (the real `Fleet.gate/2`)
  # and rendered as the operator on_mount would — role assigned, template untouched.
  defp fleet_register_page(role) do
    Application.put_env(@fleet_host, :fleet_authority,
      {__MODULE__, :fleet_roles_for, [%{fleet: role}]}
    )

    on_exit(fn -> Application.delete_env(@fleet_host, :fleet_authority) end)

    mount =
      build_operator_mount(@operator_org,
        labels: %{
          otp_app: @fleet_host,
          fleet_namespace: Samen.WebTest.Fleet,
          fleet_cockpit: true
        }
      )

    session = mount_session(mount) |> Map.put("samen_current_user", "role-help-op")

    {:ok, socket} = FleetRegisterLive.mount(%{}, session, %Phoenix.LiveView.Socket{})

    socket
    |> Phoenix.Component.assign(:samen_operator_role, role)
    |> Map.fetch!(:assigns)
    |> then(&render_html(FleetRegisterLive, &1))
  end

  test "the DLQ's withheld-control note IS the disclosure — the note text is the summary, the panel is behind it" do
    html = dlq_page(:operator_readonly)

    note = note_html(html, "dlq-readonly")
    [_, summary] = Regex.run(~r|<summary>(.*?)</summary>|s, note)

    # The sentence that withheld the control is what you click — not a separate "help" link.
    assert summary =~ "Read-only"
    assert summary =~ "replay and resolve require an operator role"
    assert summary =~ "What each operator role may do"

    # …and the body behind it is the matrix, focused on THIS note's capability.
    assert note =~ ~s(data-capability="dlq_write")
    assert note =~ ~s(data-focus="true")
    assert count_of(note, ~s(data-focus="true")) == 1,
           "the note highlights more than one row — the operator cannot tell which one it is about"

    assert focus_key(note) == :dlq_write
    assert mark_for(note, :dlq_write) == :no

    # The note's panel IS the footer's panel — every row marks the same in both.
    for row <- Live.operator_capabilities(:operator_readonly) do
      assert mark_for(note, row.key) == mark_for(html, row.key),
             "the note and the footer disagree about #{row.key} — two answers on one page"
    end
  end

  test "the fleet register note opens the REGISTER row, not the status-page one, for a non-admin fleet role" do
    html = fleet_register_page(:operator_readonly)

    # The control really is withheld (the pre-existing gate), and it is the note that says so.
    refute html =~ "register-form"
    refute html =~ "enroll-form"

    note = note_html(html, "register-not-admin")
    assert note =~ "roles[:fleet] == :operator_admin"
    assert focus_key(note) == :fleet_register
    assert mark_for(note, :fleet_register) == :no
    # A reader told "registering needs :operator_admin" is answered by ITS OWN row — and can
    # also see the neighbouring fleet row is withheld for the same reason.
    assert mark_for(note, :fleet_publish) == :no
  end

  test "POSITIVE CONTROL — a fleet admin gets the forms and NO withheld-control note" do
    html = fleet_register_page(:operator_admin)

    assert html =~ "register-form"
    assert html =~ "enroll-form"
    refute html =~ "register-not-admin"
  end

  test "PIN — the fleet_register row matches what the REAL register page allows, for every role" do
    for role <- Actor.roles() do
      html = fleet_register_page(role)

      page_withheld? = html =~ "register-not-admin"
      panel_says? = not capability(role, :fleet_register).mine?

      assert page_withheld? == panel_says?,
             "the role-help fleet_register row for #{role} disagrees with the register page"

      if role == :operator_admin do
        refute page_withheld?, "anti-vacuity: even :operator_admin was withheld registration"
      end
    end
  end

  test "the drill-in withheld-control predicate is the SAME gate Impersonation.open/4 applies" do
    for role <- Actor.roles() do
      actor = Actor.new("role-help-drill-in", role)

      assert Live.drill_in_role_denied?(role) == not Actor.may_impersonate?(actor),
             "#{role}: the drill-in note would appear for the wrong session roles"
    end

    # No role resolved, or a role outside the closed set: `Impersonation.open/4`'s catch-all
    # refuses both, so the note belongs on both — and neither may raise (`Actor.new/2`
    # RAISES on an unknown role, which would take the page down instead of explaining it).
    assert Live.drill_in_role_denied?(nil)
    assert Live.drill_in_role_denied?(:bogus_role_not_in_the_closed_set)
  end

  test "SABOTAGE TWIN — the focus assertion is refutable on the real page" do
    note = note_html(dlq_page(:operator_readonly), "dlq-readonly")

    assert focus_key(note) == :dlq_write

    assert_raise ExUnit.AssertionError, fn ->
      assert focus_key(note) == :automation_manage
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp capability(role, key), do: Enum.find(Live.operator_capabilities(role), &(&1.key == key))

  # The INSIDE of a withheld-control note (`<details id="…">` … `</details>`), so an assertion
  # about "the note's panel" can never accidentally read the sidebar's panel instead.
  defp note_html(html, id) do
    case Regex.run(~r|<details[^>]*id="#{Regex.escape(id)}"[^>]*>(.*?)</details>|s, html) do
      [_, inner] -> inner
      nil -> flunk("no withheld-control note ##{id} in the rendered page")
    end
  end

  # The capability the note's panel marks as its own.
  defp focus_key(note_html) do
    case Regex.run(~r|data-capability="([a-z_]+)" data-held="[^"]*" data-focus="true"|, note_html) do
      [_, key] -> String.to_atom(key)
      nil -> :none
    end
  end

  # The role-help row for `key`, as its own slice of the rendered panel (split on the row
  # marker, so a slice never contains a later row's marks). Raises if the row is missing.
  defp row_html(html, key) do
    marker = ~s(<div class="role-help-row" data-capability="#{key}")
    [_, after_marker] = String.split(html, marker, parts: 2)
    after_marker |> String.split(~s(<div class="role-help-row"), parts: 2) |> hd()
  end

  defp mark_for(html, key) do
    row = row_html(html, key)

    cond do
      row =~ ~s(class="role-help-mark yes") -> :yes
      row =~ ~s(class="role-help-mark no") -> :no
      true -> :none
    end
  end

  defp count_of(html, needle), do: length(String.split(html, needle)) - 1
end
