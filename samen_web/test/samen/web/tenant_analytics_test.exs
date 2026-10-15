defmodule Samen.Web.TenantAnalyticsTest do
  @moduledoc """
  P17 (ADR-045 §3) — the TENANT own-org analytics read (`Samen.Web.Tenant.AnalyticsReads`).
  Proves the covert-channel discipline the brief names, all at the read layer where the
  security lives:

    * **Sub-floor suppression (fail closed)** — a count-of-one own-org cohort is `⊘`
      (`%Suppressed{}`), never a raw count; a `>= k` cohort releases. The floor is the
      shipped `Samen.Aggregate.Privacy.apply/3`, REUSED (the `k:` override proves it is
      load-bearing — the anti-tautology flip).
    * **Cross-org isolation** — org A's read binds `paf_org_id` off its OWN authenticated
      scope; org B's rows are never in the result. No cohort spans orgs.
    * **Role gate (P17 Q3)** — a masked `:member` MAY query (insight-without-PII, the whole
      point), as do `:admin` and `:owner`; the read-only `:viewer` is refused, as is an
      org-less / role-less caller (`can_query?/1` fail-closed), and `funnel/3` returns `[]`.
    * **The four silences are never "no data yet"** (P17 fail-honest) — `read/3` names WHY it
      could not answer (`:no_org` / `:not_authorized` / `:not_configured` / `:read_failed`),
      and `unread: nil` is reserved for the ONE answered case (the rollup ran, zero rows).
    * **The MaskingCase twin** — the floor IS the intra-org masking enforcement: the SAME
      lower-privilege plane that resolves a subject's vault field to `••••` sees a
      count-of-one org cohort as `⊘`; NEUTER the floor (`k: 1`) and the count-of-one
      reconstructs ("exactly 1 subject reached this stage") — leak DETECTED.
  """
  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  alias Samen.Aggregate.Suppressed
  alias Samen.Web.Mount
  alias Samen.Web.Tenant.AnalyticsReads

  defp insert_paf!(org_id, stage, actor_count) do
    Ecto.Adapters.SQL.query!(
      Samen.WebTest.Repo,
      """
      INSERT INTO paf_product_event_rollup (paf_org_id, paf_kind, paf_stage, paf_actor_count)
      VALUES ($1, 'funnel', $2, $3)
      """,
      [Ecto.UUID.dump!(org_id), stage, actor_count]
    )
  end

  defp stage(funnel, name), do: Enum.find(funnel, &(&1.stage == name))

  # ---------------------------------------------------------------------------
  # Sub-floor suppression — the shipped floor, load-bearing
  # ---------------------------------------------------------------------------

  test "k-anon: a count-of-one own-org stage SUPPRESSES (⊘); a >= k stage RELEASES" do
    mount = build_mount(:crm)
    org = Ash.UUID.generate()
    scope = Mount.scope(mount, org)

    insert_paf!(org, "signup", 8)
    insert_paf!(org, "first_record", 1)

    funnel = AnalyticsReads.funnel(mount, scope, k: 5)

    assert %{actor_count: 8} = stage(funnel, "signup")
    lonely = stage(funnel, "first_record")
    assert Suppressed.suppressed?(lonely.actor_count)
    assert lonely.actor_count.reason == :k_anonymity
    assert to_string(lonely.actor_count) == Suppressed.glyph()
  end

  test "anti-tautology: neutering the floor (k: 1) RELEASES the count-of-one — the flip" do
    mount = build_mount(:crm)
    org = Ash.UUID.generate()
    scope = Mount.scope(mount, org)
    insert_paf!(org, "first_record", 1)

    assert Suppressed.suppressed?(stage(AnalyticsReads.funnel(mount, scope, k: 5), "first_record").actor_count)
    assert stage(AnalyticsReads.funnel(mount, scope, k: 1), "first_record").actor_count == 1
  end

  # ---------------------------------------------------------------------------
  # Cross-org isolation
  # ---------------------------------------------------------------------------

  test "cross-org: org A's read never sees org B's rows (org_id bound from the scope)" do
    mount = build_mount(:crm)
    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()
    scope_a = Mount.scope(mount, org_a)

    insert_paf!(org_a, "signup", 6)
    insert_paf!(org_b, "signup", 999_999)

    funnel = AnalyticsReads.funnel(mount, scope_a, k: 5)
    assert %{actor_count: 6} = stage(funnel, "signup")
    refute Enum.any?(funnel, &(&1.actor_count == 999_999))
  end

  # ---------------------------------------------------------------------------
  # Role gate (P17 Q3)
  # ---------------------------------------------------------------------------

  test "role gate: :owner/:admin/:member MAY query; :viewer and an org-less caller are refused" do
    for role <- [:owner, :admin, :member] do
      assert AnalyticsReads.can_query?(%{org_id: Ash.UUID.generate(), role: role}),
             "#{role} is at or above :member rank and must be able to query"
    end

    refute AnalyticsReads.can_query?(%{org_id: Ash.UUID.generate(), role: :viewer})
    refute AnalyticsReads.can_query?(%{role: :member})
    refute AnalyticsReads.can_query?(%{org_id: Ash.UUID.generate(), role: :guest})
    refute AnalyticsReads.can_query?(nil)
  end

  test "a caller who may not query gets [] (fail closed), even with seeded rows" do
    mount = build_mount(:crm)
    org = Ash.UUID.generate()
    insert_paf!(org, "signup", 8)
    orgless = %Samen.Scope{actor: %{id: "x", role: :member, plane: :tenant}}
    assert AnalyticsReads.funnel(mount, orgless, k: 1) == []
  end

  # ---------------------------------------------------------------------------
  # The four silences — one reason each, never an unobserved "no data yet"
  # ---------------------------------------------------------------------------

  test "read/3 names the silence: :no_org, :not_authorized, :not_configured, :read_failed" do
    mount = build_mount(:crm)
    org = Ash.UUID.generate()
    scope = Mount.scope(mount, org)

    # (1) the caller's authenticated scope carries no org → there is no own-org scope to read.
    orgless = %Samen.Scope{actor: %{id: "x", role: :member, plane: :tenant}}
    assert %{funnel: [], unread: :no_org} = AnalyticsReads.read(mount, orgless, k: 1)

    # (2) an org IS resolved, but the caller's REAL role is outside `queryable_roles/0`.
    viewer = %Samen.Scope{actor: %{id: "x", org_id: org, role: :viewer, plane: :tenant}}
    assert %{funnel: [], unread: :not_authorized} = AnalyticsReads.read(mount, viewer, k: 1)

    # (3) no mount at all — the host wired no seam for this read.
    assert %{funnel: [], unread: :not_configured} = AnalyticsReads.read(nil, scope, k: 1)

    # ANTI-TAUTOLOGY: an ANSWERED read is `unread: nil` — the empty answer is not a silence, and
    # the four reasons above cannot be reached by a caller the gate admits on a wired host.
    assert %{funnel: [], unread: nil} = AnalyticsReads.read(mount, scope, k: 1)
    assert AnalyticsReads.funnel(mount, scope, k: 1) == [],
           "`funnel/3` is the rows-only reader — every silence collapses to [] there, which is " <>
             "exactly why a surface must read `read/3`"
  end

  test "a rollup that cannot be read is :read_failed — never the 'no data yet' answer" do
    mount = build_mount(:crm)
    org = Ash.UUID.generate()
    scope = Mount.scope(mount, org)

    assert %{funnel: [], unread: nil} = AnalyticsReads.read(mount, scope),
           "the rollup table is present here, so this read ANSWERS (zero rows)"

    # An UNMIGRATED host's shape: the read's table is gone. Postgres DDL is transactional, so
    # the sandbox rollback at the end of this test restores it.
    Ecto.Adapters.SQL.query!(
      Repo,
      "ALTER TABLE paf_product_event_rollup RENAME TO paf_product_event_rollup_absent",
      []
    )

    assert %{funnel: [], unread: :read_failed} = AnalyticsReads.read(mount, scope),
           "a raised/errored rollup read must report :read_failed, not an empty org"
  end

  # ---------------------------------------------------------------------------
  # The MaskingCase twin — the floor IS the intra-org masking enforcement
  # ---------------------------------------------------------------------------

  test "twin: same lower-priv plane → •••• on the vault field AND ⊘ on the count-of-one; neuter → leak" do
    require Ash.Query
    seeded = Seeds.seed_all()
    org = seeded.org_id

    # Re-read the person with the vault-routed field SELECTED (not loaded by default) —
    # the same ensure_selected posture the framework Reads run before PiiResolution.
    person =
      Samen.WebTest.Crm.Person
      |> Ash.Query.filter(id == ^seeded.crm.person.id)
      |> Ash.Query.ensure_selected([:full_name])
      |> Ash.read_one!(authorize?: false)

    # (a) DIRECT field read on the operator-without-grant (lower-priv) plane → ••••.
    operator = resolve_on_plane(person, Samen.WebTest.Crm.Person, :operator, repo: Samen.WebTest.Repo)
    assert_plane_masked!(operator.full_name)

    # (b) The count-of-one org COHORT for the SAME org, same floor → ⊘.
    mount = build_mount(:crm)
    scope = Mount.scope(mount, org)
    insert_paf!(org, "first_record", 1)

    floored = stage(AnalyticsReads.funnel(mount, scope, k: 5), "first_record")
    assert Suppressed.suppressed?(floored.actor_count)
    assert to_string(floored.actor_count) == Suppressed.glyph()

    # (c) SABOTAGE flip: neuter the floor → the count-of-one reconstructs (leak detected).
    #     "exactly 1 subject reached first_record" is the re-identifying fact the floor withheld.
    leaked = stage(AnalyticsReads.funnel(mount, scope, k: 1), "first_record")
    assert leaked.actor_count == 1
    refute Suppressed.suppressed?(leaked.actor_count)
  end

  # ---------------------------------------------------------------------------
  # The LiveView renderer (direct load + render — no router integration needed)
  # ---------------------------------------------------------------------------

  alias Samen.Web.Tenant.AnalyticsLive

  defp render_funnel(org) do
    mount = build_mount(:crm)

    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> AnalyticsLive.load(org)
    |> then(&render_html(AnalyticsLive, &1.assigns))
  end

  test "LiveView render: a >= k stage shows its count; a count-of-one stage renders ⊘, never the value" do
    org = Ash.UUID.generate()
    insert_paf!(org, "signup", 8)
    insert_paf!(org, "first_record", 1)

    html = render_funnel(org)

    assert html =~ "Signed up"
    assert html =~ ">8<"
    # the count-of-one stage suppresses — ⊘ present, the withheld "1" never rendered as a count
    assert html =~ "⊘"
    assert html =~ "suppressed to prevent re-identification"
    refute html =~ ~r/first-record.*>1</s
  end

  # The states: every silence is itself, and the ONE answered case is the only empty state.
  defp render_surface(assigns, mount \\ nil) do
    mount = mount || build_mount(:crm)

    base = %{
      funnel: [],
      suppressed_count: 0,
      unread: nil,
      org_id: Ash.UUID.generate(),
      samen_mount: mount,
      # The shared shell's impersonation banner reads this on every render (`load/2` defaults it
      # for a session that carried no mount); a direct render has to state it.
      samen_acting_as: false
    }

    assigns = Map.merge(base, assigns)

    render_html(
      AnalyticsLive,
      Map.put(assigns, :next_step, AnalyticsLive.unread_next_step(assigns.unread, mount, assigns.org_id))
    )
  end

  # The `build_mount/2` shape plus the seams a HOST declares (the next-step destinations this
  # surface is allowed to link to).
  defp labelled_mount(labels), do: %{build_mount(:crm) | labels: labels}

  test "LiveView render: no org resolved → the HONEST no-org state, never the empty state" do
    html = render_funnel(nil)

    assert html =~ "analytics-unread"
    assert html =~ ~s(data-unread-reason="no_org")
    refute html =~ "analytics-empty",
           "a session with no org says so — it must never claim the org has no activation data"
    refute html =~ "funnel-table"
  end

  test "LiveView render: a session with no mount → the not-configured state, never a crash" do
    org = Ash.UUID.generate()

    html =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, nil)
      |> AnalyticsLive.load(org)
      |> then(&render_html(AnalyticsLive, &1.assigns))

    assert html =~ ~s(data-unread-reason="not_configured")
    refute html =~ "analytics-empty"
  end

  test "LiveView render: every silence is a DISTINCT state — and never the empty state" do
    for reason <- [:no_org, :not_authorized, :not_configured, :read_failed] do
      html = render_surface(%{unread: reason})

      assert html =~ "analytics-unread", "#{reason} did not render the unread state"
      assert html =~ ~s(data-read-state="unread")
      assert html =~ ~s(data-unread-reason="#{reason}")
      refute html =~ "analytics-empty",
             "#{reason} rendered 'No activation data yet' — a fact about the org's data " <>
               "that this read never observed"
      refute html =~ "funnel-table"
    end
  end

  test "LiveView render: the ANSWERED empty state is a measurement, and is never the unread state" do
    html = render_surface(%{unread: nil})

    assert html =~ "analytics-empty"
    refute html =~ "data-read-state=\"unread\"",
           "the answered empty state must not be dressed as a read failure (nor vice versa)"
  end

  test "LiveView render: the refusal state names the role and renders no cell at all" do
    html = render_surface(%{unread: :not_authorized})

    assert html =~ "does not include activation analytics"
    refute html =~ "funnel-table"
    refute html =~ "f-count",
           "nothing was read, so no count cell — not even a suppressed one — may render"
  end

  # ---------------------------------------------------------------------------
  # The chrome — the message belongs to the PAGE, in the main panel beside the sidebar
  # ---------------------------------------------------------------------------

  test "every state renders INSIDE the main panel of the shared shell — never as a bare viewport" do
    for reason <- [:no_org, :not_authorized, :not_configured, :read_failed, nil] do
      html = render_surface(%{unread: reason})

      # The two-pane shell (sidebar + main) is what every other tenant page mounts…
      assert html =~ ~s(<div class="app">), "#{inspect(reason)} rendered outside the app shell"
      assert html =~ ~s(class="side"), "#{inspect(reason)} rendered with no sidebar beside it"
      # …and the page's own state is inside <main>, i.e. in the pane BESIDE that sidebar, not
      # loose on the viewport (the cosmetic defect: a warning that floats outside the main area).
      assert html =~ ~r/<main class="main">.*id="tenant-analytics"/s,
             "#{inspect(reason)} rendered the page outside the main panel"
    end

    unread = render_surface(%{unread: :not_authorized})
    assert unread =~ ~r/<main class="main">.*analytics-unread/s

    answered = render_surface(%{unread: nil})
    assert answered =~ ~r/<main class="main">.*id="analytics-empty"/s
  end

  # The reader-facing sentence per state: the warning has to be COMPREHENSIBLE, which is an
  # assertion on the words, not only on the token beside them.
  test "one plain-language sentence per silence — a tenant can tell what happened and what to do" do
    states = [
      {:no_org, "No organization is selected."},
      {:not_authorized, "Your role does not include activation analytics."},
      {:not_configured, "Activation analytics is not set up on this app."},
      {:read_failed, "We could not read your activation data."}
    ]

    for {reason, title} <- states do
      html = render_surface(%{unread: reason})
      assert html =~ title, "#{reason} did not state what happened in plain words"
    end

    # The answered empty state says what the zero IS (a measurement), and none of the four
    # silences may borrow its sentence.
    answered = render_surface(%{unread: nil})
    assert answered =~ "No activation data yet."
    assert answered =~ "it came back with no rows"

    for {reason, _title} <- states do
      refute render_surface(%{unread: reason}) =~ "it came back with no rows",
             "#{reason} claimed the measured empty result it never observed"
    end
  end

  # ---------------------------------------------------------------------------
  # Every silence names the step that clears it (the WHY is half the fix)
  # ---------------------------------------------------------------------------

  test "a refused role is handed the ONE step that clears it — the org's team settings" do
    org = Ash.UUID.generate()
    mount = labelled_mount(%{settings_path: "/settings"})

    html = render_surface(%{unread: :not_authorized, org_id: org}, mount)

    assert html =~ ~s(id="unread-next-not_authorized")
    assert html =~ ~s(href="/settings/invitations?org=#{org}"),
           "a refused member must be given the page where a role is actually granted"
  end

  test "a host that declares no settings path still STATES the step, without inventing an href" do
    html = render_surface(%{unread: :not_authorized})

    assert html =~ ~s(id="unread-next-not_authorized")
    assert html =~ "Ask an owner of this org to raise your role"

    # The dead-link guard: label PRESENCE is what makes the route real, so an undeclared path
    # must never become the STEP's href (a 404 dressed as a fix). Scoped to the step's OWN node
    # on purpose — the inherited SIDEBAR beside it legitimately links the Settings group, and a
    # bare `href="/settings` grep would fail on the chrome rather than on the next step.
    refute html =~ ~r|<a[^>]*id="unread-next-not_authorized"|
    refute html =~ ~r|<a[^>]*unread-next-step|
  end

  test "the wiring gap and the failed read name their doc — linked only under a declared docs base" do
    mount = build_mount(:crm)

    for {reason, doc} <- [
          {:not_configured, "docs/ws-analytics/p17-tenant-analytics-design.md"},
          {:read_failed, "docs/runbooks/alerts.md"}
        ] do
      html = render_surface(%{unread: reason}, mount)

      assert html =~ ~s(id="unread-next-#{reason}")
      assert html =~ doc, "#{reason} must NAME the doc to open"

      # No docs base declared → the reference is NAMED, never a href to a relative path.
      refute html =~ ~r/href="[^"]*docs\//
    end

    # A host that declares where its docs live gets a real link instead.
    linking = labelled_mount(%{docs_base: "https://docs.example.test/samen/"})

    html = render_surface(%{unread: :read_failed}, linking)
    assert html =~ ~s(href="https://docs.example.test/samen/docs/runbooks/alerts.md")

    html = render_surface(%{unread: :not_configured}, linking)

    assert html =~
             ~s(href="https://docs.example.test/samen/docs/ws-analytics/p17-tenant-analytics-design.md")
  end

  test "a state with no honest next step renders no affordance at all" do
    # There is no org to act on, so every "fix" would be a fact about a session this page never
    # resolved — the page says so and stops there.
    html = render_surface(%{unread: :no_org})

    assert html =~ ~s(data-unread-reason="no_org")
    refute html =~ ~s(id="unread-next-")

    # …and the ANSWERED empty state is a measurement, not a gap: no next step either.
    answered = render_surface(%{unread: nil})
    assert answered =~ "analytics-empty"
    refute answered =~ "unread-next-"
  end

  test "the load/2 WIRING carries the step — a mount-less session surfaces the mount docs" do
    org = Ash.UUID.generate()

    html =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, nil)
      |> AnalyticsLive.load(org)
      |> then(&render_html(AnalyticsLive, &1.assigns))

    assert html =~ ~s(data-unread-reason="not_configured")
    assert html =~ ~s(id="unread-next-not_configured")
    assert html =~ "docs/ws-analytics/p17-tenant-analytics-design.md"
  end
end
