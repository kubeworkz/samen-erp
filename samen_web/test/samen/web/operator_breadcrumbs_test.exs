defmodule Samen.Web.OperatorBreadcrumbsTest do
  @moduledoc """
  The operator plane's breadcrumb trails are **live** — the reported "the breadcrumbs don't
  work" on Operator → Portfolio.

  `Samen.UI.topbar/1` renders a `{label, href}` crumb as a link and a plain string as INERT
  text. The tenant trails got that right (`Samen.Web.Crumbs.org/2` links the org name at the
  workspace Dashboard), but every operator page passed `"Operator plane"` as a STRING: the
  plane declares no route at its prefix (`samen_operator_routes/2` mounts `/operator/accounts`,
  `…/desk`, … and never `/operator` itself), so the plane marker had nowhere real to point and
  the WHOLE plane had no clickable crumb in any trail — an operator three screens deep had no
  breadcrumb path back. `Crumbs.operator/0` links it at the plane's entry (Accounts).

  Three legs, each paired with a control:

    * GREEN — `operator/0` is a tuple at the plane's entry, and that href is the SAME one the
      operator sidebar's Accounts item renders (one source of truth; `samen.verify.nav_links`
      dead-link-checks that sidebar href against the host router, so the crumb's destination is
      certified by the same gate the nav item is). `operator_section/1` links a real index and
      refuses `:accounts`, which is `operator/0`'s own destination.
    * RENDERED — the REAL Portfolio page (`AggregateLive.render/1`) leads with that live crumb
      and its leaf is INERT (it never links to itself), and the stale mid-trail label
      ("Aggregate", the page's old name) is gone from the trail.
    * SWEEP — every operator LiveView that renders a topbar LEADS its trail with that crumb, so
      a new operator screen cannot ship an inert trail. The sabotage twin
      (`scripts/sabotages/401-operator-breadcrumb-inert-again.patch`) reverts one page and this
      leg must fail.
  """
  use ExUnit.Case, async: true

  alias Samen.Web.Crumbs
  alias Samen.Web.Mount
  alias Samen.Web.Operator.AggregateLive

  @operator_lib ["lib", "samen", "web", "operator"]

  # ── leg 1 — the seam, and the one source of truth it shares with the sidebar ────────────────

  test "GREEN: operator/0 is a LIVE crumb at the plane's entry — the sidebar's own Accounts href" do
    assert {"Operator plane", href} = Crumbs.operator()

    # The plane's ENTRY, not its prefix: there is no `/operator` index route to link, which is
    # exactly why the marker used to be inert text.
    assert href == "/operator/accounts"

    # …and it is the href the operator nav itself offers, rendered from the real component: the
    # crumb and the nav item cannot disagree about where the plane begins.
    sidebar =
      Phoenix.LiveViewTest.__render_component__(
        nil,
        &Samen.Web.Operator.Live.operator_sidebar/1,
        %{
          mount: Mount.new(:operator, nil, nil, labels: %{}),
          active: nil,
          operator_role: nil,
          __changed__: %{}
        },
        []
      )

    assert sidebar =~ ~s(href="#{href}")
  end

  test "GREEN: operator_section/1 links a real index — and :accounts is refused, not guessed" do
    assert {"Desk", "/operator/desk"} = Crumbs.operator_section(:desk)
    assert {"Fleet", "/operator/fleet"} = Crumbs.operator_section(:fleet)

    # `:accounts` is deliberately NOT a section: it is `operator/0`'s destination, so a trail
    # asking for it would render two crumbs to one href. A programming error, not a nil.
    #
    # Called through `apply/3` on purpose: the spec is deliberately narrow (`:desk | :fleet`), and
    # a literal call would make the type checker warn about the very refusal this asserts. The
    # refusal is a RUNTIME property here, so it is exercised at runtime.
    assert_raise FunctionClauseError, fn -> apply(Crumbs, :operator_section, [:accounts]) end
  end

  # ── leg 2 — the rendered Portfolio page ──────────────────────────────────────────────────────

  test "RENDERED: the Portfolio page leads with a live crumb and links NOTHING else" do
    mount = Mount.new(:aggregate, Some.Host.Aggregate, Some.Host.Repo, labels: %{})

    html =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> AggregateLive.load()
      |> Map.get(:assigns)
      |> Map.put(:__changed__, %{})
      |> AggregateLive.render()
      |> Phoenix.HTML.Safe.to_iodata()
      |> IO.iodata_to_binary()

    # The page really rendered (so the assertions below cannot pass on an empty string).
    assert html =~ ~s(id="operator-aggregate")
    assert html =~ ~s(class="crumb")

    # The crumb the operator clicks.
    assert html =~ ~r/<a[^>]+href="\/operator\/accounts"[^>]*>\s*Operator plane\s*<\/a>/

    # The LEAF is the page you are already on: text, never a link to itself.
    refute html =~ ~r/<a[^>]*>\s*Portfolio\s*<\/a>/
    assert html =~ "Portfolio"

    # The stale mid-trail label — the page's OLD name, "Aggregate" — is gone from the trail; the
    # sidebar's own item reads "Aggregate · portfolio", so an exact `>Aggregate<` cannot be that.
    refute html =~ ~r/>\s*Aggregate\s*</
  end

  # ── leg 3 — the plane-wide sweep ─────────────────────────────────────────────────────────────

  test "SWEEP: every operator trail LEADS with that live crumb (no inert operator trail)" do
    trails =
      operator_sources()
      |> Enum.flat_map(fn {file, body} ->
        ~r/crumbs=\{\[(.{0,60})/s
        |> Regex.scan(body)
        |> Enum.map(fn [_, open] -> {file, String.trim_leading(open)} end)
      end)

    # Anti-vacuous: the scan really read the plane's pages. A wrong cwd (or a renamed directory)
    # would find zero trails and pass this test while certifying nothing.
    assert length(trails) >= 19,
           "the sweep found only #{length(trails)} operator trail(s) — it is not reading the plane"

    inert = Enum.reject(trails, fn {_file, open} -> String.starts_with?(open, "Crumbs.operator()") end)

    assert inert == [],
           "operator trail(s) that do NOT lead with Crumbs.operator(), i.e. an INERT operator " <>
             "trail — the reported 'breadcrumbs don't work'. Every operator topbar trail starts " <>
             "with the live plane crumb: #{inspect(inert)}"
  end

  defp operator_sources do
    [File.cwd!() | @operator_lib]
    |> Path.join()
    |> Path.join("*.ex")
    |> Path.wildcard()
    |> Enum.map(&{Path.basename(&1), File.read!(&1)})
  end
end
