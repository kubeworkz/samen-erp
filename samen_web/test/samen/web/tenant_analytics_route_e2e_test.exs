defmodule Samen.Web.TenantAnalyticsRouteE2ETest do
  @moduledoc """
  P17 (ADR-045 §3, P17-carry-2) — the tenant own-org analytics surface, driven END-TO-END
  through a REAL router + endpoint (`Samen.WebTest.SecurityEndpoint`), not just at the read
  layer.

  ## The coverage gap this closes (P17 verdict residual #2)

  `tenant_analytics_test.exs` proved the SECURITY of `Samen.Web.Tenant.AnalyticsReads` — the
  org-scoped floor, the cross-org read isolation, the role gate — but every one of those
  assertions ran against the read layer (`AnalyticsReads.funnel/3`) or `AnalyticsLive.load/2`
  DIRECTLY. The `samen_tenant_analytics_routes` macro was mounted by NO router any suite
  exercised, so the `{Samen.Web.TenantAuthz, :require_tenant}` on_mount and the
  `Samen.Web.CurrentOrg` org-authority pinning on THIS route were asserted only by
  construction — the `?org=`-forge was never refused end-to-end through a real mount.

  This suite mounts the macro on the driftwood-shaped armed host (`Samen.WebTest.SecurityRouter`)
  and drives `/analytics` through the endpoint. It proves, on an ARMED host:

    * **(a) the route mounts + renders** for a legitimately authenticated tenant member — its
      OWN org's floored funnel comes back 200 (the positive control / anti-tautology anchor).
    * **(b) the `?org=`-forge is refused** — an authenticated member of org A requesting
      `?org=<org B's uuid>` is bound to org A off the AUTHENTICATED scope; org B's cohorts
      NEVER appear. The org is bound from the authenticated scope, the forge is ignored, fail
      closed.
    * **the on_mount gate is load-bearing** — an UNAUTHENTICATED `?org=` dead render is halted
      (302 → /login), never served (mirrors `TenantAuthnCoverageTest` / `TenantAuthzLiveTest`).

  Sabotaging the surface's org resolution to trust `params["org"]` (sabotage 284) flips (b).
  """
  use Samen.WebTest.DataCase, async: false

  import Phoenix.ConnTest

  alias Samen.Auth.SessionCreate
  alias Samen.Identity.Invite
  alias Samen.Identity.Register
  alias Samen.Web.Auth
  alias Samen.WebTest.Operator, as: Op
  alias Samen.WebTest.SecurityHost

  @endpoint Samen.WebTest.SecurityEndpoint

  # Org A is the caller's OWN org (authorized). Org B is the foreign target the forge names.
  # Org B's signup count is a DISTINCTIVE sentinel: if the forge ever succeeds it renders as a
  # cell and this string appears in the attacker's DOM.
  @foreign_signup 987_654
  @own_signup 61

  setup do
    prev = Application.get_env(SecurityHost.otp_app(), :auth_required?)
    prev_orgs = Application.get_env(:samen_web, :security_test_authorized_orgs, %{})

    # The Identity-spine harness registers + invites, and invite/accept dispatches through the
    # fail-honest Delivery chokepoint; `:test` makes the sink a no-op capture (the
    # `tenant_authz_live_test.exs` precedent), never a real send and never a fake `{:ok, _}`.
    prev_delivery = Application.get_env(:samen_core, :delivery_env)
    Application.put_env(:samen_core, :delivery_env, :test)

    on_exit(fn ->
      case prev_delivery do
        nil -> Application.delete_env(:samen_core, :delivery_env)
        v -> Application.put_env(:samen_core, :delivery_env, v)
      end
    end)

    on_exit(fn ->
      case prev do
        nil -> Application.delete_env(SecurityHost.otp_app(), :auth_required?)
        v -> Application.put_env(SecurityHost.otp_app(), :auth_required?, v)
      end

      Application.put_env(:samen_web, :security_test_authorized_orgs, prev_orgs)
    end)

    SecurityHost.revoke_all!()

    org_a = Ash.UUID.generate()
    org_b = Ash.UUID.generate()

    # Org A's OWN funnel — all stages >= config k (=5), so they RELEASE (distinctive counts).
    insert_paf!(org_a, "signup", @own_signup)
    insert_paf!(org_a, "first_run", 55)
    insert_paf!(org_a, "first_record", 50)

    # Org B's funnel — the foreign data the forge must NEVER reach.
    insert_paf!(org_b, "signup", @foreign_signup)
    insert_paf!(org_b, "first_run", 918_273)
    insert_paf!(org_b, "first_record", 555_444)

    %{org_a: org_a, org_b: org_b}
  end

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

  # A conn carrying a REAL authenticated principal in the SIGNED session (never a param — the
  # only thing `Samen.Web.Auth.authenticated_user_id/1` reads).
  defp signed_in_conn(user_id) do
    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(Auth.session_user_key(), user_id)
  end

  # ==========================================================================
  # (a) the route mounts + renders for the authenticated tenant (positive control)
  # ==========================================================================

  test "an authenticated member is served its OWN org's floored funnel end-to-end", ctx do
    SecurityHost.arm!()
    SecurityHost.grant!("member-a", [ctx.org_a])

    html =
      signed_in_conn("member-a")
      |> get("/analytics?org=#{ctx.org_a}")
      |> html_response(200)

    # The route mounted and rendered the P17 surface.
    assert html =~ "funnel-table"
    assert html =~ "Your organization"
    # Org A's own >= k cohort released its distinctive count.
    assert html =~ ">#{@own_signup}<",
           "the authenticated member must see its OWN org's floored funnel"
  end

  # ==========================================================================
  # (b) the ?org=<other-org> forge is refused — org bound from the authenticated scope
  # ==========================================================================

  test "an authenticated member of org A asking for org B gets A's funnel, never B's", ctx do
    SecurityHost.arm!()
    SecurityHost.grant!("member-a", [ctx.org_a])

    html =
      signed_in_conn("member-a")
      |> get("/analytics?org=#{ctx.org_b}")
      |> html_response(200)

    # Org B's foreign data is NEVER reached — the org is bound off the authenticated scope, the
    # `?org=` forge is ignored (CurrentOrg constrains the param to the principal's authorized set).
    refute html =~ "#{@foreign_signup}",
           "the ?org= forge leaked another org's cohort through the real analytics mount"
    refute html =~ "918273"
    refute html =~ "555444"

    # POSITIVE CONTROL (anti-tautology): the member still lands on its OWN org's funnel.
    assert html =~ ">#{@own_signup}<",
           "the forged request must fall back to the caller's own authorized org, not an empty page"
  end

  # ==========================================================================
  # (c) the FIVE states — a silence is never served as "no data yet" (fail-honest)
  # ==========================================================================

  test "the org's OWNER is served the activation state end-to-end (the gate admits rank 3)" do
    SecurityHost.arm!()
    host = register_owner!()

    html =
      spine_conn(host.credential.id)
      |> get("/analytics?org=#{host.org.id}")
      |> html_response(200)

    assert html =~ "Your organization"

    refute html =~ ~s(data-unread-reason="not_authorized"),
           "an org OWNER (rank 3) outranks :member — a gate that refuses the owner is inverted"

    # POSITIVE CONTROL (anti-tautology): the fresh org's rollup read ANSWERS (zero rows), so the
    # page renders the measured empty state rather than any silence.
    assert html =~ ~s(id="analytics-empty")
  end

  test "a REAL :viewer member is refused with :not_authorized — never 'no data yet'" do
    SecurityHost.arm!()
    host = register_owner!()
    viewer = accept_into!(host, :viewer)

    html =
      spine_conn(viewer.credential.id)
      |> get("/analytics?org=#{host.org.id}")
      |> html_response(200)

    assert html =~ ~s(data-unread-reason="not_authorized"),
           "a resolved org + a real role outside queryable_roles/0 must be named, not silently empty"

    # …and the refusal is ACTIONABLE end-to-end: the ONE step that clears it is this org's team
    # settings, where an owner grants the role (a refusal with no step is a dead end). The href
    # exists because THIS host declared `:settings_path` on the analytics mount.
    assert html =~ ~s(id="unread-next-not_authorized")
    assert html =~ ~s(href="/settings/invitations?org=#{host.org.id}")

    # …and the refusal is a state OF THE PAGE: through this REAL router it renders in the shared
    # shell's main panel, with the workspace sidebar beside it — not as a loose sentence on an
    # unstyled viewport.
    assert html =~ ~s(class="side"), "the refusal rendered outside the tenant shell"

    assert Regex.match?(~r/<main class="main">.*data-unread-reason="not_authorized"/s, html),
           "the refusal rendered outside the main panel"

    refute html =~ ~s(id="analytics-empty"),
           "a REFUSED caller was shown 'no own-org activation data yet' — a claim about the org's " <>
             "data that this request never read"
    refute html =~ "funnel-table"
  end

  test "an authenticated principal with NO resolved org says so — never 'no data yet'" do
    SecurityHost.arm!()
    SecurityHost.revoke_all!()

    html =
      signed_in_conn("orgless-member")
      |> get("/analytics")
      |> html_response(200)

    assert html =~ ~s(data-unread-reason="no_org")
    refute html =~ ~s(id="analytics-empty")
    refute html =~ "funnel-table"
  end

  # ==========================================================================
  # the on_mount tenant gate is load-bearing (unauthenticated → halted, never served)
  # ==========================================================================

  test "an UNAUTHENTICATED ?org= dead render is REFUSED (302 → /login), never served", ctx do
    SecurityHost.arm!()

    conn = get(build_conn(), "/analytics?org=#{ctx.org_b}")

    assert conn.status == 302,
           "an armed, unauthenticated tenant analytics dead render must not render"

    assert redirected_to(conn) == "/login"

    body = response(conn, 302)
    refute body =~ "#{@foreign_signup}"
    refute body =~ "funnel-table"
  end

  # -- the Identity-spine harness (the P17 role-gate legs) -----------------------
  #
  # The role the analytics gate reads is the caller's REAL `Identity.Membership` role, so the
  # refusal/`owner` legs need a principal that actually HAS one. This mirrors the established
  # spine harness in `tenant_authz_live_test.exs` (register → invite → accept → spine session);
  # a BYO-auth principal (`signed_in_conn/1`) has no membership row and therefore resolves to the
  # fail-closed `:member`.

  defp register_mods,
    do: %{
      org: Op.Org,
      credential: Op.Credential,
      user: Op.User,
      membership: Op.Membership,
      auth_token: Op.AuthToken,
      repo: Samen.WebTest.Repo
    }

  defp invite_mods,
    do: %{
      invitation: Op.Invitation,
      credential: Op.Credential,
      user: Op.User,
      membership: Op.Membership,
      repo: Samen.WebTest.Repo
    }

  defp session_create_mods,
    do: %{session: Op.Session, org: Op.Org, membership: Op.Membership, user: Op.User}

  # A real org + its real :owner membership + credential (the sanctioned register path).
  defp register_owner! do
    attrs = %{
      org_name: "P17 Co #{System.unique_integer([:positive])}",
      first_name: "Ada",
      last_name: "Lovelace",
      email: "p17-#{System.unique_integer([:positive])}@example.test",
      password: "correct horse battery staple"
    }

    {:ok, result} = Register.register(attrs, register_mods())
    Map.put(result, :email, attrs.email)
  end

  # Land an invitee into `host`'s org at exactly `role` through the sanctioned invite/accept path,
  # so the acting principal holds a REAL `Identity.Membership` row at that role.
  defp accept_into!(host, role) do
    invitee = register_owner!()

    owner_scope = %Samen.Scope{
      actor: %{
        id: host.user.id,
        org_id: host.org.id,
        role: :owner,
        verified?: true,
        kind: :tenant,
        plane: :tenant
      }
    }

    {:ok, _invitation, raw_token} =
      Invite.create(invite_mods(), owner_scope, %{email: invitee.email, role: role})

    {:ok, _joined} = Invite.accept(invite_mods(), raw_token)
    invitee
  end

  # A conn carrying a REAL spine session (the credential id `Samen.Auth.OrgActor` keys the
  # membership lookup on).
  defp spine_conn(credential_id) do
    {:ok, _session, raw_session_token} = SessionCreate.create(session_create_mods(), credential_id)

    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(Auth.session_token_key(), raw_session_token)
  end
end
