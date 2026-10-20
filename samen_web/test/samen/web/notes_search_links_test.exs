defmodule Samen.Web.NotesSearchLinksTest do
  @moduledoc """
  WS-Notes Phase 4 — block search + backlinks, and the red paths the gate names
  (ADR-053 §5/§6 R13/R14/R15).

  What is proven, and why each proof is non-vacuous:

    * **registration is guard-first (R14)** — `Doc.title` and `DocBlock.text` are registered
      through `SearchIndexGuard`, while `text_secure`/`secure_body` are REFUSED; the positive
      control (`text` allowed) keeps the refusal from being a tautology.
    * **results are block-level** — a hit carries the page id + title, the matched block id and a
      snippet from the plain text; a title match returns a page hit.
    * **a vaulted block is not searchable** — its distinctive text never appears in a result.
    * **archived pages leave all three views (R15)** — the tree, search and backlinks drop a page
      archived after it was linked/searched.
    * **a cross-org title does not resolve (R13)** — resolution is org-scoped, so org B's page is
      not linkable from org A; the positive control resolves org B's own title.
    * **links resolve on write, go stale on rename, and re-resolve on the next save** — `DocLink`
      rows are the reverse of `[[Title]]`, `anchor_text` carries the typed title for the stale
      hint, and a save reconciles the whole set (dropping a link that no longer resolves).
    * **unresolved links create nothing until clicked** — the affordance renders, the click
      creates the page and re-resolves, and only then does the link exist.
  """

  use Samen.WebTest.DataCase, async: false

  require Ash.Query

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Samen.Scopes.Primitives.SearchIndexGuard
  alias Samen.Web.{Mount, Notes.IndexLive, Notes.Links, Notes.PageLive, Notes.Reads, Notes.Writes, Plane}
  alias Samen.Web.Notes.Search, as: NotesSearch
  alias Samen.WebTest.Docs.{Doc, DocBlock, DocLink}
  alias Samen.WebTest.SecurityHost

  @endpoint Samen.WebTest.SecurityEndpoint

  @vaulted "VAULTED-BLOCK-SENTINEL"
  @archived "ARCHIVED-BLOCK-SENTINEL"

  # ── harness ────────────────────────────────────────────────────────────────

  defp notes_mount(plane \\ Plane.tenant()) do
    Mount.new(:notes, Samen.WebTest.Docs, Samen.WebTest.Repo,
      plane: plane,
      labels: %{
        pages_path: "/pages",
        search_index: Samen.WebTest.Primitives.SearchIndex
      }
    )
  end

  defp scope_for(org_id, plane \\ Plane.tenant()),
    do: Mount.scope(notes_mount(plane), org_id)

  defp seed_doc!(org_id, attrs \\ %{}) do
    Doc
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{org_id: org_id, title: "Runbook"}, attrs),
      scope: scope_for(org_id)
    )
    |> Ash.create!()
  end

  defp insert!(org_id, doc_id, attrs) do
    {:ok, block} = Writes.insert_block(notes_mount(), scope_for(org_id), doc_id, attrs)
    block
  end

  defp register!(org_id) do
    assert :ok = NotesSearch.register_index(notes_mount(), scope_for(org_id))
  end

  defp search!(org_id, term) do
    NotesSearch.search(notes_mount(), scope_for(org_id), term)
  end

  defp links_for(org_id, source_doc_id) do
    DocLink
    |> Ash.Query.filter(source_doc_id == ^source_doc_id)
    |> Ash.read!(scope: scope_for(org_id))
  end

  # ── 4.1 registration + the index guard (R14) ───────────────────────────────

  describe "index registration (R14)" do
    test "registers title/text only, idempotently, and refuses a vaulted column" do
      org_id = Ash.UUID.generate()
      register!(org_id)

      rows =
        Samen.WebTest.Primitives.SearchIndex
        |> Ash.Query.filter(org_id == ^org_id)
        |> Ash.read!(scope: scope_for(org_id))

      assert Enum.any?(rows, &(&1.resource_name == inspect(Doc) and &1.field_name == "title"))
      assert Enum.any?(rows, &(&1.resource_name == inspect(DocBlock) and &1.field_name == "text"))

      # Idempotent: a second registration does not duplicate the two rows.
      register!(org_id)

      assert length(
               Samen.WebTest.Primitives.SearchIndex
               |> Ash.Query.filter(org_id == ^org_id)
               |> Ash.read!(scope: scope_for(org_id))
             ) == 2

      # R14: the vaulted halves are structurally unindexable…
      assert_raise ArgumentError, fn ->
        SearchIndexGuard.assert_no_pii_column(DocBlock, "text_secure")
      end

      assert_raise ArgumentError, fn ->
        SearchIndexGuard.assert_no_pii_column(Doc, "secure_body")
      end

      # …while the plain columns pass (the guard discriminates).
      assert :ok = SearchIndexGuard.assert_no_pii_column(DocBlock, "text")
      assert :ok = SearchIndexGuard.assert_no_pii_column(Doc, "title")
    end
  end

  # ── 4.2 block-level search ─────────────────────────────────────────────────

  describe "block-level search" do
    test "finds a block by its plain text and returns page link + snippet" do
      org_id = Ash.UUID.generate()
      register!(org_id)
      doc = seed_doc!(org_id, %{title: "Runbook"})
      block = insert!(org_id, doc.id, %{type: :paragraph, text: "Reconcile the INVOICENEEDLE monthly."})
      _other = insert!(org_id, doc.id, %{type: :paragraph, text: "Unrelated prose."})

      assert [%NotesSearch.Hit{kind: :block} = hit] = search!(org_id, "INVOICENEEDLE")

      assert hit.doc_id == doc.id
      assert hit.doc_title == "Runbook"
      assert hit.block_id == block.id
      assert hit.snippet =~ "INVOICENEEDLE"
      assert hit.rank > 0
    end

    test "a title match returns a page hit" do
      org_id = Ash.UUID.generate()
      register!(org_id)
      doc = seed_doc!(org_id, %{title: "TITLEONLYNEEDLE Runbook"})
      _block = insert!(org_id, doc.id, %{type: :paragraph, text: "Nothing matching here."})

      assert [%NotesSearch.Hit{kind: :page} = hit] = search!(org_id, "TITLEONLYNEEDLE")

      assert hit.doc_id == doc.id
      assert hit.doc_title == "TITLEONLYNEEDLE Runbook"
      assert is_nil(hit.block_id)
    end

    test "a vaulted block is NOT searchable — its text is absent from results" do
      org_id = Ash.UUID.generate()
      register!(org_id)
      doc = seed_doc!(org_id)

      {:ok, _secure} =
        Writes.insert_block(notes_mount(), scope_for(org_id), doc.id, %{
          type: :paragraph,
          text_secure: "#{@vaulted} is private"
        })

      # Positive control: the same term IS findable when it is plain content.
      plain_doc = seed_doc!(org_id, %{title: "Public"})
      insert!(org_id, plain_doc.id, %{type: :paragraph, text: "#{@vaulted} is public"})

      hits = search!(org_id, @vaulted)

      assert Enum.any?(hits, &(&1.doc_id == plain_doc.id)),
             "the plain sentinel must be findable (the assertion is discriminating)"

      refute Enum.any?(hits, &(&1.doc_id == doc.id)),
             "a block whose text is vaulted must never be a search hit"
    end

    test "search from org A never returns org B's blocks or titles" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      register!(org_a)
      register!(org_b)

      doc_a = seed_doc!(org_a, %{title: "ORGNEEDLE A"})
      insert!(org_a, doc_a.id, %{type: :paragraph, text: "ORGNEEDLE alpha"})
      doc_b = seed_doc!(org_b, %{title: "ORGNEEDLE B"})
      insert!(org_b, doc_b.id, %{type: :paragraph, text: "ORGNEEDLE beta"})

      hits = search!(org_a, "ORGNEEDLE")

      assert Enum.any?(hits, &(&1.doc_id == doc_a.id))
      refute Enum.any?(hits, &(&1.doc_id == doc_b.id))
    end

    test "archived pages leave the tree, search and backlinks (R15)" do
      org_id = Ash.UUID.generate()
      register!(org_id)
      target = seed_doc!(org_id, %{title: "Target"})
      archived_doc = seed_doc!(org_id, %{title: "ARCHNEEDLE retired"})
      insert!(org_id, archived_doc.id, %{type: :paragraph, text: "#{@archived} body"})

      source = seed_doc!(org_id, %{title: "Guide"})
      insert!(org_id, source.id, %{type: :paragraph, text: "See [[Target]]."})

      # Pre-archive: search finds the block, the tree lists it, the backlink exists.
      assert Enum.any?(search!(org_id, @archived), &(&1.doc_id == archived_doc.id))
      assert Enum.any?(Reads.index(notes_mount(), scope_for(org_id)) |> elem(1), &(&1.id == archived_doc.id))

      assert [%{source_id: source_id}] = Reads.backlinks(notes_mount(), scope_for(org_id), target.id)
      assert source_id == source.id

      # Archive the searched page AND the linking source.
      archive_doc!(org_id, archived_doc.id)
      archive_doc!(org_id, source.id)

      refute Enum.any?(search!(org_id, @archived), &(&1.doc_id == archived_doc.id)),
             "an archived page must not be searchable"

      refute Enum.any?(Reads.index(notes_mount(), scope_for(org_id)) |> elem(1), &(&1.id == archived_doc.id)),
             "an archived page must leave the tree"

      assert Reads.backlinks(notes_mount(), scope_for(org_id), target.id) == [],
             "an archived SOURCE must leave the backlink list"
    end
  end

  # ── 4.3 backlinks + resolution (R13) ──────────────────────────────────────

  describe "backlinks and [[Title]] resolution" do
    test "a link resolves on write and renders on the target page" do
      org_id = Ash.UUID.generate()
      target = seed_doc!(org_id, %{title: "Runbook"})
      source = seed_doc!(org_id, %{title: "Guide"})
      _block = insert!(org_id, source.id, %{type: :paragraph, text: "Start with [[Runbook]] today."})

      assert [link] = links_for(org_id, source.id)
      assert link.target_doc_id == target.id
      assert link.anchor_text == "Runbook"

      assert [%{source_id: source_id, source_title: "Guide", anchor_text: "Runbook", stale?: false}] =
               Reads.backlinks(notes_mount(), scope_for(org_id), target.id)

      assert source_id == source.id

      html = render_live(PageLive, notes_mount(), [org_id, target.id])
      assert html =~ "note-backlinks"
      assert html =~ "Guide"
      assert html =~ "Runbook"
      refute html =~ "link may point at an older title"
    end

    test "a cross-org title does NOT resolve (R13) — and the positive control does" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()

      foreign = seed_doc!(org_b, %{title: "Foreign Secret"})
      source = seed_doc!(org_a, %{title: "Guide"})
      _block = insert!(org_a, source.id, %{type: :paragraph, text: "Link to [[Foreign Secret]]."})

      assert Links.resolve(notes_mount(), scope_for(org_a), "Foreign Secret") == :unresolved
      assert links_for(org_a, source.id) == []

      # POSITIVE CONTROL: org B resolves its own page, so the refusal above is about the SCOPE,
      # not a typo or a missing title.
      assert {:ok, doc} = Links.resolve(notes_mount(), scope_for(org_b), "Foreign Secret")
      assert doc.id == foreign.id

      # And the foreign page has no backlink from org A.
      assert Reads.backlinks(notes_mount(), scope_for(org_b), foreign.id) == []
    end

    test "a rename leaves a STALE hint until the source page is saved again" do
      org_id = Ash.UUID.generate()
      target = seed_doc!(org_id, %{title: "Runbook"})
      source = seed_doc!(org_id, %{title: "Guide"})
      _block = insert!(org_id, source.id, %{type: :paragraph, text: "See [[Runbook]]."})

      rename!(org_id, target.id, "Playbook")

      assert [%{anchor_text: "Runbook", stale?: true}] =
               Reads.backlinks(notes_mount(), scope_for(org_id), target.id)

      html = render_live(PageLive, notes_mount(), [org_id, target.id])
      assert html =~ "link may point at an older title"
    end

    test "a save re-resolves links: the old title drops, the new title re-links" do
      org_id = Ash.UUID.generate()
      target = seed_doc!(org_id, %{title: "Runbook"})
      source = seed_doc!(org_id, %{title: "Guide"})
      block = insert!(org_id, source.id, %{type: :paragraph, text: "See [[Runbook]]."})

      rename!(org_id, target.id, "Playbook")

      # Saving the OLD text does not resolve: the typed title no longer names a live page.
      {:ok, _} = Writes.update_text(notes_mount(), scope_for(org_id), block.id, "See [[Runbook]].")
      assert links_for(org_id, source.id) == []

      # Saving the NEW title re-links the same target with the typed anchor.
      {:ok, updated} = Writes.update_text(notes_mount(), scope_for(org_id), block.id, "See [[Playbook]].")

      assert [link] = links_for(org_id, source.id)
      assert link.target_doc_id == target.id
      assert link.anchor_text == "Playbook"
      assert updated.id == block.id
    end

    test "unresolved links create nothing, render the affordance, and resolve on click" do
      previous = Application.get_env(SecurityHost.otp_app(), :auth_required?)
      SecurityHost.disarm!()

      on_exit(fn ->
        case previous do
          nil -> Application.delete_env(SecurityHost.otp_app(), :auth_required?)
          value -> Application.put_env(SecurityHost.otp_app(), :auth_required?, value)
        end
      end)

      org_id = Ash.UUID.generate()
      source = seed_doc!(org_id, %{title: "Guide"})
      _block = insert!(org_id, source.id, %{type: :paragraph, text: "Draft [[Missing Page]] next."})

      assert Reads.unresolved(notes_mount(), scope_for(org_id), source.id) == ["Missing Page"]
      assert links_for(org_id, source.id) == [], "an unresolved title persists no link"

      {:ok, view, html} = live(build_conn(), "/pages/#{source.id}?org=#{org_id}")
      assert html =~ "note-unresolved"
      assert html =~ "Missing Page"

      view |> element("#note-create-link-0") |> render_click()

      # The click's write broadcasts (block + structure), and those envelopes arrive as messages:
      # drain them with a synchronous render BEFORE the test ends, or the socket's re-read lands
      # while the sandbox is checking the connection back in (a poisoned neighbour connection).
      _ = render(view)

      assert Reads.unresolved(notes_mount(), scope_for(org_id), source.id) == []

      created = fetch_doc_by_title!(org_id, "Missing Page")
      assert [link] = links_for(org_id, source.id)
      assert link.target_doc_id == created.id
    end
  end

  # ── search surface ─────────────────────────────────────────────────────────

  describe "the Pages search surface" do
    test "renders a block hit with the page title and snippet, and states the vault trade-off" do
      org_id = Ash.UUID.generate()
      register!(org_id)
      doc = seed_doc!(org_id, %{title: "Runbook"})
      insert!(org_id, doc.id, %{type: :paragraph, text: "SURFACENEEDLE in a sentence."})

      html = render_live(IndexLive, notes_mount(), [org_id, "SURFACENEEDLE"])

      assert html =~ "Runbook"
      assert html =~ "SURFACENEEDLE"
      assert html =~ "note-search-results"
      assert html =~ "Vaulted (🔒) blocks are not searchable"
      refute html =~ "note-tree"
    end

    test "an unmatched term renders an honest empty state, not a blank pane" do
      org_id = Ash.UUID.generate()
      register!(org_id)
      doc = seed_doc!(org_id, %{title: "Runbook"})
      insert!(org_id, doc.id, %{type: :paragraph, text: "Some content."})

      html = render_live(IndexLive, notes_mount(), [org_id, "NOSUCHNEEDLE"])

      assert html =~ "No blocks match"
      refute html =~ "note-search-hit-"
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp archive_doc!(org_id, doc_id) do
    doc =
      Doc
      |> Ash.Query.filter(id == ^doc_id)
      |> Ash.read_one!(scope: scope_for(org_id))

    doc
    |> Ash.Changeset.for_destroy(:archive, %{}, scope: scope_for(org_id))
    |> Ash.destroy!()
  end

  defp rename!(org_id, doc_id, title) do
    doc =
      Doc
      |> Ash.Query.filter(id == ^doc_id)
      |> Ash.read_one!(scope: scope_for(org_id))

    doc
    |> Ash.Changeset.for_update(:update, %{title: title}, scope: scope_for(org_id))
    |> Ash.update!()
  end

  defp fetch_doc_by_title!(org_id, title) do
    Doc
    |> Ash.Query.filter(title == ^title)
    |> Ash.read!(scope: scope_for(org_id))
    |> List.first()
    |> case do
      nil -> flunk("no page titled #{inspect(title)} was created")
      doc -> doc
    end
  end
end
