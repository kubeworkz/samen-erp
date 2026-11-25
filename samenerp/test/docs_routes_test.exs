defmodule Samenerp.DocsRoutesTest do
  @moduledoc """
  DOCS-REACHABILITY — `SamenerpWeb.Docs` is DATA (15 sidebar-matching groups, one
  `{name, path, note}` row per feature), and every path in it is a promise that
  the reader can click through to the live screen. This is the same discipline
  `Samenerp.NavReachabilityTest` applies to the sidebar's http links, applied to
  the docs: a path that drifts from the route macro (a renamed surface, a
  `/conversations`-for-`/chat` slip) must fail HERE, not on a reader's first
  click.

  Four legs:

    1. **the docs surface is mounted** — `/docs` and `/docs/:id` are declared
       routes owned by `SamenerpWeb.DocsController` (`:index` / `:show`), so the
       index cannot vanish while a deeper page still matches the wildcard.
    2. **no dead links** — every `/docs/<id>` the index emits resolves to a real
       catalog entry, and every feature `path` resolves to a route this host
       declares. The resolver is refutable (a fabricated path is NOT reported
       mounted) and the catalog is non-trivial, so neither assertion can pass
       vacuously.
    3. **reachable** — every category and guide is linked from `/docs` itself
       (the sidebar-reachability posture: a page nothing links is an island).
    4. **the rendered pages emit only live targets** — every `href` in every
       rendered doc page (index, each category, the guide, the 404) is a route
       this router serves, so the shared layout's chrome cannot rot either.
  """

  use ExUnit.Case, async: true

  alias SamenerpWeb.Docs

  # Links a page legitimately renders that are not routes of this host.
  @inert_hrefs ["#", "", "/"]

  test "the docs index and every documentation page are mounted routes" do
    index_routes = Enum.filter(routes(), &(&1.path == "/docs"))

    assert index_routes != [],
           "SamenerpWeb.Router declares no `/docs` route — the documentation link on the landing " <>
             "page would 404 (a bare `/docs/:id` route does NOT serve `/docs`)"

    for route <- index_routes do
      assert route.plug == SamenerpWeb.DocsController,
             "`/docs` is served by #{inspect(route.plug)}"

      assert route.plug_opts == :index, "`/docs` dispatches to #{inspect(route.plug_opts)}"
    end

    assert mounted?("/docs/:id"), "SamenerpWeb.Router declares no `/docs/:id` route"

    for route <- routes(), route.path == "/docs/:id" do
      assert route.plug == SamenerpWeb.DocsController,
             "`/docs/:id` is served by #{inspect(route.plug)}"

      assert route.plug_opts == :show, "`/docs/:id` dispatches to #{inspect(route.plug_opts)}"
    end

    assert length(Docs.groups()) > 1,
           "the docs catalog is empty — the scan below would be vacuous"

    assert is_binary(Docs.getting_started_html()),
           "the getting-started guide renders no page"
  end

  test "every documentation page id is served and every feature path is mounted" do
    # `/docs/:id` is a wildcard, so the route table alone cannot tell a real
    # category from a typo: the catalog (and its controller) is the oracle.
    for group <- Docs.groups() do
      assert Docs.group(group.id) == group,
             "the catalog does not resolve its own group #{group.id}"

      assert mounted?("/docs/#{group.id}"),
             "`/docs/#{group.id}` does not match the declared `/docs/:id` route"

      refute Docs.group_html(group.id) == nil,
             "`/docs/#{group.id}` renders no page (the controller would 404 it)"
    end

    for guide <- Docs.guides() do
      assert mounted?("/docs/#{guide.id}"), "`/docs/#{guide.id}` is not served by `/docs/:id`"

      assert is_binary(Docs.getting_started_html()),
             "`/docs/#{guide.id}` renders no guide page (the controller would fall through)"
    end

    assert Docs.page_count() ==
             Docs.groups() |> Enum.map(&length(&1.pages)) |> Enum.sum()

    assert Docs.page_count() > 0, "the catalog documents no feature pages"

    for group <- Docs.groups(), {name, path, _note} <- group.pages do
      assert is_binary(path) and String.starts_with?(path, "/"),
             "#{group.id}/#{name} documents #{inspect(path)}, which is not a rooted path"

      assert live_target?(path),
             "the docs link #{path} (#{group.label} → #{name}) has no live target in " <>
               "SamenerpWeb.Router — either no route serves it (a Phoenix.Router.NoRouteError on " <>
               "the reader's first click), or it rides the `/erp/:surface` wildcard under a name " <>
               "`Samen.Web.Erp.surfaces/0` does not carry, in which case the surface page renders " <>
               "its not-found state"
    end

    # ANTI-TAUTOLOGY: the resolver can fail. Without this, every assertion above
    # could be satisfied by a matcher that answers true unconditionally.
    refute mounted?("/definitely/not/a/route"),
           "mounted?/1 reported a fabricated path as served — the dead-link scan is vacuous"

    refute docs_page?("/docs/definitely-not-a-category"),
           "docs_page?/1 accepted an id that is neither a category nor a guide — the page-id scan " <>
             "would be vacuous (`/docs/:id` is a wildcard, so the route table alone cannot tell them " <>
             "apart: the catalog is the oracle)"

    refute mounted?("/docs/erp/not-a-page"),
           "mounted?/1 matched a two-segment path against the one-segment `/docs/:id` route"
  end

  test "the documentation index links every category, guide and feature page" do
    html = Docs.index_html()

    for group <- Docs.groups() do
      assert html =~ ~s(href="/docs/#{group.id}"),
             "#{group.label} has no link to `/docs/#{group.id}` from the index"

      assert html =~ Phoenix.HTML.safe_to_string(Phoenix.HTML.html_escape(group.label)),
             "the index does not name the #{group.label} category"

      for {name, path, _note} <- group.pages do
        assert html =~ ~s(href="#{path}"),
               "the index does not link #{path} (#{group.label} → #{name})"
      end
    end

    for guide <- Docs.guides() do
      assert html =~ ~s(href="/docs/#{guide.id}"),
             "the #{guide.title} guide is not linked from the index"
    end
  end

  test "every href the rendered documentation pages emit is a route this host serves" do
    pages =
      [
        {"index", Docs.index_html()},
        {"404", Docs.not_found_html()},
        {"getting-started", Docs.getting_started_html()}
      ] ++
        Enum.map(Docs.groups(), fn group -> {group.id, Docs.group_html(group.id)} end)

    for {name, html} <- pages, href <- hrefs(html) do
      cond do
        href in @inert_hrefs or String.starts_with?(href, ["http://", "https://", "mailto:"]) ->
          :ok

        String.starts_with?(href, "/docs") ->
          assert docs_page?(href),
                 "the #{name} page links #{href}, which is neither `/docs`, a category, nor a guide"

        true ->
          assert mounted?(href),
                 "the #{name} page links #{href}, which SamenerpWeb.Router does not serve"
      end
    end
  end

  # ---- the route-table resolver (the nav guard's own matcher) ------------------

  defp routes, do: SamenerpWeb.Router.__routes__()

  # A mounted path that still lands on a page. `/erp/:surface` is a WILDCARD, so the route
  # table says yes to `/erp/anything`; `Samen.Web.Erp.surface/1` is the closed allowlist the
  # surface LiveView actually resolves through, and an unlisted name renders its not-found
  # state — a dead link that matching alone would miss. Same oracle the runtime uses.
  defp live_target?("/erp/" <> surface), do: mounted?("/erp/" <> surface) and erp_target?(surface)
  defp live_target?(path), do: mounted?(path)

  defp erp_target?(surface) do
    statically_declared?(surface) or Samen.Web.Erp.surface(surface) != nil
  end

  defp statically_declared?(surface) do
    Enum.any?(routes(), &(&1.path == "/erp/" <> surface))
  end

  defp mounted?(href) do
    path = href |> String.split("?") |> hd()

    Enum.any?(routes(), fn route -> path_matches?(route.path, path) end)
  end

  defp docs_page?("/docs"), do: true

  defp docs_page?("/docs/" <> id) do
    id = id |> String.split("?") |> hd()
    Docs.group(id) != nil or Enum.any?(Docs.guides(), &(&1.id == id))
  end

  defp docs_page?(_other), do: false

  # A declared route matches when the segment counts agree and every segment is
  # either a dynamic one (`:id` / `*glob`) or byte-equal.
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

  defp hrefs(html) do
    ~r/href="([^"]+)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, href] -> href end)
    |> Enum.uniq()
  end
end
