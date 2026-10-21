defmodule Samenerp.NotesSearchTest do
  @moduledoc """
  WS-Notes Phase 6 — the host half of search: the registry rows and the vaulting trade-off.

  `Samen.Web.Notes.Search` is wired and FAIL-CLOSED: with no `:search_index` seam, or no
  registry rows for the org, `?q=` answers the honest empty state. That makes "mounted" and
  "searchable" two different things — this file proves the second one on THIS host:

    1. `Samenerp.Seeds.ensure_notes_search_index!/1` writes exactly the two non-PII registry
       rows (`Doc.title`, `DocBlock.text`) and is idempotent;
    2. a page seeded through `seed_notes_pages!/1` is findable through the REAL router
       (`GET /pages?org=…&q=…`) by its plain block text;
    3. a VAULTED block's text is never a hit — the `text_secure` column is not registered, and
       the seeded plaintext appears nowhere in the response;
    4. the guard is not decorative: registering `text_secure` raises, so a future edit that
       names the vaulted column fails loudly instead of indexing it;
    5. another org's pages are not searched (the registry + reads are org-scoped).
  """

  use Samenerp.DataCase, async: false

  import Phoenix.ConnTest

  require Ash.Query

  alias Samenerp.Operator
  alias Samenerp.Primitives.SearchIndex
  alias Samenerp.Seeds

  @endpoint SamenerpWeb.Endpoint

  # The seeded vaulted block's plaintext — asserted ABSENT from every result body.
  @vaulted_plaintext "Demo vaulted block"

  setup do
    start_supervised!(@endpoint)
    :ok
  end

  defp create_org!(name) do
    Operator.Org
    |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  defp get_page!(path) do
    conn = get(build_conn(), path)
    assert conn.status == 200, "GET #{path} did not render (status=#{conn.status})"
    conn.resp_body
  end

  defp index_rows(org) do
    SearchIndex
    |> Ash.Query.filter(org_id == ^org.id)
    |> Ash.read!(authorize?: false)
  end

  test "registration writes exactly Doc.title + DocBlock.text, idempotently" do
    org = create_org!("Notes Registry QA")

    assert :ok = Seeds.ensure_notes_search_index!(org.id)
    first = index_rows(org)
    assert :ok = Seeds.ensure_notes_search_index!(org.id)

    assert length(index_rows(org)) == length(first),
           "re-registering duplicated the registry rows (the ensure is not idempotent)"

    assert Enum.sort(Enum.map(first, & &1.field_name)) == ["text", "title"]

    resources = Enum.map(first, & &1.resource_name)
    assert Enum.any?(resources, &String.ends_with?(&1, ".Doc")), "Doc.title is not registered"

    assert Enum.any?(resources, &String.ends_with?(&1, ".DocBlock")),
           "DocBlock.text is not registered"

    refute Enum.any?(resources, &String.ends_with?(&1, "text_secure")),
           "a vaulted column was registered into the search index"
  end

  test "a seeded page is found by its PLAIN block text through the real /pages?q=" do
    org = create_org!("Notes Search Hit QA")
    doc_id = Seeds.seed_notes_pages!(org.id)

    html = get_page!("/pages?org=#{org.id}&q=typed")

    assert html =~ "Welcome to Pages", "the page title is missing from the search body"

    assert html =~ ~s(id="note-search-hit-),
           "no block hit rendered for a plain block that contains the term — the host's " <>
             "registry rows or the :search_index seam are not wired"

    assert html =~ "note-search-hit-title"
    refute html =~ ~s(id="notes-search-empty"), "search reported no match for a plain block"

    # The hit deep-links to the block it matched on the page the host actually serves.
    assert html =~ "/pages/#{doc_id}?org=#{org.id}"
  end

  test "a VAULTED block's text is never a hit (and never in the DOM)" do
    org = create_org!("Notes Search Vault QA")
    _doc_id = Seeds.seed_notes_pages!(org.id)

    html = get_page!("/pages?org=#{org.id}&q=vaulted")

    assert html =~ ~s(id="notes-search-empty"),
           "search returned a hit for a query that only the VAULTED block could match"

    assert html =~ "No blocks match “vaulted”"

    refute html =~ @vaulted_plaintext,
           "the vaulted block's plaintext appeared in the response body"

    refute html =~ "never enters the search index",
           "the vaulted block's text leaked into a snippet"

    # Positive control (anti-tautology): the SAME page, searched through the SAME path, does
    # answer for its plain block. So the silence above is the vault, not a dead query — a
    # registry that indexed `text_secure` would make the vaulted term hit and this pair fail.
    hit_html = get_page!("/pages?org=#{org.id}&q=typed")
    assert hit_html =~ ~s(id="note-search-hit-)
  end

  test "the search registry REFUSES the vaulted column (guard, not convention)" do
    assert_raise ArgumentError, ~r/pii_attribute/, fn ->
      Samen.Scopes.Primitives.SearchIndexGuard.assert_no_pii_column(
        Samenerp.Docs.DocBlock,
        "text_secure"
      )
    end

    # Positive control: the plain column the host DOES register passes the same guard.
    assert :ok =
             Samen.Scopes.Primitives.SearchIndexGuard.assert_no_pii_column(
               Samenerp.Docs.DocBlock,
               "text"
             )
  end

  test "another org's pages are not searched (registry + reads are org-scoped)" do
    mine = create_org!("Notes Search Tenant A")
    theirs = create_org!("Notes Search Tenant B")
    _their_doc = Seeds.seed_notes_pages!(theirs.id)

    html = get_page!("/pages?org=#{mine.id}&q=typed")

    assert html =~ ~s(id="notes-search-empty"),
           "search matched another org's seeded block — the query is not org-scoped"

    refute html =~ "Welcome to Pages",
           "another org's page title rendered in this org's result set"

    # Positive control: the term IS a genuine match in the org that owns the page, so the
    # empty result above proves SCOPE (the registry row and the block read are org-filtered),
    # not a query that could never have hit anywhere.
    assert get_page!("/pages?org=#{theirs.id}&q=typed") =~ ~s(id="note-search-hit-)
  end
end
