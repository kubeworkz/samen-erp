defmodule Samenerp.NotesSurfaceMountTest do
  @moduledoc """
  WS-Notes Phase 6 — the **Pages** surface is MOUNTED in this host, proved through the REAL
  router (the `Samenerp.NavReachabilityTest` / `*SurfaceTest` discipline: nothing is constructed
  by hand and rendered directly here).

  The library's own `notes_surface_test.exs` proves the editor's mechanics on its test router.
  What only a HOST can prove is the wiring:

    1. `samen_notes_routes/3` is called with THIS app's mounts — `Samenerp.Docs` for the
       `Doc`/`DocBlock` rows and `Samenerp.Primitives.SearchIndex` for block search — so
       `/pages` and `/pages/:id` are served by `SamenerpWeb.Endpoint`;
    2. the Documents → Pages nav item rides the shared tenant label map, so it appears on a page
       that does NOT mount the notes surface itself (`/crm/companies`) — the same inherited-chrome
       leg `NavReachabilityTest` asserts, now covering Pages;
    3. a page belonging to ANOTHER org is `:not_found` on the editor route (R1) rather than
       rendered — the org authority comes from the mount, never from the URL's `:id`.
  """

  use Samenerp.DataCase, async: false

  import Phoenix.ConnTest

  alias Samenerp.Docs.{Doc, DocBlock}
  alias Samenerp.Operator

  @endpoint SamenerpWeb.Endpoint

  setup do
    start_supervised!(@endpoint)
    :ok
  end

  defp create_org!(name) do
    Operator.Org
    |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  # Host rows are seeded with `authorize?: false` (the router's reads are what is under test —
  # they resolve the org through `Samen.Web.CurrentOrg`, never through these calls).
  defp create_page!(org, title) do
    Doc
    |> Ash.Changeset.for_create(:create, %{org_id: org.id, title: title}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp create_block!(org, page, text) do
    DocBlock
    |> Ash.Changeset.for_create(
      :create,
      %{org_id: org.id, doc_id: page.id, type: :paragraph, text: text, position: 0},
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  defp get_page!(path) do
    conn = get(build_conn(), path)
    assert conn.status == 200, "GET #{path} did not render (status=#{conn.status})"
    conn.resp_body
  end

  test "the router DECLARES the notes surface at /pages and /pages/:id" do
    paths = Enum.map(SamenerpWeb.Router.__routes__(), & &1.path)

    assert "/pages" in paths,
           "samen_notes_routes/3 is not mounted — the Pages index is a hand-typed URL only"

    assert "/pages/:id" in paths,
           "samen_notes_routes/3 did not declare the editor route"
  end

  test "GET /pages renders the host's pages, inside the tenant chrome" do
    org = create_org!("Notes Mount QA")
    page = create_page!(org, "Onboarding runbook")

    html = get_page!("/pages?org=#{org.id}")

    assert html =~ ~s(id="notes-index"),
           "the Pages index did not render — the Docs mount or the route macro is miswired"

    assert html =~ ~s(class="app"), "the page must render inside the shared app shell"

    assert html =~ "Onboarding runbook",
           "the org's own page is missing from the index (the Docs mount read nothing)"

    assert html =~ "/pages/#{page.id}?org=#{org.id}",
           "the index did not link the page by id"

    assert html =~ ~s(id="notes-new-page"),
           "the \\\"New page\\\" form is missing (the index cannot create a page)"
  end

  test "GET /pages/:id renders the block editor with the page's blocks" do
    org = create_org!("Notes Editor QA")
    page = create_page!(org, "Release checklist")
    _block = create_block!(org, page, "First paragraph of the checklist")

    html = get_page!("/pages/#{page.id}?org=#{org.id}")

    assert html =~ "Release checklist", "the editor did not render the page title"

    assert html =~ "First paragraph of the checklist",
           "the editor did not render the page's block — the Docs/DocBlock read is miswired"

    assert html =~ ~s(id="note-block-),
           "the editor rendered no block control (the block id anchor is missing)"
  end

  test "the Documents → Pages nav item is inherited chrome on a page that mounts notes nowhere" do
    org = create_org!("Notes Nav QA")

    html = get_page!("/crm/companies?org=#{org.id}")

    aside =
      case Regex.run(~r/<aside class="side">.*?<\/aside>/s, html) do
        [sidebar] -> sidebar
        nil -> flunk("the tenant page rendered no sidebar — the inherited chrome is missing")
      end

    assert aside =~ ">Documents<",
           "the Documents group is missing from the tenant sidebar"

    assert aside =~ ~r/>\s*Pages\s*<\/a>/,
           "the Pages item is missing from the Documents group (the shared :pages_path label " <>
             "is not on this host's tenant mounts)"

    assert aside =~ ~s(href="/pages?org=#{org.id}"),
           "the Pages entry does not link the mounted route"
  end

  test "another org's page is NOT FOUND on the editor route (R1 — never rendered)" do
    mine = create_org!("Notes Tenant A")
    theirs = create_org!("Notes Tenant B")
    foreign = create_page!(theirs, "Foreign secret title")
    _block = create_block!(theirs, foreign, "Foreign secret block text")

    html = get_page!("/pages/#{foreign.id}?org=#{mine.id}")

    assert html =~ "Page not found",
           "a foreign page id did not render the not-found state — the org authority is " <>
             "not coming from the mount"

    refute html =~ "Foreign secret title",
           "the editor rendered another org's page title across tenants"

    refute html =~ "Foreign secret block text",
           "the editor rendered another org's block text across tenants"
  end
end
