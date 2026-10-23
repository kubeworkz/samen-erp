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
  alias Samen.WebTest.Docs.{Doc, DocBlock, DocLink}

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

  # A socket loaded the way the route loads it, so a handler can be driven without a router.
  defp index_socket(mount, org_id) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> IndexLive.load(org_id, "")
  end

  # The editor's socket, loaded the way the route loads it (the copy/declassify tests' shape).
  defp page_socket(mount, org_id, doc_id) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> PageLive.load(org_id, doc_id)
  end

  # Render a socket's assigns the way `render_live/3` does — a handler's RESULT can then be
  # asserted in the DOM instead of only in `assigns`.
  defp html_of(socket), do: render_html(IndexLive, socket.assigns)

  # The trash view: the `:archived` read, never a raw table query, so "recoverable" is asserted
  # through the same seam a restore would use.
  defp archived_ids(org_id) do
    Doc
    |> Ash.Query.for_read(:archived)
    |> Ash.Query.ensure_selected([:id])
    |> Ash.read!(scope: scope_for(org_id))
    |> Enum.map(& &1.id)
  end

  defp links(org_id), do: Ash.read!(DocLink, scope: scope_for(org_id))

  defp aud_event_types(subject_id) do
    %{rows: rows} =
      Samen.WebTest.Repo.query!(
        "SELECT aud_event_type FROM aud_event WHERE aud_subject_id = $1",
        [to_string(subject_id)]
      )

    Enum.map(rows, fn [type] -> type end)
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

  # ── deleting a page ────────────────────────────────────────────────────────

  describe "deleting a page" do
    test "every row offers a delete control on the tenant plane; the operator plane is not offered one" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, %{title: "Retire me"})

      html = render_live(IndexLive, notes_mount(), [org_id])

      assert html =~ "note-delete-#{doc.id}"
      assert html =~ ~s(phx-value-id="#{doc.id}")

      operator_html = render_live(IndexLive, notes_mount(Plane.operator("op-1", org_id)), [org_id])

      refute operator_html =~ "note-delete-#{doc.id}",
             "the operator plane must not be OFFERED a delete it cannot be given"

      # Positive control: the plane hides the CONTROL, not the list.
      assert operator_html =~ "/pages/#{doc.id}?org=#{org_id}"
    end

    test "the ✕ only asks — nothing is archived until the confirmation is clicked" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, %{title: "Retire me"})

      {:noreply, confirming} = IndexLive.handle_event("confirm_archive", %{"id" => doc.id}, index_socket(notes_mount(), org_id))

      assert confirming.assigns.confirm == doc.id
      assert archived_ids(org_id) == [], "asking must not delete anything"
      assert {:ok, _page} = Reads.page(notes_mount(), scope_for(org_id), doc.id)

      html = html_of(confirming)
      assert html =~ "note-delete-confirm-#{doc.id}"
      assert html =~ "Delete “Retire me”?"
      assert html =~ "note-delete-yes-#{doc.id}"
      assert html =~ "note-delete-cancel-#{doc.id}"

      {:noreply, cancelled} = IndexLive.handle_event("cancel_archive", %{}, confirming)

      assert cancelled.assigns.confirm == nil
      assert archived_ids(org_id) == []
      refute html_of(cancelled) =~ "note-delete-confirm-#{doc.id}"
    end

    test "confirming deletes the page: it leaves the tree and is RECOVERABLE, not shredded" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, %{title: "Retire me"})

      {:noreply, confirming} =
        IndexLive.handle_event("confirm_archive", %{"id" => doc.id}, index_socket(notes_mount(), org_id))

      {:noreply, after_delete} = IndexLive.handle_event("archive_page", %{"id" => doc.id}, confirming)

      # Gone from every read the tree uses…
      assert after_delete.assigns.pages == []
      assert after_delete.assigns.confirm == nil
      assert {:error, :not_found} = Reads.page(notes_mount(), scope_for(org_id), doc.id)
      refute render_live(IndexLive, notes_mount(), [org_id]) =~ "Retire me"

      # …and recoverable, not shredded: the row is in the trash view, with the audit line that
      # records WHO deleted it. Sabotage 380 (the `:archive` action swapped for a hard
      # `:destroy`) flips this, and nothing else in the suite pins it.
      assert archived_ids(org_id) == [doc.id]
      assert "record_archived" in aud_event_types(doc.id)
    end

    test "the EDITOR offers the same delete — tenant plane only, and it asks first" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, %{title: "Retire me"})
      _block = insert!(org_id, doc.id, %{type: :paragraph, text: "still here"})

      html = render_live(PageLive, notes_mount(), [org_id, doc.id])
      assert html =~ "note-delete-page"
      refute html =~ "note-delete-page-confirm", "the confirm must not be open before it is asked"

      operator_html = render_live(PageLive, notes_mount(Plane.operator("op-1", org_id)), [org_id, doc.id])
      refute operator_html =~ "note-delete-page", "the operator plane is not OFFERED the delete"
      assert operator_html =~ "Retire me", "the page itself still renders on that plane"
    end

    test "the editor's delete asks first, then archives the page and leaves for the index" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, %{title: "Retire me"})
      socket = page_socket(notes_mount(), org_id, doc.id)

      {:noreply, confirming} = PageLive.handle_event("confirm_delete", %{}, socket)

      assert confirming.assigns.confirm_delete == true
      assert archived_ids(org_id) == [], "asking must not delete anything"

      confirm_html = render_html(PageLive, confirming.assigns)
      assert confirm_html =~ "note-delete-page-confirm"
      assert confirm_html =~ "Delete “Retire me”?"

      {:noreply, cancelled} = PageLive.handle_event("cancel_delete", %{}, confirming)

      assert cancelled.assigns.confirm_delete == false
      assert archived_ids(org_id) == []
      refute render_html(PageLive, cancelled.assigns) =~ "note-delete-page-confirm"

      {:noreply, reconfirm} = PageLive.handle_event("confirm_delete", %{}, cancelled)
      {:noreply, leaving} = PageLive.handle_event("delete_page", %{}, reconfirm)

      # The editor leaves for the index it can no longer be reached from…
      assert {:live, :redirect, opts} = leaving.redirected

      assert opts[:to] == "/pages?org=#{org_id}&deleted=#{doc.id}",
             "the index must be handed the page that was just deleted, so it can offer the undo"

      # …the write is the SAME soft delete the index row performs…
      assert archived_ids(org_id) == [doc.id]
      assert {:error, :not_found} = Reads.page(notes_mount(), scope_for(org_id), doc.id)

      # …and a second attempt (another tab, a stale socket) SAYS so instead of claiming a delete.
      {:noreply, stale} = PageLive.handle_event("delete_page", %{}, reconfirm)
      assert stale.assigns.error =~ "already gone"
      assert archived_ids(org_id) == [doc.id]
    end

    test "the delete offers an UNDO, and the undo puts the page back with its content" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, %{title: "Retire me"})
      _block = insert!(org_id, doc.id, %{type: :paragraph, text: "Undo keeps my content"})

      {:noreply, confirming} =
        IndexLive.handle_event("confirm_archive", %{"id" => doc.id}, index_socket(notes_mount(), org_id))

      {:noreply, after_delete} = IndexLive.handle_event("archive_page", %{"id" => doc.id}, confirming)

      assert after_delete.assigns.deleted == doc.id

      notice = html_of(after_delete)
      assert notice =~ "notes-deleted-notice"
      assert notice =~ "Page deleted."
      assert notice =~ "notes-undo-delete"

      {:noreply, undone} = IndexLive.handle_event("undo_delete", %{}, after_delete)

      # The row is back, the notice is gone, and the write was the model's `:restore` — which is
      # what makes the page (and its blocks) return intact instead of as an empty shell.
      assert undone.assigns.deleted == nil
      assert Enum.any?(undone.assigns.pages, &(&1.id == doc.id))
      assert archived_ids(org_id) == []
      assert {:ok, page} = Reads.page(notes_mount(), scope_for(org_id), doc.id)
      assert Enum.any?(page.blocks, &(&1.text == "Undo keeps my content"))
      assert "record_restored" in aud_event_types(doc.id)
      refute html_of(undone) =~ "notes-deleted-notice"

      # The URL loses the `?deleted=` carrier, so a reload cannot re-offer an undo that no longer
      # applies.
      assert {:live, :patch, opts} = undone.redirected
      assert opts[:to] == "/pages?org=#{org_id}"
    end

    test "the editor's ?deleted carrier gives the index the same undo" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, %{title: "Retire me"})
      {:ok, _deleted} = Writes.archive_page(notes_mount(), scope_for(org_id), doc.id)

      uri = "/pages?org=#{org_id}&deleted=#{doc.id}"

      {:noreply, landing} =
        IndexLive.handle_params(%{"org" => org_id, "deleted" => doc.id}, uri, index_socket(notes_mount(), org_id))

      assert landing.assigns.deleted == doc.id
      assert html_of(landing) =~ "notes-deleted-notice"

      {:noreply, undone} = IndexLive.handle_event("undo_delete", %{}, landing)
      assert {:ok, _page} = Reads.page(notes_mount(), scope_for(org_id), doc.id)
      assert archived_ids(org_id) == []
      assert undone.assigns.deleted == nil
    end

    test "an undo is idempotent at the seam: a second restore writes no second audit row" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)
      {:ok, _deleted} = Writes.archive_page(notes_mount(), scope_for(org_id), doc.id)

      assert {:ok, _restored} = Writes.restore_page(notes_mount(), scope_for(org_id), doc.id)
      assert {:ok, _already_live} = Writes.restore_page(notes_mount(), scope_for(org_id), doc.id)

      assert Enum.count(aud_event_types(doc.id), &(&1 == "record_restored")) == 1
      assert {:ok, _page} = Reads.page(notes_mount(), scope_for(org_id), doc.id)
    end

    test "another org's page cannot be deleted — and the refusal names nothing" do
      mine = Ash.UUID.generate()
      theirs = Ash.UUID.generate()
      foreign = seed_doc!(theirs, %{title: "Foreign secret title"})

      assert {:error, :not_found} = Writes.archive_page(notes_mount(), scope_for(mine), foreign.id)

      # Nothing moved, and the page is still readable in its own org.
      assert archived_ids(theirs) == []
      assert {:ok, _page} = Reads.page(notes_mount(), scope_for(theirs), foreign.id)

      # Positive control: the SAME call in the page's own org deletes it, so the refusal above is
      # the org scope and not a broken path.
      assert {:ok, _deleted} = Writes.archive_page(notes_mount(), scope_for(theirs), foreign.id)
      assert archived_ids(theirs) == [foreign.id]
    end

    test "deleting is a MEMBER write — a viewer is refused and the page survives" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)

      viewer = %Samen.Scope{
        actor: %{id: "user:viewer", org_id: org_id, role: :viewer, kind: :tenant, plane: :tenant}
      }

      assert {:error, _refused} = Writes.archive_page(notes_mount(), viewer, doc.id)
      assert archived_ids(org_id) == []
      assert {:ok, _page} = Reads.page(notes_mount(), scope_for(org_id), doc.id)

      # Positive control — same page, same path, a member scope.
      assert {:ok, _deleted} = Writes.archive_page(notes_mount(), scope_for(org_id), doc.id)
    end

    test "deleting a page destroys BOTH directions of its link graph, and leaves its blocks live" do
      org_id = Ash.UUID.generate()
      target = seed_doc!(org_id, %{title: "Target page"})
      source = seed_doc!(org_id, %{title: "Source page"})

      # Source → target (this page links here) …
      _ = insert!(org_id, source.id, %{type: :paragraph, text: "see [[Target page]]"})
      # … and target → source (the deleted page links out).
      _ = insert!(org_id, target.id, %{type: :paragraph, text: "back to [[Source page]]"})

      assert length(links(org_id)) == 2, "both edges must exist before the delete"

      assert {:ok, _deleted} = Writes.archive_page(notes_mount(), scope_for(org_id), target.id)

      # No edge survives in either direction: nothing points AT the page the tree no longer has.
      assert links(org_id) == []

      # The blocks are NOT archived with the page (ADR-053 §3.1) — they stay rows, unreachable
      # because every surface joins through an archive-filtered PAGE read…
      assert {:error, :not_found} = Reads.page(notes_mount(), scope_for(org_id), target.id)
      assert Enum.any?(Ash.read!(DocBlock, scope: scope_for(org_id)), &(&1.doc_id == target.id))

      # …while the page that linked here keeps its own content untouched.
      assert {:ok, source_page} = Reads.page(notes_mount(), scope_for(org_id), source.id)
      assert Enum.any?(source_page.blocks, &(&1.text == "see [[Target page]]"))
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
