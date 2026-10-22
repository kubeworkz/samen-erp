defmodule Samen.Web.NotesDeclassifyUiTest do
  @moduledoc """
  WS-Notes / ADR-053 §2 D5 + §6 R17 — the **"Move out of the vault"** control on the page editor,
  driven through the REAL router (`Samen.WebTest.SecurityEndpoint` + `SecurityRouter`, which mounts
  `samen_notes_routes/3` itself).

  The model half (a `:member` is refused by policy, an `:admin` succeeds and is audited, a blank
  reason is refused) is proven in `Samen.DocsScopeTest` c11. What is proven HERE is the surface:

    * **GREEN (admin)** — an admin on the tenant plane sees one 🔓 control on the vaulted block,
      opens it, reads the block's own clear text (the positive control: the tenant plane still
      resolves its own vault), submits a reason, and the control is GONE afterwards because the
      block is no longer vaulted. The database agrees: the plain column holds the vault's text,
      `text_secure` is nil, and an `aud_event` row records WHO and WHY without the text. Sabotage
      **378** (the surface's role gate reduced to "everyone") flips the refusals below.
    * **GREEN (armed admin, REAL membership)** — the same control works on an ARMED host through
      the router's `live_session`: a real `Identity.Membership` at `:admin` (created by the
      sanctioned `Register`/`Invite` path, the S1a harness shape) is what `TenantRole` resolves
      through the notes mount's `:identity_namespace` seam, so the `RoleAtLeast :admin` gate is
      satisfied by a role the test did not fabricate. Without that seam an armed module mount fails
      closed to `:member` — which is exactly what the paired RED test drives.
    * **RED (role)** — on an ARMED host a member gets no control at all, and a crafted
      `declassify_block` event (what a tampered client would send) is refused: the error says the
      write is admin-only, the row stays vaulted, nothing is audited. The same page still renders
      the member's own vaulted text in the clear on the tenant plane, so the refusal is the ROLE
      gate — never a broken read. Driven twice: with a fail-closed mount that carries no principal
      (a fabricated socket), and on the REAL route with a REAL `:member` membership pushed through
      `render_hook`.
    * **RED (plane)** — the operator-plane mount of the same page renders `••••` (never the text,
      never a `vt_*` token) and offers no control: a reveal grant is temporary, moving tenant
      content out of the vault permanently is a tenant decision (refused by the model too, proven
      in c11).
  """

  use Samen.WebTest.DataCase, async: false
  use Samen.MaskingCase

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Samen.Auth.SessionCreate
  alias Samen.Identity.{Invite, Register}
  alias Samen.Web.{Auth, Mount, Notes.PageLive, Notes.Reads, Notes.Writes, Plane, TenantRole}
  alias Samen.WebTest.Docs.Doc
  alias Samen.WebTest.Operator, as: Op
  alias Samen.WebTest.SecurityHost

  @endpoint Samen.WebTest.SecurityEndpoint

  # Plain ASCII on purpose: this prose is asserted inside a `<textarea>` and in `aud_event`.
  @prose "Q3 budget notes, no personal data in this paragraph"
  @reason "over-classified at authoring"

  setup do
    previous = Application.get_env(SecurityHost.otp_app(), :auth_required?)

    # The sanctioned dev/dogfood posture: an unarmed host resolves the `?org=` it is given. The
    # tests that need the ROLE gate arm the fictional host themselves (it is the SecurityHost's
    # own app env, never `:samen_web`, so no other suite is affected).
    SecurityHost.disarm!()

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(SecurityHost.otp_app(), :auth_required?)
        value -> Application.put_env(SecurityHost.otp_app(), :auth_required?, value)
      end
    end)

    org_id = Ash.UUID.generate()
    doc = seed_doc!(org_id)
    {:ok, block} = Writes.insert_block(tenant_mount(), tenant_scope(org_id), doc.id, %{text_secure: @prose})

    %{org_id: org_id, doc: doc, block: block}
  end

  # ── GREEN: the admin path, end to end ──────────────────────────────────────

  test "an admin moves a block out of the vault with a reason — and the control disappears",
       %{org_id: org_id, doc: doc, block: block} do
    {:ok, view, html} = live(build_conn(), "/pages/#{doc.id}?org=#{org_id}")

    # The tenant plane reads its OWN vault in the clear (the positive control), the block is 🔒,
    # and the one exit control is offered.
    assert html =~ @prose
    assert has_element?(view, "#note-block-#{block.id}[data-secure=true]")
    assert has_element?(view, "#note-declassify-#{block.id}")

    # The form is NOT standing open: the control opens it (a form, not a toggle).
    refute has_element?(view, "#note-declassify-form-#{block.id}")

    view |> element("#note-declassify-#{block.id}") |> render_click()

    assert has_element?(view, "#note-declassify-form-#{block.id}")
    # The dialog never prints the value — no text, no mask: it only asks WHY.
    assert (view |> element("#note-declassify-form-#{block.id}") |> render()) =~ "Move out of the vault"
    refute (view |> element("#note-declassify-form-#{block.id}") |> render()) =~ @prose

    html =
      view
      |> form("#note-declassify-form-#{block.id}", %{"reason" => @reason})
      |> render_submit()

    # Now plain: the page renders the same text (no mask standing in for it) and the exit control
    # is gone, because there is nothing vaulted left to move.
    assert html =~ @prose
    refute html =~ "••••"
    assert has_element?(view, "#note-block-#{block.id}[data-secure=false]")
    refute has_element?(view, "#note-declassify-#{block.id}")
    refute has_element?(view, "#note-declassify-form-#{block.id}")

    # The database agrees with the render.
    assert [projected] = page!(org_id, doc.id).blocks
    assert projected.secure? == false
    assert projected.text == @prose
    assert raw_block(block.id) == %{text: @prose, secure: nil}

    # …and the governance decision is on the record: WHICH block, WHICH revision, WHY — no text.
    assert [detail] = aud_details(block.id)
    assert detail =~ "docs.block.declassified"
    assert detail =~ "field=text_secure"
    assert detail =~ "reason=#{@reason}"
    refute detail =~ @prose, "the audit row must never carry the block's text"
  end

  test "a blank reason is refused by the surface too — the block stays vaulted",
       %{org_id: org_id, doc: doc, block: block} do
    {:ok, view, _html} = live(build_conn(), "/pages/#{doc.id}?org=#{org_id}")

    view |> element("#note-declassify-#{block.id}") |> render_click()

    html =
      view
      |> form("#note-declassify-form-#{block.id}", %{"reason" => "   "})
      |> render_submit()

    assert html =~ "Give a reason", "a blank reason must be answered, not silently dropped"
    assert has_element?(view, "#note-block-#{block.id}[data-secure=true]")
    assert raw_block(block.id).text == nil
    assert aud_details(block.id) == []
  end

  # ── GREEN: the armed admin leg, with a REAL membership ─────────────────────

  test "an armed host's REAL admin membership sees the control and moves the block out" do
    SecurityHost.arm!()

    with_test_delivery(fn ->
      host = register_owner!()
      admin = accept_into!(host, :admin)

      # The premise, asserted rather than assumed: this mount resolves the REAL role through the
      # `:identity_namespace` seam, so the gate below is satisfied by a membership, not a fixture.
      assert TenantRole.membership_role(armed_mount(), host.org.id, admin.credential.id) == :admin

      {doc, block} = seed_page!(host.org.id)

      {:ok, view, html} =
        live(session_conn(admin.credential.id), "/pages/#{doc.id}?org=#{host.org.id}")

      assert html =~ @prose, "an armed host's admin still reads their own vault in the clear"
      assert has_element?(view, "#note-declassify-#{block.id}")

      view |> element("#note-declassify-#{block.id}") |> render_click()

      html =
        view
        |> form("#note-declassify-form-#{block.id}", %{"reason" => @reason})
        |> render_submit()

      assert html =~ @prose
      assert has_element?(view, "#note-block-#{block.id}[data-secure=false]")
      refute has_element?(view, "#note-declassify-#{block.id}")

      assert raw_block(block.id) == %{text: @prose, secure: nil}
      assert [detail] = aud_details(block.id)
      assert detail =~ "docs.block.declassified"
      assert detail =~ "reason=#{@reason}"
      refute detail =~ @prose
    end)
  end

  # ── RED: the role gate (armed host, non-admin member) ──────────────────────

  test "the same armed route offers a REAL non-admin member nothing, and refuses a pushed event" do
    SecurityHost.arm!()

    with_test_delivery(fn ->
      host = register_owner!()
      member = accept_into!(host, :member)

      assert TenantRole.membership_role(armed_mount(), host.org.id, member.credential.id) ==
               :member

      {doc, block} = seed_page!(host.org.id)

      {:ok, view, html} =
        live(session_conn(member.credential.id), "/pages/#{doc.id}?org=#{host.org.id}")

      assert html =~ @prose, "the member still reads their own org's page in the clear"
      refute html =~ "note-declassify-#{block.id}"
      refute html =~ "note-declassify-form"

      vaulted_at_rest = raw_block(block.id)

      # A pushed event on the REAL socket — the shape a tampered client sends. The surface's
      # gate is posture; the model's `RoleAtLeast :admin` policy is what refuses.
      html =
        render_hook(view, "declassify_block", %{
          "block_id" => block.id,
          "reason" => "member tries to leave the vault"
        })

      assert html =~ "Only an admin"
      assert raw_block(block.id) == vaulted_at_rest
      assert aud_details(block.id) == []
    end)
  end

  test "RED: on an armed host a member is never OFFERED the control, and a crafted event is refused",
       %{org_id: org_id, doc: doc, block: block} do
    SecurityHost.arm!()

    # An armed mount carrying NO principal: `TenantRole` fails closed to `:member`, so this is the
    # least-privilege leg of the role gate. The page still renders (and still reads its own vault
    # in the clear, below), which is what makes the refusal a ROLE decision and not a dead render.
    mount = armed_mount()

    html = render_live(PageLive, mount, [org_id, doc.id])

    assert html =~ @prose, "the member's own tenant plane still reads the page's vault in the clear"
    refute html =~ "note-declassify-#{block.id}", "a member must not be offered the vault exit"
    refute html =~ "note-declassify-form", "nor the reason form"

    # Crafted event (a tampered client, or a role changed in another tab): the write is refused by
    # the model's `RoleAtLeast :admin` policy, and the surface says so.
    socket = page_socket(mount, org_id, doc.id)

    assert {:noreply, socket} =
             PageLive.handle_event(
               "declassify_block",
               %{"block_id" => block.id, "reason" => "member tries to leave the vault"},
               socket
             )

    assert socket.assigns.error =~ "Only an admin"

    # Nothing moved, nothing was recorded: the ciphertext at rest is the SAME bytes it was.
    vaulted_at_rest = raw_block(block.id)
    assert vaulted_at_rest.text == nil and is_binary(vaulted_at_rest.secure)

    assert [still_vaulted] = page!(org_id, doc.id).blocks
    assert still_vaulted.secure? == true
    assert still_vaulted.text == @prose
    assert raw_block(block.id) == vaulted_at_rest
    assert aud_details(block.id) == []
    refute socket.assigns.declassify_for, "a refused write must not leave the form open"
  end

  test "RED: the OPERATOR plane renders masks and offers no control on the same page",
       %{org_id: org_id, doc: doc, block: block} do
    {:ok, _view, html} = live(build_conn(), "/op-pages/#{doc.id}?org=#{org_id}")

    # The masking red path: the operator DOM holds the mask, never the text and never a vault token.
    assert html =~ "••••"
    refute html =~ @prose
    refute html =~ "vt_"

    # And the vault exit is a TENANT decision: no control, no form on this plane.
    refute html =~ "note-declassify-#{block.id}"
    refute html =~ "note-declassify-form"

    assert raw_block(block.id).text == nil, "rendering the operator plane must not declassify"
  end

  # ── harness ────────────────────────────────────────────────────────────────

  defp tenant_mount do
    Mount.new(:notes, Samen.WebTest.Docs, Samen.WebTest.Repo,
      plane: Plane.tenant(),
      labels: %{pages_path: "/pages"}
    )
  end

  # The armed twin of the security router's notes mount: the SAME `:otp_app` + `:authn` seams, so
  # `TenantRole.admin_scope/2` derives the REAL membership role (fail-closed `:member` with no
  # principal) instead of the disarmed `:admin` convenience.
  defp armed_mount do
    Mount.new(:notes, Samen.WebTest.Docs, Samen.WebTest.Repo,
      plane: Plane.tenant(),
      labels: %{
        pages_path: "/pages",
        otp_app: SecurityHost.otp_app(),
        authn: {:app_env, SecurityHost.otp_app(), :auth_required?},
        # The seam a real host wires (samenerp's shared labels) so the armed leg can resolve the
        # caller's REAL membership; absent it, `TenantRole` fails closed to `:member`.
        identity_namespace: Op
      }
    )
  end

  defp tenant_scope(org_id), do: Mount.scope(tenant_mount(), org_id)

  defp seed_doc!(org_id) do
    Doc
    |> Ash.Changeset.for_create(:create, %{org_id: org_id, title: "Sensitive runbook"},
      scope: tenant_scope(org_id)
    )
    |> Ash.create!()
  end

  defp page!(org_id, doc_id) do
    {:ok, page} = Reads.page(tenant_mount(), tenant_scope(org_id), doc_id)
    page
  end

  defp seed_page!(org_id) do
    doc = seed_doc!(org_id)

    {:ok, block} =
      Writes.insert_block(tenant_mount(), tenant_scope(org_id), doc.id, %{text_secure: @prose})

    {doc, block}
  end

  # ── the identity spine (a REAL org + memberships on the armed host) ────────
  #
  # The SAME sanctioned paths `TenantAuthzLiveTest`'s S1a harness uses: `Register.register/2` for
  # the org + owner, `Invite.create/3` + `Invite.accept/2` to land a second principal at an exact
  # role. Nothing here writes an `Identity.Membership` by hand, so `TenantRole` reads what a real
  # host would read.

  defp register_owner! do
    attrs = %{
      org_name: "Notes vault exit #{System.unique_integer([:positive])}",
      first_name: "Ada",
      last_name: "Lovelace",
      email: "notes-declassify-#{System.unique_integer([:positive])}@example.test",
      password: "correct horse battery staple"
    }

    {:ok, result} = Register.register(attrs, register_mods())
    Map.put(result, :email, attrs.email)
  end

  defp accept_into!(host, role) do
    invitee = register_owner!()

    owner_scope = %Samen.Scope{
      actor: %{
        id: host.user.id,
        org_id: host.org.id,
        role: :owner,
        verified?: true,
        kind: :tenant,
        plane: :tenant
      }
    }

    {:ok, _invitation, raw_token} =
      Invite.create(invite_mods(), owner_scope, %{email: invitee.email, role: role})

    {:ok, _joined} = Invite.accept(invite_mods(), raw_token)
    invitee
  end

  defp register_mods do
    %{
      org: Op.Org,
      credential: Op.Credential,
      user: Op.User,
      membership: Op.Membership,
      auth_token: Op.AuthToken,
      repo: Samen.WebTest.Repo
    }
  end

  defp invite_mods do
    %{
      invitation: Op.Invitation,
      credential: Op.Credential,
      user: Op.User,
      membership: Op.Membership,
      repo: Samen.WebTest.Repo
    }
  end

  defp session_create_mods do
    %{session: Op.Session, org: Op.Org, membership: Op.Membership, user: Op.User}
  end

  defp session_conn(credential_id) do
    {:ok, _session, raw_session_token} = SessionCreate.create(session_create_mods(), credential_id)

    build_conn()
    |> Plug.Test.init_test_session(%{})
    |> Plug.Conn.put_session(Auth.session_token_key(), raw_session_token)
  end

  # The invite email rides the fail-honest Delivery chokepoint; `:test` makes it a no-op (the
  # `tenant_authz_live_test` / `invitation_test` precedent).
  defp with_test_delivery(fun) do
    previous = Application.get_env(:samen_core, :delivery_env)
    Application.put_env(:samen_core, :delivery_env, :test)

    on_exit(fn ->
      case previous do
        nil -> Application.delete_env(:samen_core, :delivery_env)
        value -> Application.put_env(:samen_core, :delivery_env, value)
      end
    end)

    fun.()
  end

  defp page_socket(mount, org_id, doc_id) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> PageLive.load(org_id, doc_id)
  end

  # The raw domain columns of the block — what landed at rest, outside Ash's types.
  defp raw_block(id) do
    %{rows: [[text, secure]]} =
      Samen.WebTest.Repo.query!(
        "SELECT wdb_text, pii_wdb_text_secure FROM wdb_doc_block WHERE wdb_id = $1",
        [Ecto.UUID.dump!(id)]
      )

    %{text: text, secure: secure}
  end

  # The details of the aud_event rows naming this block as their subject.
  defp aud_details(subject_id) do
    %{rows: rows} =
      Samen.WebTest.Repo.query!(
        "SELECT aud_detail FROM aud_event WHERE aud_subject_id = $1",
        [subject_id]
      )

    Enum.map(rows, fn [detail] -> detail end)
  end
end
