defmodule Samen.Web.RouterTest do
  @moduledoc """
  Tests the router macro's route table + plane building. A full `Phoenix.Router` that `import
  Samen.Web.Router` and calls `samen_module_routes/3` compiles below — proving the macro
  expands into real `live` routes threaded through a `live_session` carrying the mount.
  """
  use ExUnit.Case, async: true

  # A real host router that mounts all three modules via the macro — if the macro is broken,
  # THIS MODULE FAILS TO COMPILE, which is the strongest possible test of expansion.
  defmodule HostRouter do
    use Phoenix.Router
    # A real host gets this via `use MyAppWeb, :router`; a bare Phoenix.Router needs it
    # explicitly (the macro expands `live_session` + `live`, both from this module).
    import Phoenix.LiveView.Router
    import Samen.Web.Router

    scope "/" do
      samen_module_routes(:crm, Some.Host.Crm, repo: Some.Host.Repo)
      samen_module_routes(:billing, Some.Host.Billing, repo: Some.Host.Repo)
      samen_module_routes(:support, Some.Host.Support, repo: Some.Host.Repo)
      samen_module_routes(:marketing, Some.Host.Marketing, repo: Some.Host.Repo)
      # T78 (spec §I5) — the UNAUTHENTICATED tenant-portal mount, in the SAME public
      # scope as everything else here (this test proves only that the macro expands;
      # a real host places `:kb` in a scope with no auth pipeline, same as
      # `samen_auth_routes`).
      samen_module_routes(:kb, Some.Host.Cms, repo: Some.Host.Repo, path: "/portal")
      # T79 (spec §I6) — the UNAUTHENTICATED CSAT survey-response mount, SAME
      # public-scope posture as `:kb` above (this test proves only that the
      # macro expands; a real host places `:csat` in a scope with no auth
      # pipeline).
      samen_module_routes(:csat, Some.Host.Support, repo: Some.Host.Repo)
      # T142: mounting WITH an :actor_resolver compiles (the safe-by-construction happy path).
      samen_mcp_route(actor_resolver: {Some.Host.KeyAuthPlug, :resolve_scope, []})
    end
  end

  # T84b's compile-time POSITIVE CONTROLS (see the describe far below). The namespace/repo values
  # are labels only (a fake `Some.Host.*` atom is never loaded); the cockpit's own LiveView modules
  # are the framework's real ones, which is why a successful compile here means exactly what it
  # says. Declared up here so the tests below can name them bare, like `HostRouter`.
  defmodule CockpitWithNamespaceProbeRouter do
    use Phoenix.Router
    import Phoenix.LiveView.Router
    import Samen.Web.Router

    scope "/" do
      samen_operator_routes(Some.Host.Operator,
        repo: Some.Host.Repo,
        fleet_cockpit: true,
        fleet_namespace: Some.Host.Fleet
      )
    end
  end

  defmodule PlainOperatorProbeRouter do
    use Phoenix.Router
    import Phoenix.LiveView.Router
    import Samen.Web.Router

    scope "/" do
      samen_operator_routes(Some.Host.Operator, repo: Some.Host.Repo)
    end
  end

  test "the CRM route table maps the three CRM pages to the framework LiveViews" do
    routes = Samen.Web.Router.__routes__(:crm, "/crm")

    assert {"/crm/companies", Samen.Web.CRM.CompaniesLive} in routes
    assert {"/crm/companies/:id", Samen.Web.CRM.CompanyLive} in routes
    assert {"/crm/contacts", Samen.Web.CRM.ContactsLive} in routes
    assert {"/crm/contacts/:id", Samen.Web.CRM.ContactLive} in routes
    assert {"/crm/pipeline", Samen.Web.CRM.PipelineLive} in routes
  end

  test "the Billing + Support route tables map their pages" do
    billing = Samen.Web.Router.__routes__(:billing, "/billing")
    assert {"/billing", Samen.Web.Billing.OverviewLive} in billing
    assert {"/billing/invoices", Samen.Web.Billing.InvoicesLive} in billing
    assert {"/billing/plans", Samen.Web.Billing.PlansLive} in billing
    assert {"/billing/settings", Samen.Web.Billing.SettingsLive} in billing

    support = Samen.Web.Router.__routes__(:support, "/support")
    assert {"/support", Samen.Web.Support.TicketsLive} in support
    assert {"/support/tickets/:id", Samen.Web.Support.TicketLive} in support
    # T78 (spec §I5) — the agent-facing KB, mounted alongside tickets on the Support kind.
    assert {"/support/kb", Samen.Web.Support.KbLive} in support
  end

  test "the KB (portal) route table maps the unauthenticated tenant-portal page (T78, spec §I5)" do
    kb = Samen.Web.Router.__routes__(:kb, "/portal")
    assert {"/portal/:org", Samen.Web.Support.PortalKbLive} in kb
  end

  test "the CSAT route table maps the unauthenticated survey-response page (T79, spec §I6)" do
    csat = Samen.Web.Router.__routes__(:csat, "/support/csat")
    assert {"/support/csat/:token", Samen.Web.Support.CsatRespondLive} in csat
  end

  test "the Marketing route table maps the campaigns/segments/leads pages (ADR-011 §7)" do
    marketing = Samen.Web.Router.__routes__(:marketing, "/marketing")
    assert {"/marketing/campaigns", Samen.Web.Marketing.CampaignsLive} in marketing
    assert {"/marketing/campaigns/:id", Samen.Web.Marketing.CampaignLive} in marketing
    assert {"/marketing/segments", Samen.Web.Marketing.SegmentsLive} in marketing
    assert {"/marketing/leads", Samen.Web.Marketing.LeadsLive} in marketing
    # The DETAIL twins (segment + lead record pages).
    assert {"/marketing/segments/:id", Samen.Web.Marketing.SegmentLive} in marketing
    assert {"/marketing/leads/:id", Samen.Web.Marketing.LeadLive} in marketing
  end

  test "__plane__/1 defaults to tenant and honors :operator" do
    assert Samen.Web.Router.__plane__([]).kind == :tenant

    op = Samen.Web.Router.__plane__(plane: :operator, operator_id: "op", target_org_id: "t")
    assert op.kind == :operator
    assert op.operator_id == "op"
    assert op.target_org_id == "t"
  end

  test "the host router compiled and registered the mounted live routes" do
    paths = HostRouter.__routes__() |> Enum.map(& &1.path)

    assert "/crm/companies" in paths
    assert "/crm/companies/:id" in paths
    assert "/crm/contacts" in paths
    assert "/crm/contacts/:id" in paths
    assert "/billing" in paths
    assert "/support/tickets/:id" in paths
    assert "/marketing/campaigns" in paths
    assert "/marketing/campaigns/:id" in paths
    assert "/marketing/segments" in paths
    assert "/marketing/segments/:id" in paths
    assert "/marketing/leads" in paths
    assert "/marketing/leads/:id" in paths
    # T78 (spec §I5) — the unauthenticated portal route registered from the same macro.
    assert "/portal/:org" in paths
    # T79 (spec §I6) — the unauthenticated CSAT survey-response route.
    assert "/support/csat/:token" in paths
    # T142: the MCP route mounted WITH a resolver (in HostRouter above) registered its forward.
    assert "/mcp" in paths
  end

  # The `on_mount` hooks a COMPILED router attached to the `live_session` that owns
  # `path` — read off `Phoenix.Router.routes/1` metadata, where Phoenix stamps
  # `metadata.phoenix_live_view` as `{view, action, opts, %{extra: %{session: …,
  # on_mount: …}, name: …}}`. Enumerated off the compiled router (the
  # `TenantAuthnCoverageTest` discipline) rather than a hand-maintained list.
  # Hooks come back in their PREPARED form (`%{function:, id:, stage:}`), so this
  # projects them to the `{module, fun}` identity a reader recognizes.
  defp session_on_mount_ids(router, path) do
    {_view, _action, _opts, live} =
      router
      |> Phoenix.Router.routes()
      |> Enum.find(&(&1.path == path))
      |> Map.fetch!(:metadata)
      |> Map.fetch!(:phoenix_live_view)

    Enum.map(live.extra.on_mount, & &1.id)
  end

  # T78/T79 + Phase 5 — the two PRE-ACTOR PUBLIC kinds must NOT carry the B-SEC tenant
  # gate. Both authorize themselves by construction (`Post.read_public` runs with no
  # actor at all; the CSAT token derives org/ticket from its own match), so attaching
  # `{Samen.Web.TenantAuthz, :require_tenant}` would `:halt` an anonymous visitor on an
  # ARMED host and redirect the help center and every survey link to `/login` — the
  # documented "public router scope" posture would be a lie in production. The
  # framework's own KB/CSAT tests could not catch that: they build the `Mount` struct
  # directly and bypass the router, which is exactly the blind spot this pins.
  test "the public :kb/:csat kinds carry NO tenant on_mount; every tenant kind keeps it" do
    assert session_on_mount_ids(HostRouter, "/portal/:org") == []
    assert session_on_mount_ids(HostRouter, "/support/csat/:token") == []

    # Positive control — the gate still rides every TENANT-bearing kind, so the
    # assertion above is a real difference and not a vacuous "no hooks anywhere".
    assert session_on_mount_ids(HostRouter, "/crm/contacts") ==
             [{Samen.Web.TenantAuthz, :require_tenant}]

    assert session_on_mount_ids(HostRouter, "/billing") ==
             [{Samen.Web.TenantAuthz, :require_tenant}]
  end

  # T142 — samen_mcp_route is safe-by-construction: no :actor_resolver ⇒ compile-time refusal.
  describe "T142: samen_mcp_route requires an :actor_resolver (no insecure default)" do
    test "the guard refuses opts with no :actor_resolver and accepts opts with one" do
      assert_raise ArgumentError, ~r/actor_resolver/, fn ->
        Samen.Web.Router.__require_actor_resolver__!([])
      end

      assert_raise ArgumentError, ~r/actor_resolver/, fn ->
        Samen.Web.Router.__require_actor_resolver__!(path: "/mcp", tool_opts: [])
      end

      assert :ok =
               Samen.Web.Router.__require_actor_resolver__!(
                 actor_resolver: {Some.Host.KeyAuthPlug, :resolve_scope, []}
               )
    end

    test "mounting samen_mcp_route/1 with NO :actor_resolver RAISES at macro expansion (won't compile)" do
      assert_raise ArgumentError, ~r/actor_resolver/, fn ->
        defmodule McpNoResolverProbeRouter do
          use Phoenix.Router
          import Samen.Web.Router

          scope "/" do
            samen_mcp_route()
          end
        end
      end
    end
  end

  # T118 (ADR-039 §12 done-criterion 4) — the tenant automation builder macro.
  # A real host router that mounts it via ONE macro call — if the macro is broken,
  # THIS MODULE FAILS TO COMPILE, the same expansion proof `HostRouter` gives crm/
  # billing/support/marketing above.
  defmodule AutomationHostRouter do
    use Phoenix.Router
    import Phoenix.LiveView.Router
    import Samen.Web.Router

    scope "/" do
      samen_automation_routes(:automation, Some.Host.Automation, repo: Some.Host.Repo)
    end
  end

  test "the automation route table maps ONE builder page (list + author/edit modal)" do
    routes = Samen.Web.Router.__routes__(:automation, "/automation")
    assert routes == [{"/automation", Samen.Web.Automation.BuilderLive}]
  end

  test "the automation host router compiled and registered the builder route" do
    paths = AutomationHostRouter.__routes__() |> Enum.map(& &1.path)
    assert "/automation" in paths
  end

  test "samen_automation_routes/3 accepts NO :plane option — the mount is always tenant (INV-2)" do
    # Unlike samen_flags_routes/samen_files_routes/etc, this macro's expansion (see
    # its definition) hardcodes `plane: Samen.Web.Plane.tenant()` — it never reads a
    # `:plane` opt at all. Passing one is simply ignored (no compile error, no
    # runtime branch reads it), which is itself the INV-2 proof: there is no code
    # path in this macro that could ever produce an operator-plane mount.
    defmodule AutomationOperatorAttemptRouter do
      use Phoenix.Router
      import Phoenix.LiveView.Router
      import Samen.Web.Router

      scope "/" do
        samen_automation_routes(:automation, Some.Host.Automation,
          repo: Some.Host.Repo,
          plane: :operator,
          target_org_id: "ignored"
        )
      end
    end

    paths = AutomationOperatorAttemptRouter.__routes__() |> Enum.map(& &1.path)
    assert "/automation" in paths
  end

  # T84b (ADR-044 §9.2) — the cockpit mount is safe-by-construction, in the T142 shape: mounting
  # `fleet_cockpit: true` with no `:fleet_namespace` is a BUILD failure, not a runtime surprise.
  # The three proofs below are the accept/refuse table, a real `defmodule` that must NOT compile,
  # and the positive controls that keep the refusal from being over-broad (the SAME macro compiles
  # WITH a namespace, and a NON-cockpit operator mount still needs none).
  describe "T84b: samen_operator_routes requires :fleet_namespace when fleet_cockpit: true" do
    test "the guard refuses a cockpit with no (or a nil) :fleet_namespace and accepts one" do
      # Not a cockpit — the plain operator mount this macro has always emitted.
      assert :ok = Samen.Web.Router.__require_fleet_namespace__!([repo: Some.Host.Repo])

      assert :ok =
               Samen.Web.Router.__require_fleet_namespace__!(
                 repo: Some.Host.Repo,
                 fleet_cockpit: false
               )

      assert_raise ArgumentError, ~r/fleet_namespace/, fn ->
        Samen.Web.Router.__require_fleet_namespace__!(repo: Some.Host.Repo, fleet_cockpit: true)
      end

      # A `nil` VALUE is the same hole as a missing KEY — the label would still be nil. This is
      # the anti-tautology pin: a guard written with `Keyword.has_key?/2` (the T142 spelling)
      # would ACCEPT this and quietly pass a nil namespace through to the cockpit.
      assert_raise ArgumentError, ~r/fleet_namespace/, fn ->
        Samen.Web.Router.__require_fleet_namespace__!(
          repo: Some.Host.Repo,
          fleet_cockpit: true,
          fleet_namespace: nil
        )
      end

      assert :ok =
               Samen.Web.Router.__require_fleet_namespace__!(
                 repo: Some.Host.Repo,
                 fleet_cockpit: true,
                 fleet_namespace: Some.Host.Fleet
               )
    end

    test "mounting with fleet_cockpit: true and NO :fleet_namespace RAISES at macro expansion (won't compile)" do
      assert_raise ArgumentError, ~r/fleet_namespace/, fn ->
        defmodule CockpitNoNamespaceProbeRouter do
          use Phoenix.Router
          import Phoenix.LiveView.Router
          import Samen.Web.Router

          scope "/" do
            samen_operator_routes(Some.Host.Operator, repo: Some.Host.Repo, fleet_cockpit: true)
          end
        end
      end
    end

    test "positive control: WITH :fleet_namespace the SAME mount compiles, and a non-cockpit mount needs none" do
      # Both modules below compile at load time — if the guard were over-broad (requiring a
      # namespace unconditionally, or refusing any cockpit), THIS TEST MODULE would not compile.
      cockpit = CockpitWithNamespaceProbeRouter.__routes__() |> Enum.map(& &1.path)
      assert "/operator/fleet" in cockpit
      assert "/operator/accounts" in cockpit

      plain = PlainOperatorProbeRouter.__routes__() |> Enum.map(& &1.path)
      assert "/operator/accounts" in plain
      # ...and the cockpit routes are genuinely gated behind the opt, not always emitted.
      refute "/operator/fleet" in plain
    end
  end
end
