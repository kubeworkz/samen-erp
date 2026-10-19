defmodule Samen.DocsScopeTest do
  @moduledoc """
  The Docs scope (F3, T45) — Doc + Note, attachable via the generic object-ref
  anchor + PII-classified-routes-to-vault, mounted via
  `test/support/docs_fixture.ex`.

  Every red-path pairs denial with a positive control (anti-tautology, the
  `Samen.RedPath` / masking-watch-list house style — CLAUDE.md):

    * c1 CRUD via governed actions + org-scoped reads (cross-org RED / own-org
      CONTROL, org-less fail-closed — mirrors `Samen.CalendarScopeTest` c1) for
      BOTH `Doc` and `Note`;
    * c2 archive/restore (ADR-040 §5.9): hide-on-archive / show-via-`:archived`
      / return-on-restore, double-archive idempotent;
    * c3 distinct-from-CMS probe (spec F3): `Doc`/`Note` own tables, never
      `cpg_page`/`cpt_post` (no shared storage with CMS `Page`/`Post`);
    * c4 INV-1 — `secure_body` masks by default (green/red/sabotage
      three-proof, `Samen.MaskingCase`): tenant plane clear, operator-without-
      grant plane `%Samen.Masked{}` (never plaintext, never a `vt_*` token),
      leak scan refutable (anti-tautology);
    * c5 vault routing: `secure_body` lands a `vt_*` token in the raw domain
      row, plaintext nowhere, ciphertext in `pii_vault`;
    * c6 an ARCHIVED Doc/Note keeps its vault token and still masks per plane;
    * c7 catalog registration — `mix samen.verify.catalog_parity` is green;
    * c8 the F3 Unit 6 free-text write chokepoint (`Samen.Pii.FreeTextScan`):
      a bare email/SSN/phone-shaped `body` value is REFUSED at the write path
      (RED, DB unchanged), ordinary prose is accepted (CONTROL) — this is the
      "vaulted when PII-classified" mechanism's plain-path belt: an obviously
      PII-shaped value can never land in the unvaulted `body` column, forcing
      the caller to the vaulted `secure_body` path instead.
  """
  use ExUnit.Case, async: false

  require Ash.Query

  import Samen.MaskingCase,
    only: [resolve_on_plane: 4, assert_plane_masked!: 2, assert_leak_detected!: 2, mask: 0]

  alias Samen.Archival
  alias SamenCore.Support.DocsFixture.{Doc, DocBlock, DocLink, Note}

  @repo SamenCore.TestRepo

  # No-grant vault stub: even wired to a vault, the operator-without-grant plane
  # must mask. Proves the mask is the plane/grant gate, independent of decrypt
  # availability (mirrors Samen.CalendarScopeTest's DenyAll).
  defmodule DenyAll do
    @behaviour Samen.Reveal.Grant
    @impl true
    def granted?(_ctx), do: false
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    Samen.Kms.FileBacked.simulate_outage(false)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    on_exit(fn -> Samen.Kms.FileBacked.simulate_outage(false) end)
    org = Ash.UUID.generate()
    {:ok, org: org, scope: tenant_scope(org)}
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp tenant_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, kind: :tenant, plane: :tenant}
    }
  end

  @secret_body "vaulted.subject@sample.invalid"

  defp new_doc(scope, org, attrs \\ %{}) do
    Doc
    |> Ash.Changeset.for_create(:create, Map.merge(%{org_id: org, title: "Doc"}, attrs),
      scope: scope
    )
    |> Ash.create!()
  end

  defp new_note(scope, org, attrs \\ %{}) do
    Note
    |> Ash.Changeset.for_create(:create, Map.merge(%{org_id: org}, attrs), scope: scope)
    |> Ash.create!()
  end

  # secure_body is NOT select-by-default — a fresh read that needs it must
  # select it explicitly (mirrors every other 🔒 field, e.g.
  # Samen.CalendarScopeTest.with_attendees_loaded/2).
  defp with_secure_body_loaded(%{id: id}, resource, scope) do
    resource
    |> Ash.Query.filter(id == ^id)
    |> Ash.Query.ensure_selected([:secure_body])
    |> Ash.read_one!(scope: scope)
  end

  defp doc_ids(scope), do: Doc |> Ash.read!(scope: scope) |> Enum.map(& &1.id) |> MapSet.new()
  defp note_ids(scope), do: Note |> Ash.read!(scope: scope) |> Enum.map(& &1.id) |> MapSet.new()

  defp new_block(scope, org, doc, attrs \\ %{}) do
    DocBlock
    |> Ash.Changeset.for_create(
      :create,
      Map.merge(%{org_id: org, doc_id: doc.id, type: :paragraph, text: "hello"}, attrs),
      scope: scope
    )
    |> Ash.create!()
  end

  # A block/link write that Ash REFUSES (a changeset that carries errors, or an
  # `Ash.Error.Invalid` raised while building it) — the shape both red paths below
  # assert against.
  defp refused_changeset(fun) do
    try do
      case fun.() do
        {:error, _reason} = error -> error
        other -> flunk("expected the write to be REFUSED, but it succeeded: #{inspect(other)}")
      end
    rescue
      e in [Ash.Error.Invalid, ArgumentError] -> {:error, e}
    end
  end

  defp archived_docs(scope), do: Doc |> Ash.Query.for_read(:archived) |> Ash.read!(scope: scope)
  defp archived_notes(scope), do: Note |> Ash.Query.for_read(:archived) |> Ash.read!(scope: scope)

  # ── c1: CRUD via governed actions; org-scoped reads ───────────────────────

  describe "c1 — CRUD via governed actions; org-scoped reads" do
    test "create/read/update/destroy(=archive) a Doc", %{org: org, scope: scope} do
      d = new_doc(scope, org, %{title: "Runbook", body: "How to deploy."})
      assert d.title == "Runbook"
      assert d.body == "How to deploy."

      [read] = Doc |> Ash.read!(scope: scope)
      assert read.id == d.id

      updated = d |> Ash.Changeset.for_update(:update, %{title: "Runbook v2"}, scope: scope) |> Ash.update!()
      assert updated.title == "Runbook v2"

      :ok = Ash.destroy!(d, scope: scope)
      assert Doc |> Ash.read!(scope: scope) == []
    end

    test "create/read/update/destroy(=archive) a Note", %{org: org, scope: scope} do
      n = new_note(scope, org, %{body: "Called re: renewal."})
      assert n.body == "Called re: renewal."

      [read] = Note |> Ash.read!(scope: scope)
      assert read.id == n.id

      updated = n |> Ash.Changeset.for_update(:update, %{body: "Updated note."}, scope: scope) |> Ash.update!()
      assert updated.body == "Updated note."

      :ok = Ash.destroy!(n, scope: scope)
      assert Note |> Ash.read!(scope: scope) == []
    end

    test "an actor never reads another org's Docs/Notes (RED); reads its own org's (CONTROL)" do
      org_a = Ash.UUID.generate()
      org_b = Ash.UUID.generate()
      scope_a = tenant_scope(org_a)
      scope_b = tenant_scope(org_b)

      doc_a = new_doc(scope_a, org_a, %{title: "A"})
      _doc_b = new_doc(scope_b, org_b, %{title: "B"})
      note_a = new_note(scope_a, org_a)
      _note_b = new_note(scope_b, org_b)

      seen_docs = Doc |> Ash.read!(scope: scope_a) |> Enum.map(& &1.id)
      seen_notes = Note |> Ash.read!(scope: scope_a) |> Enum.map(& &1.id)

      assert doc_a.id in seen_docs and length(seen_docs) == 1
      assert note_a.id in seen_notes and length(seen_notes) == 1
    end

    test "an org-less actor sees zero Docs/Notes (fail closed)", %{org: org, scope: scope} do
      _d = new_doc(scope, org, %{title: "hidden"})
      _n = new_note(scope, org)

      orgless = %Samen.Scope{actor: %{id: "nobody", org_id: nil, role: :member}}

      case Ash.read(Doc, scope: orgless) do
        {:ok, seen} -> assert seen == []
        {:error, %Ash.Error.Forbidden{}} -> assert true
      end

      case Ash.read(Note, scope: orgless) do
        {:ok, seen} -> assert seen == []
        {:error, %Ash.Error.Forbidden{}} -> assert true
      end
    end

    test "the object-ref anchor (subject_key/subject_id) is a plain scalar pair, storable and readable",
         %{org: org, scope: scope} do
      target_id = Ash.UUID.generate()
      d = new_doc(scope, org, %{title: "Attached", subject_key: "crm.person", subject_id: target_id})
      assert d.subject_key == "crm.person"
      assert d.subject_id == target_id

      n = new_note(scope, org, %{subject_key: "work.task", subject_id: target_id})
      assert n.subject_key == "work.task"
      assert n.subject_id == target_id
    end
  end

  # ── c2: archive/restore ────────────────────────────────────────────────────

  describe "c2 — archive/restore (ADR-040 §5.9)" do
    test "Doc: archive hides it (RED), :archived shows it (CONTROL), restore returns it (ASSERT)",
         %{org: org, scope: scope} do
      d = new_doc(scope, org)
      {:ok, _} = Archival.archive(d, scope: scope)

      refute MapSet.member?(doc_ids(scope), d.id)
      assert Enum.any?(archived_docs(scope), &(&1.id == d.id))

      restored = archived_docs(scope) |> Enum.find(&(&1.id == d.id))
      {:ok, _} = Archival.restore(restored, scope: scope)
      assert MapSet.member?(doc_ids(scope), d.id)
    end

    test "Note: archive hides it (RED), :archived shows it (CONTROL), restore returns it (ASSERT)",
         %{org: org, scope: scope} do
      n = new_note(scope, org)
      {:ok, _} = Archival.archive(n, scope: scope)

      refute MapSet.member?(note_ids(scope), n.id)
      assert Enum.any?(archived_notes(scope), &(&1.id == n.id))

      restored = archived_notes(scope) |> Enum.find(&(&1.id == n.id))
      {:ok, _} = Archival.restore(restored, scope: scope)
      assert MapSet.member?(note_ids(scope), n.id)
    end

    test "double-archive is an idempotent no-op (archived_at does not move)", %{org: org, scope: scope} do
      d = new_doc(scope, org)
      {:ok, once} = Archival.archive(d, scope: scope)
      {:ok, twice} = Archival.archive(once, scope: scope)
      assert once.archived_at == twice.archived_at
    end
  end

  # ── c3: distinct-from-CMS probe (spec F3) ──────────────────────────────────

  describe "c3 — distinct from CMS Page/Post (no shared table)" do
    test "Doc/Note own tables, never cpg_page/cpt_post; distinct from each other" do
      doc_table = AshPostgres.DataLayer.Info.table(Doc)
      note_table = AshPostgres.DataLayer.Info.table(Note)

      refute doc_table in ["cpg_page", "cpt_post"]
      refute note_table in ["cpg_page", "cpt_post"]
      assert doc_table != note_table
      assert doc_table == "sdd_doc"
      assert note_table == "sdn_note"
    end
  end

  # ── c4: INV-1 — secure_body masks by default (three-proof) ────────────────

  describe "c4 — INV-1: secure_body masks by default (green/red/sabotage three-proof)" do
    test "GREEN: tenant plane resolves Doc.secure_body CLEAR", %{org: org, scope: scope} do
      d = new_doc(scope, org, %{secure_body: @secret_body}) |> with_secure_body_loaded(Doc, scope)

      resolved = d |> resolve_on_plane(Doc, :tenant, repo: @repo) |> Map.get(:secure_body)

      refute match?(%Samen.Masked{}, resolved)
      assert resolved == @secret_body
    end

    test "RED: operator-without-grant plane resolves Doc.secure_body to %Masked{} — never " <>
           "plaintext, never a vt_ token", %{org: org, scope: scope} do
      d = new_doc(scope, org, %{secure_body: @secret_body}) |> with_secure_body_loaded(Doc, scope)

      masked = resolve_on_plane(d, Doc, :operator, repo: @repo, grant: DenyAll).secure_body
      assert_plane_masked!(masked, nil)
      refute to_string(masked) =~ @secret_body
      refute to_string(masked) =~ "vt_"
    end

    test "GREEN/RED: Note.secure_body masks identically to Doc.secure_body", %{org: org, scope: scope} do
      n = new_note(scope, org, %{secure_body: @secret_body}) |> with_secure_body_loaded(Note, scope)

      tenant_val = n |> resolve_on_plane(Note, :tenant, repo: @repo) |> Map.get(:secure_body)
      operator_val = resolve_on_plane(n, Note, :operator, repo: @repo, grant: DenyAll).secure_body

      assert tenant_val == @secret_body
      assert_plane_masked!(operator_val, nil)
      refute to_string(operator_val) =~ @secret_body
    end

    test "ANTI-TAUTOLOGY: plane flip — the SAME row resolves clear on tenant, masked on operator",
         %{org: org, scope: scope} do
      d = new_doc(scope, org, %{secure_body: @secret_body}) |> with_secure_body_loaded(Doc, scope)

      tenant_val = resolve_on_plane(d, Doc, :tenant, repo: @repo).secure_body
      operator_val = resolve_on_plane(d, Doc, :operator, repo: @repo, grant: DenyAll).secure_body

      refute match?(%Samen.Masked{}, tenant_val)
      assert match?(%Samen.Masked{}, operator_val)
      assert to_string(operator_val) == mask()
    end

    test "ANTI-TAUTOLOGY: the leak scan is refutable — a modeled plaintext render IS caught",
         %{org: org, scope: scope} do
      d = new_doc(scope, org, %{secure_body: @secret_body}) |> with_secure_body_loaded(Doc, scope)

      leaked = "<div>secure_body: #{@secret_body}</div>"
      assert_leak_detected!(leaked, @secret_body)

      masked = resolve_on_plane(d, Doc, :operator, repo: @repo, grant: DenyAll).secure_body
      assert_plane_masked!(masked, nil)
    end
  end

  # ── c5: vault routing ───────────────────────────────────────────────────────

  describe "c5 — vault routing: secure_body writes a vt_ token; plaintext never in the domain row" do
    test "Doc raw-row + pii_vault proof", %{org: org, scope: scope} do
      d = new_doc(scope, org, %{secure_body: @secret_body})
      Samen.RedPath.assert_vault_routed!(@repo, Doc, d.id, [:secure_body], [@secret_body])
    end

    test "Note raw-row + pii_vault proof", %{org: org, scope: scope} do
      n = new_note(scope, org, %{secure_body: @secret_body})
      Samen.RedPath.assert_vault_routed!(@repo, Note, n.id, [:secure_body], [@secret_body])
    end

    test "the VaultField last-line guard refuses a raw plaintext write (red path)" do
      assert {:ok, "vt_realtoken"} = Samen.Type.VaultField.dump_to_native("vt_realtoken", [])
      assert :error == Samen.Type.VaultField.dump_to_native(@secret_body, [])
    end
  end

  # ── c6: an archived Doc/Note keeps its vault token and still masks per plane ─

  describe "c6 — archiving does not disturb INV-1 (trash, not erasure)" do
    test "archived Doc: vt_ token at rest, masks on operator plane (RED), clears on tenant (CONTROL)",
         %{org: org, scope: scope} do
      d = new_doc(scope, org, %{secure_body: @secret_body})
      {:ok, _} = Archival.archive(d, scope: scope)

      archived =
        Doc
        |> Ash.Query.for_read(:archived)
        |> Ash.Query.filter(id == ^d.id)
        |> Ash.Query.ensure_selected([:secure_body])
        |> Ash.read!(scope: scope)
        |> hd()

      %{rows: [[stored]]} =
        @repo.query!("SELECT pii_sdd_secure_body FROM sdd_doc WHERE sdd_id = $1", [
          Ecto.UUID.dump!(archived.id)
        ])

      assert is_binary(stored) and String.starts_with?(stored, "vt_")

      masked = resolve_on_plane(archived, Doc, :operator, repo: @repo, grant: DenyAll).secure_body
      assert_plane_masked!(masked, nil)
      refute to_string(masked) =~ @secret_body

      tenant_val = resolve_on_plane(archived, Doc, :tenant, repo: @repo).secure_body
      refute match?(%Samen.Masked{}, tenant_val)
    end
  end

  # ── c7: catalog registration ────────────────────────────────────────────────

  describe "c7 — catalog registration (mix samen.verify.catalog_parity is green)" do
    test "the Docs fixture's tables/columns are fully catalogued (no violations)" do
      violations =
        Mix.Tasks.Samen.Verify.CatalogParity.check(@repo)
        |> Enum.filter(&(&1 =~ "sdd_doc" or &1 =~ "sdn_note"))

      assert violations == [],
             "expected no catalog_parity violations for the Docs fixture tables, got: " <>
               inspect(violations)
    end
  end

  # ── c8: F3 Unit 6 free-text write chokepoint on the plain `body` path ────────

  describe "c8 — Samen.Pii.FreeTextScan refuses a bare PII-shaped body (RED); ordinary prose " <>
             "is accepted (CONTROL)" do
    test "RED: a bare email-shaped body is refused at create; DB unchanged", %{org: org, scope: scope} do
      result =
        Doc
        |> Ash.Changeset.for_create(:create, %{org_id: org, title: "x", body: @secret_body}, scope: scope)
        |> Ash.create()

      assert {:error, %Ash.Error.Invalid{}} = result
      assert Doc |> Ash.read!(scope: scope) == []
    end

    test "RED: a bare phone-shaped body is refused on Note; DB unchanged", %{org: org, scope: scope} do
      result =
        Note
        |> Ash.Changeset.for_create(:create, %{org_id: org, body: "800-555-1234"}, scope: scope)
        |> Ash.create()

      assert {:error, %Ash.Error.Invalid{}} = result
      assert Note |> Ash.read!(scope: scope) == []
    end

    test "CONTROL: ordinary prose is accepted in body (anti-tautology — the scan is not " <>
           "blanket-refusing everything)", %{org: org, scope: scope} do
      d = new_doc(scope, org, %{body: "Renewal call scheduled for next week."})
      assert d.body == "Renewal call scheduled for next week."

      n = new_note(scope, org, %{body: "Follow up after the demo."})
      assert n.body == "Follow up after the demo."
    end

    test "CONTROL: a PII-classified value is accepted via the vaulted secure_body path " <>
           "(the caller's declared-classification route)", %{org: org, scope: scope} do
      d = new_doc(scope, org, %{secure_body: @secret_body})
      assert d.id
    end
  end

  # ── c9: the block model (WS-Notes Phase 1, ADR-053 §2 D2 / §3) ──────────────

  describe "c9 — DocBlock + DocLink + the Doc page columns (ADR-053 Phase 1)" do
    test "the Doc page columns round-trip (parent_doc_id/icon/position/revision)",
         %{org: org, scope: scope} do
      parent = new_doc(scope, org, %{title: "Root"})

      child =
        new_doc(scope, org, %{title: "Child", parent_doc_id: parent.id, icon: "📄", position: 2048})

      assert child.parent_doc_id == parent.id
      assert child.icon == "📄"
      assert child.position == 2048
      # The optimistic-concurrency counter starts at 1 (the write seam CASes it).
      assert child.revision == 1
    end

    test "R4 (org half): a Doc's parent must be same-org (RED); a same-org parent is accepted (CONTROL)",
         %{org: org, scope: scope} do
      org_b = Ash.UUID.generate()
      foreign = new_doc(tenant_scope(org_b), org_b, %{title: "B root"})
      mine = new_doc(scope, org, %{title: "Mine"})

      assert refused_changeset(fn ->
               Doc
               |> Ash.Changeset.for_create(
                 :create,
                 %{org_id: org, title: "graft", parent_doc_id: foreign.id},
                 scope: scope
               )
               |> Ash.create!()
             end)

      # CONTROL — the identical shape with a same-org parent is accepted.
      ok =
        Doc
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org, title: "graft ok", parent_doc_id: mine.id},
          scope: scope
        )
        |> Ash.create!()

      assert ok.parent_doc_id == mine.id
    end

    test "block CRUD: create/read/update/destroy(=archive) a DocBlock, ordered by position",
         %{org: org, scope: scope} do
      d = new_doc(scope, org, %{title: "Page"})
      b = new_block(scope, org, d, %{type: :heading_1, text: "Title"})

      assert b.doc_id == d.id
      assert b.type == :heading_1
      assert b.text == "Title"
      assert b.position == 0
      assert b.revision == 1

      second = new_block(scope, org, d, %{type: :code, text: "x = 1", metadata: %{"language" => "elixir"}, position: 1024})

      ordered =
        DocBlock
        |> Ash.Query.filter(doc_id == ^d.id)
        |> Ash.Query.sort(position: :asc)
        |> Ash.read!(scope: scope)

      assert Enum.map(ordered, & &1.id) == [b.id, second.id]

      updated =
        b |> Ash.Changeset.for_update(:update, %{text: "Title v2", revision: 2}, scope: scope) |> Ash.update!()

      assert updated.text == "Title v2"
      assert updated.revision == 2

      {:ok, _archived} = Archival.archive(b, scope: scope)

      visible = DocBlock |> Ash.Query.filter(doc_id == ^d.id) |> Ash.read!(scope: scope) |> Enum.map(& &1.id)
      refute b.id in visible
      assert second.id in visible
    end

    test "R2: a block's doc must be same-org (RED); a same-org doc is accepted (CONTROL)",
         %{org: org, scope: scope} do
      org_b = Ash.UUID.generate()
      foreign_doc = new_doc(tenant_scope(org_b), org_b, %{title: "B"})
      mine = new_doc(scope, org, %{title: "Mine"})

      assert refused_changeset(fn -> new_block(scope, org, foreign_doc) end)
      assert %DocBlock{} = new_block(scope, org, mine)
    end

    test "R3: `doc_id` cannot be re-pointed on update", %{org: org, scope: scope} do
      d = new_doc(scope, org, %{title: "A"})
      other = new_doc(scope, org, %{title: "B"})
      b = new_block(scope, org, d)

      assert refused_changeset(fn ->
               b |> Ash.Changeset.for_update(:update, %{doc_id: other.id}, scope: scope) |> Ash.update!()
             end)

      [fresh] = DocBlock |> Ash.Query.filter(id == ^b.id) |> Ash.read!(scope: scope)
      assert fresh.doc_id == d.id
    end

    test "an actor never reads another org's blocks (RED); reads its own (CONTROL)",
         %{org: org, scope: scope} do
      org_b = Ash.UUID.generate()
      scope_b = tenant_scope(org_b)
      mine = new_block(scope, org, new_doc(scope, org, %{title: "A"}))
      _theirs = new_block(scope_b, org_b, new_doc(scope_b, org_b, %{title: "B"}))

      seen = DocBlock |> Ash.read!(scope: scope) |> Enum.map(& &1.id)
      assert seen == [mine.id]
    end

    test "the closed shape is enforced ON THE WRITE PATH (R11's substrate half)",
         %{org: org, scope: scope} do
      d = new_doc(scope, org, %{title: "Page"})

      # GREEN controls first — the shapes the table exists for.
      assert %DocBlock{} = new_block(scope, org, d, %{type: :paragraph})
      assert %DocBlock{} = new_block(scope, org, d, %{type: :to_do, checked: true})
      assert %DocBlock{} = new_block(scope, org, d, %{type: :code, metadata: %{"language" => "elixir"}})
      assert %DocBlock{} = new_block(scope, org, d, %{type: :callout, metadata: %{"icon" => "💡"}})
      assert %DocBlock{} = new_block(scope, org, d, %{type: :page_link, metadata: %{"target_doc_id" => Ash.UUID.generate()}})

      # RED — attributes the type does not name are REFUSED, not dropped.
      assert refused_changeset(fn -> new_block(scope, org, d, %{type: :paragraph, checked: true}) end)
      assert refused_changeset(fn ->
               new_block(scope, org, d, %{type: :callout, metadata: %{"language" => "elixir"}})
             end)
      assert refused_changeset(fn ->
               new_block(scope, org, d, %{type: :code, metadata: %{"language" => "elixir", "rows" => "3"}})
             end)
      assert refused_changeset(fn -> new_block(scope, org, d, %{type: :to_do, checked: "yes"}) end)
      # RED — an undefined type is refused by the bounded enum.
      assert refused_changeset(fn -> new_block(scope, org, d, %{type: :database}) end)
    end

    test "a block's plain `text` is FreeTextScan-guarded (RED); the vaulted `text_secure` accepts it",
         %{org: org, scope: scope} do
      d = new_doc(scope, org, %{title: "Page"})

      assert refused_changeset(fn -> new_block(scope, org, d, %{text: @secret_body}) end)

      b = new_block(scope, org, d, %{text: "ordinary prose", text_secure: @secret_body})
      assert b.text == "ordinary prose"
      Samen.RedPath.assert_vault_routed!(@repo, DocBlock, b.id, [:text_secure], [@secret_body])
    end

    test "block text_secure masks per plane (INV-1), same three-proof as Doc.secure_body",
         %{org: org, scope: scope} do
      d = new_doc(scope, org, %{title: "Page"})
      b = new_block(scope, org, d, %{text_secure: @secret_body})

      loaded =
        DocBlock
        |> Ash.Query.filter(id == ^b.id)
        |> Ash.Query.ensure_selected([:text_secure])
        |> Ash.read_one!(scope: scope)

      tenant_val = resolve_on_plane(loaded, DocBlock, :tenant, repo: @repo).text_secure
      refute match?(%Samen.Masked{}, tenant_val)
      assert tenant_val == @secret_body

      operator_val = resolve_on_plane(loaded, DocBlock, :operator, repo: @repo, grant: DenyAll).text_secure
      assert_plane_masked!(operator_val, nil)
      refute to_string(operator_val) =~ @secret_body
      refute to_string(operator_val) =~ "vt_"

      # ANTI-TAUTOLOGY: the same row flips clear ⇄ masked with the plane alone.
      assert to_string(resolve_on_plane(loaded, DocBlock, :operator, repo: @repo, grant: DenyAll).text_secure) == mask()
    end

    test "DocLink: a resolved edge is created same-org; a cross-org target is REFUSED (R13)",
         %{org: org, scope: scope} do
      org_b = Ash.UUID.generate()
      source = new_doc(scope, org, %{title: "Source"})
      target = new_doc(scope, org, %{title: "Target"})
      foreign = new_doc(tenant_scope(org_b), org_b, %{title: "Foreign"})

      link =
        DocLink
        |> Ash.Changeset.for_create(
          :create,
          %{org_id: org, source_doc_id: source.id, target_doc_id: target.id, anchor_text: "Target"},
          scope: scope
        )
        |> Ash.create!()

      assert link.target_doc_id == target.id

      assert refused_changeset(fn ->
               DocLink
               |> Ash.Changeset.for_create(
                 :create,
                 %{org_id: org, source_doc_id: source.id, target_doc_id: foreign.id, anchor_text: "Foreign"},
                 scope: scope
               )
               |> Ash.create!()
             end)

      # Re-resolution refreshes the typed title; the endpoints never move.
      refreshed = link |> Ash.Changeset.for_update(:update, %{anchor_text: "Target (renamed)"}, scope: scope) |> Ash.update!()
      assert refreshed.anchor_text == "Target (renamed)"
      assert refreshed.target_doc_id == target.id

      assert refused_changeset(fn ->
               refreshed
               |> Ash.Changeset.for_update(:update, %{target_doc_id: foreign.id}, scope: scope)
               |> Ash.update!()
             end)

      # A DocLink is a pure edge row — it has NO archive state at all.
      refute Enum.any?(Ash.Resource.Info.attributes(DocLink), &(&1.name == :archived_at))
    end

    test "the block model's tables are catalogued in-tx (catalog_parity green)",
         %{org: org, scope: scope} do
      _ = new_block(scope, org, new_doc(scope, org, %{title: "Page"}))

      violations =
        Mix.Tasks.Samen.Verify.CatalogParity.check(@repo)
        |> Enum.filter(&(&1 =~ "sdb_doc_block" or &1 =~ "sdl_doc_link"))

      assert violations == [],
             "expected no catalog_parity violations for the block-model tables, got: " <>
               inspect(violations)

      assert AshPostgres.DataLayer.Info.table(DocBlock) == "sdb_doc_block"
      assert AshPostgres.DataLayer.Info.table(DocLink) == "sdl_doc_link"
    end
  end
end
