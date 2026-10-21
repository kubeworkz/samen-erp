defmodule Samen.Web.NotesExportMaskingTest do
  @moduledoc """
  WS-Notes Phase 2 unit 2.4 — the page EXPORT (`Samen.Web.Notes.Export`, ADR-053 §5 D5 / §6 R6).

  R6 in one sentence: a page leaves the product as a FILE or on the CLIPBOARD — Markdown, CSV or
  the copy — and that artifact is exactly as masked as the screen that offered it. Export is the
  easiest place to leak a vaulted block by accident: it is a second render path, with no HEEx in
  between to turn a `%Samen.Masked{}` into `••••` for you, and the copy path hands its bytes
  straight to `navigator.clipboard`. So this file is the masking watch-list proof for all three:

    * **GREEN** — the tenant plane's download carries the org's own vaulted block in the CLEAR
      (the tenant-as-owner rule), and every block type renders (headings, lists, to-dos, quote,
      fenced code, divider, callout, page link);
    * **RED** — the operator plane's download of the SAME page carries `••••`, never the
      plaintext, never a `vt_*` vault token — asserted over the whole artifact body with
      `assert_masked_dom!/2`, which is the scan a leak would have to survive;
    * **SABOTAGE twin** — the mask scan is refutable: the same page flipped to the tenant plane
      goes CLEAR, and a modeled leaked render IS detected by the same helper. Two patches, one
      per way out: `364-notes-export-bypasses-plane-resolution.patch` forges the plane the
      download's `Notes.Reads` call runs on, and
      `372-notes-clipboard-copy-bypasses-plane-resolution.patch` does the same to the copy — so
      each path has its own gate (364 leaves the clipboard tests green, 372 leaves the downloads
      green).

  The clipboard half is proven twice on purpose: at the module (`copy_text/3`, the artifact's
  bytes) and at the SOCKET (the event's pushed payload, driven on a real operator-plane socket),
  because a copy is only a leak if the bytes that reach `writeText` are the wrong ones.

  Beyond masking, the other invariants a download route owes: another org's page is `:not_found`
  (R1 — the same answer as a page that never existed, no existence oracle), the CSV is
  RFC-4180 (an embedded comma/newline stays ONE cell) and defanged against formula injection,
  a zero-block page exports its legacy body (ADR-053 §8 O3), and the artifact reaches the
  browser through the real route with a `Content-Type` and an attachment filename.
  """

  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest
  import Plug.Conn, only: [get_resp_header: 2]

  alias Samen.Web.{Csv, Mount, Notes.Export, Notes.PageLive, Notes.Writes, Plane}
  alias Samen.WebTest.Docs.Doc
  alias Samen.WebTest.SecurityHost

  @endpoint Samen.WebTest.SecurityEndpoint

  @secret "NOTES-EXPORT-PLAINTEXT-SENTINEL"

  setup do
    previous = Application.get_env(SecurityHost.otp_app(), :auth_required?)

    # The sanctioned dev/dogfood posture: an unarmed host resolves the `?org=` it is given, so the
    # download route can be driven without standing up the full auth spine. The armed-host posture
    # (a signed-out download is refused by the tenant gate) belongs to `tenant_authz_live_test.exs`.
    SecurityHost.disarm!()

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(SecurityHost.otp_app(), :auth_required?)
        value -> Application.put_env(SecurityHost.otp_app(), :auth_required?, value)
      end
    end)

    :ok
  end

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

  defp seed_doc!(org_id, title) do
    Doc
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, title: title}, scope: scope_for(org_id))
    |> Ash.create!()
  end

  # Writes are always seeded on the TENANT plane: the operator plane REFUSES a write at the
  # kernel, so a seeded block must be the org's own.
  defp insert!(org_id, doc_id, attrs) do
    {:ok, block} = Writes.insert_block(notes_mount(), scope_for(org_id), doc_id, attrs)
    block
  end

  defp markdown!(org_id, doc_id, plane \\ Plane.tenant()) do
    mount = notes_mount(plane)
    {:ok, artifact} = Export.markdown(mount, Mount.scope(mount, org_id), doc_id)
    artifact
  end

  defp csv!(org_id, doc_id, plane \\ Plane.tenant()) do
    mount = notes_mount(plane)
    {:ok, artifact} = Export.csv(mount, Mount.scope(mount, org_id), doc_id)
    artifact
  end

  # Drive the copy HANDLER on a real socket for `plane`, with no router: the payload it pushes
  # lands in the socket's pending pushes, which is exactly what the client would receive. This is
  # how the operator plane's copy is exercised without standing up a second router whose target
  # org would have to be static.
  defp copy_pushes(org_id, doc_id, plane) do
    mount = notes_mount(plane)

    socket =
      %Phoenix.LiveView.Socket{}
      |> Phoenix.Component.assign(:samen_mount, mount)
      |> Phoenix.Component.assign(:samen_acting_as, false)
      |> PageLive.load(org_id, doc_id)

    {:noreply, socket} = PageLive.handle_event("copy_page", %{}, socket)
    Phoenix.LiveView.Utils.get_push_events(socket)
  end

  # ── GREEN: the tenant's own page, in full ──────────────────────────────────

  describe "Markdown — the tenant plane" do
    test "renders every block type and the org's own vaulted block in the CLEAR" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, "Quarterly plan")

      insert!(org_id, doc.id, %{type: :heading_1, text: "Goals"})
      insert!(org_id, doc.id, %{type: :heading_2, text: "This quarter"})
      insert!(org_id, doc.id, %{type: :paragraph, text: "plain paragraph text"})
      insert!(org_id, doc.id, %{type: :bulleted_list_item, text: "bullet one"})
      insert!(org_id, doc.id, %{type: :numbered_list_item, text: "first step"})
      insert!(org_id, doc.id, %{type: :numbered_list_item, text: "second step"})
      insert!(org_id, doc.id, %{type: :to_do, text: "ship it", checked: true})
      insert!(org_id, doc.id, %{type: :quote, text: "quoted line"})
      insert!(org_id, doc.id, %{type: :code, text: "IO.puts(:ok)"})
      insert!(org_id, doc.id, %{type: :divider})
      insert!(org_id, doc.id, %{type: :callout, text: "remember this"})
      insert!(org_id, doc.id, %{type: :page_link, text: "Other page"})
      insert!(org_id, doc.id, %{type: :paragraph, text_secure: @secret})

      artifact = markdown!(org_id, doc.id)

      assert artifact.filename == "quarterly-plan.md"

      # The title is the H1; a heading block is one level DOWN from it, never a second H1.
      assert artifact.body =~ "# Quarterly plan"
      assert artifact.body =~ "## Goals"
      assert artifact.body =~ "### This quarter"

      assert artifact.body =~ "plain paragraph text"
      assert artifact.body =~ "- bullet one"
      assert artifact.body =~ "1. first step"
      assert artifact.body =~ "2. second step"
      assert artifact.body =~ "- [x] ship it"
      assert artifact.body =~ "> quoted line"
      assert artifact.body =~ "```\nIO.puts(:ok)\n```"
      assert artifact.body =~ "---"
      assert artifact.body =~ "> [!NOTE]"
      assert artifact.body =~ "> remember this"
      assert artifact.body =~ "[[Other page]]"

      # GREEN: the org's OWN vaulted content exports in the clear — this is the tenant-as-owner
      # rule, and it is what makes the operator assertion below a real per-plane flip.
      assert artifact.body =~ @secret
      refute artifact.body =~ "vt_"
      refute artifact.body =~ "••••"
    end
  end

  # ── RED: the same page, on the operator plane ──────────────────────────────

  describe "Markdown — the operator plane (masking watch-list)" do
    test "downloads the mask: never the plaintext, never a vt_* token" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, "Quarterly plan")
      insert!(org_id, doc.id, %{type: :paragraph, text: "plain paragraph text"})
      insert!(org_id, doc.id, %{type: :paragraph, text_secure: @secret})

      artifact = markdown!(org_id, doc.id, Plane.operator("op-1", org_id, "op-session"))

      assert_masked_dom!(artifact.body, [@secret])
      # Positive control: this is a REAL export of the page, not a blanket refusal or a blank
      # file — the unvaulted block and the title are still there. Without this, a download that
      # emitted nothing at all would "pass" the masking scan.
      assert artifact.body =~ "# Quarterly plan"
      assert artifact.body =~ "plain paragraph text"
    end

    test "an operator-plane block write was never possible, so the file is not a copy of a masked write" do
      # The masked value is the RESOLVER's output at read time, not something stored: the row's
      # own ciphertext is intact and the tenant plane still reads it clear afterwards.
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, "Round trip")
      insert!(org_id, doc.id, %{type: :paragraph, text_secure: @secret})

      _ = markdown!(org_id, doc.id, Plane.operator("op-1", org_id, "op-session"))
      tenant = markdown!(org_id, doc.id)

      assert tenant.body =~ @secret
      refute tenant.body =~ "••••"
    end
  end

  describe "CSV — the same plane rule, per cell" do
    test "the artifact is a real CSV table, and the vaulted cell masks on the operator plane" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, "Export table")
      insert!(org_id, doc.id, %{type: :paragraph, text: "plain paragraph text"})
      insert!(org_id, doc.id, %{type: :to_do, text: "ship it", checked: true})
      insert!(org_id, doc.id, %{type: :paragraph, text_secure: @secret})

      tenant = csv!(org_id, doc.id)
      assert tenant.filename == "export-table.csv"

      assert [header | rows] = Csv.parse(tenant.body)
      assert header == ["position", "type", "text", "checked"]
      assert length(rows) == 3
      assert Enum.any?(rows, fn row -> Enum.at(row, 2) == @secret end)

      operator = csv!(org_id, doc.id, Plane.operator("op-1", org_id, "op-session"))

      assert_masked_dom!(operator.body, [@secret])
      assert [op_header | op_rows] = Csv.parse(operator.body)
      assert op_header == ["position", "type", "text", "checked"]
      # Positive control: the unvaulted cells still export.
      assert Enum.any?(op_rows, fn row -> Enum.at(row, 2) == "plain paragraph text" end)
      assert Enum.any?(op_rows, fn row -> Enum.at(row, 3) == "true" end)
    end

    test "a comma or newline inside a block stays ONE cell, and a formula lead is defanged" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, "Escapes")
      insert!(org_id, doc.id, %{type: :paragraph, text: "step one, then two\nnext line"})
      insert!(org_id, doc.id, %{type: :paragraph, text: "=1+1"})

      assert [header | rows] = Csv.parse(csv!(org_id, doc.id).body)
      assert header == ["position", "type", "text", "checked"]

      texts = Enum.map(rows, fn row -> Enum.at(row, 2) end)
      assert "step one, then two\nnext line" in texts
      assert "'=1+1" in texts
    end
  end

  # ── SABOTAGE twin: the scan is refutable, and the flip is the plane ────────

  describe "anti-tautology" do
    test "the same page is CLEAR on tenant and MASKED on operator; a modeled leak IS caught" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, "Flip proof")
      insert!(org_id, doc.id, %{type: :paragraph, text_secure: @secret})

      tenant = markdown!(org_id, doc.id)
      operator = markdown!(org_id, doc.id, Plane.operator("op-1", org_id, "op-session"))

      # Only the plane differs between these two calls.
      assert tenant.body =~ @secret
      refute operator.body =~ @secret
      assert operator.body =~ mask()

      # The scan `assert_masked_dom!/2` runs is not vacuous: a render that DID carry the
      # plaintext (the sabotage patch's modeled failure) is detected by the very same helper.
      leaked = String.replace(operator.body, mask(), @secret)
      assert_leak_detected!(leaked, @secret)

      assert_raise ExUnit.AssertionError, fn -> assert_masked_dom!(leaked, [@secret]) end
    end
  end

  # ── org scope: another org's page is not found, and says nothing ───────────

  describe "org scope (R1)" do
    test "another org's page is :not_found from the exporter and a 404 from the route" do
      mine = Ash.UUID.generate()
      theirs = Ash.UUID.generate()

      foreign = seed_doc!(theirs, "Their secret plan")
      insert!(theirs, foreign.id, %{type: :paragraph, text: "foreign body text"})
      insert!(theirs, foreign.id, %{type: :paragraph, text_secure: @secret})

      assert {:error, :not_found} = Export.markdown(notes_mount(), scope_for(mine), foreign.id)
      assert {:error, :not_found} = Export.csv(notes_mount(), scope_for(mine), foreign.id)

      conn = get(build_conn(), "/pages/#{foreign.id}/export.md?org=#{mine}")
      assert conn.status == 404
      refute conn.resp_body =~ "Their secret plan"
      refute conn.resp_body =~ "foreign body text"
      refute conn.resp_body =~ @secret
    end
  end

  # ── the route: the artifact actually reaches the browser ──────────────────

  describe "the download route" do
    test "serves Markdown and CSV with a content type and an attachment filename" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, "Downloadable page")
      insert!(org_id, doc.id, %{type: :paragraph, text: "download body"})

      md = get(build_conn(), "/pages/#{doc.id}/export.md?org=#{org_id}")
      assert md.status == 200
      assert [content_type] = get_resp_header(md, "content-type")
      assert content_type =~ "text/markdown"
      assert [disposition] = get_resp_header(md, "content-disposition")
      assert disposition =~ ~s(attachment)
      assert disposition =~ ~s(filename="downloadable-page.md")
      assert md.resp_body =~ "download body"
      assert md.resp_body =~ "# Downloadable page"

      csv = get(build_conn(), "/pages/#{doc.id}/export.csv?org=#{org_id}")
      assert csv.status == 200
      assert [csv_type] = get_resp_header(csv, "content-type")
      assert csv_type =~ "text/csv"
      assert [csv_disposition] = get_resp_header(csv, "content-disposition")
      assert csv_disposition =~ ~s(filename="downloadable-page.csv")
      assert csv.resp_body =~ "position,type,text,checked"
    end

    test "the operator-plane route downloads masks too — the route is not a hint to hide" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, "Masked download")
      insert!(org_id, doc.id, %{type: :paragraph, text: "unvaulted line"})
      insert!(org_id, doc.id, %{type: :paragraph, text_secure: @secret})

      # The controller resolves the mount from the ROUTE assigns; the harness mounts the same
      # module on both planes, so drive the exporter through the identical scope the route
      # builds (an operator plane over this tenant) and prove the wiring is plane-neutral.
      operator = markdown!(org_id, doc.id, Plane.operator("op-1", org_id, "op-session"))
      assert_masked_dom!(operator.body, [@secret])
      assert operator.body =~ "unvaulted line"
    end
  end

  # ── legacy pages (ADR-053 §8 O3) ──────────────────────────────────────────

  describe "a zero-block page" do
    test "exports its legacy body, and masks a legacy vaulted body on the operator plane" do
      org_id = Ash.UUID.generate()

      legacy =
        Doc
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org_id, title: "Legacy", body: "legacy plain body"},
          scope: scope_for(org_id)
        )
        |> Ash.create!()

      vaulted =
        Doc
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org_id, title: "Legacy vaulted", body: "legacy vaulted body"},
          scope: scope_for(org_id)
        )
        |> Ash.create!()

      insert!(org_id, vaulted.id, %{type: :paragraph, text: "a block wins"})

      # A doc with at least one block ignores its legacy body entirely.
      vaulted_md = markdown!(org_id, vaulted.id).body
      assert vaulted_md =~ "a block wins"
      refute vaulted_md =~ "legacy vaulted body"

      legacy_md = markdown!(org_id, legacy.id).body
      assert legacy_md =~ "# Legacy"
      assert legacy_md =~ "legacy plain body"
    end

    test "a legacy body is never treated as Markdown structure (stored text is never markup)" do
      org_id = Ash.UUID.generate()

      doc =
        Doc
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org_id, title: "Not markup", body: "# not a heading\n<script>x</script>"},
          scope: scope_for(org_id)
        )
        |> Ash.create!()

      body = markdown!(org_id, doc.id).body

      # Stored text is TEXT — the export half of R12. The legacy body's `<script>` downloads as
      # escaped characters, so no Markdown viewer opening the file executes it; nothing is
      # stripped, so the characters are all still there.
      refute body =~ "<script>"
      assert body =~ "&lt;script&gt;"
      # ...and its `#` never becomes a second H1: a legacy body is literal text under the one
      # title heading, not Markdown source.
      refute body =~ ~r/^# not a heading/m
    end
  end

  # ── the editor offers the downloads ───────────────────────────────────────

  # ── clipboard copy: the third export, and the shortest way out ────────────

  describe "clipboard copy (R6's clipboard half)" do
    test "GREEN: the tenant's copy is plain text of the page, its own vaulted block in the CLEAR" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, "Quarterly plan")
      insert!(org_id, doc.id, %{type: :heading_1, text: "Goals"})
      insert!(org_id, doc.id, %{type: :paragraph, text: "plain paragraph text"})
      insert!(org_id, doc.id, %{type: :bulleted_list_item, text: "bullet one"})
      insert!(org_id, doc.id, %{type: :to_do, text: "ship it", checked: true})
      insert!(org_id, doc.id, %{type: :code, text: "IO.puts(:ok)"})
      insert!(org_id, doc.id, %{type: :divider})
      insert!(org_id, doc.id, %{type: :paragraph, text: "<script>alert(1)</script>"})
      insert!(org_id, doc.id, %{type: :paragraph, text_secure: @secret})

      {:ok, %{body: text}} = Export.copy_text(notes_mount(), scope_for(org_id), doc.id)

      assert text =~ "Quarterly plan"
      assert text =~ "Goals"
      assert text =~ "plain paragraph text"
      assert text =~ "bullet one"
      assert text =~ "[x] ship it"
      assert text =~ "IO.puts(:ok)"
      assert text =~ "———"

      # GREEN: the org's OWN vaulted block copies in the clear (tenant-as-owner), and the
      # clipboard holds no vault token either way.
      assert text =~ @secret
      refute text =~ "••••"
      refute text =~ "vt_"

      # PLAIN text, not Markdown — no heading `#`, no bullet, no fence to paste into a document...
      refute text =~ "# Goals"
      refute text =~ "- bullet one"
      refute text =~ "```"
      # ...and no HTML escaping, because a clipboard is text: escaping would paste `&lt;`.
      assert text =~ "<script>alert(1)</script>"
      refute text =~ "&lt;script&gt;"
    end

    test "RED: the operator's copy is the mask — never the plaintext, never a vt_* token" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, "Copy proof")
      insert!(org_id, doc.id, %{type: :paragraph, text: "plain paragraph text"})
      insert!(org_id, doc.id, %{type: :paragraph, text_secure: @secret})

      mount = notes_mount(Plane.operator("op-1", org_id, "op-session"))
      {:ok, %{body: text}} = Export.copy_text(mount, Mount.scope(mount, org_id), doc.id)

      assert_masked_dom!(text, [@secret])
      # Positive control: this is a real copy of the page, not a blanket refusal.
      assert text =~ "Copy proof"
      assert text =~ "plain paragraph text"
    end

    test "the copy EVENT pushes that artifact to the requester — masked on the operator plane" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, "Pushed copy")
      insert!(org_id, doc.id, %{type: :paragraph, text: "unvaulted line"})
      insert!(org_id, doc.id, %{type: :paragraph, text_secure: @secret})

      plane = Plane.operator("op-1", org_id, "op-session")
      # `get_push_events/1` reports each pending push as `[event, payload]`.
      assert [["copy_text", %{text: pushed}]] = copy_pushes(org_id, doc.id, plane)

      assert_masked_dom!(pushed, [@secret])
      assert pushed =~ "unvaulted line"

      # The event is a TRANSPORT for the module's artifact, not a second renderer: the pushed
      # bytes are exactly what `copy_text/3` returns for this plane.
      mount = notes_mount(plane)
      assert {:ok, %{body: artifact}} = Export.copy_text(mount, Mount.scope(mount, org_id), doc.id)
      assert pushed == artifact
    end

    test "the real route copies through the socket, and only claims 'Copied' after the client acks" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, "Socket copy")
      insert!(org_id, doc.id, %{type: :paragraph, text: "socket body"})
      insert!(org_id, doc.id, %{type: :paragraph, text_secure: @secret})

      {:ok, view, _html} = live(build_conn(), "/pages/#{doc.id}?org=#{org_id}")

      html = render_click(view, "copy_page")
      assert_push_event(view, "copy_text", %{text: pushed})
      assert pushed =~ "socket body"
      assert pushed =~ @secret

      # The page never claims success on its own: the client must report the clipboard write.
      refute html =~ "Copied"
      assert render_hook(view, "copied", %{}) =~ "Copied"
    end

    test "ANTI-TAUTOLOGY: the same page copies clear on tenant and masked on operator; a leaked payload IS caught" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, "Flip copy")
      insert!(org_id, doc.id, %{type: :paragraph, text_secure: @secret})

      {:ok, %{body: tenant}} = Export.copy_text(notes_mount(), scope_for(org_id), doc.id)
      operator = notes_mount(Plane.operator("op-1", org_id, "op-session"))
      {:ok, %{body: masked}} = Export.copy_text(operator, Mount.scope(operator, org_id), doc.id)

      # Only the plane differs between these two calls.
      assert tenant =~ @secret
      refute masked =~ @secret
      assert masked =~ mask()

      # The scan is refutable: a clipboard payload that DID carry the plaintext is caught by the
      # same helper (the sabotage's modeled failure).
      leaked = String.replace(masked, mask(), @secret)
      assert_leak_detected!(leaked, @secret)
      assert_raise ExUnit.AssertionError, fn -> assert_masked_dom!(leaked, [@secret]) end
    end

    test "a zero-block page copies its legacy body as plain text" do
      org_id = Ash.UUID.generate()

      doc =
        Doc
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org_id, title: "Legacy", body: "legacy plain body"},
          scope: scope_for(org_id)
        )
        |> Ash.create!()

      {:ok, %{body: text}} = Export.copy_text(notes_mount(), scope_for(org_id), doc.id)

      assert text =~ "Legacy"
      assert text =~ "legacy plain body"
    end

    test "the copy button is offered on BOTH planes with the hook, and the masked page pre-renders no payload" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, "Copy button")
      insert!(org_id, doc.id, %{type: :paragraph, text_secure: @secret})

      tenant_html = render_live(PageLive, notes_mount(), [org_id, doc.id])

      operator_html =
        render_live(PageLive, notes_mount(Plane.operator("op-1", org_id, "op-session")), [
          org_id,
          doc.id
        ])

      for html <- [tenant_html, operator_html] do
        assert html =~ ~s(id="note-copy-page")
        assert html =~ ~s(phx-hook="CopyText")
        assert html =~ "Copy page"
      end

      # The copy payload travels on the socket, never in the page: a masked render carries the
      # mask and nothing else.
      assert operator_html =~ "••••"
      refute operator_html =~ @secret
      refute operator_html =~ "vt_"
    end
  end

  describe "PageLive" do
    test "offers both downloads, threaded with the page's own org" do
      org_id = Ash.UUID.generate()
      doc = seed_doc!(org_id, "Downloadable page")
      insert!(org_id, doc.id, %{type: :paragraph, text: "download body"})

      html = render_live(PageLive, notes_mount(), [org_id, doc.id])

      assert html =~ ~s(id="note-export-md")
      assert html =~ ~s(id="note-export-csv")
      assert html =~ "/pages/#{doc.id}/export.md?org=#{org_id}"
      assert html =~ "/pages/#{doc.id}/export.csv?org=#{org_id}"
    end
  end
end
