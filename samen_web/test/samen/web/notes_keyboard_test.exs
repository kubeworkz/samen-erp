defmodule Samen.Web.NotesKeyboardTest do
  @moduledoc """
  WS-Notes Phase 3 GATE — the **keyboard-only pass**, scripted as a test (build-plan Phase 3).

  The pass runs through a REAL compiled router + endpoint (`Samen.WebTest.SecurityEndpoint` and
  `Samen.WebTest.SecurityRouter`, which mounts `samen_notes_routes/3` itself), so it exercises:

    * the router macro's `live_session` + signed-mount round trip (`Mount.to_session/1` →
      `assign_mount/2` → `from_session/1`),
    * `Samen.Web.CurrentOrg`'s `?org=` binding on the actual `/pages/:id` route,
    * the REAL LiveView process, receiving the same events the browser sends.

  The sequence is the one the gate names — **insert → type → split → indent → move → archive** —
  and every step is asserted against the DATABASE through the same read seam the page uses, not
  against the render alone (a page that painted a change it did not persist would fail here).

  The events are driven the way the keyboard drives them: the structure intents (`split_block`,
  `merge_block`, `indent_block`, `move_block`) are the ones the `NoteBlock` hook pushes on
  Enter / Backspace / Tab / Alt+Arrow, delivered here with `render_hook` on the element that
  carries the hook; the palette and the control buttons are clicked.

  A stale write is proven here too: the SAME form submitted with the revision the client saw
  BEFORE an intervening edit is refused (`{:error, :stale}`), the DB keeps the newer text, and the
  conflict banner (not a silent overwrite) is what the user sees (R9). Since P5 a broadcast patches
  every block EXCEPT the one the viewer is typing into (R10 defers it to blur), so the client that
  is genuinely stale is the one whose control is focused — that is the client this test plays, and
  the form API's hidden-value check proves the deferral as a side effect (the revision in the DOM is
  still the old one, and a submit carrying anything else is refused by the harness).
  """

  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  require Ash.Query

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Samen.Web.{Mount, Notes.Reads, Notes.Writes, Plane}
  alias Samen.WebTest.Docs.Doc
  alias Samen.WebTest.SecurityHost

  @endpoint Samen.WebTest.SecurityEndpoint

  @secret "NOTES-VAULTED-EDIT-SENTINEL"

  setup do
    previous = Application.get_env(SecurityHost.otp_app(), :auth_required?)

    # The sanctioned dev/dogfood posture: an unarmed host resolves the `?org=` it is given, which
    # is how every tenant route test drives a page without standing up the full auth spine.
    SecurityHost.disarm!()

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(SecurityHost.otp_app(), :auth_required?)
        value -> Application.put_env(SecurityHost.otp_app(), :auth_required?, value)
      end
    end)

    org_id = Ash.UUID.generate()
    doc = seed_doc!(org_id)

    %{org_id: org_id, doc: doc}
  end

  test "a keyboard-only pass — insert → type → split → indent → move → archive", %{
    org_id: org_id,
    doc: doc
  } do
    {:ok, view, html} = live(build_conn(), "/pages/#{doc.id}?org=#{org_id}")

    assert html =~ ~s(class="app"), "the editor must render inside the shared shell"
    assert html =~ "note-empty"

    # ── insert (the palette, opened by `/` in an empty block; here by its button) ──
    view |> element("#note-empty-add") |> render_click()

    assert has_element?(view, "#note-palette")

    view |> element("#note-palette-bulleted_list_item") |> render_click()

    assert [first] = blocks(org_id, doc.id)
    assert first.type == :bulleted_list_item
    refute has_element?(view, "#note-palette"), "choosing a type closes the palette"

    # ── type (a debounced phx-change; the server echoes exactly what was typed) ──
    view |> form("#note-form-#{first.id}", %{"text" => "Milk"}) |> render_change()

    assert [typed] = blocks(org_id, doc.id)
    assert typed.text == "Milk"
    assert typed.revision > first.revision

    # ── split (Enter at the caret) ──
    render =
      view
      |> element("#note-text-#{typed.id}")
      |> render_hook("split_block", %{"id" => typed.id, "offset" => 2})

    assert [left, right] = blocks(org_id, doc.id)
    assert left.text == "Mi"
    assert right.text == "lk"
    assert right.type == :bulleted_list_item, "a list item's Enter starts the next list item"
    # The server nominates the new block for focus; the hook moves the caret, the server cannot.
    assert render =~ ~s(data-focus-request="#{right.id}")

    # ── indent (Tab; a LIST type only, and the boundary case still flips the type) ──
    view |> element("#note-indent-#{right.id}") |> render_click()

    assert [_, indented] = blocks(org_id, doc.id)
    assert indented.type == :numbered_list_item

    # ── move (Alt+↑) ──
    view |> element("#note-move-up-#{right.id}") |> render_click()

    assert [moved | _] = blocks(org_id, doc.id)
    assert moved.id == right.id

    # ── archive (a block soft delete, never a page delete) ──
    view |> element("#note-archive-#{right.id}") |> render_click()

    assert [survivor] = blocks(org_id, doc.id)
    assert survivor.id == first.id
    # It left the page's ordered list (archivable, so the row is soft-deleted, not destroyed).
    refute Enum.any?(blocks(org_id, doc.id), &(&1.id == right.id))

    # The page itself is untouched: archiving a block is not archiving the page.
    assert {:ok, _page} = Reads.page(tenant_mount(), tenant_scope(org_id), doc.id)
  end

  test "a stale write is REFUSED and the conflict banner is what the user sees", %{
    org_id: org_id,
    doc: doc
  } do
    {:ok, view, _html} = live(build_conn(), "/pages/#{doc.id}?org=#{org_id}")

    view |> element("#note-add-block") |> render_click()
    view |> element("#note-palette-paragraph") |> render_click()

    assert [block] = blocks(org_id, doc.id)

    # This viewer is IN the block — the same state the browser is in mid-sentence.
    view |> element("#note-text-#{block.id}") |> render_focus()

    # A second client commits a newer revision first…
    {:ok, current} =
      Writes.update_text(tenant_mount(), tenant_scope(org_id), block.id, "from another tab",
        revision: block.revision
      )

    assert current.revision > block.revision

    # …and the broadcast is DEFERRED (R10), so this tab's DOM still holds the old revision: the
    # submit below carries what the browser actually has in hand. Dropping the deferral (sabotage
    # 357) patches the control first, and the form API then refuses the stale value outright.
    view
    |> form("#note-form-#{block.id}", %{
      "text" => "typed in a stale tab",
      "block_revision" => to_string(block.revision)
    })
    |> render_change()

    assert has_element?(view, "#note-conflict-#{block.id}")

    assert [unchanged] = blocks(org_id, doc.id)
    assert unchanged.text == "from another tab", "the stale write must NOT overwrite (R9)"

    # The banner's reload affordance clears it, and the current text is what the page shows.
    view |> element("#note-conflict-#{block.id} button", "Load the current text") |> render_click()

    refute has_element?(view, "#note-conflict-#{block.id}")
    assert render(view) =~ "from another tab"
  end

  # The form is the ORDINARY edit path: `phx-change` carries only the block id and the text the
  # textarea holds — no classification hint at all. On a vaulted block that used to mean the write
  # landed in the PLAIN column and cleared `text_secure`, so typing one character declassified 🔒
  # content and the operator plane stopped masking it. The write is now sticky instead: the row
  # keeps its vault, the operator plane still masks the EDITED value, and only a governed action
  # (not a keystroke) could ever move it out.
  test "an ordinary edit of a VAULTED block keeps it vaulted — the UI cannot declassify", %{
    org_id: org_id
  } do
    doc = seed_doc!(org_id)

    {:ok, block} =
      Writes.insert_block(tenant_mount(), tenant_scope(org_id), doc.id, %{
        type: :paragraph,
        text_secure: @secret
      })

    {:ok, view, html} = live(build_conn(), "/pages/#{doc.id}?org=#{org_id}")

    # On the tenant's OWN plane the vaulted text renders clear, so the textarea holds it.
    assert html =~ @secret

    edited = @secret <> " · typed"
    view |> form("#note-form-#{block.id}", %{"text" => edited}) |> render_change()

    assert view |> element("#note-text-#{block.id}") |> render() =~ edited

    # The ROW is still vaulted: the edit rewrote the ciphertext column and left `text` empty.
    assert [row] = blocks(org_id, doc.id)
    assert row.secure?, "an ordinary UI edit must not declassify the block"
    assert_plane_clear!(row.text, edited)

    # And a masked reader of the same page sees the mask of the EDITED value — the proof that
    # nothing landed in the clear column (a declassified block would render in the clear here).
    operator = operator_mount(org_id)
    {:ok, operator_page} = Reads.page(operator, Mount.scope(operator, org_id), doc.id)

    operator_block = hd(operator_page.blocks)
    assert operator_block.secure?
    assert_plane_masked!(operator_block.text, edited)
  end

  test "creating a page from the index lands on its editor", %{org_id: org_id} do
    {:ok, view, _html} = live(build_conn(), "/pages?org=#{org_id}")

    view |> form("#notes-new-page", %{"title" => "Fresh page"}) |> render_submit()

    created = fetch_doc_by_title!(org_id, "Fresh page")

    assert_redirect(view, "/pages/#{created.id}?org=#{org_id}")
  end

  # ── harness ────────────────────────────────────────────────────────────────

  defp tenant_mount do
    Mount.new(:notes, Samen.WebTest.Docs, Samen.WebTest.Repo,
      plane: Plane.tenant(),
      labels: %{pages_path: "/pages"}
    )
  end

  defp tenant_scope(org_id), do: Mount.scope(tenant_mount(), org_id)

  defp operator_mount(org_id) do
    Mount.new(:notes, Samen.WebTest.Docs, Samen.WebTest.Repo,
      plane: Plane.operator("op-1", org_id),
      labels: %{pages_path: "/pages"}
    )
  end

  defp seed_doc!(org_id) do
    Doc
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, title: "Keyboard pass"},
      scope: tenant_scope(org_id)
    )
    |> Ash.create!()
  end

  defp blocks(org_id, doc_id) do
    {:ok, page} = Reads.page(tenant_mount(), tenant_scope(org_id), doc_id)
    page.blocks
  end

  defp fetch_doc_by_title!(org_id, title) do
    Doc
    |> Ash.Query.filter(title == ^title)
    |> Ash.read!(scope: tenant_scope(org_id))
    |> List.first()
    |> case do
      nil -> flunk("no page titled #{inspect(title)} was created")
      doc -> doc
    end
  end
end
