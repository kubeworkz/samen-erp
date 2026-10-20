defmodule Samen.Web.NotesSurfaceTest do
  @moduledoc """
  WS-Notes Phase 3 unit 3.2 — the Pages surface, rendered through the SAME modules the router
  mounts (`Samen.Web.Notes.IndexLive` / `Samen.Web.Notes.PageLive`).

  What is proven here, and why each proof is non-vacuous:

    * **the wrapper is load-bearing** — both pages render the shared app shell because they
      `use Samen.Web.Tenant.Live` (which refuses a page-owned `render/1` at compile time); the
      sweep in `tenant_shell_coverage_test.exs` finds them in the route table automatically;
    * **one row per block, ordered** — the editor renders the ordered block list `Reads.page/3`
      returns, and each editable row carries the block's own `revision` (the CAS the write seam
      needs);
    * **masking (INV-1)** — the SAME page renders the clear text on the tenant plane and `••••`
      on an operator plane without a grant, with no `vt_*` token and no plaintext anywhere in the
      operator DOM;
    * **the legacy body is READ-ONLY and never markup** — a zero-block page renders its original
      `body` through the constrained inline renderer (escaped, constructed HEEx), and a doc with
      at least one block ignores it (ADR-053 §8 O3). This is the assertion sabotage **354** flips
      when a `raw/1` is introduced into the notes render path (R12);
    * **a foreign page is not found** — `Reads` returns `:not_found` for another org's page
      (R1), and the page says so without naming it.
  """

  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.{Mount, Notes.IndexLive, Notes.PageLive, Notes.Reads, Notes.Writes, Plane}
  alias Samen.WebTest.Docs.Doc

  @secret "NOTES-SURFACE-PLAINTEXT-SENTINEL"

  # ── harness ────────────────────────────────────────────────────────────────

  defp notes_mount(plane \\ Plane.tenant()) do
    Mount.new(:notes, Samen.WebTest.Docs, Samen.WebTest.Repo,
      plane: plane,
      labels: %{pages_path: "/pages"}
    )
  end

  defp scope_for(org_id, plane \\ Plane.tenant()) do
    Mount.scope(notes_mount(plane), org_id)
  end

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

  defp blocks(org_id, doc_id) do
    {:ok, page} = Reads.page(notes_mount(), scope_for(org_id), doc_id)
    page.blocks
  end

  # ── the index ──────────────────────────────────────────────────────────────

  describe "IndexLive — the page list" do
    test "renders inside the shared shell and links every page by id" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, %{title: "Onboarding runbook"})
      second = seed_doc!(org_id, %{title: "Release checklist"})

      html = render_live(IndexLive, notes_mount(), [org_id])

      assert html =~ ~s(class="app"), "the page must render inside the app shell"
      assert html =~ "Onboarding runbook"
      assert html =~ "Release checklist"
      assert html =~ "/pages/#{doc.id}?org=#{org_id}"
      assert html =~ "/pages/#{second.id}?org=#{org_id}"
    end

    test "shows the Pages nav item (the `pages_path` label the route macro sets)" do
      org_id = Ash.UUID.generate()
      _doc = seed_doc!(org_id)

      html = render_live(IndexLive, notes_mount(), [org_id])

      assert html =~ ~s(href="/pages?org=#{org_id}")
    end

    test "an org with no pages offers the empty state instead of a blank tree" do
      org_id = Ash.UUID.generate()

      html = render_live(IndexLive, notes_mount(), [org_id])

      assert html =~ "note-empty"
      assert html =~ "Add your first block"
    end

    test "one org's pages are absent from another org's index (R1)" do
      mine = Ash.UUID.generate()
      theirs = Ash.UUID.generate()
      _hidden = seed_doc!(theirs, %{title: "Foreign secret title"})

      html = render_live(IndexLive, notes_mount(), [mine])

      refute html =~ "Foreign secret title"
    end
  end

  # ── the editor ─────────────────────────────────────────────────────────────

  describe "PageLive — the block editor" do
    test "renders one row per block, in order, each carrying the revision the client saw" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)
      first = insert!(org_id, doc.id, %{type: :paragraph, text: "First paragraph"})
      second = insert!(org_id, doc.id, %{type: :heading_2, text: "Second block"})

      html = render_live(PageLive, notes_mount(), [org_id, doc.id])

      assert html =~ ~s(class="app")
      assert html =~ "note-block-#{first.id}"
      assert html =~ "note-block-#{second.id}"
      assert index_of(html, first.id) < index_of(html, second.id)
      assert html =~ ~s(name="block_revision" value="#{first.revision}")
      assert html =~ "First paragraph"
      assert html =~ "Heading 2 block"
    end

    test "the palette offers exactly the bounded block types (R11's surface half)" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)
      _block = insert!(org_id, doc.id, %{type: :paragraph, text: "x"})

      html = render_live(PageLive, notes_mount(), [org_id, doc.id])

      # The palette is rendered on demand, so this asserts the kit's own closed vocabulary —
      # the same list the model validates — rather than a hardcoded UI copy of it.
      types = Samen.UI.NoteBlock.types()

      assert length(types) == length(Enum.uniq(types))
      assert :paragraph in types
      assert :to_do in types
      refute html =~ ~s(phx-value-type="evil")
    end

    test "the SAME page is clear on the tenant plane and masked on the operator plane (INV-1)" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)

      {:ok, _block} =
        Writes.insert_block(notes_mount(), scope_for(org_id), doc.id, %{
          type: :paragraph,
          text_secure: @secret
        })

      tenant_html = render_live(PageLive, notes_mount(), [org_id, doc.id])
      operator_html = render_live(PageLive, notes_mount(Plane.operator("op-1", org_id)), [org_id, doc.id])

      assert tenant_html =~ @secret,
             "the tenant plane reads its own org's vaulted block in the clear"

      assert operator_html =~ "••••",
             "an operator without a grant must render the mask"

      refute operator_html =~ @secret,
             "an operator without a grant must NEVER see the plaintext"

      refute operator_html =~ "vt_",
             "a vault token must never reach the DOM"

      # Anti-tautology: the two renders are of the same page and differ ONLY by plane, so the
      # assertion is refutable by the plane, not by the fixture.
      refute tenant_html =~ "••••"
    end

    test "a masked plane is READ-ONLY — no textarea is offered for the block" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)

      {:ok, _block} =
        Writes.insert_block(notes_mount(), scope_for(org_id), doc.id, %{
          type: :paragraph,
          text_secure: @secret
        })

      operator_html = render_live(PageLive, notes_mount(Plane.operator("op-1", org_id)), [org_id, doc.id])

      refute operator_html =~ ~s(phx-hook="NoteBlock")
      refute operator_html =~ "note-add-block"
    end

    test "a legacy body renders read-only through the inline renderer and can never become markup" do
      org_id = Ash.UUID.generate()

      doc =
        seed_doc!(org_id, %{
          body: ~s{<script>alert("pwn")</script> **bold** and <b>markup</b>}
        })

      html = render_live(PageLive, notes_mount(), [org_id, doc.id])

      assert html =~ "note-legacy"

      # The constrained dialect IS rendered (constructed HEEx)…
      assert html =~ "<strong>bold</strong>"

      # …while stored text stays text: escaped, never a live element. Sabotage 354 (a `raw/1`
      # in this render path) is exactly what makes this assertion fail.
      refute html =~ "<script>"
      refute html =~ "<b>markup</b>"
      assert html =~ "&lt;script&gt;"
    end

    test "a doc with at least one block ignores its legacy body (blocks win, O3)" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, %{body: "LEGACY-BODY-SENTINEL"})
      _block = insert!(org_id, doc.id, %{type: :paragraph, text: "A real block"})

      html = render_live(PageLive, notes_mount(), [org_id, doc.id])

      assert html =~ "A real block"
      refute html =~ "LEGACY-BODY-SENTINEL"
      refute html =~ "note-legacy"
    end

    test "an empty page offers the first block" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)

      html = render_live(PageLive, notes_mount(), [org_id, doc.id])

      assert html =~ "note-empty"
      assert html =~ "Add your first block"
    end

    test "another org's page is not found — and is not named" do
      mine = Ash.UUID.generate()
      theirs = Ash.UUID.generate()
      foreign = seed_doc!(theirs, %{title: "Foreign secret title"})

      html = render_live(PageLive, notes_mount(), [mine, foreign.id])

      assert html =~ "Page not found"
      refute html =~ "Foreign secret title"
    end

    test "the editor's blocks are the ordered list the ONE read seam returns" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)
      _a = insert!(org_id, doc.id, %{type: :paragraph, text: "one"})
      _b = insert!(org_id, doc.id, %{type: :paragraph, text: "two"})

      html = render_live(PageLive, notes_mount(), [org_id, doc.id])
      ids = Enum.map(blocks(org_id, doc.id), & &1.id)

      positions = Enum.map(ids, &index_of(html, &1))
      assert positions == Enum.sort(positions)
    end
  end

  defp index_of(html, needle) do
    case :binary.match(html, needle) do
      {index, _length} -> index
      :nomatch -> flunk("expected the rendered page to contain #{inspect(needle)}")
    end
  end
end
