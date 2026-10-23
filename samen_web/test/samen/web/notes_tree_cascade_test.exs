defmodule Samen.Web.NotesTreeCascadeTest do
  @moduledoc """
  WS-Notes Phase 3 unit 3.13 — the **page tree's cascade**: a page is live iff its ancestors are
  live, in every direction a page's liveness can change.

  What is proven here, and why each proof is non-vacuous:

    * **deleting a page retires its whole subtree**, every page at the SAME instant and every page
      with its own `record_archived` row — the row is what answers "who deleted this?", and a cascade
      that wrote one summary event could not answer it for the children;
    * **the cascade is the MODEL's** — an archive issued straight through `Samen.Archival.archive/2`,
      never touching `Samen.Web.Notes.Writes`, takes the subtree too. That is the difference between
      a guarantee and a helper every future caller has to remember;
    * **a restore brings back exactly what went down with the page** — the same-instant match, so a
      subpage deleted on its own (a different instant) stays in the trash. Without the discriminator
      an undo would resurrect a deletion the user never asked to undo;
    * **a page cannot come back under a parent that is still deleted** — both at the seam
      (`{:error, :parent_in_trash}`, what the trash renders) and in the model (a direct `:restore`
      refused), because the state it would create is the orphan the cascade exists to prevent;
    * **a purge destroys the subtree** — rows, blocks and one `record_purged` row per page, attributed
      to the admin who clicked — and REFUSES (`{:error, :live_descendants}`) rather than destroy a
      page that was never deleted; the bulk empty is the same write and does not trip over the
      children it already removed;
    * **the surfaces say what they are about to do** — the index's confirm names the subpage count
      before the click and the notice reports it after, and the trash tells the user which page to
      restore first.
  """

  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.{Mount, Notes.IndexLive, Notes.Reads, Notes.TrashLive, Notes.Writes, Plane}
  alias Samen.WebTest.Docs.Doc

  # ── harness ────────────────────────────────────────────────────────────────

  defp notes_mount do
    Mount.new(:notes, Samen.WebTest.Docs, Samen.WebTest.Repo,
      plane: Plane.tenant(),
      labels: %{pages_path: "/pages"}
    )
  end

  defp scope_for(org_id), do: Mount.scope(notes_mount(), org_id)

  # A tenant-plane scope with an explicit ROLE — the purge gate is the model's, so the test hands it
  # a fabricated rank (the `Samen.DocsScopeTest` shape the trash's own suite uses).
  defp scope_as(org_id, role) do
    %Samen.Scope{
      actor: %{id: "user:#{role}", org_id: org_id, role: role, kind: :tenant, plane: :tenant}
    }
  end

  defp seed_doc!(org_id, attrs) do
    Doc
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{org_id: org_id, title: "Page"}, attrs),
      scope: scope_for(org_id)
    )
    |> Ash.create!()
  end

  defp insert!(org_id, doc_id, text) do
    {:ok, block} =
      Writes.insert_block(notes_mount(), scope_for(org_id), doc_id, %{
        type: :paragraph,
        text: text
      })

    block
  end

  defp delete!(org_id, doc_id) do
    {:ok, archived} = Writes.archive_page(notes_mount(), scope_for(org_id), doc_id)
    archived
  end

  defp index_socket(org_id) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, notes_mount())
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> IndexLive.load(org_id)
  end

  defp trash_socket(org_id) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, notes_mount())
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> TrashLive.load(org_id)
  end

  defp html(socket), do: render_html(IndexLive, socket.assigns)

  # The trash read — the same `:archived` read the restore seam consults, so "it is in the trash" and
  # "it can come back" are asserted through the path that brings it back.
  defp trashed(org_id) do
    Doc
    |> Ash.Query.for_read(:archived)
    |> Ash.Query.ensure_selected([:id, :archived_at])
    |> Ash.read!(scope: scope_for(org_id))
  end

  defp trashed_ids(org_id), do: Enum.map(trashed(org_id), & &1.id)

  defp live_ids(org_id) do
    {:ok, pages} = Reads.index(notes_mount(), scope_for(org_id))
    Enum.map(pages, & &1.id)
  end

  defp archived_doc!(org_id, doc_id) do
    require Ash.Query

    Doc
    |> Ash.Query.for_read(:archived)
    |> Ash.Query.ensure_selected([:id, :parent_doc_id, :archived_at])
    |> Ash.Query.filter(id == ^doc_id)
    |> Ash.read_one!(scope: scope_for(org_id))
  end

  # The rows at rest — a purge is proven by the table, not by a read that could be filtering.
  defp rows(table, column, id) do
    %{rows: [[count]]} =
      Samen.WebTest.Repo.query!(
        "SELECT count(*) FROM #{table} WHERE #{column} = $1",
        [Ecto.UUID.dump!(id)]
      )

    count
  end

  defp doc_rows(doc_id), do: rows("wdd_doc", "wdd_id", doc_id)
  defp block_rows(doc_id), do: rows("wdb_doc_block", "wdb_doc_id", doc_id)

  defp aud_event_types(subject_id) do
    %{rows: rows} =
      Samen.WebTest.Repo.query!(
        "SELECT aud_event_type FROM aud_event WHERE aud_subject_id = $1",
        [to_string(subject_id)]
      )

    Enum.map(rows, fn [type] -> type end)
  end

  defp actors_of(subject_id, event_type) do
    %{rows: rows} =
      Samen.WebTest.Repo.query!(
        "SELECT aud_actor_id FROM aud_event WHERE aud_subject_id = $1 AND aud_event_type = $2",
        [to_string(subject_id), event_type]
      )

    Enum.map(rows, fn [actor] -> actor end)
  end

  # ── delete ─────────────────────────────────────────────────────────────────

  describe "deleting a page takes its subpages with it" do
    test "the whole subtree leaves the tree, each page audited, all at one instant" do
      org_id = Ash.UUID.generate()
      root = seed_doc!(org_id, %{title: "Handbook"})
      chapter = seed_doc!(org_id, %{title: "Chapter", parent_doc_id: root.id})
      section = seed_doc!(org_id, %{title: "Section", parent_doc_id: chapter.id})
      unrelated = seed_doc!(org_id, %{title: "Elsewhere"})

      assert {:ok, archived} = Writes.archive_page(notes_mount(), scope_for(org_id), root.id)

      # Out of the tree — the unrelated page is the positive control: this was a delete, not a list
      # that broke.
      assert live_ids(org_id) == [unrelated.id]

      # Every page of the subtree is in the trash, stamped with the instant the parent was deleted
      # at. That equality is what `CascadeRestore` matches on, so it is asserted, not assumed.
      trashed = trashed(org_id)
      assert Enum.sort(Enum.map(trashed, & &1.id)) == Enum.sort([root.id, chapter.id, section.id])
      assert Enum.all?(trashed, &(&1.archived_at == archived.archived_at))

      # A cascade is not one row saying "some pages were deleted": each page answers "who deleted
      # this?" for itself.
      for doc <- [root, chapter, section] do
        assert "record_archived" in aud_event_types(doc.id)

        refute "record_archived" in aud_event_types(unrelated.id),
               "the positive control was archived too — the assertion above proves nothing"
      end
    end

    test "the cascade belongs to the model, not to the helper" do
      org_id = Ash.UUID.generate()
      root = seed_doc!(org_id, %{title: "Handbook"})
      child = seed_doc!(org_id, %{title: "Chapter", parent_doc_id: root.id})
      grandchild = seed_doc!(org_id, %{title: "Section", parent_doc_id: child.id})

      # Straight through the substrate: no `Writes.archive_page/3`, no link reconcile, nothing this
      # module does. If the subtree still retires, the guarantee is where it belongs.
      assert {:ok, _archived} = Samen.Archival.archive(root, scope: scope_for(org_id))

      assert Enum.sort(trashed_ids(org_id)) == Enum.sort([root.id, child.id, grandchild.id])
      assert live_ids(org_id) == []
    end
  end

  # ── restore ────────────────────────────────────────────────────────────────

  describe "restoring a page restores what went down with it" do
    test "the same-instant match brings the subtree back and leaves an earlier delete alone" do
      org_id = Ash.UUID.generate()
      root = seed_doc!(org_id, %{title: "Handbook"})
      with_parent = seed_doc!(org_id, %{title: "Chapter", parent_doc_id: root.id})
      alone = seed_doc!(org_id, %{title: "Draft", parent_doc_id: root.id})

      # Deleted on its OWN first: its instant is its own, and the parent's cascade must not claim it.
      alone_archived = delete!(org_id, alone.id)
      parent_archived = delete!(org_id, root.id)
      refute alone_archived.archived_at == parent_archived.archived_at

      assert {:ok, restored} = Writes.restore_page(notes_mount(), scope_for(org_id), root.id)
      assert restored.id == root.id

      # The subtree that went down with the page is back…
      assert Enum.sort(live_ids(org_id)) == Enum.sort([root.id, with_parent.id])

      # …and the page deleted on its own is STILL in the trash, at its own instant: an undo restores
      # what the action removed, not every deletion that happened nearby.
      remaining = trashed(org_id)
      assert Enum.map(remaining, & &1.id) == [alone.id]
      assert hd(remaining).archived_at == alone_archived.archived_at
    end

    test "a page cannot be restored under a parent that is still in the trash" do
      org_id = Ash.UUID.generate()
      root = seed_doc!(org_id, %{title: "Handbook"})
      child = seed_doc!(org_id, %{title: "Chapter", parent_doc_id: root.id})

      _deleted = delete!(org_id, root.id)

      # The seam's answer — what the trash renders…
      assert {:error, :parent_in_trash} =
               Writes.restore_page(notes_mount(), scope_for(org_id), child.id)

      # …and the MODEL's, for a caller this seam has never heard of. A direct governed `:restore` is
      # refused too, so the orphan cannot be created by going around the helper.
      assert {:error, _refused} =
               archived_doc!(org_id, child.id)
               |> Ash.Changeset.for_update(:restore, %{}, scope: scope_for(org_id))
               |> Ash.update()

      # Refused is not "failed halfway": both pages are still in the trash and still out of the tree.
      assert Enum.sort(trashed_ids(org_id)) == Enum.sort([root.id, child.id])
      assert live_ids(org_id) == []

      # Positive control — the parent, the same path: it comes back, and the child comes back WITH it,
      # so the refusal above was the orphan rule and not a broken restore.
      assert {:ok, _restored} = Writes.restore_page(notes_mount(), scope_for(org_id), root.id)
      assert Enum.sort(live_ids(org_id)) == Enum.sort([root.id, child.id])
      assert trashed_ids(org_id) == []

      # …and a second restore of the child (now live) settles instead of erroring.
      assert {:ok, _already} = Writes.restore_page(notes_mount(), scope_for(org_id), child.id)
    end
  end

  # ── purge ──────────────────────────────────────────────────────────────────

  describe "purging a page destroys its subtree" do
    test "every page, its blocks and its own record_purged row, attributed to the admin" do
      org_id = Ash.UUID.generate()
      root = seed_doc!(org_id, %{title: "Handbook"})
      chapter = seed_doc!(org_id, %{title: "Chapter", parent_doc_id: root.id})
      section = seed_doc!(org_id, %{title: "Section", parent_doc_id: chapter.id})

      for doc <- [root, chapter, section] do
        _block = insert!(org_id, doc.id, "content for #{doc.id}")
        assert block_rows(doc.id) == 1
      end

      _deleted = delete!(org_id, root.id)

      admin = scope_as(org_id, :admin)
      assert {:ok, purged} = Writes.purge_page(notes_mount(), admin, root.id)
      assert purged.id == root.id

      for doc <- [root, chapter, section] do
        assert doc_rows(doc.id) == 0, "a subpage row survived the purge of its parent"
        assert block_rows(doc.id) == 0, "authored content survived the purge of its page"
        assert "record_purged" in aud_event_types(doc.id)
        assert actors_of(doc.id, "record_purged") == ["user:admin"]
      end

      assert trashed_ids(org_id) == []

      # Nothing is left to point at: the child cannot be restored or purged a second time.
      assert {:error, :not_found} =
               Writes.restore_page(notes_mount(), scope_for(org_id), section.id)

      assert {:error, :not_found} = Writes.purge_page(notes_mount(), admin, section.id)
    end

    test "the bulk empty destroys a parent and its children once, without tripping on the ids it removed" do
      org_id = Ash.UUID.generate()
      first = seed_doc!(org_id, %{title: "Handbook"})
      first_child = seed_doc!(org_id, %{title: "Chapter", parent_doc_id: first.id})
      second = seed_doc!(org_id, %{title: "Notes"})
      _second_block = insert!(org_id, second.id, "content")

      _deleted = delete!(org_id, first.id)
      _deleted = delete!(org_id, second.id)

      assert {:ok, purged} = Writes.empty_trash(notes_mount(), scope_as(org_id, :admin))

      # Four pages went, each exactly once: the loop reaches the child's id AFTER the parent's purge
      # removed it, and skips it instead of failing the whole empty (which would leave the trash
      # untouched).
      assert Enum.sort(Enum.map(purged, & &1.id)) ==
               Enum.sort([first.id, first_child.id, second.id])

      for doc <- [first, first_child, second], do: assert(doc_rows(doc.id) == 0)
      assert trashed_ids(org_id) == []
    end

    test "a purge refuses rather than destroy a LIVE subpage" do
      org_id = Ash.UUID.generate()
      root = seed_doc!(org_id, %{title: "Handbook"})
      _deleted = delete!(org_id, root.id)

      # The legacy shape: a live page under a trashed parent. Only reachable from a parent deleted
      # before the cascade existed (no surface creates one) — which is exactly why the purge may not
      # assume it cannot happen.
      late = seed_doc!(org_id, %{title: "Late arrival", parent_doc_id: root.id})

      admin = scope_as(org_id, :admin)

      assert {:error, :live_descendants} = Writes.purge_page(notes_mount(), admin, root.id)

      # Refused is not "destroyed some of it": the parent is still in the trash, the live child still
      # live and still readable.
      assert trashed_ids(org_id) == [root.id]
      assert doc_rows(late.id) == 1
      assert late.id in live_ids(org_id)

      # Positive control — once the live child is deleted (into the trash, where emptying can reach
      # it), the same purge goes through and takes both.
      _deleted = delete!(org_id, late.id)
      assert {:ok, _purged} = Writes.purge_page(notes_mount(), admin, root.id)
      assert doc_rows(late.id) == 0
    end
  end

  # ── the surfaces ───────────────────────────────────────────────────────────

  describe "the surfaces say what the cascade will do" do
    test "the index names the subpage count before the click and reports it after" do
      org_id = Ash.UUID.generate()
      root = seed_doc!(org_id, %{title: "Handbook"})
      child = seed_doc!(org_id, %{title: "Chapter", parent_doc_id: root.id})
      _grandchild = seed_doc!(org_id, %{title: "Section", parent_doc_id: child.id})
      _other = seed_doc!(org_id, %{title: "Elsewhere"})

      socket = index_socket(org_id)

      {:noreply, confirming} =
        IndexLive.handle_event("confirm_archive", %{"id" => root.id}, socket)

      html = html(confirming)

      assert html =~ "Delete “Handbook”?"
      assert html =~ "Its 2 subpages go with it."

      # The count belongs to the page the question names, not to whichever row rendered first.
      refute html =~ "note-delete-subpages-#{child.id}"

      {:noreply, after_delete} =
        IndexLive.handle_event("archive_page", %{"id" => root.id}, confirming)

      # The notice reports what actually went (the count is read BEFORE the write, because after it
      # those rows are gone and the notice could not know).
      notice = html(after_delete)
      assert notice =~ "notes-deleted-notice"
      assert notice =~ "Page and 2 subpages deleted."
      refute notice =~ "Chapter"
    end

    test "a page with no subpages keeps the plain sentence" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, %{title: "Lonely"})

      {:noreply, confirming} =
        IndexLive.handle_event("confirm_archive", %{"id" => doc.id}, index_socket(org_id))

      assert html(confirming) =~ "Delete “Lonely”?"
      refute html(confirming) =~ "go with it."

      {:noreply, after_delete} =
        IndexLive.handle_event("archive_page", %{"id" => doc.id}, confirming)

      assert html(after_delete) =~ "Page deleted."
    end

    test "the trash tells the user which page to restore first" do
      org_id = Ash.UUID.generate()
      root = seed_doc!(org_id, %{title: "Handbook"})
      child = seed_doc!(org_id, %{title: "Chapter", parent_doc_id: root.id})
      _deleted = delete!(org_id, root.id)

      {:noreply, refused} =
        TrashLive.handle_event("restore_page", %{"id" => child.id}, trash_socket(org_id))

      assert refused.assigns.error =~ "restore the parent first"
      assert Enum.sort(trashed_ids(org_id)) == Enum.sort([root.id, child.id])

      # Positive control: the parent restores, the child comes with it, and the trash is empty.
      {:noreply, restored} =
        TrashLive.handle_event("restore_page", %{"id" => root.id}, trash_socket(org_id))

      assert restored.assigns.pages == []
      assert Enum.sort(live_ids(org_id)) == Enum.sort([root.id, child.id])
    end
  end
end
