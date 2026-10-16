defmodule Samen.Web.Tenant.Live do
  @moduledoc """
  The TENANT LiveView wrapper: `use` this instead of `use Phoenix.LiveView` and the page's
  `render/1` is the framework's — it composes the shared app shell around the two things the
  page actually owns (`tenant_sidebar/1` and `tenant_page/1`), so a tenant page CANNOT render
  outside the chrome.

  ## Why this exists

  The tenant-chrome audit found three authenticated tenant surfaces rendering outside the shell —
  the first-run wizard and the settings 2FA enrollment page as a lone centred card on an empty
  viewport (no sidebar beside them, no workspace header, no way back), and the CRM dashboard
  rendering inside the shell but with no main-panel wrapper. The sweep that came out of that
  audit (`samen_web/test/samen/web/tenant_shell_coverage_test.exs`) DETECTS the defect at test
  time; this module removes the possibility, and the pages the audit fixed are its consumers. A
  page written through the wrapper has no `render/1` of its own to get wrong:

      defmodule MyHostWeb.BrokerLive do
        use Samen.Web.Tenant.Live

        @impl Samen.Web.Tenant.Live
        def tenant_sidebar(assigns) do
          ~H\"\"\"
          <.sidebar title={CurrentOrg.name(@samen_mount, @org_id)} subtitle=\"Freight\">
            <.module_nav {Samen.UI.nav_paths(@samen_mount)} org_id={@org_id} active={:broker} />
          </.sidebar>
          \"\"\"
        end

        @impl Samen.Web.Tenant.Live
        def tenant_page(assigns) do
          ~H\"\"\"
          <.topbar title=\"Dispatch board\" crumbs={crumbs(@samen_mount, @org_id)} />
          <div class=\"wrap\">…the page's own content…</div>
          \"\"\"
        end
      end

  ## The shell is structural — enforced at COMPILE time

  What is guaranteed BY CONSTRUCTION is the SHELL: `<.app_shell>` with a page's `:sidebar` slot
  and a `<main class=\"main\">` block, composed once in `tenant_shell/2` and reached through the
  `render/1` this module injects. A page cannot get between the two, and it is told so while the
  module compiles rather than at runtime:

    * defining `render/1` is refused — `CompileError`, naming the callback to use instead. This
      is the whole point: a page-owned `render/1` is the ONE thing that lets a tenant surface
      render outside the chrome, so the wrapper does not merely out-rank it, it rejects it.
    * omitting `tenant_page/1` or `tenant_sidebar/1` is refused — `CompileError` naming the
      missing callback (the `@behaviour`/`@impl` pair a consumer writes anyway, so the diagnostic
      points at the line they are already at).

  The `render/1` that IS there is injected by the module's `@before_compile` hook, so the page's
  own source contains no shell at all — nothing to forget, nothing to copy, nothing to drift.

  What is NOT covered by the wrapper is the MAIN PANEL: whether the page's content sits in a
  `.wrap`/`.pane` pane stays the page's own choice (a full-bleed map or a split view is a
  legitimate layout and the wrapper cannot tell the difference), and the topbar stays page-owned
  because its title/crumbs/actions are page facts. Those remain the sweep's job — structural
  where it can be, checked where it cannot.

  ## The tenant plane only — never the pre-actor public surfaces

  This wrapper is for surfaces a SIGNED-IN tenant reaches inside its workspace. The pre-actor
  public pages (the auth spine's signup/verify/reset/login/2FA-challenge, the KB portal, the CSAT
  link) authorize themselves by construction and deliberately render their own centred chrome;
  they do not use this module, and a workspace sidebar on them would claim a signed-in user the
  page never observed. The operator plane has its own chrome and its own gate
  (`Samen.Web.Operator.Authz`), so it is out of this wrapper's scope for the same reason.

  ## `tenant_sidebar/1` is REQUIRED, with no framework default

  A default sidebar is the one thing that must not be defaulted: the framework's generic
  `Samen.UI.Nav.module_nav/1` falls back to DEFAULT paths (`/crm`, `/settings`, …) and would emit
  links to routes the host may never have mounted — the dead-link trap documented in
  `Samen.Web.Onboarding.Live` (clicking one raises `Phoenix.Router.NoRouteError`; X1 / ADR-045
  §4.1). Every page states its own sidebar, so every link it renders is a route its host declared.
  """

  use Phoenix.Component

  import Samen.UI, only: [app_shell: 1]

  @doc """
  The page's own content: the topbar, any banner, and the main-panel wrapper (`.wrap`/`.pane`)
  around the page's body. Rendered inside the shell's `<main>`. Required.
  """
  @callback tenant_page(assigns :: map()) :: Phoenix.LiveView.Rendered.t()

  @doc """
  The sidebar the page mounts — its `:sidebar` slot inside the shell. Required: see the
  moduledoc for why the framework must not default it.
  """
  @callback tenant_sidebar(assigns :: map()) :: Phoenix.LiveView.Rendered.t()

  @doc """
  Optional assign defaults, applied ONCE before the shell (and therefore before both callbacks)
  renders — the place for `assign_new/3` tolerance of a synthetic socket (a unit test that calls
  `load/*` and renders the page directly). Default: the assigns unchanged.
  """
  @callback tenant_assigns(assigns :: map()) :: map()

  @optional_callbacks tenant_assigns: 1

  defmacro __using__(_opts) do
    quote do
      use Phoenix.LiveView

      # The page's callbacks render with the whole kit (`Samen.UI.app_shell/1` is the wrapper's,
      # but `topbar/1`, `sidebar/1`, `crumbs/3`, … are the page's).
      import Samen.UI

      @behaviour Samen.Web.Tenant.Live

      @impl Samen.Web.Tenant.Live
      def tenant_assigns(assigns), do: assigns

      defoverridable tenant_assigns: 1

      # The shell's `render/1` is injected LAST (see `__before_compile__/1`), so it is the module's
      # only one — a page that writes its own is refused rather than silently out-ranked.
      @before_compile Samen.Web.Tenant.Live
    end
  end

  @doc false
  defmacro __before_compile__(env) do
    module = env.module

    cond do
      Module.defines?(module, {:render, 1}) ->
        raise CompileError, file: env.file, line: env.line, description: render_refusal(module)

      not Module.defines?(module, {:tenant_page, 1}) ->
        raise CompileError, file: env.file, line: env.line, description: missing_refusal(module, :tenant_page)

      not Module.defines?(module, {:tenant_sidebar, 1}) ->
        raise CompileError,
          file: env.file,
          line: env.line,
          description: missing_refusal(module, :tenant_sidebar)

      true ->
        quote do
          @doc false
          @impl Phoenix.LiveView
          def render(assigns) do
            Samen.Web.Tenant.Live.tenant_shell(__MODULE__, assigns)
          end
        end
    end
  end

  defp render_refusal(module) do
    """
    #{inspect(module)} uses Samen.Web.Tenant.Live but defines its own render/1.

    A page-owned render/1 is the one thing that lets a tenant surface render OUTSIDE the shared
    chrome — no sidebar, no workspace header, no way back. The wrapper composes the shell around
    the page instead, so delete render/1 and put its body in the two callbacks:

      * `tenant_page/1`    — everything inside the shell's <main>: the topbar, banners and the
                             page's `.wrap`/`.pane` panel.
      * `tenant_sidebar/1` — the shell's `:sidebar` slot (the page's own sidebar).
    """
  end

  defp missing_refusal(module, callback) do
    case callback do
      :tenant_page ->
        """
        #{inspect(module)} uses Samen.Web.Tenant.Live but defines no tenant_page/1.

        The wrapper renders the page through it: `tenant_page/1` is everything inside the shell's
        <main> — the topbar, any banner, and the page's own content in a `.wrap`/`.pane` panel.
        """

      :tenant_sidebar ->
        """
        #{inspect(module)} uses Samen.Web.Tenant.Live but defines no tenant_sidebar/1.

        The wrapper renders it as the shell's `:sidebar` slot. The framework deliberately has no
        default: `module_nav/1` would emit the framework's DEFAULT paths (`/crm`, `/settings`, …)
        for routes the host may never have mounted, and a link to an unmounted route raises
        `Phoenix.Router.NoRouteError` on the first click. State the sidebar this page mounts.
        """
    end
  end

  @doc """
  Compose the shell around `module`'s `tenant_sidebar/1` and `tenant_page/1` — the ONE seam every
  wrapper page renders through (its injected `render/1` calls exactly this, and so can a test
  that renders a page module directly). `module.tenant_assigns/1` runs first, so the page's
  assign defaults are in place before either callback renders.
  """
  def tenant_shell(module, assigns) when is_atom(module) and is_map(assigns) do
    # A direct caller (a test, or a `load/*` helper rendering a page by hand) may hand in a bare
    # map: `assign_new/3` needs the assigns' change-tracking key to exist, which is the same
    # tolerance `Samen.WebTest.DataCase.render_html/2` gives. A real render already carries it,
    # so this is a no-op there.
    assigns = Map.put_new(assigns, :__changed__, %{})
    assigns = module.tenant_assigns(assigns)

    shell(%{
      sidebar_html: module.tenant_sidebar(assigns),
      page_html: module.tenant_page(assigns)
    })
  end

  attr :sidebar_html, :any, required: true
  attr :page_html, :any, required: true

  defp shell(assigns) do
    ~H"""
    <.app_shell>
      <:sidebar>{@sidebar_html}</:sidebar>
      {@page_html}
    </.app_shell>
    """
  end
end
