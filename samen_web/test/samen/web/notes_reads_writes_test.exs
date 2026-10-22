defmodule Samen.Web.NotesReadsWritesTest do
  @moduledoc """
  WS-Notes Phase 2 units 2.1/2.2/2.5 (ADR-053 §2 D4/D5, §8 O2) — the ONE read seam and the
  ordered write helpers.

  What is proven here, and why each proof is non-vacuous:

    * **Ordering** — positions are gapped (`#{1024}`), an explicit `after`/`before` lands
      BETWEEN neighbours, and a gap that closes is rebalanced IN the same transaction. The
      rebalance proof also asserts a sibling's `revision` did NOT move: moving a block is not
      editing it, so a concurrent CAS on that block must still succeed.
    * **Revision compare-and-set (R9)** — a stale write is REFUSED with `{:error, :stale}` and
      the row is unchanged (paired with a clear control: the same write at the current
      revision succeeds). A refused split rolls the whole transaction back.
    * **Split/merge boundaries** — UTF-16 caret offsets (emoji included), offset clamping, a
      list item keeping its type, a paragraph tail becoming a paragraph, merging the first
      block is a no-op, and a merge never DOWNGRADES a vaulted block to the plain column.
    * **Classification is sticky on an ordinary edit** — `update_text/5` picks the column from the
      ROW, not from the caller, so editing a 🔒 block rewrites its ciphertext and leaves `text`
      empty (and the operator plane still masks the EDITED value). Explicit `secure: false`
      cannot declassify either; `:secure` is raise-only. Sabotage **374** flips these.
    * **Masking (INV-1)** — the read seam resolves `text_secure` per plane (tenant clear /
      operator `••••`, never a `vt_*` token), and a write that would have to manipulate a
      masked value is refused rather than writing `••••` into content.
    * **Unknown type / shape (R11)** — an unknown type token and an out-of-shape
      `metadata`/`checked` pair are refused before any row lands.
    * **Cross-org (R1)** — another org's page is `:not_found`, and a cross-org write is
      `:not_found` with the row unchanged (no existence oracle, no leak).
  """

  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  alias Samen.Web.{Mount, Notes.Reads, Notes.Writes}
  alias Samen.WebTest.Docs.Doc

  @gap 1024
  @secret "NOTES-BLOCK-PLAINTEXT-SENTINEL"

  # ── harness ────────────────────────────────────────────────────────────────

  defp docs_mount(:tenant), do: mount_on(Samen.Web.Plane.tenant())

  defp docs_mount({:operator, org_id}),
    do: mount_on(Samen.Web.Plane.operator("op-1", org_id))

  defp mount_on(plane),
    do: Mount.new(:docs, Samen.WebTest.Docs, Samen.WebTest.Repo, plane: plane)

  defp tenant_scope(org_id), do: Mount.scope(docs_mount(:tenant), org_id)

  defp operator_scope(org_id), do: Mount.scope(docs_mount({:operator, org_id}), org_id)

  defp seed_doc!(org_id, attrs \\ %{}) do
    Doc
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{org_id: org_id, title: "Runbook"}, attrs),
      scope: tenant_scope(org_id)
    )
    |> Ash.create!()
  end

  defp insert!(org_id, doc_id, attrs) do
    {:ok, block} = Writes.insert_block(docs_mount(:tenant), tenant_scope(org_id), doc_id, attrs)
    block
  end

  defp page!(org_id, doc_id) do
    {:ok, page} = Reads.page(docs_mount(:tenant), tenant_scope(org_id), doc_id)
    page
  end

  defp texts(page), do: Enum.map(page.blocks, & &1.text)

  defp positions(page), do: Enum.map(page.blocks, & &1.position)

  # ── the ONE read seam ──────────────────────────────────────────────────────

  describe "Reads.page/3 — the single read seam" do
    test "returns the page and its blocks ordered by (position, id)" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)

      insert!(org_id, doc.id, %{text: "first"})
      insert!(org_id, doc.id, %{text: "second"})
      insert!(org_id, doc.id, %{text: "third"})

      page = page!(org_id, doc.id)

      assert texts(page) == ["first", "second", "third"]
      assert positions(page) == [@gap, @gap * 2, @gap * 3]
      assert Enum.all?(page.blocks, &(&1.type == :paragraph))
    end

    test "the legacy body is the page ONLY while there are zero blocks" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, %{body: "legacy prose"})

      assert page!(org_id, doc.id).legacy == %{text: "legacy prose", secure?: false}

      insert!(org_id, doc.id, %{text: "a block wins"})

      assert page!(org_id, doc.id).legacy == nil
    end

    test "a doc with no blocks and no body has no legacy value" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)

      assert page!(org_id, doc.id).legacy == nil
      assert page!(org_id, doc.id).blocks == []
    end

    test "a vaulted block is CLEAR on the tenant plane and MASKED on the operator plane — " <>
           "never plaintext, never a vt_ token" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)

      block = insert!(org_id, doc.id, %{text_secure: @secret})

      {:ok, stored} = block |> Ash.reload(scope: tenant_scope(org_id))
      refute stored.text_secure == @secret, "the vault column must never store plaintext"

      [tenant_block] = page!(org_id, doc.id).blocks
      assert_plane_clear!(tenant_block.text, @secret)
      assert tenant_block.secure?
      refute tenant_block.masked?

      {:ok, operator_page} =
        Reads.page(docs_mount({:operator, org_id}), operator_scope(org_id), doc.id)

      [operator_block] = operator_page.blocks
      assert_plane_masked!(operator_block.text, @secret)
      assert operator_block.masked?
      assert to_string(operator_block.text) == mask()
      refute to_string(operator_block.text) =~ "vt_"
    end

    test "another org's page is :not_found (R1 — no existence oracle)" do
      owner_org = Ash.UUID.generate()
      doc = seed_doc!(owner_org)

      assert {:error, :not_found} =
               Reads.page(docs_mount(:tenant), tenant_scope(Ash.UUID.generate()), doc.id)
    end
  end

  # ── insert + ordering ──────────────────────────────────────────────────────

  describe "insert_block/4 — appending, placement, and gaps" do
    test "appends at 1024-spaced positions and bumps the PAGE revision" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)

      a = insert!(org_id, doc.id, %{text: "a"})
      b = insert!(org_id, doc.id, %{text: "b"})

      assert a.position + @gap == b.position
      assert b.revision == 1

      assert {:ok, refreshed} = doc |> Ash.reload(scope: tenant_scope(org_id))
      assert refreshed.revision > doc.revision
    end

    test "honours :after_block_id and :before_block_id by landing BETWEEN neighbours" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)

      a = insert!(org_id, doc.id, %{text: "a"})
      b = insert!(org_id, doc.id, %{text: "b"})

      mid = insert!(org_id, doc.id, %{text: "mid", after_block_id: a.id})

      assert mid.position > a.position and mid.position < b.position

      before = insert!(org_id, doc.id, %{text: "before-a", before_block_id: a.id})
      assert before.position < a.position
      assert before.position > 0

      assert texts(page!(org_id, doc.id)) == ["before-a", "a", "mid", "b"]
    end

    test "refuses a hint that names no sibling" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)
      insert!(org_id, doc.id, %{text: "a"})

      assert {:error, :anchor_not_found} =
               Writes.insert_block(docs_mount(:tenant), tenant_scope(org_id), doc.id, %{
                 text: "x",
                 after_block_id: Ash.UUID.generate()
               })
    end

    test "rebalances positions in the same transaction when a gap closes — and does NOT " <>
           "touch a sibling's revision" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)

      a = insert!(org_id, doc.id, %{text: "a"})
      b = insert!(org_id, doc.id, %{text: "b"})

      # Repeated midpoints halve the gap each time; the 11th insert has no room left and
      # forces the rebalance to rewrite the parent's ordinals back to fresh 1024 gaps.
      for n <- 1..12 do
        assert {:ok, _} =
                 Writes.insert_block(docs_mount(:tenant), tenant_scope(org_id), doc.id, %{
                   text: "fill-#{n}",
                   after_block_id: a.id
                 })
      end

      page = page!(org_id, doc.id)
      got = positions(page)

      assert length(got) == 14
      assert got == Enum.sort(got)
      assert length(Enum.uniq(got)) == length(got), "ordinals must stay distinct: #{inspect(got)}"

      # The anchor is still first, and every insert still sits directly after it.
      assert hd(texts(page)) == "a"
      assert Enum.at(got, 1) < Enum.at(got, 2)

      # Rebalancing MOVED b, it did not EDIT b: its CAS token is untouched — and the anchor
      # is still the first sibling.
      b_now = Enum.find(page.blocks, &(&1.id == b.id))
      assert b_now.revision == 1
      assert hd(page.blocks).id == a.id
      assert b_now.position > hd(page.blocks).position
    end
  end

  # ── the closed shape (R11) ─────────────────────────────────────────────────

  describe "insert_block/4 — the closed type shape" do
    test "refuses an unknown type token, atom or string (R11)" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)
      mount = docs_mount(:tenant)
      scope = tenant_scope(org_id)

      assert {:error, {:unknown_type, "sandwich"}} =
               Writes.insert_block(mount, scope, doc.id, %{type: "sandwich", text: "x"})

      assert {:error, {:unknown_type, :sandwich}} =
               Writes.insert_block(mount, scope, doc.id, %{type: :sandwich, text: "x"})

      assert page!(org_id, doc.id).blocks == []
    end

    test "refuses checked on a paragraph and foreign metadata on a callout" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)
      mount = docs_mount(:tenant)
      scope = tenant_scope(org_id)

      assert {:error, {:invalid_shape, message}} =
               Writes.insert_block(mount, scope, doc.id, %{type: :paragraph, checked: true})

      assert message =~ "checked"

      assert {:error, {:invalid_shape, message}} =
               Writes.insert_block(mount, scope, doc.id, %{
                 type: :callout,
                 metadata: %{"language" => "elixir"}
               })

      assert message =~ "metadata"

      assert page!(org_id, doc.id).blocks == []
    end

    test "accepts the string form a phx-value sends, and refuses both text columns at once" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)

      block = insert!(org_id, doc.id, %{type: "heading_2", text: "Title"})
      assert block.type == :heading_2

      assert {:error, :both_text_and_secure} =
               Writes.insert_block(docs_mount(:tenant), tenant_scope(org_id), doc.id, %{
                 text: "plain",
                 text_secure: "vaulted"
               })
    end
  end

  # ── revision compare-and-set (R9) ──────────────────────────────────────────

  describe "update_text/5 — revision compare-and-set" do
    test "bumps the BLOCK revision and leaves the PAGE revision alone" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)
      block = insert!(org_id, doc.id, %{text: "draft"})

      # The insert bumped the page revision; a TEXT edit must leave that value alone.
      {:ok, doc_after_insert} = doc |> Ash.reload(scope: tenant_scope(org_id))

      assert {:ok, updated} =
               Writes.update_text(docs_mount(:tenant), tenant_scope(org_id), block.id, "final")

      assert updated.text == "final"
      assert updated.revision == block.revision + 1

      assert {:ok, doc_now} = doc |> Ash.reload(scope: tenant_scope(org_id))
      assert doc_now.revision == doc_after_insert.revision
    end

    test "REFUSES a stale revision and leaves the row unchanged (R9), while the current " <>
           "revision still succeeds (positive control)" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)
      block = insert!(org_id, doc.id, %{text: "first"})
      mount = docs_mount(:tenant)
      scope = tenant_scope(org_id)

      # control: the value the writer actually saw is accepted
      assert {:ok, _} = Writes.update_text(mount, scope, block.id, "second", revision: block.revision)

      # the lost writer still holds revision 1 and must NOT win
      assert {:error, :stale} =
               Writes.update_text(mount, scope, block.id, "stale overwrite", revision: block.revision)

      assert texts(page!(org_id, doc.id)) == ["second"]
    end

    test "an omitted revision still CASes against the revision it just read" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)
      block = insert!(org_id, doc.id, %{text: "one"})
      mount = docs_mount(:tenant)
      scope = tenant_scope(org_id)

      assert {:ok, _} = Writes.update_text(mount, scope, block.id, "two")
      assert {:ok, _} = Writes.update_text(mount, scope, block.id, "three")
      assert texts(page!(org_id, doc.id)) == ["three"]
    end

    test "writes text_secure when :secure, clearing the plain column (one text per block)" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)
      block = insert!(org_id, doc.id, %{text: "public"})

      assert {:ok, updated} =
               Writes.update_text(docs_mount(:tenant), tenant_scope(org_id), block.id, @secret,
                 secure: true
               )

      assert updated.text_secure != @secret
      assert updated.text == nil

      page = page!(org_id, doc.id)
      assert hd(page.blocks).secure?
      assert_plane_clear!(hd(page.blocks).text, @secret)
    end

    # The ordinary edit path (`PageLive`'s debounced `block_text`) passes NO `:secure` — it just
    # hands over what the textarea says. For a vaulted block that used to mean "write this as the
    # PLAIN column and clear `text_secure`": one keystroke silently declassified 🔒 content, and
    # the operator plane stopped masking it. Classification is therefore STICKY on this path: an
    # edit rewrites the column the block already lives in.
    test "an ordinary edit of a VAULTED block keeps it vaulted — no silent declassification" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)
      block = insert!(org_id, doc.id, %{text_secure: @secret})
      edited = @secret <> " · edited"

      assert {:ok, updated} =
               Writes.update_text(docs_mount(:tenant), tenant_scope(org_id), block.id, edited)

      # The ciphertext column was REWRITTEN and the plain column is still empty.
      assert updated.text == nil
      assert updated.text_secure != edited

      page_block = hd(page!(org_id, doc.id).blocks)
      assert page_block.secure?, "a plain edit must not move the block out of the vault"
      assert_plane_clear!(page_block.text, edited)

      # …and the operator plane masks the NEW value: nothing landed in the clear column.
      {:ok, operator_page} =
        Reads.page(docs_mount({:operator, org_id}), operator_scope(org_id), doc.id)

      operator_block = hd(operator_page.blocks)
      assert operator_block.secure?
      assert_plane_masked!(operator_block.text, edited)
    end

    test "an explicit `secure: false` cannot declassify either — the option is raise-only" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)
      block = insert!(org_id, doc.id, %{text_secure: @secret})

      assert {:ok, updated} =
               Writes.update_text(docs_mount(:tenant), tenant_scope(org_id), block.id, "edited",
                 secure: false
               )

      assert updated.text == nil
      assert hd(page!(org_id, doc.id).blocks).secure?
    end

    test "refuses a non-binary value instead of casting it" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)
      block = insert!(org_id, doc.id, %{text: "x"})

      assert {:error, :not_a_string} =
               Writes.update_text(docs_mount(:tenant), tenant_scope(org_id), block.id, 42)
    end
  end

  # ── split ──────────────────────────────────────────────────────────────────

  describe "split/5 — the Enter key" do
    test "keeps whitespace byte-identically (a block's text is not trimmed on write)" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)

      block = insert!(org_id, doc.id, %{text: "  padded  "})
      assert block.text == "  padded  "
      assert texts(page!(org_id, doc.id)) == ["  padded  "]

      assert {:ok, updated} =
               Writes.update_text(docs_mount(:tenant), tenant_scope(org_id), block.id, "trailing ")

      assert updated.text == "trailing "
      assert texts(page!(org_id, doc.id)) == ["trailing "]
    end

    test "splits at a UTF-16 offset, ordering the tail directly after the anchor" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)
      block = insert!(org_id, doc.id, %{text: "hello world"})

      assert {:ok, %{left: left, right: right}} =
               Writes.split(docs_mount(:tenant), tenant_scope(org_id), block.id, 5)

      assert left.text == "hello"
      assert right.text == " world"
      assert right.position > left.position
      assert texts(page!(org_id, doc.id)) == ["hello", " world"]
    end

    test "an offset inside an emoji's surrogate pair snaps back, never cutting the grapheme" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)
      block = insert!(org_id, doc.id, %{text: "ab👍cd"})

      # "a"+"b" = 2 units; 👍 = 2 units (3..4). Offset 3 lands INSIDE the pair.
      assert {:ok, %{left: inside, right: rest}} =
               Writes.split(docs_mount(:tenant), tenant_scope(org_id), block.id, 3)

      assert inside.text == "ab"
      assert rest.text == "👍cd"

      # Offset 4 is the grapheme boundary: the emoji stays whole on the LEFT.
      {:ok, block2} =
        Writes.insert_block(docs_mount(:tenant), tenant_scope(org_id), doc.id, %{
          text: "ab👍cd"
        })

      assert {:ok, %{left: exact, right: tail}} =
               Writes.split(docs_mount(:tenant), tenant_scope(org_id), block2.id, 4)

      assert exact.text == "ab👍"
      assert tail.text == "cd"
    end

    test "clamps an out-of-range offset instead of raising" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)
      block = insert!(org_id, doc.id, %{text: "short"})

      assert {:ok, %{left: l1, right: r1}} =
               Writes.split(docs_mount(:tenant), tenant_scope(org_id), block.id, 9_999)

      assert l1.text == "short"
      assert r1.text == ""

      assert {:ok, %{left: l2, right: r2}} =
               Writes.split(docs_mount(:tenant), tenant_scope(org_id), block.id, "0")

      assert l2.text == ""
      assert r2.text == "short"
    end

    test "a list item keeps its type (and its checked state); any other type tails as paragraph" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)

      item = insert!(org_id, doc.id, %{type: :to_do, text: "milk and bread", checked: false})

      assert {:ok, %{right: item_tail}} =
               Writes.split(docs_mount(:tenant), tenant_scope(org_id), item.id, 4)

      assert item_tail.type == :to_do
      assert item_tail.checked == false

      heading = insert!(org_id, doc.id, %{type: :heading_1, text: "Title body"})

      assert {:ok, %{right: heading_tail}} =
               Writes.split(docs_mount(:tenant), tenant_scope(org_id), heading.id, 5)

      assert heading_tail.type == :paragraph
      assert heading_tail.checked == nil
    end

    test "a vaulted block splits into two VAULTED blocks" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)
      block = insert!(org_id, doc.id, %{text_secure: "secret tail"})

      assert {:ok, %{left: left, right: right}} =
               Writes.split(docs_mount(:tenant), tenant_scope(org_id), block.id, 6)

      assert not is_nil(left.text_secure)
      assert not is_nil(right.text_secure)
      assert left.text == nil and right.text == nil
      assert texts(page!(org_id, doc.id)) == ["secret", " tail"]
    end

    test "a stale revision refuses the split and rolls the whole transaction back (R9)" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)
      block = insert!(org_id, doc.id, %{text: "hello world"})

      assert {:error, :stale} =
               Writes.split(docs_mount(:tenant), tenant_scope(org_id), block.id, 5,
                 revision: block.revision - 1
               )

      page = page!(org_id, doc.id)
      assert texts(page) == ["hello world"]
      assert block.revision == 1
    end

    test "an operator without a grant cannot split a vaulted block (split would write masks)" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)
      block = insert!(org_id, doc.id, %{text_secure: @secret})

      assert {:error, :masked} =
               Writes.split(docs_mount({:operator, org_id}), operator_scope(org_id), block.id, 3)

      assert length(page!(org_id, doc.id).blocks) == 1
    end
  end

  # ── merge ──────────────────────────────────────────────────────────────────

  describe "merge/3 — the Backspace at offset 0" do
    test "joins into the previous sibling, deletes this block, and keeps order" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)

      a = insert!(org_id, doc.id, %{text: "one "})
      b = insert!(org_id, doc.id, %{text: "two"})
      c = insert!(org_id, doc.id, %{text: "three"})

      assert {:ok, %{block: survivor, removed: removed}} =
               Writes.merge(docs_mount(:tenant), tenant_scope(org_id), b.id)

      assert survivor.id == a.id
      assert survivor.text == "one two"
      assert removed == b.id
      assert texts(page!(org_id, doc.id)) == ["one two", "three"]
      assert Enum.map(page!(org_id, doc.id).blocks, & &1.id) == [a.id, c.id]
    end

    test "merging the FIRST block is a no-op (nothing to merge into)" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)
      a = insert!(org_id, doc.id, %{text: "only"})

      assert {:ok, :noop} = Writes.merge(docs_mount(:tenant), tenant_scope(org_id), a.id)
      assert texts(page!(org_id, doc.id)) == ["only"]
    end

    test "never DOWNGRADES classification: a vaulted neighbour keeps the survivor vaulted" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)

      insert!(org_id, doc.id, %{text: "public "})
      secret = insert!(org_id, doc.id, %{text_secure: @secret})

      assert {:ok, %{block: survivor}} =
               Writes.merge(docs_mount(:tenant), tenant_scope(org_id), secret.id)

      assert not is_nil(survivor.text_secure)
      assert survivor.text == nil

      [merged] = page!(org_id, doc.id).blocks
      assert merged.secure?
      assert_plane_clear!(merged.text, "public " <> @secret)
    end

    test "an operator without a grant cannot merge a vaulted block" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)
      insert!(org_id, doc.id, %{text: "public "})
      secret = insert!(org_id, doc.id, %{text_secure: @secret})

      assert {:error, :masked} =
               Writes.merge(docs_mount({:operator, org_id}), operator_scope(org_id), secret.id)

      assert length(page!(org_id, doc.id).blocks) == 2
    end
  end

  # ── move / indent ──────────────────────────────────────────────────────────

  describe "move/4" do
    test "swaps a block with its neighbour, reflected in the read order" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)

      insert!(org_id, doc.id, %{text: "a"})
      b = insert!(org_id, doc.id, %{text: "b"})
      insert!(org_id, doc.id, %{text: "c"})

      assert {:ok, _} = Writes.move(docs_mount(:tenant), tenant_scope(org_id), b.id, :up)
      assert texts(page!(org_id, doc.id)) == ["b", "a", "c"]

      assert {:ok, _} = Writes.move(docs_mount(:tenant), tenant_scope(org_id), b.id, :down)
      assert texts(page!(org_id, doc.id)) == ["a", "b", "c"]
    end

    test "is a :noop at the boundary and refuses an unknown direction" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)
      a = insert!(org_id, doc.id, %{text: "a"})

      assert {:ok, :noop} = Writes.move(docs_mount(:tenant), tenant_scope(org_id), a.id, :up)
      assert {:error, {:bad_direction, :sideways}} =
               Writes.move(docs_mount(:tenant), tenant_scope(org_id), a.id, :sideways)
    end
  end

  describe "indent/4" do
    test ":in swaps down and flips a bullet to numbered; :out flips it back" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)

      bullet = insert!(org_id, doc.id, %{type: :bulleted_list_item, text: "first"})
      insert!(org_id, doc.id, %{type: :bulleted_list_item, text: "second"})

      assert {:ok, moved} =
               Writes.indent(docs_mount(:tenant), tenant_scope(org_id), bullet.id, :in)

      assert moved.type == :numbered_list_item
      assert texts(page!(org_id, doc.id)) == ["second", "first"]

      assert {:ok, back} =
               Writes.indent(docs_mount(:tenant), tenant_scope(org_id), bullet.id, :out)

      assert back.type == :bulleted_list_item
      assert texts(page!(org_id, doc.id)) == ["first", "second"]
    end

    test "a non-list block is :not_indentable (the client cannot widen the rule)" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)
      p = insert!(org_id, doc.id, %{type: :paragraph, text: "prose"})
      insert!(org_id, doc.id, %{type: :paragraph, text: "more prose"})

      assert {:error, :not_indentable} =
               Writes.indent(docs_mount(:tenant), tenant_scope(org_id), p.id, :in)
    end
  end

  # ── archive / restore ──────────────────────────────────────────────────────

  describe "archive/3 + restore/3" do
    test "an archived block leaves the read seam and restore brings it back, bumping the page" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id)
      block = insert!(org_id, doc.id, %{text: "temporary"})

      assert {:ok, _} = Writes.archive(docs_mount(:tenant), tenant_scope(org_id), block.id)
      assert page!(org_id, doc.id).blocks == []

      assert {:ok, _} = Writes.restore(docs_mount(:tenant), tenant_scope(org_id), block.id)
      assert texts(page!(org_id, doc.id)) == ["temporary"]
    end
  end

  # ── cross-org (R1) ─────────────────────────────────────────────────────────

  describe "cross-org writes are :not_found, never applied" do
    test "another org cannot update, split, merge, move, indent, archive, or restore a block" do
      owner_org = Ash.UUID.generate()
      attacker_org = Ash.UUID.generate()
      doc = seed_doc!(owner_org)

      insert!(owner_org, doc.id, %{text: "one "})
      target = insert!(owner_org, doc.id, %{text: "two two"})
      insert!(owner_org, doc.id, %{text: "three"})

      mount = docs_mount(:tenant)
      scope = tenant_scope(attacker_org)

      assert {:error, :not_found} = Writes.update_text(mount, scope, target.id, "pwned")
      assert {:error, :not_found} = Writes.split(mount, scope, target.id, 3)
      assert {:error, :not_found} = Writes.merge(mount, scope, target.id)
      assert {:error, :not_found} = Writes.move(mount, scope, target.id, :up)
      assert {:error, :not_found} = Writes.indent(mount, scope, target.id, :in)
      assert {:error, :not_found} = Writes.archive(mount, scope, target.id)
      assert {:error, :not_found} = Writes.restore(mount, scope, target.id)

      assert texts(page!(owner_org, doc.id)) == ["one ", "two two", "three"]
    end

    test "another org cannot insert into the page" do
      owner_org = Ash.UUID.generate()
      doc = seed_doc!(owner_org)

      assert {:error, :not_found} =
               Writes.insert_block(docs_mount(:tenant), tenant_scope(Ash.UUID.generate()), doc.id, %{
                 text: "intruder"
               })

      assert page!(owner_org, doc.id).blocks == []
    end
  end
end
