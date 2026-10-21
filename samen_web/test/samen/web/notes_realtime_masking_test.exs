defmodule Samen.Web.NotesRealtimeMaskingTest do
  @moduledoc """
  WS-Notes Phase 5 GATE — the id-only realtime envelope, the `editing_block_id` re-read skip, and
  the three-plane masking proofs (ADR-053 §2 D4/D5, §6 R5/R8/R10; ADR-038 §5.5).

  What is proven here, and why each proof is non-vacuous:

    * **a broadcast never patches the focused control (R10)** — two REAL sockets on the same page
      through the real router: socket B writes, and socket A (which has the block's `<textarea>`
      focused) keeps its own value while B sees the new one. Blurring A applies the deferred change
      (the skip is a deferral, never a drop). Sabotage **357** removes the skip, and A's value
      changes under the user, so the assertion fails.
    * **the envelope is id-only (R8)** — the broadcast a subscriber receives has exactly
      `[:block_id, :revision]` (`[:doc_id, :revision]` for a structure change), and a byte scan of
      the serialized envelope finds neither the block's plaintext nor a `vt_*` vault token. The
      struct handed to the builder DOES carry a token for a vaulted block, so "send the text to
      save a re-read" is a one-line mistake — sabotage **358** — that this test catches.
    * **the re-read happens on the RECEIVING plane (R8's other half)** — two REAL sockets through
      the REAL router on the same page (a tenant tab and an operator tab, the latter on the
      framework's documented `plane: :operator` mount): one broadcast, and each tab re-reads the
      id itself, so the operator tab shows the mask of what the tenant tab shows in the clear.
      Covered for BOTH paths — the block envelope (`refresh_block/2`) and the structure envelope
      (`reload/2`) — because they re-read through different calls. Sabotage **373** makes both
      re-read on the writer's plane and these two tests are what flip (the envelope tests stay
      green, which is the point: a clean wire is not enough if the subscriber resolves wrongly).
    * **masking (INV-1) at the resolver** — the SAME `DocBlock` row resolves CLEAR on the tenant
      plane, CLEAR for an operator WITH a grant, and `••••` for an operator WITHOUT one
      (`assert_plane_clear!` / `assert_plane_masked!` / `assert_two_plane!`).
    * **masking at the shipped DOM** — the real editor page renders the plaintext on the tenant
      plane and `assert_masked_dom!`-clean on the operator plane (mask present, plaintext absent,
      no `vt_*`), with the tenant/operator pair differing ONLY by plane.
    * **the sabotage twin (anti-tautology)** — a modeled leaked render IS detected by the same
      scan that the masked render passes (`assert_leak_detected!`), so the red assertion is
      refutable rather than vacuous.

  The export half of 5.3's byte scan landed with unit 2.4: `notes_export_masking_test.exs` proves
  the downloads and the clipboard resolve through the same seam, and sabotages **364**/**372** are
  its twins. This file is the realtime half.
  """

  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  require Ash.Query

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Samen.Web.{Mount, Notes.PageLive, Notes.PubSub, Notes.Reads, Notes.Writes, Plane}
  alias Samen.WebTest.Docs.{Doc, DocBlock}
  alias Samen.WebTest.SecurityHost

  @endpoint Samen.WebTest.SecurityEndpoint

  # The same server the test router's notes mount names on its `:pubsub` label (test_helper starts
  # it once for the VM) — so a broadcast here is the REAL delivery path, not a stub.
  @pubsub Samen.WebTest.PubSub

  @secret "NOTES-REALTIME-PLAINTEXT-SENTINEL"
  @rotated "NOTES-REALTIME-ROTATED-SENTINEL"

  defmodule AllowAllGrant do
    @moduledoc false
    def granted?(_ctx), do: true
  end

  defmodule DenyAllGrant do
    @moduledoc false
    def granted?(_ctx), do: false
  end

  setup do
    previous = Application.get_env(SecurityHost.otp_app(), :auth_required?)

    # The sanctioned dev/dogfood posture: an unarmed host resolves the `?org=` it is given, which
    # is how a tenant route test drives a page without standing up the full auth spine.
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

  # ── harness ────────────────────────────────────────────────────────────────

  defp notes_mount(plane \\ Plane.tenant()) do
    Mount.new(:notes, Samen.WebTest.Docs, Samen.WebTest.Repo,
      plane: plane,
      labels: %{pages_path: "/pages", pubsub: @pubsub}
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

  # An Ash READ (so the vault column is `%Samen.Masked{}` at rest, the shape the resolver sees on
  # every real surface) rather than the struct a write hands back.
  defp reload_block(org_id, block_id) do
    DocBlock
    |> Ash.Query.filter(id == ^block_id)
    |> Ash.Query.ensure_selected([:id, :text, :text_secure, :revision])
    |> Ash.read_one!(scope: scope_for(org_id))
  end

  defp page_text(org_id, doc_id) do
    {:ok, page} = Reads.page(notes_mount(), scope_for(org_id), doc_id)
    Enum.map_join(page.blocks, " | ", &to_string(&1.text))
  end

  # A broadcast is delivered asynchronously, so a socket can still be holding one when the test
  # body ends — and its re-read would then race the sandbox check-in (the owner exits while the
  # LiveView is mid-query, which disconnects the shared Postgrex protocol and poisons a NEIGHBOUR
  # test's connection). `render/1` is a synchronous call, so it drains every queued `handle_info`
  # first; calling it is a test-hygiene requirement here, not an assertion.
  defp drain(views), do: Enum.each(List.wrap(views), fn view -> _ = render(view) end)

  # ── R10 — the editing-block re-read skip (sabotage 357) ─────────────────────

  test "a broadcast never patches the focused block; blur applies it (R10)", %{
    org_id: org_id,
    doc: doc
  } do
    first = insert!(org_id, doc.id, %{type: :paragraph, text: "ORIGINAL"})

    # Two REAL sockets on the SAME page (two browser tabs). Both subscribe on connect.
    {:ok, a, html_a} = live(build_conn(), "/pages/#{doc.id}?org=#{org_id}")
    {:ok, b, _html_b} = live(build_conn(), "/pages/#{doc.id}?org=#{org_id}")

    assert html_a =~ "ORIGINAL"

    # A focuses the block (a real `phx-focus`, the event the browser sends when the caret lands).
    a |> element("#note-text-#{first.id}") |> render_focus()

    # B types. Its debounced change persists AND broadcasts the id-only envelope.
    b |> form("#note-form-#{first.id}", %{"text" => "REMOTE EDIT"}) |> render_change()

    # The write really landed, and the writer's own view shows it…
    assert page_text(org_id, doc.id) =~ "REMOTE EDIT"
    assert b |> element("#note-text-#{first.id}") |> render() =~ "REMOTE EDIT"

    # …but the FOCUSED control is untouched: the value the browser owns is never patched.
    assert a |> element("#note-text-#{first.id}") |> render() =~ "ORIGINAL"
    refute a |> element("#note-text-#{first.id}") |> render() =~ "REMOTE EDIT"

    # Blurring is when the deferral is applied — the skip is not a drop.
    a |> element("#note-text-#{first.id}") |> render_blur()

    assert a |> element("#note-text-#{first.id}") |> render() =~ "REMOTE EDIT"

    drain([a, b])
  end

  test "a non-focused block IS re-read from the broadcast (the skip is targeted, not a blanket)", %{
    org_id: org_id,
    doc: doc
  } do
    first = insert!(org_id, doc.id, %{type: :paragraph, text: "FIRST"})
    second = insert!(org_id, doc.id, %{type: :paragraph, text: "SECOND"})

    {:ok, a, _html} = live(build_conn(), "/pages/#{doc.id}?org=#{org_id}")
    {:ok, b, _html} = live(build_conn(), "/pages/#{doc.id}?org=#{org_id}")

    # A focuses block ONE; B edits block TWO.
    a |> element("#note-text-#{first.id}") |> render_focus()
    b |> form("#note-form-#{second.id}", %{"text" => "SECOND EDITED"}) |> render_change()

    # The untouched-by-focus block updates on A — proving the handler does run the re-read and
    # the guard above is the only thing stopping it.
    assert a |> element("#note-text-#{second.id}") |> render() =~ "SECOND EDITED"
    assert a |> element("#note-text-#{first.id}") |> render() =~ "FIRST"

    drain([a, b])
  end

  # ── R8 — the id-only envelope (sabotage 358) ───────────────────────────────

  test "the block envelope is id-only: no text, no vt_ token, a closed key set (R8)", %{
    org_id: org_id,
    doc: doc
  } do
    block = insert!(org_id, doc.id, %{type: :paragraph, text_secure: @secret})
    reloaded = reload_block(org_id, block.id)

    assert match?(%Samen.Masked{}, reloaded.text_secure),
           "the at-rest vault column must be %Masked{} (no plaintext on a read struct)"

    Phoenix.PubSub.subscribe(@pubsub, PubSub.topic(doc.id))

    assert :ok = PubSub.broadcast_block_changed(notes_mount(), doc.id, reloaded)

    assert_receive {:block_changed, payload}, 2_000

    assert payload.block_id == block.id
    assert payload.revision == reloaded.revision

    # The CLOSED envelope contract: an added :text/:text_secure key is a failing test, not a
    # silent leak. This is what sabotage 358 trips.
    assert Map.keys(payload) |> Enum.sort() == [:block_id, :revision]

    bytes = :erlang.term_to_binary(payload)
    refute bytes =~ @secret, "the block's plaintext must never transit PubSub"
    refute bytes =~ "vt_", "a vault token must never transit PubSub"

    # Non-vacuity: the scan IS refutable — an envelope that carried the value would be caught.
    leaky = inspect(%{block_id: block.id, revision: reloaded.revision, text: @secret})
    assert_leak_detected!(leaky, @secret)
  end

  test "the structure envelope names the page and its revision only (R8)", %{
    org_id: org_id,
    doc: doc
  } do
    _block = insert!(org_id, doc.id, %{type: :paragraph, text: "x"})

    Phoenix.PubSub.subscribe(@pubsub, PubSub.topic(doc.id))

    assert :ok = PubSub.broadcast_page_structure_changed(notes_mount(), doc.id, doc.id, 7)

    assert_receive {:page_structure_changed, payload}, 2_000

    assert payload.doc_id == doc.id
    assert payload.revision == 7
    assert Map.keys(payload) |> Enum.sort() == [:doc_id, :revision]
    refute :erlang.term_to_binary(payload) =~ "vt_"
  end

  test "a page edit broadcasts an id-only block envelope on the page topic", %{
    org_id: org_id,
    doc: doc
  } do
    first = insert!(org_id, doc.id, %{type: :paragraph, text: "BEFORE"})

    Phoenix.PubSub.subscribe(@pubsub, PubSub.topic(doc.id))

    {:ok, view, _html} = live(build_conn(), "/pages/#{doc.id}?org=#{org_id}")

    view |> form("#note-form-#{first.id}", %{"text" => "AFTER"}) |> render_change()

    assert_receive {:block_changed, payload}, 2_000
    assert payload.block_id == first.id
    assert payload.revision > first.revision
    assert Map.keys(payload) |> Enum.sort() == [:block_id, :revision]
    refute :erlang.term_to_binary(payload) =~ "AFTER"

    drain(view)
  end

  test "a structure write broadcasts a structure envelope for the page", %{
    org_id: org_id,
    doc: doc
  } do
    first = insert!(org_id, doc.id, %{type: :paragraph, text: "alpha beta"})

    Phoenix.PubSub.subscribe(@pubsub, PubSub.topic(doc.id))

    {:ok, view, _html} = live(build_conn(), "/pages/#{doc.id}?org=#{org_id}")

    view |> element("#note-text-#{first.id}") |> render_hook("split_block", %{"id" => first.id, "offset" => 5})

    # Two block envelopes (the anchor and the new tail) and one page-structure envelope.
    anchor_id = first.id
    assert_receive {:block_changed, %{block_id: ^anchor_id}}, 2_000
    assert_receive {:block_changed, %{block_id: other_id}}, 2_000
    assert other_id != first.id

    assert_receive {:page_structure_changed, payload}, 2_000
    assert payload.doc_id == doc.id
    assert payload.revision >= 1

    drain(view)
  end

  # ── R8's other half: WHO re-reads, and on WHICH plane (real sockets) ──────

  # The envelope tests above prove the WIRE carries ids. These two prove the consequence the
  # envelope relies on: every subscriber re-reads the id itself, on ITS plane. Both run two REAL
  # sockets through the REAL router on the SAME page — a tenant tab and an operator tab (the
  # `/op-pages` mount) — so "per-plane" is a fact about two live LiveView processes, not about a
  # scope built in a helper.

  test "a broadcast is re-read per SUBSCRIBER: the operator tab masks what the tenant tab shows", %{
    org_id: org_id,
    doc: doc
  } do
    block = insert!(org_id, doc.id, %{type: :paragraph, text_secure: @secret})

    {:ok, tenant_view, tenant_html} = live(build_conn(), "/pages/#{doc.id}?org=#{org_id}")
    {:ok, operator_view, operator_html} = live(build_conn(), "/op-pages/#{doc.id}?org=#{org_id}")

    # Both tabs start from the SAME row, resolved on their own plane.
    assert tenant_html =~ @secret
    assert_masked_dom!(operator_html, [@secret])

    Phoenix.PubSub.subscribe(@pubsub, PubSub.topic(doc.id))

    # A write from ANOTHER process (another tab, or a job) on the tenant plane, through the
    # governed write path: the block stays vaulted and the returned struct carries the NEW
    # plaintext — exactly the shape a "send the value along" envelope would leak.
    {:ok, updated} =
      Writes.update_text(notes_mount(), scope_for(org_id), block.id, @rotated, secure: true)

    assert :ok = PubSub.broadcast_block_changed(notes_mount(), doc.id, updated)

    assert_receive {:block_changed, payload}, 2_000
    assert payload.block_id == block.id
    assert Map.keys(payload) |> Enum.sort() == [:block_id, :revision]

    bytes = :erlang.term_to_binary(payload)
    refute bytes =~ @rotated, "the rotated plaintext must never transit PubSub"
    refute bytes =~ "vt_", "a vault token must never transit PubSub"

    # Both tabs received the SAME envelope, and each re-read the id on ITS plane: the tenant tab
    # shows the new value, the operator tab the mask of it — never either plaintext.
    assert render(tenant_view) =~ @rotated

    operator_after = render(operator_view)
    assert operator_after =~ mask()
    refute operator_after =~ @rotated
    refute operator_after =~ @secret
    refute operator_after =~ "vt_"

    drain([tenant_view, operator_view])
  end

  test "a structure change reloads each tab through ITS own plane — masked on the operator tab", %{
    org_id: org_id,
    doc: doc
  } do
    plain = insert!(org_id, doc.id, %{type: :paragraph, text: "alpha beta"})
    _vaulted = insert!(org_id, doc.id, %{type: :paragraph, text_secure: @secret})

    {:ok, tenant_view, _html} = live(build_conn(), "/pages/#{doc.id}?org=#{org_id}")
    {:ok, operator_view, operator_html} = live(build_conn(), "/op-pages/#{doc.id}?org=#{org_id}")

    assert_masked_dom!(operator_html, [@secret])

    Phoenix.PubSub.subscribe(@pubsub, PubSub.topic(doc.id))

    # The tenant tab splits a block: two id-only block envelopes + one structure envelope.
    tenant_view
    |> element("#note-text-#{plain.id}")
    |> render_hook("split_block", %{"id" => plain.id, "offset" => 5})

    assert_receive {:block_changed, _}, 2_000
    assert_receive {:page_structure_changed, payload}, 2_000
    assert payload.doc_id == doc.id
    assert Map.keys(payload) |> Enum.sort() == [:doc_id, :revision]
    refute :erlang.term_to_binary(payload) =~ @secret

    # The operator tab RELOADS the page on the structure envelope, and that reload is a read on
    # the OPERATOR plane: the split is visible, and the vaulted block is still the mask.
    operator_after = render(operator_view)
    assert operator_after =~ "alpha"
    assert operator_after =~ "beta"
    assert operator_after =~ mask()
    refute operator_after =~ @secret
    refute operator_after =~ "vt_"

    assert render(tenant_view) =~ @secret

    drain([tenant_view, operator_view])
  end

  # ── the three masking proofs on the SAME vaulted block (INV-1) ─────────────

  describe "the masking trio (ADR-038 §5.5)" do
    test "GREEN: tenant AND operator-with-grant resolve the block's text_secure clear", %{
      org_id: org_id,
      doc: doc
    } do
      block = insert!(org_id, doc.id, %{type: :paragraph, text_secure: @secret})
      reloaded = reload_block(org_id, block.id)

      tenant = resolve_on_plane(reloaded, DocBlock, :tenant, repo: Samen.WebTest.Repo)
      assert_plane_clear!(tenant.text_secure, @secret)

      granted =
        resolve_on_plane(reloaded, DocBlock, :operator,
          repo: Samen.WebTest.Repo,
          grant: AllowAllGrant
        )

      assert_plane_clear!(granted.text_secure, @secret)
    end

    test "RED: operator WITHOUT a grant resolves •••• — never plaintext, never vt_", %{
      org_id: org_id,
      doc: doc
    } do
      block = insert!(org_id, doc.id, %{type: :paragraph, text_secure: @secret})
      reloaded = reload_block(org_id, block.id)

      masked =
        resolve_on_plane(reloaded, DocBlock, :operator,
          repo: Samen.WebTest.Repo,
          grant: DenyAllGrant
        )

      assert_plane_masked!(masked.text_secure, @secret)
      assert to_string(masked.text_secure) == mask()
      refute to_string(masked.text_secure) =~ "vt_"
    end

    test "SABOTAGE twin: the plane IS the gate — the same row flips, and a leak is detected", %{
      org_id: org_id,
      doc: doc
    } do
      block = insert!(org_id, doc.id, %{type: :paragraph, text_secure: @secret})
      reloaded = reload_block(org_id, block.id)

      tenant = resolve_on_plane(reloaded, DocBlock, :tenant, repo: Samen.WebTest.Repo)

      operator =
        resolve_on_plane(reloaded, DocBlock, :operator,
          repo: Samen.WebTest.Repo,
          grant: DenyAllGrant
        )

      # Same record, same resolver, one differing input — the anti-tautology.
      assert_two_plane!(tenant.text_secure, operator.text_secure, @secret)

      # And the scan the DOM proof uses is refutable: a modeled broken render IS caught.
      leaked_html = ~s(<div class="note-block-text">#{@secret}</div>)
      assert_leak_detected!(leaked_html, @secret)
    end

    test "the shipped DOM is clear on the tenant plane and mask-only on the operator plane", %{
      org_id: org_id,
      doc: doc
    } do
      _block = insert!(org_id, doc.id, %{type: :paragraph, text_secure: @secret})

      tenant_html = render_live(PageLive, notes_mount(), [org_id, doc.id])

      operator_html =
        render_live(PageLive, notes_mount(Plane.operator("op-1", org_id)), [org_id, doc.id])

      # GREEN half.
      assert tenant_html =~ @secret
      refute tenant_html =~ mask(), "the tenant plane has nothing to mask"

      # RED half: mask present, plaintext absent, no vault token anywhere.
      assert_masked_dom!(operator_html, [@secret])
    end
  end

  # ── the realtime path is plane-correct by construction ─────────────────────

  test "a masked operator re-reads the SAME broadcast to •••• (never the plaintext)", %{
    org_id: org_id,
    doc: doc
  } do
    block = insert!(org_id, doc.id, %{type: :paragraph, text_secure: @secret})

    Phoenix.PubSub.subscribe(@pubsub, PubSub.topic(doc.id))

    assert :ok = PubSub.broadcast_block_changed(notes_mount(), doc.id, reload_block(org_id, block.id))

    assert_receive {:block_changed, payload}, 2_000

    # The TENANT subscriber this broadcast is meant for re-reads clear…
    {:ok, tenant_block} =
      Reads.block(notes_mount(), scope_for(org_id), payload.block_id)

    assert_plane_clear!(tenant_block.text, @secret)

    # …and an OPERATOR socket re-reading the very same id gets the mask.
    operator_mount = notes_mount(Plane.operator("op-1", org_id))
    {:ok, operator_block} = Reads.block(operator_mount, scope_for(org_id, Plane.operator("op-1", org_id)), payload.block_id)

    assert_plane_masked!(operator_block.text, @secret)
  end
end
