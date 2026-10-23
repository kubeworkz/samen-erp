defmodule Samen.Web.NotesTrashTest do
  @moduledoc """
  WS-Notes Phase 3 unit 3.8 — the Pages **Trash** (`Samen.Web.Notes.TrashLive`, `/pages/trash`),
  rendered and driven through the SAME module the router mounts.

  What is proven here, and why each proof is non-vacuous:

    * **the undo's durable sibling** — a page deleted with `Writes.archive_page/3` leaves the
      index's transient notice but is still findable here, through `Reads.trash/2` (the
      `:archived` read on the same `Doc` resource). Without this view, "recoverable" would mean
      "recoverable until the socket reloads";
    * **restoring is the SAME governed write as the Undo** — `Writes.restore_page/3`, so the page
      returns with its blocks and its `record_restored` audit row, and the row leaves the trash;
    * **a row is metadata, never content** — the list shows the title and the deletion time, and
      the page's text (clear on the tenant plane, vaulted or not) is ABSENT from this DOM. That is
      the one plane-related claim this surface makes: it reads no body, so there is nothing for a
      plane to mask or reveal;
    * **org scope and role decide** — another org's deleted page is absent from the list and its
      id cannot be restored from a foreign scope (R1, and the refusal names nothing); a viewer is
      refused while the page stays archived;
    * **the route cannot swallow a page id** — `/pages/trash` is declared BEFORE `/pages/:id` in
      the framework's route table, which is what makes the URL the trash's rather than a page
      editor's;
    * **emptying the trash is the one write that ends a page** (unit 3.11) — `Writes.purge_page/3`
      destroys the row AND its blocks (which archiving deliberately leaves behind), writes
      `record_purged`, and is 404-safe: a live, foreign, unknown or already-emptied page is
      `{:error, :not_found}` and the page survives. The gate is the model's (`RoleAtLeast :admin`
      on `Doc.:purge`), not the button's: a member's crafted event is refused and the page stays;
    * **the bulk empty is the same write, all at once** (unit 3.12) — `Writes.empty_trash/2` purges
      every page the trash holds in ONE transaction, with one `record_purged` row per page. A live
      page is never a candidate (the read is `:archived`), and one refusal rolls the lot back, so a
      member's crafted event cannot leave the trash half-emptied.
  """

  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  alias Samen.Web.{Mount, Notes.IndexLive, Notes.TrashLive, Notes.Writes, Plane, TenantRole}
  alias Samen.WebTest.Operator, as: Op

  alias Samen.WebTest.Docs.Doc

  @secret "TRASH-CONTENT-SENTINEL"

  # The deleter's vaulted name — a distinctive sentinel, so a leak into an operator DOM is
  # unmistakable. The surname is checked separately (a partial-name leak is still a leak).
  @surname "Trashworth"
  @full_name "Aurelia " <> @surname

  # ── harness ────────────────────────────────────────────────────────────────

  defp identified_operator_mount(org_id) do
    notes_mount(Plane.operator("op-1", org_id), %{identity_namespace: Op})
  end

  defp notes_mount(plane \\ Plane.tenant(), extra_labels \\ %{}) do
    Mount.new(:notes, Samen.WebTest.Docs, Samen.WebTest.Repo,
      plane: plane,
      labels: Map.merge(%{pages_path: "/pages"}, extra_labels)
    )
  end

  # A tenant mount that can resolve WHO is acting: the `:identity_namespace` sibling seam (User /
  # Membership live under the test host's Operator identity scope) plus the principal the tenant
  # `live_session` stashes on the mount — the two facts `TenantRole.identity_scope/2` needs.
  defp identified_mount(credential_id) do
    notes_mount(Plane.tenant(), %{identity_namespace: Op, __principal__: credential_id})
  end

  # A real `Identity.User` + `Membership` for `credential_id` in `org_id` — what `OrgActor.resolve/3`
  # reads, so `identity_scope/2` names this user rather than the workspace pseudo-principal. A
  # `:full_name` seeds the VAULTED name the trash resolves per plane (the write goes through the
  # ordinary vault write path, exactly as `Samen.WebTest.Operator.Seeds` does it).
  # A fictional host app whose `:auth_required?` flag a test arms in isolation — never poisoning
  # `:samen_web` for other suites (the `SecurityHost` idiom).
  @armed_app :notes_purge_test_host

  defp seed_member!(org_id, credential_id, handle, opts \\ []) do
    attrs =
      %{org_id: org_id, handle: handle}
      |> then(fn attrs ->
        case Keyword.get(opts, :full_name) do
          nil -> attrs
          %Samen.Type.FullName{} = name -> Map.put(attrs, :full_name, name)
        end
      end)

    # `credential_id` is the spine's nullable FK and is `public?: false` (never settable through a
    # public `create :*`), so the fixture forces it — the same value a confirmed sign-in lands.
    user =
      Op.User
      |> Ash.Changeset.for_create(:create, attrs)
      |> Ash.Changeset.force_change_attribute(:credential_id, credential_id)
      |> Ash.create!(authorize?: false)

    _membership =
      Op.Membership
      |> Ash.Changeset.for_create(:create, %{
        org_id: org_id,
        user_id: user.id,
        role: Keyword.get(opts, :role, :member)
      })
      |> Ash.create!(authorize?: false)

    user
  end

  # An ARMED tenant mount: the `:authn` seam plus the `:otp_app` it resolves against, and the
  # Identity namespace the caller's REAL `Membership` role is read from (a host that wires
  # samenerp's shared labels). Without the arm the dev convenience reports `:admin` for everyone
  # and the role gate below could not be distinguished from a broken one.
  defp armed_mount(credential_id) do
    notes_mount(Plane.tenant(), %{
      otp_app: @armed_app,
      authn: {:app_env, @armed_app, :auth_required?},
      identity_namespace: Op,
      __principal__: credential_id
    })
  end

  defp arm! do
    previous = Application.get_env(@armed_app, :auth_required?)
    Application.put_env(@armed_app, :auth_required?, true)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(@armed_app, :auth_required?)
        value -> Application.put_env(@armed_app, :auth_required?, value)
      end
    end)

    :ok
  end

  # A tenant-plane scope with an explicit ROLE — the surface's own scope is membership-derived; the
  # model's gate is proven by handing it a fabricated rank (the `Samen.DocsScopeTest` c11 shape).
  defp scope_as(org_id, role) do
    %Samen.Scope{
      actor: %{id: "user:#{role}", org_id: org_id, role: role, kind: :tenant, plane: :tenant}
    }
  end

  # The page's block rows at rest — the count a hard delete must take to zero (the page's blocks are
  # NOT archived with it, so a page-only delete would leave content behind).
  defp block_rows(doc_id) do
    %{rows: [[count]]} =
      Samen.WebTest.Repo.query!(
        "SELECT count(*) FROM wdb_doc_block WHERE wdb_doc_id = $1",
        [Ecto.UUID.dump!(doc_id)]
      )

    count
  end

  defp actors_of(subject_id, event_type) do
    %{rows: rows} =
      Samen.WebTest.Repo.query!(
        "SELECT aud_actor_id FROM aud_event WHERE aud_subject_id = $1 AND aud_event_type = $2",
        [to_string(subject_id), event_type]
      )

    Enum.map(rows, fn [actor] -> actor end)
  end

  # The user row with its VAULTED name loaded — the shape `PiiResolution` resolves, and the record
  # the sabotage-twin resolver assertions drive directly.
  defp read_user!(user_id) do
    require Ash.Query

    Op.User
    |> Ash.Query.filter(id == ^user_id)
    |> Ash.Query.ensure_selected([:id, :org_id, :full_name])
    |> Ash.read_one!(authorize?: false)
  end

  # A scope that names a DIFFERENT person — a colleague's delete, as their own session would write it.
  defp as_actor(user, org_id) do
    %Samen.Scope{
      actor: %{id: user.id, org_id: org_id, role: :member, kind: :tenant, plane: :tenant}
    }
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

  defp delete!(org_id, doc_id) do
    {:ok, deleted} = Writes.archive_page(notes_mount(), scope_for(org_id), doc_id)
    deleted
  end

  # A socket loaded the way the route loads it, so a handler can be driven without a router.
  defp trash_socket(mount, org_id) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> TrashLive.load(org_id)
  end

  defp html_of(socket), do: render_html(TrashLive, socket.assigns)

  # The trash read is the `:archived` read — the same one the restore seam consults, never a raw
  # table query, so "it can come back" is asserted through the path that brings it back.
  defp archived_ids(org_id) do
    Doc
    |> Ash.Query.for_read(:archived)
    |> Ash.Query.ensure_selected([:id])
    |> Ash.read!(scope: scope_for(org_id))
    |> Enum.map(& &1.id)
  end

  # The governance trail's own record of who deleted the page — the read the surface renders.
  defp delete_audit_actors(subject_id) do
    %{rows: rows} =
      Samen.WebTest.Repo.query!(
        "SELECT aud_actor_id FROM aud_event WHERE aud_subject_id = $1 " <>
          "AND aud_event_type = 'record_archived' ORDER BY aud_occurred_at DESC",
        [to_string(subject_id)]
      )

    Enum.map(rows, fn [actor] -> actor end)
  end

  defp aud_event_types(subject_id) do
    %{rows: rows} =
      Samen.WebTest.Repo.query!(
        "SELECT aud_event_type FROM aud_event WHERE aud_subject_id = $1",
        [to_string(subject_id)]
      )

    Enum.map(rows, fn [type] -> type end)
  end

  # ── finding a deleted page ─────────────────────────────────────────────────

  describe "the trash lists what the tree no longer shows" do
    test "a deleted page is here, a live page is not, and the index links to it" do
      org_id = Ash.UUID.generate()
      live = seed_doc!(org_id, %{title: "Still live"})
      gone = seed_doc!(org_id, %{title: "Retired page"})
      _deleted = delete!(org_id, gone.id)

      index_html = render_live(IndexLive, notes_mount(), [org_id])
      assert index_html =~ ~s(href="/pages/trash?org=#{org_id}")

      html = render_live(TrashLive, notes_mount(), [org_id])

      assert html =~ ~s(class="app"), "the trash must render inside the shared shell"
      assert html =~ "note-trash-item-#{gone.id}"
      assert html =~ "Retired page"
      assert html =~ "deleted "

      refute html =~ "note-trash-item-#{live.id}",
             "a live page belongs in the tree, not in the trash"

      assert html =~ ~s(href="/pages?org=#{org_id}"), "the trash must offer the way back"
    end

    test "the trash shows the title and the deletion time — never the page's text" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, %{title: "Retired page"})
      _block = insert!(org_id, doc.id, %{type: :paragraph, text: @secret})
      _deleted = delete!(org_id, doc.id)

      html = render_live(TrashLive, notes_mount(), [org_id])

      # The row is metadata: a deleted page is a title and a date, not a second reader of content
      # (which on this plane would be clear text — the assertion is refutable by adding a block
      # read to the row).
      assert html =~ "Retired page"
      refute html =~ @secret
    end

    test "an empty trash says so instead of rendering a blank list" do
      org_id = Ash.UUID.generate()
      _live = seed_doc!(org_id)

      html = render_live(TrashLive, notes_mount(), [org_id])

      assert html =~ "notes-trash-empty"
      assert html =~ "The trash is empty."
    end

    test "one org's deleted pages are absent from another org's trash (R1)" do
      mine = Ash.UUID.generate()
      theirs = Ash.UUID.generate()
      foreign = seed_doc!(theirs, %{title: "Foreign secret title"})
      _deleted = delete!(theirs, foreign.id)

      html = render_live(TrashLive, notes_mount(), [mine])

      assert html =~ "notes-trash-empty"
      refute html =~ "Foreign secret title"
    end
  end

  # ── restoring ──────────────────────────────────────────────────────────────

  describe "restoring from the trash" do
    test "the page comes back with its blocks, its audit line and a way to open it" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, %{title: "Retire me"})
      _block = insert!(org_id, doc.id, %{type: :paragraph, text: "Content that survives"})
      _deleted = delete!(org_id, doc.id)

      socket = trash_socket(notes_mount(), org_id)
      assert Enum.any?(socket.assigns.pages, &(&1.id == doc.id))

      {:noreply, restored} = TrashLive.handle_event("restore_page", %{"id" => doc.id}, socket)

      # The row leaves the trash and the page returns to the tree…
      assert restored.assigns.pages == []
      assert archived_ids(org_id) == []

      # …with its content intact, because the restore is the model's `:restore` (a re-create would
      # have produced an empty shell)…
      assert {:ok, page} = Samen.Web.Notes.Reads.page(notes_mount(), scope_for(org_id), doc.id)
      assert Enum.any?(page.blocks, &(&1.text == "Content that survives"))

      # …and with an audit row that pairs the delete's.
      assert "record_archived" in aud_event_types(doc.id)
      assert "record_restored" in aud_event_types(doc.id)

      html = html_of(restored)

      assert restored.assigns.restored == %{id: doc.id, title: "Retire me"}
      assert html =~ "notes-restored-notice"
      assert html =~ "Page restored."

      assert html =~ ~s(href="/pages/#{doc.id}?org=#{org_id}"),
             "the notice must carry the way to the page it restored"

      refute html =~ "note-trash-item-#{doc.id}"
    end

    test "a restore that cannot land says so instead of claiming it did" do
      org_id = Ash.UUID.generate()

      {:noreply, after_event} =
        TrashLive.handle_event(
          "restore_page",
          %{"id" => Ash.UUID.generate()},
          trash_socket(notes_mount(), org_id)
        )

      assert after_event.assigns.error == "The page could not be restored."
      assert after_event.assigns.restored == nil
      assert html_of(after_event) =~ "notes-trash-error"
    end

    test "another org's deleted page cannot be restored — and the refusal names nothing" do
      mine = Ash.UUID.generate()
      theirs = Ash.UUID.generate()
      foreign = seed_doc!(theirs, %{title: "Foreign secret title"})
      _deleted = delete!(theirs, foreign.id)

      assert {:error, :not_found} =
               Writes.restore_page(notes_mount(), scope_for(mine), foreign.id)

      # Nothing moved: the page is still in ITS org's trash and still absent from the tree.
      assert archived_ids(theirs) == [foreign.id]

      assert {:error, :not_found} =
               Samen.Web.Notes.Reads.page(notes_mount(), scope_for(theirs), foreign.id)

      # Positive control: the SAME call in the page's own org restores it, so the refusal above is
      # the org scope rather than a broken path.
      assert {:ok, _restored} = Writes.restore_page(notes_mount(), scope_for(theirs), foreign.id)
      assert archived_ids(theirs) == []
    end

    test "restoring is a MEMBER write — a viewer is refused and the page stays deleted" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)
      _deleted = delete!(org_id, doc.id)

      viewer = %Samen.Scope{
        actor: %{id: "user:viewer", org_id: org_id, role: :viewer, kind: :tenant, plane: :tenant}
      }

      assert {:error, _refused} = Writes.restore_page(notes_mount(), viewer, doc.id)
      assert archived_ids(org_id) == [doc.id]

      # Positive control — same page, same path, a member scope.
      assert {:ok, _restored} = Writes.restore_page(notes_mount(), scope_for(org_id), doc.id)
      assert archived_ids(org_id) == []
    end
  end

  # ── emptying the trash (permanent delete) ─────────────────────────────────

  describe "deleting a page forever — emptying the trash" do
    test "an admin empties a page: the row, its blocks and its content go, and the trail says so" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, %{title: "Purge me"})

      _block =
        insert!(org_id, doc.id, %{
          type: :paragraph,
          text: "Content that must not outlive the page"
        })

      _deleted = delete!(org_id, doc.id)

      # Positive control for the count below: the trashed page really does have a block at rest
      # (a page's blocks are NOT archived with it, so a page-only delete would orphan it).
      assert block_rows(doc.id) == 1
      assert archived_ids(org_id) == [doc.id]

      socket = trash_socket(notes_mount(), org_id)
      assert Enum.any?(socket.assigns.pages, &(&1.id == doc.id))

      # Two-step: the control ASKS before it writes (server-side, so it works with no JavaScript).
      {:noreply, confirming} = TrashLive.handle_event("confirm_purge", %{"id" => doc.id}, socket)
      assert confirming.assigns.confirm == doc.id
      assert html_of(confirming) =~ "note-purge-confirm-#{doc.id}"
      assert html_of(confirming) =~ "Delete forever"
      refute html_of(confirming) =~ "note-trash-purge-#{doc.id}"

      {:noreply, purged} = TrashLive.handle_event("purge_page", %{"id" => doc.id}, confirming)

      # Gone from every read path — not merely filtered out of the list this render shows.
      assert purged.assigns.pages == []
      assert archived_ids(org_id) == []

      assert {:error, :not_found} =
               Samen.Web.Notes.Reads.page(notes_mount(), scope_for(org_id), doc.id)

      # …and the CONTENT went with it. This is the assertion a page-only hard delete fails.
      assert block_rows(doc.id) == 0

      assert purged.assigns.purged == %{title: "Purge me"}
      assert purged.assigns.confirm == nil

      html = html_of(purged)
      assert html =~ "notes-purged-notice"
      assert html =~ "Page deleted permanently."
      refute html =~ "note-trash-item-#{doc.id}"

      refute html =~ ~s(href="/pages/#{doc.id}?org=#{org_id}"),
             "the notice must not link to the page it just destroyed"

      # The terminal delete is on the record, paired with the archive that preceded it.
      assert Enum.sort(aud_event_types(doc.id)) == ["record_archived", "record_purged"]
      assert actors_of(doc.id, "record_purged") == ["broker:#{org_id}"]
    end

    test "a purge that cannot land is 404-safe — unknown, already-purged and LIVE ids are never found" do
      org_id = Ash.UUID.generate()
      live = seed_doc!(org_id, %{title: "Still live"})
      gone = seed_doc!(org_id, %{title: "Gone"})
      _deleted = delete!(org_id, gone.id)

      admin = scope_as(org_id, :admin)

      assert {:ok, _purged} = Writes.purge_page(notes_mount(), admin, gone.id)

      # A second attempt on the same id — an old tab — settles instead of raising.
      assert {:error, :not_found} = Writes.purge_page(notes_mount(), admin, gone.id)

      # A LIVE page is not in the trash, so there is nothing here to empty…
      assert {:error, :not_found} = Writes.purge_page(notes_mount(), admin, live.id)

      # …and it SURVIVES: the refusal is the trash read, not a delete that lost its way.
      assert {:ok, _still} = Samen.Web.Notes.Reads.page(notes_mount(), scope_for(org_id), live.id)

      assert {:error, :not_found} =
               Writes.purge_page(notes_mount(), admin, Ash.UUID.generate())

      # The surface answers the same way instead of crashing on a row it cannot find.
      {:noreply, missing} =
        TrashLive.handle_event(
          "purge_page",
          %{"id" => live.id},
          trash_socket(notes_mount(), org_id)
        )

      assert missing.assigns.error == "That page is no longer in the trash."
      assert missing.assigns.confirm == nil
      assert html_of(missing) =~ "notes-trash-error"

      # The live page is still live for everyone else too.
      assert {:ok, _still} = Samen.Web.Notes.Reads.page(notes_mount(), scope_for(org_id), live.id)
    end

    test "trashing a page is a MEMBER write; emptying the trash is not — the page stays" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, %{title: "Recoverable"})
      _deleted = delete!(org_id, doc.id)

      assert {:error, :forbidden} =
               Writes.purge_page(notes_mount(), scope_as(org_id, :member), doc.id)

      # Refused is not "failed after deleting": the row is still in the trash and nothing else is
      # on its trail — the state a member who crafted the event would have changed.
      assert archived_ids(org_id) == [doc.id]
      assert aud_event_types(doc.id) == ["record_archived"]

      # Positive control — the SAME page, the SAME path, an admin scope, attributed to that admin.
      assert {:ok, _purged} = Writes.purge_page(notes_mount(), scope_as(org_id, :admin), doc.id)
      assert archived_ids(org_id) == []
      assert actors_of(doc.id, "record_purged") == ["user:admin"]
    end

    test "the control is OFFERED to an admin and withheld from a member (armed host)" do
      :ok = arm!()

      org_id = Ash.UUID.generate()
      admin_credential = Ash.UUID.generate()
      member_credential = Ash.UUID.generate()
      _admin = seed_member!(org_id, admin_credential, "notes-admin", role: :admin)
      _member = seed_member!(org_id, member_credential, "notes-member")

      doc = seed_doc!(org_id, %{title: "Trash business"})
      _deleted = delete!(org_id, doc.id)

      admin_html = render_live(TrashLive, armed_mount(admin_credential), [org_id])
      assert admin_html =~ "note-trash-purge-#{doc.id}"
      refute admin_html =~ "notes-trash-purge-admin-only"

      member_mount = armed_mount(member_credential)
      member_html = render_live(TrashLive, member_mount, [org_id])

      refute member_html =~ "note-trash-purge-#{doc.id}",
             "a member must not be OFFERED a write the kernel refuses"

      assert member_html =~ "notes-trash-purge-admin-only"

      # The plane hides the CONTROL, not the list: restoring is still theirs, and the page is still
      # a fact about their workspace.
      assert member_html =~ "note-trash-item-#{doc.id}"
      assert member_html =~ "note-trash-restore-#{doc.id}"

      # …and the crafted event a tampered client would send is refused by the MODEL, not the view.
      {:noreply, refused} =
        TrashLive.handle_event(
          "purge_page",
          %{"id" => doc.id},
          trash_socket(member_mount, org_id)
        )

      assert refused.assigns.error == "The page could not be deleted permanently."
      assert archived_ids(org_id) == [doc.id]
      refute "record_purged" in aud_event_types(doc.id)
    end

    test "the model refuses to purge a LIVE page — archive first is not optional" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, %{title: "Live page"})

      # A direct governed write, the shape a caller outside the trash would take.
      assert {:error, error} =
               doc
               |> Ash.Changeset.for_destroy(:purge, %{}, scope: scope_as(org_id, :admin))
               |> Ash.destroy()

      assert inspect(error) =~ "deleted permanently",
             "the refusal must say the page has to be trashed first"

      # The row is untouched, still live, still readable through the ordinary read…
      assert {:ok, _still} = Samen.Web.Notes.Reads.page(notes_mount(), scope_for(org_id), doc.id)
      # …and nothing was audited for a destroy that never happened.
      assert aud_event_types(doc.id) == []

      # Positive control: the SAME page, the SAME action, once it is in the trash.
      _deleted = delete!(org_id, doc.id)
      assert {:ok, _purged} = Writes.purge_page(notes_mount(), scope_as(org_id, :admin), doc.id)
      assert archived_ids(org_id) == []
    end
  end

  # ── emptying the WHOLE trash (unit 3.12) ───────────────────────────────────

  describe "emptying the whole trash at once" do
    test "an admin empties EVERY trashed page in one write — rows, blocks and one audit line each" do
      org_id = Ash.UUID.generate()
      first = seed_doc!(org_id, %{title: "First retired"})
      second = seed_doc!(org_id, %{title: "Second retired"})

      _block = insert!(org_id, first.id, %{type: :paragraph, text: "First content"})
      _block = insert!(org_id, second.id, %{type: :paragraph, text: "Second content"})

      _deleted = delete!(org_id, first.id)
      _deleted = delete!(org_id, second.id)

      assert Enum.sort(archived_ids(org_id)) == Enum.sort([first.id, second.id])
      assert block_rows(first.id) == 1
      assert block_rows(second.id) == 1

      assert {:ok, purged} = Writes.empty_trash(notes_mount(), scope_as(org_id, :admin))

      assert Enum.sort(Enum.map(purged, & &1.id)) == Enum.sort([first.id, second.id]),
             "the bulk empty must take the WHOLE trash, not the first row it found"

      # Gone from every read path — asserted through the `:archived` read, not this render's list…
      assert archived_ids(org_id) == []

      # …and the CONTENT went with each of them. A page-only hard delete fails this, for both.
      assert block_rows(first.id) == 0
      assert block_rows(second.id) == 0

      # One `record_purged` PER PAGE: the trail says which pages were destroyed, not "some were".
      for doc <- [first, second] do
        assert Enum.sort(aud_event_types(doc.id)) == ["record_archived", "record_purged"]
        assert actors_of(doc.id, "record_purged") == ["user:admin"]
      end
    end

    test "a live page is never dragged in — the bulk write reads the trash and nothing else" do
      org_id = Ash.UUID.generate()
      live = seed_doc!(org_id, %{title: "Still live"})
      gone = seed_doc!(org_id, %{title: "Retired page"})

      _live_block = insert!(org_id, live.id, %{type: :paragraph, text: "Live content"})
      _gone_block = insert!(org_id, gone.id, %{type: :paragraph, text: "Deleted content"})
      _deleted = delete!(org_id, gone.id)

      assert {:ok, purged} = Writes.empty_trash(notes_mount(), scope_as(org_id, :admin))

      assert Enum.map(purged, & &1.id) == [gone.id],
             "a live page is not in the trash and must not be a candidate for the terminal delete"

      # The live page is untouched, content included, and nothing was audited against it.
      assert {:ok, page} = Samen.Web.Notes.Reads.page(notes_mount(), scope_for(org_id), live.id)
      assert Enum.any?(page.blocks, &(&1.text == "Live content"))
      assert block_rows(live.id) == 1
      assert aud_event_types(live.id) == []

      assert archived_ids(org_id) == []
    end

    test "a member cannot empty the trash — ONE refusal leaves the WHOLE trash standing" do
      org_id = Ash.UUID.generate()
      first = seed_doc!(org_id, %{title: "First retired"})
      second = seed_doc!(org_id, %{title: "Second retired"})

      _block = insert!(org_id, first.id, %{type: :paragraph, text: "First content"})
      _block = insert!(org_id, second.id, %{type: :paragraph, text: "Second content"})

      _deleted = delete!(org_id, first.id)
      _deleted = delete!(org_id, second.id)

      assert {:error, :forbidden} =
               Writes.empty_trash(notes_mount(), scope_as(org_id, :member))

      # Refused is not "emptied 1 of 2": the transaction rolls back whole, so both pages are still
      # in the trash, both keep their content, and neither grew an audit row for a delete that the
      # model refused.
      assert Enum.sort(archived_ids(org_id)) == Enum.sort([first.id, second.id])
      assert block_rows(first.id) == 1
      assert block_rows(second.id) == 1

      for doc <- [first, second] do
        assert aud_event_types(doc.id) == ["record_archived"]
      end

      # Positive control — the same call, the same trash, an admin scope.
      assert {:ok, purged} = Writes.empty_trash(notes_mount(), scope_as(org_id, :admin))
      assert length(purged) == 2
      assert archived_ids(org_id) == []
    end

    test "an empty trash is a no-op — {:ok, []}, and no audit row invented" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, %{title: "Once retired"})
      _deleted = delete!(org_id, doc.id)

      assert {:ok, [_purged]} = Writes.empty_trash(notes_mount(), scope_as(org_id, :admin))
      assert {:ok, []} = Writes.empty_trash(notes_mount(), scope_as(org_id, :admin))

      # The second call claims nothing, so it records nothing.
      assert Enum.sort(aud_event_types(doc.id)) == ["record_archived", "record_purged"]
    end

    test "the control is OFFERED to an admin, withheld from a member, and reports what it emptied" do
      :ok = arm!()

      org_id = Ash.UUID.generate()
      admin_credential = Ash.UUID.generate()
      member_credential = Ash.UUID.generate()
      admin = seed_member!(org_id, admin_credential, "notes-admin", role: :admin)
      _member = seed_member!(org_id, member_credential, "notes-member")

      first = seed_doc!(org_id, %{title: "First retired"})
      second = seed_doc!(org_id, %{title: "Second retired"})
      _deleted = delete!(org_id, first.id)
      _deleted = delete!(org_id, second.id)

      admin_html = render_live(TrashLive, armed_mount(admin_credential), [org_id])
      assert admin_html =~ "note-trash-empty"

      member_html = render_live(TrashLive, armed_mount(member_credential), [org_id])

      refute member_html =~ "note-trash-empty",
             "a member must not be OFFERED a write the kernel refuses"

      # The list is still theirs to read and to restore from.
      assert member_html =~ "note-trash-item-#{first.id}"
      assert member_html =~ "notes-trash-purge-admin-only"

      socket = trash_socket(armed_mount(admin_credential), org_id)

      # Two-step: the bulk control ASKS first, and the question carries the count it will destroy.
      {:noreply, confirming} = TrashLive.handle_event("confirm_empty_trash", %{}, socket)
      assert confirming.assigns.confirm_empty
      assert html_of(confirming) =~ "note-trash-empty-confirm"
      assert html_of(confirming) =~ "Delete all 2 deleted pages forever?"

      # …and cancelling is a real state change, not a hidden DOM attribute.
      {:noreply, cancelled} = TrashLive.handle_event("cancel_empty_trash", %{}, confirming)
      refute cancelled.assigns.confirm_empty
      assert html_of(cancelled) =~ "note-trash-empty"

      {:noreply, emptied} = TrashLive.handle_event("empty_trash", %{}, confirming)

      assert emptied.assigns.pages == []
      assert emptied.assigns.emptied == 2
      assert archived_ids(org_id) == []

      html = html_of(emptied)
      assert html =~ "notes-trash-emptied-notice"
      assert html =~ "2 pages deleted permanently."
      assert html =~ "The trash is empty."
      refute html =~ "note-trash-item-#{first.id}"

      # Each page's terminal delete names the admin who emptied the trash — not the workspace.
      assert actors_of(first.id, "record_purged") == [admin.id]
      assert actors_of(second.id, "record_purged") == [admin.id]
    end

    test "a crafted bulk event from a member empties nothing and says so" do
      :ok = arm!()

      org_id = Ash.UUID.generate()
      member_credential = Ash.UUID.generate()
      _member = seed_member!(org_id, member_credential, "notes-member")

      doc = seed_doc!(org_id, %{title: "Trash business"})
      _deleted = delete!(org_id, doc.id)

      {:noreply, refused} =
        TrashLive.handle_event(
          "empty_trash",
          %{},
          trash_socket(armed_mount(member_credential), org_id)
        )

      assert refused.assigns.error == "The trash could not be emptied."
      assert html_of(refused) =~ "notes-trash-error"
      refute refused.assigns.emptied

      # The refusal is the MODEL's: the row is still in the trash and nothing is on its trail.
      assert archived_ids(org_id) == [doc.id]
      assert aud_event_types(doc.id) == ["record_archived"]
    end
  end

  # ── posture, not protection ────────────────────────────────────────────────

  describe "the plane the trash is viewed on" do
    test "the operator plane sees the row but is not OFFERED the restore" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, %{title: "Retired page"})
      _deleted = delete!(org_id, doc.id)

      tenant_html = render_live(TrashLive, notes_mount(), [org_id])
      assert tenant_html =~ "note-trash-restore-#{doc.id}"

      operator_html =
        render_live(TrashLive, notes_mount(Plane.operator("op-1", org_id)), [org_id])

      refute operator_html =~ "note-trash-restore-#{doc.id}",
             "the operator plane must not be OFFERED a write it cannot be given"

      # Positive control: the plane hides the CONTROL, not the list — a page is not content, and a
      # deleted one is still a fact about the workspace.
      assert operator_html =~ "note-trash-item-#{doc.id}"
      assert operator_html =~ "Retired page"
      assert operator_html =~ "notes-trash-readonly"
    end
  end

  # ── who deleted it, from the governance trail ──────────────────────────────

  describe "the row says who deleted the page" do
    test "a workspace-scope deletion reads as 'a workspace member' — never as an opaque id" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, %{title: "Retired page"})
      _deleted = delete!(org_id, doc.id)

      # The label is READ from the trail, not invented by the view: the event really does carry the
      # workspace's shared pseudo-principal, because that is the actor `Mount.scope/2` fabricates.
      assert delete_audit_actors(doc.id) == ["broker:#{org_id}"]

      html = render_live(TrashLive, notes_mount(), [org_id])

      assert html =~ "by a workspace member"

      refute html =~ "broker:#{org_id}",
             "the row must render a label, never the opaque actor id it was derived from"

      refute html =~ "by you", "an unresolvable viewer must not claim every deletion as their own"
    end

    test "the signed-in member's own deletion reads as 'you' — and the trail names that member" do
      org_id = Ash.UUID.generate()
      credential = Ash.UUID.generate()
      member = seed_member!(org_id, credential, "notes-owner")
      mount = identified_mount(credential)
      doc = seed_doc!(org_id, %{title: "Retired page"})

      scope = TenantRole.identity_scope(mount, org_id)

      assert scope.actor.id == member.id,
             "the delete's scope must carry the principal's user id or the trail names nobody"

      assert {:ok, _deleted} = Writes.archive_page(mount, scope, doc.id)
      assert delete_audit_actors(doc.id) == [member.id]

      html = render_live(TrashLive, mount, [org_id])

      assert html =~ "by you"
      refute html =~ member.id, "the surface must not print the actor id it compared against"
    end

    test "a colleague's deletion is 'another member', not 'you'" do
      org_id = Ash.UUID.generate()
      viewer_credential = Ash.UUID.generate()
      _viewer = seed_member!(org_id, viewer_credential, "notes-viewer")
      colleague = seed_member!(org_id, Ash.UUID.generate(), "notes-colleague")

      doc = seed_doc!(org_id, %{title: "Retired page"})

      assert {:ok, _deleted} =
               Writes.archive_page(notes_mount(), as_actor(colleague, org_id), doc.id)

      html = render_live(TrashLive, identified_mount(viewer_credential), [org_id])

      assert html =~ "by another member"
      refute html =~ "by you"
      refute html =~ "by a workspace member"
    end
  end

  # ── the deleter's NAME: the masking watch-list proof ───────────────────────

  describe "the deleter's name is vault-routed PII — per-plane masking" do
    test "GREEN: the tenant plane reads its own member's name in the CLEAR" do
      org_id = Ash.UUID.generate()
      viewer_credential = Ash.UUID.generate()
      _viewer = seed_member!(org_id, viewer_credential, "notes-viewer")

      deleter =
        seed_member!(org_id, Ash.UUID.generate(), "notes-deleter",
          full_name: %Samen.Type.FullName{first: "Aurelia", last: @surname}
        )

      doc = seed_doc!(org_id, %{title: "Retired page"})

      assert {:ok, _deleted} =
               Writes.archive_page(notes_mount(), as_actor(deleter, org_id), doc.id)

      html = render_live(TrashLive, identified_mount(viewer_credential), [org_id])

      assert html =~ @full_name,
             "the tenant owns its own members' names — the row must read them in the clear"

      refute html =~ mask(), "a clear name must not be rendered as a mask on the tenant plane"
      refute html =~ "vt_"
    end

    test "RED: the operator plane without a grant renders •••• — never the name, never a vt_ token" do
      org_id = Ash.UUID.generate()

      deleter =
        seed_member!(org_id, Ash.UUID.generate(), "notes-deleter",
          full_name: %Samen.Type.FullName{first: "Aurelia", last: @surname}
        )

      doc = seed_doc!(org_id, %{title: "Retired page"})

      assert {:ok, _deleted} =
               Writes.archive_page(notes_mount(), as_actor(deleter, org_id), doc.id)

      html = render_live(TrashLive, identified_operator_mount(org_id), [org_id])

      # The row is still there (the plane hides the NAME, not the page) — and it is masked, not
      # omitted: an impersonation session sees the tenant's real UI with •••• where PII would be.
      assert html =~ "note-trash-item-#{doc.id}"
      assert_masked_dom!(html, [@full_name, @surname, deleter.id])
    end

    test "SABOTAGE twin: the mask scan is refutable, and the plane is what decides it" do
      org_id = Ash.UUID.generate()

      deleter =
        seed_member!(org_id, Ash.UUID.generate(), "notes-deleter",
          full_name: %Samen.Type.FullName{first: "Aurelia", last: @surname}
        )

      doc = seed_doc!(org_id, %{title: "Retired page"})

      assert {:ok, _deleted} =
               Writes.archive_page(notes_mount(), as_actor(deleter, org_id), doc.id)

      # (1) The resolver is the gate, not a blanket mask: the SAME record, read on the tenant
      # plane, goes clear — and the operator plane masks it. One record, one seam, two planes.
      user = read_user!(deleter.id)

      tenant_user =
        resolve_on_plane(user, Op.User, :tenant, repo: Samen.WebTest.Repo)

      operator_user =
        resolve_on_plane(user, Op.User, :operator, repo: Samen.WebTest.Repo)

      # GREEN: the tenant plane reveals the vaulted name (the vault stores the composite as the
      # JSON the shared formatter decodes).
      refute match?(%Samen.Masked{}, tenant_user.full_name)
      assert Jason.decode!(tenant_user.full_name) == %{"first" => "Aurelia", "last" => @surname}

      # RED: the same record on the operator plane is a `%Masked{}` (`••••`).
      assert_plane_masked!(operator_user.full_name, tenant_user.full_name)

      # The ONLY difference between the two reads is the plane.
      assert_two_plane!(tenant_user.full_name, operator_user.full_name, tenant_user.full_name)

      # (2) The render's mask scan is refutable: the SAME assertion that passes on the operator
      # DOM catches a leaked render. A `refute html =~ name` that could never fail is a tautology.
      tenant_html =
        render_live(TrashLive, notes_mount(Plane.tenant(), %{identity_namespace: Op}), [org_id])

      assert_leak_detected!(tenant_html, @full_name)
    end

    test "a name is read ONLY inside the acting org — a foreign actor id resolves no name" do
      org_id = Ash.UUID.generate()
      other_org = Ash.UUID.generate()

      # A user in ANOTHER org, and a delete recorded against this org with that foreign id: an
      # audit row is an opaque string, so the org filter on the identity read is the guard.
      foreign =
        seed_member!(other_org, Ash.UUID.generate(), "foreign-user",
          full_name: %Samen.Type.FullName{first: "Foreign", last: "Secretname"}
        )

      doc = seed_doc!(org_id, %{title: "Retired page"})

      assert {:ok, _deleted} =
               Writes.archive_page(notes_mount(), as_actor(foreign, org_id), doc.id)

      html = render_live(TrashLive, notes_mount(), [org_id])

      assert html =~ "note-trash-item-#{doc.id}"

      refute html =~ "Secretname",
             "the identity read is org-filtered — a foreign user's name must never render"

      # Positive control: the trail DID record that id, so the absence above is the org filter and
      # not a broken read.
      assert delete_audit_actors(doc.id) == [foreign.id]
    end
  end

  # ── the route ──────────────────────────────────────────────────────────────

  test "the router declares /pages/trash BEFORE /pages/:id, so the URL is the trash's" do
    routes = Samen.Web.Router.__routes__(:notes, "/pages")

    trash_index = Enum.find_index(routes, &(elem(&1, 0) == "/pages/trash"))
    page_index = Enum.find_index(routes, &(elem(&1, 0) == "/pages/:id"))

    assert trash_index, "the notes route table must mount the trash"
    assert page_index, "the notes route table must still mount the editor"
    assert trash_index < page_index

    assert Enum.at(routes, trash_index) == {"/pages/trash", TrashLive}
  end
end
