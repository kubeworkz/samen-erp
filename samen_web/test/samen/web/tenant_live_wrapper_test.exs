defmodule Samen.Web.TenantLiveWrapperTest do
  @moduledoc """
  `Samen.Web.Tenant.Live` — the tenant page wrapper: the app shell is composed AROUND the page's
  render, and a page cannot get outside it.

  ## The defect class this closes

  A tenant surface that renders outside the chrome is not a missing feature, it is a page a
  tenant cannot leave: no sidebar, no workspace header, no way back — and on mobile no drawer.
  Three shipped surfaces did exactly that (the first-run wizard and the 2FA enrollment page as
  lone centred cards on an empty viewport, the CRM dashboard with its `.dash-grid` hung flush off
  the shell's edge). The tenant-chrome sweep (`tenant_shell_coverage_test.exs`) DETECTS the next one at test
  time; this wrapper removes the possibility: a page written through it has no `render/1` of its
  own, so there is no shell to forget, no shell to copy, and nothing to drift.

  ## What is proven here

    * **GREEN (composition)** — the page's own markup is rendered INSIDE `<main class="main">`,
      with the shell's `.app`/sidebar/mobile-drawer chrome around it, reached only through
      `Samen.Web.Tenant.Live.tenant_shell/2` (the injector's one seam).
    * **RED (the construction)** — a page that defines its OWN `render/1` is refused with a
      `CompileError` naming the callback to use instead, and one that omits `tenant_page/1` or
      `tenant_sidebar/1` is refused the same way; the module never becomes loadable. Each red path
      carries a positive control — the SAME module, with the offending clause removed, compiles.
    * **SABOTAGE TWIN** — the assertion is refutable: the identical predicate applied to a page
      rendered WITHOUT the wrapper goes red, so "inside the main panel" is a genuine discriminator
      and not a spelling of "renders at all".
  """

  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias Samen.Web.Tenant.Live, as: TenantLive

  # ==========================================================================
  # Fixtures — pages written the way a page is written
  # ==========================================================================

  defmodule Page do
    @moduledoc false
    use Samen.Web.Tenant.Live

    @impl Samen.Web.Tenant.Live
    def tenant_sidebar(assigns) do
      ~H"""
      <div id="fixture-sidebar">the page's own sidebar</div>
      """
    end

    @impl Samen.Web.Tenant.Live
    def tenant_page(assigns) do
      ~H"""
      <div class="wrap" id="fixture-page">the page's own content</div>
      """
    end
  end

  # The optional hook, used the way a page uses it: assign defaults for a synthetic socket.
  defmodule AssignsPage do
    @moduledoc false
    use Samen.Web.Tenant.Live

    @impl Samen.Web.Tenant.Live
    def tenant_assigns(assigns), do: assign_new(assigns, :label, fn -> "framework-default" end)

    @impl Samen.Web.Tenant.Live
    def tenant_sidebar(assigns) do
      ~H"""
      <div id="fixture-sidebar">{@label}</div>
      """
    end

    @impl Samen.Web.Tenant.Live
    def tenant_page(assigns) do
      ~H"""
      <div class="wrap" id="fixture-page">page</div>
      """
    end
  end

  # The twin: the same markup, rendered with no wrapper at all — the shape the sweep exists to
  # find and the wrapper exists to make unwritable.
  defmodule BarePage do
    @moduledoc false
    use Phoenix.Component

    def bare(assigns) do
      ~H"""
      <div class="wrap" id="fixture-page">the page's own content</div>
      """
    end
  end

  # ==========================================================================
  # GREEN — the shell is composed around the page's render
  # ==========================================================================

  test "the page's markup renders INSIDE the shell's main panel" do
    html = render_page(Page)

    # The shared shell: the two-pane `.app`, the sidebar slot, and the CSS-only mobile drawer
    # that comes with it (`Samen.UI.app_shell/1`) — a page cannot render without them.
    assert html =~ ~s(<div class="app">)
    assert html =~ ~s(<main class="main">)
    assert html =~ ~s(id="samen-nav-toggle")

    # The page's own sidebar is the shell's sidebar…
    assert html =~ ~s(<div id="fixture-sidebar">the page's own sidebar</div>)

    # …and its own content is inside <main>, never beside or above it. Splitting on the <main>
    # opening tag is the strongest form of the claim: nothing the page renders may precede it.
    assert [before_main, inside_main] = String.split(html, ~s(<main class="main">), parts: 2)

    refute before_main =~ "the page's own content",
           "the page's content rendered OUTSIDE the shell's <main> — that is the defect"

    assert inside_main =~ "the page's own content"
    assert inside_main =~ ~s(<div class="wrap" id="fixture-page">)

    # …and the sidebar really is in the shell (not inside the page's own markup).
    assert before_main =~ ~s(<div id="fixture-sidebar">)
  end

  test "the injected render/1 IS the page's render/1 — there is no second path to the shell" do
    assert function_exported?(Page, :render, 1)

    # The page is rendered by the wrapper and by nothing else: its own `render/1` produces exactly
    # what the composition seam produces.
    assert rendered_to_string(Page.render(%{})) ==
             rendered_to_string(TenantLive.tenant_shell(Page, %{}))
  end

  # ==========================================================================
  # RED — the construction is enforced by the COMPILER
  # ==========================================================================

  @own_render ~S'''
  defmodule WrapperRedPath.OwnRender do
    use Samen.Web.Tenant.Live

    @impl Samen.Web.Tenant.Live
    def tenant_sidebar(assigns), do: ~H"<div>side</div>"

    @impl Samen.Web.Tenant.Live
    def tenant_page(assigns), do: ~H"<div>page</div>"

    def render(assigns), do: ~H"<div id='escaped'>no chrome at all</div>"
  end
  '''

  @same_page_without_render ~S'''
  defmodule WrapperRedPath.Good do
    use Samen.Web.Tenant.Live

    @impl Samen.Web.Tenant.Live
    def tenant_sidebar(assigns), do: ~H"<div>side</div>"

    @impl Samen.Web.Tenant.Live
    def tenant_page(assigns), do: ~H"<div>page</div>"
  end
  '''

  @no_page ~S'''
  defmodule WrapperRedPath.NoPage do
    use Samen.Web.Tenant.Live

    @impl Samen.Web.Tenant.Live
    def tenant_sidebar(assigns), do: ~H"<div>side</div>"
  end
  '''

  @no_sidebar ~S'''
  defmodule WrapperRedPath.NoSidebar do
    use Samen.Web.Tenant.Live

    @impl Samen.Web.Tenant.Live
    def tenant_page(assigns), do: ~H"<div>page</div>"
  end
  '''

  test "RED — a page that defines its own render/1 does not compile" do
    err = assert_raise CompileError, fn -> Code.compile_string(@own_render) end

    # The refusal names the thing that was written and the two callbacks to write instead…
    assert err.description =~ "defines its own render/1"
    assert err.description =~ "tenant_page/1"
    assert err.description =~ "tenant_sidebar/1"
    # …and says WHY, so the next reader does not "fix" it by deleting the wrapper.
    assert err.description =~ ~r/OUTSIDE the shared\s+chrome/

    # The page never becomes a page: nothing to mount, nothing to render outside the shell.
    refute Code.ensure_loaded?(WrapperRedPath.OwnRender)

    # ANTI-TAUTOLOGY CONTROL — the same module, minus the offending clause, compiles clean. If
    # this failed, the red path might be passing because the wrapper is broken in general.
    assert [{WrapperRedPath.Good, _}] = Code.compile_string(@same_page_without_render)
  end

  test "RED — a page that omits a required callback does not compile" do
    page_err = assert_raise CompileError, fn -> Code.compile_string(@no_page) end
    assert page_err.description =~ "defines no tenant_page/1"
    assert page_err.description =~ ~r/inside the shell's\s+<main>/
    refute Code.ensure_loaded?(WrapperRedPath.NoPage)

    side_err = assert_raise CompileError, fn -> Code.compile_string(@no_sidebar) end
    assert side_err.description =~ "defines no tenant_sidebar/1"
    # …with the dead-link reason attached: the framework must not default the nav.
    assert side_err.description =~ "Phoenix.Router.NoRouteError"
    refute Code.ensure_loaded?(WrapperRedPath.NoSidebar)

    # The two refusals are DISTINCT — one missing callback is not reported as the other, so the
    # diagnostic always names the thing that is actually missing.
    refute page_err.description == side_err.description
  end

  # ==========================================================================
  # GREEN — the optional hook is real
  # ==========================================================================

  test "tenant_assigns/1 runs before the callbacks render, and its default is overridable" do
    # A synthetic socket (a test calling `load/*` and rendering the page) gets the page's own
    # defaults — the reason the hook exists.
    bare = render_page(AssignsPage)
    assert bare =~ "framework-default"

    # …and a real mount's assign wins, because the hook is `assign_new/3`-shaped.
    overridden = render_page(AssignsPage, %{label: "from-the-mount"})
    assert overridden =~ "from-the-mount"
    refute overridden =~ "framework-default"
  end

  # ==========================================================================
  # SABOTAGE TWIN — the assertions discriminate
  # ==========================================================================

  test "SABOTAGE TWIN — a page rendered WITHOUT the wrapper fails the same assertions" do
    wrapped = render_page(Page)
    bare = rendered_to_string(BarePage.bare(%{}))

    # The same markup, the same `.wrap` pane — and no chrome, which is the whole difference the
    # wrapper makes. If `bare` matched these, the green assertions above would prove nothing.
    assert bare =~ ~s(<div class="wrap" id="fixture-page">)
    refute bare =~ ~s(<div class="app">)
    refute bare =~ ~s(<main class="main">)

    assert wrapped =~ ~s(<main class="main">)
    assert_raise ExUnit.AssertionError, fn -> assert bare =~ ~s(<main class="main">) end

    # …and the "inside <main>" split the green test asserts on: for the bare page there is no
    # `<main>` to split on at all, so the assertion cannot pass vacuously.
    refute String.contains?(bare, ~s(<main class="main">))
  end

  defp render_page(module, assigns \\ %{}) do
    rendered_to_string(TenantLive.tenant_shell(module, assigns))
  end
end
