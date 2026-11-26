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

    5. **completeness, not just soundness** — every surface the sidebar renders
       (one item per `Samen.Web.Erp.surfaces/0` entry) has a docs row. Legs 1-4
       are one-directional (docs ⊆ routes): they stayed green while Expense
       Reports, Expense Categories and Corporate Cards were sidebar-visible and
       documented nowhere, so the catalog could silently fall behind the
       allowlist. This leg fails on a MISSING row, not a broken one.

  What a route table cannot prove is that the page RENDERS: this case stayed
  green while `/erp/stock` and `/erp/ap-capture` both answered 500 (a resource
  column that had drifted out of the dev DB, and an obsolete positional
  `live_file_input/1`). That leg is `Samenerp.DocsRenderTest` at the bottom of
  this file — the same guard, driven through the real router over every
  documented page, because the catalog links only list and landing screens (no
  `/crm/contacts/:id`), and those all mount from a bare org row.
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

  test "every surface the sidebar renders is documented, under the registry's own label" do
    # `Samen.UI.Nav.module_nav/1` renders one ERP item per
    # `Samen.Web.Erp.surfaces/0` entry, so the sidebar's surface list IS the
    # catalog's floor. The legs above are soundness only (docs ⊆ routes): they
    # stayed green while the three E31 expense surfaces rendered in the sidebar
    # and appeared nowhere in `/docs`, because a missing row breaks no link.
    documented = for group <- Docs.groups(), {_name, path, _note} <- group.pages, do: path

    for surface <- Samen.Web.Erp.surfaces() do
      path = "/erp/#{surface}"
      label = Samen.Web.Erp.label(surface)

      assert path in documented,
             "#{label} (#{surface}) renders in the sidebar but /docs links no #{path} — add it to " <>
               "the ERP group in `SamenerpWeb.Docs`"

      # A row that survives a registry rename under the old name documents a
      # screen the sidebar no longer calls that: the label is the sidebar's, so
      # the catalog cites the same one ("grouped exactly as the sidebar" must
      # be true of the text, not only of the count).
      assert documented_label(path) == label,
             "/docs lists #{path} as #{inspect(documented_label(path))} but the sidebar renders it " <>
               "as #{inspect(label)} — the docs row drifted from `Samen.Web.Erp.label/1`"
    end

    # ANTI-TAUTOLOGY: the completeness scan can fail, so it is not satisfied by
    # any path at all. A surface-shaped path outside the allowlist is absent.
    refute "/erp/definitely-not-a-surface" in documented,
           "the catalog listed a fabricated ERP surface — the completeness scan is vacuous"
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

  defp documented_label(path) do
    Enum.find_value(Docs.groups(), fn group ->
      Enum.find_value(group.pages, fn {name, documented_path, _note} ->
        if documented_path == path, do: name
      end)
    end)
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

defmodule Samenerp.DocsRenderTest do
  @moduledoc """
  DOCS-RENDER — the half of the docs promise the route guard cannot reach. Every
  path in `SamenerpWeb.Docs` resolving to a mounted route says nothing about the
  page behind it: `/erp/stock` and `/erp/ap-capture` were both documented, both
  mounted, and both answered 500 (a resource column that had drifted out of the
  dev database, and an obsolete positional `live_file_input/1`). This case asks
  the remaining question through the REAL router — does the documented page
  actually render the page it names?

  Scope is every documented page, and it is cheap because the catalog links only
  list and landing screens: `/crm/companies`, `/work`, `/files`, `/chat`,
  `/search`, `/analytics`, `/flags` and the rest all mount from a bare org row
  with no fixtures, no `:id` and no seeded rows, so one `GET` per page is the
  proof. The host's DETAIL pages (`/crm/contacts/:id`, `/pages/:id`,
  `/files/:id`, …) are not documented and are deliberately out of scope — they
  need host fixtures — so this stays a render guard, not an end-to-end suite.

  Pages that share a route prefix are additionally anchored on their root id:
  `/crm/gallery` and `/crm/contacts` (or `/billing` and `/billing/plans`) both
  answer 200 in the same shell, so only the id catches a docs entry that drifted
  onto the wrong sibling. Pages with one URL need no anchor.
  """

  use Samenerp.DataCase, async: false

  import Phoenix.ConnTest

  alias Samenerp.Operator, as: Op
  alias SamenerpWeb.Docs

  @endpoint SamenerpWeb.Endpoint

  # Every documented path under these prefixes has a LIVE SIBLING one URL away
  # (`/crm/gallery` vs `/crm/contacts`, `/billing` vs `/billing/plans`), so a docs
  # entry that drifted onto the wrong one still answers 200 in the shell and only
  # the root id can tell them apart. Pages with a single URL (`/files`, `/chat`,
  # `/search`, …) need no anchor: status + shell is already the whole promise.
  @paged_prefixes ["/erp", "/crm", "/billing", "/marketing", "/banking", "/work"]

  # The root element each anchored page renders. Kept deliberately to the shared-prefix
  # subset — 61 rows pinned every UI detail to the docs; these pin the one real ambiguity.
  # The catalog/table agreement assert below keeps this in step with the docs.
  @page_ids %{
    "/erp" => "erp-dashboard",
    "/erp/coa" => "erp-surface",
    "/erp/entries" => "erp-surface",
    "/erp/journal_templates" => "erp-surface",
    "/erp/ap_invoices" => "erp-surface",
    "/erp/credit_notes" => "erp-surface",
    "/erp/vendor_credits" => "erp-surface",
    "/erp/stock" => "erp-surface",
    "/erp/purchase_orders" => "erp-surface",
    "/erp/goods_receipts" => "erp-surface",
    "/erp/work_orders" => "erp-surface",
    "/erp/expense_reports" => "erp-surface",
    "/erp/expense_categories" => "erp-surface",
    "/erp/corporate_cards" => "erp-surface",
    "/erp/ap-capture" => "erp-ap-capture",
    "/erp/ap-payments" => "erp-ap-payments",
    "/erp/ap-aging" => "erp-ap-aging",
    "/erp/ap-approval" => "erp-ap-approval",
    "/erp/ar-receipts" => "erp-ar-receipts",
    "/erp/ar-aging" => "erp-ar-aging",
    "/erp/ar-settings" => "erp-ar-settings",
    "/erp/journal-approval" => "erp-journal-approval",
    "/erp/reconciliation" => "reconciliation-workbench",
    "/erp/payroll-mappings" => "erp-payroll-mappings",
    "/crm/companies" => "crm-companies",
    "/crm/contacts" => "crm-contacts",
    "/crm/gallery" => "crm-contacts-gallery",
    "/crm/pipeline" => "crm-pipeline",
    "/crm/calendar" => "crm-calendar",
    "/crm/dashboard" => "crm-dashboard",
    "/crm/mailbox" => "crm-mailbox",
    "/crm/sequences" => "crm-sequences",
    "/billing" => "billing",
    "/billing/invoices" => "billing-invoices",
    "/billing/dunning" => "billing-dunning",
    "/billing/plans" => "billing-plans",
    "/billing/settings" => "billing-settings",
    "/marketing/campaigns" => "mkt-campaigns",
    "/marketing/segments" => "mkt-segments",
    "/marketing/leads" => "mkt-leads",
    "/banking" => "banking-accounts",
    "/banking/rules" => "banking-rules",
    "/work" => "work",
    "/work/projects" => "work-projects",
    "/work/timeline" => "work-timeline"
  }

  # The Calendar group's one documented path is a FILE, not a page: it answers
  # `text/calendar` with no HTML element to anchor on, so the shell scan below
  # skips it (it has its own test).
  @calendar_export "/calendar.ics"

  setup do
    start_supervised!(@endpoint)
    :ok
  end

  test "every documented page renders inside the tenant shell" do
    org = create_org!("Docs Render QA") |> Map.fetch!(:id)
    paths = documented_paths() -- [@calendar_export]

    assert paths != [], "the docs catalog documents no pages — the render scan would be vacuous"

    # The catalog and the table are two listings of the same promise: a newly
    # documented page under a shared prefix cannot ship unanchored, and a removed
    # one cannot leave a stale row that would pass vacuously.
    anchored = Enum.filter(paths, &shared_prefix?/1)

    assert Enum.sort(anchored) == @page_ids |> Map.keys() |> Enum.sort(),
           "the docs catalog and the root-id table disagree — every documented page under " <>
             "#{Enum.join(@paged_prefixes, ", ")} needs a root element here, and every row " <>
             "here needs a page in the catalog (catalog-only: " <>
             "#{inspect(anchored -- Map.keys(@page_ids))}, " <>
             "table-only: #{inspect(Map.keys(@page_ids) -- anchored)})"

    for path <- paths do
      conn = get(build_conn(), "#{path}?org=#{org}")

      assert conn.status == 200,
             "GET #{path} (documented in `SamenerpWeb.Docs`) answered #{conn.status} — a reader's " <>
               "click from /docs lands on an error page even though the route is mounted"

      # The page NAME is not the oracle: the inherited sidebar carries every
      # surface's label on every tenant page, so even a fallback body would say
      # "Stock". The shell is the one thing `use Samen.Web.Tenant.Live`
      # guarantees for a page that actually rendered — and a body that skipped
      # the page still answers 200 without it.
      assert conn.resp_body =~ ~s(class="app"),
             "GET #{path} answered 200 without the tenant shell — the documented page never " <>
               "rendered through `Samen.Web.Tenant.Live`"

      # Where a live sibling sits one URL away, status and shell are satisfied by
      # the wrong page too — the root id is the only thing that tells them apart.
      with id when is_binary(id) <- Map.get(@page_ids, path) do
        assert conn.resp_body =~ ~s(id="#{id}"),
               "GET #{path} rendered without `#{id}` — the docs entry points at a sibling of " <>
                 "the page it describes (every sibling under #{Enum.join(@paged_prefixes, ", ")} " <>
                 "answers 200 in the same shell)"
      end
    end
  end

  # One representative category: the route guard above already proves EVERY
  # category renders a page (`Docs.group_html/1` non-nil), so rendering all 15
  # here would re-test the same `show/2` branch.
  test "the docs index, the guide, a category and the 404 render through the controller" do
    group = hd(Docs.groups())

    pages = [
      {"/docs", "Documentation"},
      {"/docs/getting-started", "Getting started"},
      {"/docs/#{group.id}", "#{group.glyph} #{group.label}"}
    ]

    for {path, heading} <- pages do
      conn = get(build_conn(), path)

      assert conn.status == 200,
             "GET #{path} answered #{conn.status} — the docs page itself is down"

      assert conn.resp_body =~ "<h1>#{heading}</h1>",
             "GET #{path} rendered without its `<h1>#{heading}</h1>` heading"
    end

    # ANTI-TAUTOLOGY: the render leg can fail. An unknown category is a 404 page,
    # not a 200 with some heading — so the assertions above are not satisfied by
    # any response at all.
    unknown = get(build_conn(), "/docs/definitely-not-a-category")

    assert unknown.status == 404, "an undocumented category id must 404, not render a page"
    assert unknown.resp_body =~ "<h1>Page not found</h1>"
  end

  test "the documented .ics export answers with a calendar, not a page" do
    assert @calendar_export in documented_paths(),
           "#{@calendar_export} is no longer a documented Calendar path — this test would be " <>
             "asserting a URL the docs no longer promise"

    org = create_org!("Docs ICS QA") |> Map.fetch!(:id)
    conn = get(build_conn(), "#{@calendar_export}?org=#{org}")

    assert conn.status == 200,
           "GET #{@calendar_export} answered #{conn.status} — the documented Calendar export is down"

    assert conn.resp_body =~ "BEGIN:VCALENDAR",
           "GET #{@calendar_export} did not answer with a calendar body"
  end

  defp documented_paths do
    for group <- Docs.groups(), {_name, path, _note} <- group.pages, do: path
  end

  defp shared_prefix?(path) do
    Enum.any?(@paged_prefixes, &(path == &1 or String.starts_with?(path, &1 <> "/")))
  end

  defp create_org!(name) do
    Op.Org
    |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end
end
