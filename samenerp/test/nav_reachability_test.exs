defmodule Samenerp.NavReachabilityTest do
  @moduledoc """
  SIDEBAR-REACHABILITY (2026-10-10) — the seven mount phases (`docs/samenerp-mount-ledger.md`)
  adopted module groups at ≈0 authored LOC, but a mounted surface is not a REACHABLE one: the
  phase pages were islands, reachable only by hand-typing a URL. This is the host-side proof that
  the app's own sidebar now carries them, driven through the REAL router (the
  `Samenerp.Phase1..7SurfaceTest` discipline — no mount is constructed by hand here).

  Three legs:

    1. **reachable** — the sidebar of an ordinary tenant page (CRM Companies, which mounts none of
       these modules itself) lists every phase module the router mounts. The groups are inherited
       chrome, so this must hold on EVERY tenant page, not only on the module's own pages.
    2. **no dead links** — every `href` that sidebar emits resolves to a route
       `SamenerpWeb.Router` actually declares. The X1 posture is "render a group exactly when the
       host mounted it"; the way that promise rots is a label drifting from its route macro
       (e.g. `path: "/conversations"` for chat while `chat_path` still says `/chat`), and this leg
       catches exactly that drift. The resolver is refutable (a fabricated path is NOT reported
       mounted), so the assertion cannot pass vacuously.
    3. **the entries are data** — the group paths come from this host's shared tenant label map, so
       `Samen.UI.Nav.nav_paths/1` (and therefore the nav) is correct for ANY mounted subset.

  NOT covered here, deliberately: Phase 5's `:kb` / `:csat` are PUBLIC, pre-actor portal kinds
  (an unauthenticated visitor has no sidebar to render them in), and Phase 3's CSV surface is an
  ACTION on a per-resource route (`/csv/import/:resource`), not a destination — neither owes a
  sidebar entry. Phase 4's webhook ingress is vendor-facing by design (its operator-side DLQ
  lives in the operator nav), so only the flag admin joins the sidebar.
  """

  use Samenerp.DataCase, async: false

  import Phoenix.ConnTest

  alias Samenerp.Operator, as: Op

  @endpoint SamenerpWeb.Endpoint

  # {group label, item label, path} — one entry per mounted phase module that owes a destination.
  @phase_entries [
    {"Documents", "Files", "/files"},
    {"Chat", "Conversations", "/chat"},
    {"Discover", "Search", "/search"},
    {"Insights", "Activation", "/analytics"},
    {"Calendar", "Export .ics", "/calendar.ics"},
    {"AI", "AI workspace", "/ai"}
  ]

  # Inert/un-navigable targets a sidebar legitimately renders (a `#` affordance, the root).
  @inert_hrefs ["#", "", "/"]

  setup do
    start_supervised!(SamenerpWeb.Endpoint)
    :ok
  end

  defp create_org!(name) do
    Op.Org
    |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  # A tenant page that mounts NONE of the phase surfaces itself: whatever appears here is the
  # inherited sidebar, which is the thing under test. Returns the `<aside class="side">` region
  # ONLY — the route-table leg below must judge NAV links, not the root layout's asset `<link>`s.
  defp sidebar_html(org) do
    conn = get(build_conn(), "/crm/companies?org=#{org.id}")

    assert conn.status == 200,
           "GET /crm/companies did not render (status=#{conn.status}) — the CRM mount is missing or crashing"

    case Regex.run(~r/<aside class="side">.*?<\/aside>/s, conn.resp_body) do
      [sidebar] ->
        sidebar

      nil ->
        flunk(
          "the tenant page rendered no `<aside class=\"side\">` sidebar — the inherited chrome " <>
            "is missing, so nothing below could be judged"
        )
    end
  end

  defp hrefs(html) do
    ~r/href="([^"]+)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, href] -> href end)
    |> Enum.uniq()
  end

  test "the app's own sidebar reaches every phase module the router mounts" do
    org = create_org!("Nav Reachability QA")
    html = sidebar_html(org)

    for {group, item, path} <- @phase_entries do
      assert html =~ ">#{group}<",
             "the #{group} group is missing from the tenant sidebar (the phase mount is " <>
               "unreachable from the app itself — hand-typed URLs only)"

      assert html =~ ~r/>\s*#{Regex.escape(item)}\s*<\/a>/,
             "the #{item} item is missing from the #{group} group"

      href = if String.ends_with?(path, ".ics"), do: path, else: "#{path}?org=#{org.id}"

      assert html =~ ~s(href="#{href}"), "the #{item} entry must link #{href}"
    end

    # Phase 4's flag admin rides the Workspace group (a settings surface, not a module page).
    assert html =~ ~r/>\s*Feature flags\s*<\/a>/
    assert html =~ ~s(href="/flags?org=#{org.id}")
  end

  test "every nav link the tenant sidebar emits resolves to a route this host declares" do
    org = create_org!("Nav Dead-Link QA")
    html = sidebar_html(org)

    links = html |> hrefs() |> Enum.reject(&(&1 in @inert_hrefs))

    assert links != [], "the sidebar emitted no links at all — the page or the scan broke"

    for href <- links do
      assert mounted?(href),
             "the sidebar links #{href}, which SamenerpWeb.Router does not serve — " <>
               "Phoenix.Router.NoRouteError on the user's first click"
    end

    # ANTI-TAUTOLOGY: the resolver can fail. If `mounted?/1` returned true unconditionally every
    # assertion above would be vacuous.
    refute mounted?("/definitely/not/a/route"),
           "mounted?/1 reported a fabricated path as served — the dead-link scan is vacuous"

    refute mounted?("/nope?org=#{org.id}")
  end

  test "the sidebar groups are DATA on the tenant mount (nav_paths/1 is the single seam)" do
    labels = %{
      files_path: "/files",
      chat_path: "/chat",
      search_path: "/search",
      analytics_path: "/analytics",
      ics_path: "/calendar.ics",
      ai_path: "/ai",
      flags_path: "/flags"
    }

    mounted =
      Samen.Web.Mount.new(:crm, Samenerp.Crm, Samenerp.Repo,
        plane: Samen.Web.Plane.tenant(),
        labels: labels
      )

    bare = Samen.Web.Mount.new(:crm, Samenerp.Crm, Samenerp.Repo, plane: Samen.Web.Plane.tenant())

    paths = Samen.UI.nav_paths(mounted)

    for {key, path} <- labels do
      assert paths[key] == path, "#{key} did not resolve from the mount labels"
    end

    # The red half: WITHOUT the labels the nav resolves none of them, so a host that never wrote
    # those lines (or deleted one) emits no group instead of a dead link.
    bare_paths = Samen.UI.nav_paths(bare)

    for {key, _path} <- labels do
      assert bare_paths[key] == nil, "#{key} resolved without its label — the gate is broken"
    end
  end

  # ---- the route-table resolver -------------------------------------------------------------

  defp mounted?(href) do
    path = href |> String.split("?") |> hd()

    Enum.any?(SamenerpWeb.Router.__routes__(), fn route -> path_matches?(route.path, path) end)
  end

  # A declared route matches when the segment counts agree and every segment is either a dynamic
  # one (`:id` / `*glob`) or byte-equal.
  defp path_matches?(declared, path) do
    declared_segments = segments(declared)
    path_segments = segments(path)

    length(declared_segments) == length(path_segments) and
      Enum.all?(Enum.zip(declared_segments, path_segments), fn {declared, actual} ->
        dynamic?(declared) or declared == actual
      end)
  end

  defp dynamic?(segment) do
    String.starts_with?(segment, ":") or String.starts_with?(segment, "*")
  end

  defp segments(path), do: path |> String.split("/") |> Enum.reject(&(&1 == ""))
end
