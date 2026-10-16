defmodule Samen.Web.TenantShellCoverageTest do
  @moduledoc """
  THE CHROME SWEEP — every LiveView the framework mounts in an AUTHENTICATED TENANT
  `live_session` renders inside the shared app shell, and its page content in a main-panel
  wrapper (`.wrap` / `.pane`).

  ## Why this exists

  A tenant page that renders outside the chrome is not a missing feature, it is a page a
  tenant cannot leave: no sidebar, no workspace header, no way back — and on mobile no
  drawer. Two shipped surfaces had exactly that (the onboarding wizard had no shell at all;
  the CRM dashboard had the shell but its `.dash-grid` — paddingless by design, since the
  tiles carry their own padding — hung flush off the shell edge with no `.wrap` pane around
  it). Per-page render tests already assert `class="app"` for the pages they cover
  (`crm_render_test.exs`, `billing_render_test.exs`, …), but nothing swept the WHOLE mounted
  set, so a new tenant page could be added without the shell and nothing failed.

  ## What it proves, and what it does not

  This test is a STRUCTURAL COMPLETENESS check over the framework's own source, driven by the
  ROUTE TABLES THEMSELVES (`Samen.Web.Router.__routes__/2`) — the authority for what is mounted
  in a tenant `live_session`, so a page added to a route table is covered the moment it exists
  and cannot be "forgotten" by a hand-kept list. It does NOT replace the render proofs: the
  behavioural assertions live in the per-page render tests, and for the two surfaces this sweep
  found, in `auth/onboarding_test.exs` (the wizard, every state, inside `<main>`) and
  `crm_dashboard_test.exs` (the dashboard grid inside `<main> … <div class="wrap">`).

  ## Scope — the tenant plane

  The gate covers every `samen_*_routes` / `samen_module_routes` TENANT surface. Deliberately
  NOT covered, each for a stated reason rather than by omission:

    * `:kb` / `:csat` (`Samen.Web.Support.PortalKbLive`, `…CsatRespondLive`) — the two
      PRE-ACTOR PUBLIC kinds. They mount with NO `{Samen.Web.TenantAuthz, :require_tenant}`
      on_mount (an anonymous visitor authorizes by construction: `Post.read_public`, or a
      single-use token), so a workspace sidebar would be a lie about who is signed in.
    * the auth spine (`samen_auth_routes`: signup/verify/reset/login/2fa/invite) — same
      pre-actor public posture; its pages are centred cards by design. The 2FA CONTINUATION
      behind a signed-in tenant (`/settings/security/2fa`, mounted by `samen_settings_routes`)
      is a different surface and IS swept — see `@inline_tenant_modules`.
    * the OPERATOR plane (`samen_operator_routes`) — a different chrome and a different gate
      (`{Samen.Web.Operator.Authz, :require_operator}`); audited by hand, not by this sweep.
      Both operator-plane findings are named in the follow-up record, not silently skipped:
      `Samen.Web.Operator.FleetResolveLive` renders an empty `<div>` on purpose (it is a
      redirect interstitial — every path out of `handle_params/3` is a `redirect/2`), and
      `PawChartWeb.OperatorImpersonationLive` is a host-local operator page with no shell.
    * `demo`'s `ContactLive` / `OperatorImpersonationLive` — unrouted RENDER PROOFS in an
      API-only host (documented in their moduledocs; neither has a `live/2` route).
    * `Samen.Web.Onboarding.ProductTourLive` — declared and reachable from NOWHERE (the
      module has no mount macro and no router in this repo references it), so it renders
      outside the chrome for no one. Flagged for retirement in the follow-up record rather
      than polished: it also carries hardcoded links to routes a host may never mount.
  """

  use ExUnit.Case, async: true

  alias Samen.Web.Router

  # Every kind `samen_module_routes/3` mounts with the TENANT gate, plus the kinds mounted by
  # their own `samen_*_routes` macros (`:settings`, `:notifications`) — `__routes__/2` is the
  # per-kind route table, and the returned modules ARE the mounted set.
  @tenant_kinds [
    :crm,
    :billing,
    :support,
    :work,
    :banking,
    :marketing,
    :chat,
    :notifications,
    :flags,
    :files,
    :csv,
    :search,
    :settings,
    :automation,
    :ai
  ]

  # Tenant surfaces whose macro declares its `live/2` calls INLINE instead of threading a
  # `__routes__/2` table, so they are not reachable from the kinds above:
  #
  #   * `samen_onboarding_routes/2`      → the first-run wizard
  #   * `samen_tenant_analytics_routes/1` → the own-org analytics page (P17)
  #   * `samen_erp_routes/3`              → the six ERP surfaces + their detail twin
  #   * `samen_settings_routes/3`         → `/settings/security/2fa` (its OWN
  #     `{Samen.Web.Auth, :ensure_authenticated}` live_session — enrollment acts on a
  #     credential, so the boundary is authentication; still a page a signed-in tenant
  #     reaches from Settings → Security, on the same tenant-plane `:settings` mount)
  #
  # Each entry is cross-checked against the framework router's own source in
  # "the inline mounts are still mounted" below, so a stale entry here fails rather than
  # silently skipping a surface.
  @inline_tenant_modules [
    Samen.Web.Onboarding.WizardLive,
    Samen.Web.Tenant.AnalyticsLive,
    Samen.Web.Erp.SurfaceLive,
    Samen.Web.Erp.DetailLive,
    Samen.Web.Auth.TotpEnrollLive
  ]

  # The shell ENTRY POINT, as a page writes it. Narrower than the bare word "app_shell" (which
  # also appears in a page's `import` line): the check is that the module's render actually
  # OPENS the shell.
  @app_shell ~s(<.app_shell>)

  # …or the WRAPPER (`Samen.Web.Tenant.Live`), which opens the shell FOR the page: a page that
  # `use`s it has no `render/1` of its own (the compiler refuses one) and no shell to forget.
  @wrapper "use Samen.Web.Tenant.Live"

  # A tenant page's content pane. `.wrap` and `.pane` are the two equivalents in the sheet
  # (`samen_ui.css`: both `padding: 22px 30px 30px`); a page may emit either, and one that
  # emits NEITHER is hanging its content off the shell edge. Matched as a class TOKEN, because
  # the pane div often carries `:if`/`style` attributes after the class.
  @main_panel ~r/class="(wrap|pane)"/

  test "every tenant page opens the shared app shell AND a main-panel wrapper" do
    modules = tenant_modules()

    # Fail loudly on a vacuous sweep: if a route table ever stops resolving (a renamed kind,
    # an emptied table) this test must not pass by having nothing to check.
    for kind <- @tenant_kinds do
      assert Router.__routes__(kind, "/probe") != [],
             "the #{kind} route table resolved nothing — the sweep lost a surface"
    end

    assert length(modules) >= 50,
           "the tenant route tables resolved only #{length(modules)} modules — " <>
             "this sweep would be vacuous"

    for module <- modules do
      source = code_only(source!(module))

      if source =~ @wrapper do
        # The page delegates its chrome to the wrapper, so the shell it renders is the
        # WRAPPER's — assert the wrapper still composes one, or every wrapper page would be
        # "covered" by a composition that no longer exists.
        assert code_only(source!(Samen.Web.Tenant.Live)) =~ @app_shell,
               "#{inspect(Samen.Web.Tenant.Live)} no longer opens the app shell, so every " <>
                 "page mounting it renders outside the chrome."

        case wrapper_defect(source) do
          nil -> :ok
          defect -> flunk("#{inspect(module)} #{wrapper_defect_message(defect)}")
        end
      else
        assert source =~ @app_shell,
               "#{inspect(module)} renders OUTSIDE the app shell — a tenant page with no " <>
                 "sidebar, no workspace header and no way back. Mount it through " <>
                 "`Samen.Web.Tenant.Live` (the wrapper composes the shell around it; see " <>
                 "Samen.Web.Tenant.AnalyticsLive) or open `Samen.UI.app_shell/1` yourself."
      end

      assert source =~ @main_panel,
             "#{inspect(module)} has no main-panel wrapper — its content sits flush against " <>
               "the shell edge instead of in a `.wrap`/`.pane` pane."
    end
  end

  # Anti-tautology: the predicate must be capable of failing. `Samen.Web.Auth.LoginLive` is a
  # pre-actor public page — chrome-less BY DESIGN (see the moduledoc) — so it must fail the
  # shell half, and a bare fragment must fail the panel half. If someone weakens either
  # predicate to something vacuous, this control goes red first.
  test "the sweep's predicate is refutable (control)" do
    refute code_only(source!(Samen.Web.Auth.LoginLive)) =~ @app_shell
    refute ~s(<div id="loose">no chrome here</div>) =~ @main_panel

    # …and it cannot be satisfied by PROSE. A page that only TALKS about the shell — a
    # moduledoc, a `#` comment, a HEEx comment — still renders outside it, so the predicate is
    # evaluated on CODE only. Without this, `Samen.Web.Tenant.AnalyticsLive` would have passed
    # the sweep on the strength of a comment about the wrapper it mounts.
    prose = ~S'''
    defmodule SweepProseOnly do
      @moduledoc """
      This page mounts the wrapper (`use Samen.Web.Tenant.Live`) and opens <.app_shell>.
      """

      # <.app_shell> is opened for us by the wrapper.
      <%!-- <.app_shell> — and even a HEEx comment says nothing about the render. --%>
      def render(assigns), do: ~H"<div id='bare'>no chrome</div>"
    end
    '''

    assert prose =~ @app_shell
    refute code_only(prose) =~ @app_shell
    refute code_only(prose) =~ @wrapper
  end

  test "the wrapper half of the sweep is refutable too (control)" do
    # A page that mounts the wrapper but renders only ONE of its two callbacks — the wrapper
    # composition would be missing a side, so the sweep must say which one…
    assert wrapper_defect("use Samen.Web.Tenant.Live\ndef tenant_page(assigns), do: :page") ==
             {:missing_callback, "tenant_sidebar"}

    # …and a page that mounts it AND opens a shell of its own, which is two nested shells.
    assert wrapper_defect(
             "use Samen.Web.Tenant.Live\ndef tenant_sidebar(assigns), do: :s\ndef tenant_page(assigns), do: :p\n<.app_shell>"
           ) == :double_shell

    # The complete shape passes, so the two defects above are not "everything fails".
    assert wrapper_defect(
             "use Samen.Web.Tenant.Live\ndef tenant_sidebar(assigns), do: :s\ndef tenant_page(assigns), do: :p"
           ) == nil
  end

  test "every page wrote its pane in real code too (the panel half is not satisfiable by prose)" do
    prose = ~S'''
    # the content sits in a <div class="wrap"> pane
    @moduledoc """class="wrap"""
    def render(assigns), do: ~H"<div id='bare'>no pane</div>"
    '''

    assert prose =~ @main_panel
    refute code_only(prose) =~ @main_panel
  end

  test "the exempt kinds really are off the tenant plane (the exemptions are not a bypass)" do
    mounted = tenant_modules()

    # The two PRE-ACTOR PUBLIC kinds are mounted by `samen_module_routes/3` as well, but in a
    # `live_session` with NO tenant `on_mount` — they must never appear in the tenant set.
    refute Samen.Web.Support.PortalKbLive in mounted
    refute Samen.Web.Support.CsatRespondLive in mounted
    refute Samen.Web.Auth.LoginLive in mounted
    # …and the unreachable module is not mounted by any route table either (that is WHY it
    # renders outside the chrome for nobody — it is not evidence of a live defect).
    refute Samen.Web.Onboarding.ProductTourLive in mounted
  end

  test "the inline mounts are still mounted (a stale entry would skip a surface)" do
    router = source!(Router)

    for module <- @inline_tenant_modules do
      assert router =~ inspect(module),
             "#{inspect(module)} is in @inline_tenant_modules but the framework router no " <>
               "longer mounts it — drop it from the sweep (or re-point it at its new macro)."
    end
  end

  defp tenant_modules do
    (@tenant_kinds
     |> Enum.flat_map(fn kind -> Enum.map(Router.__routes__(kind, "/probe"), &elem(&1, 1)) end)
     |> Kernel.++(@inline_tenant_modules)
     |> Enum.uniq())
    |> Enum.sort()
  end

  # The wrapper half of the sweep, as a VALUE so the control above can prove it fires — the
  # control exercises this exact predicate rather than a restatement of it.
  defp wrapper_defect(source) do
    cond do
      source =~ @app_shell ->
        :double_shell

      true ->
        case Enum.find(~w(tenant_sidebar tenant_page), &(not Regex.match?(~r/defp?\s+#{&1}\(assigns\)/, source))) do
          nil -> nil
          missing -> {:missing_callback, missing}
        end
    end
  end

  defp wrapper_defect_message(:double_shell),
    do: "mounts the wrapper AND opens a shell of its own — two nested shells. The wrapper's is " <>
          "the page's chrome; drop the second one."

  defp wrapper_defect_message({:missing_callback, callback}),
    do: "mounts the wrapper but defines no #{callback}/1, which is the callback that renders " <>
          "it (the wrapper refuses to compile without it)."

  # The module's CODE: `@moduledoc`/`@doc` bodies, `#` comments and HEEx comments removed. The
  # sweep asks whether a page OPENS the shell, and prose about the shell is not a shell — a page
  # with the right comment and the wrong render must still fail (see the control above).
  #
  # Only attribute-attached heredocs are stripped, so a `~H"""` template (real code, real
  # markup) is untouched — as are the `#` inside a style attribute, since a line is only treated
  # as a comment when its first non-blank character is `#`.
  defp code_only(source) do
    source
    |> String.replace(~r/^\s*@(moduledoc|doc|typedoc)\s+~?[A-Za-z]?"""[\s\S]*?"""/m, "")
    |> String.replace(~r/^\s*@(moduledoc|doc|typedoc)\s+~?[A-Za-z]?"[^"\n]*"/m, "")
    |> String.replace(~r/<%!--.*?--%>/s, "")
    |> String.replace(~r/^[ \t]*#.*$/m, "")
  end

  # The module's own source file — the compiled `:source` is the file this build compiled, so
  # the sweep reads exactly the code under test (and fails loudly if it is missing).
  defp source!(module) do
    {:module, ^module} = Code.ensure_loaded(module)

    file =
      case module.module_info(:compile)[:source] do
        nil ->
          flunk(
            "no source path in #{inspect(module)}'s debug info — the sweep cannot read the " <>
              "page it is auditing, and a sweep that silently skips a page is not a sweep"
          )

        path ->
          to_string(path)
      end

    assert File.regular?(file),
           "no source file for #{inspect(module)} — looked at #{inspect(file)}"

    File.read!(file)
  end
end
