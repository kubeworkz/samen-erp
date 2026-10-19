defmodule Samen.Scopes.Docs do
  @moduledoc """
  The **Docs** universal scope (F3; spec §F3/§F8). Ships as a **library-authored
  blueprint** (ADR-004), same shape as `Samen.Scopes.Work`/`Samen.Scopes.Calendar`:
  `use`-ing this module inside a host's Ash domain expands into two host-owned
  resources in the host's namespace, each a normal `use Samen.Resource` with the
  host's `otp_app`, `repo`, and `domain`.

  ## Resources — `doc · note · doc_block · doc_link`

  - **`Doc`** — a titled rich-text document, attachable to any object via the generic
    `(subject_key, subject_id)` object-ref anchor. WS-Notes (ADR-053) adds
    `parent_doc_id` (the page tree), `icon`, `position` and `revision`.
  - **`Note`** — an untitled short annotation, same attachment discipline.
  - **`DocBlock`** — one typed block row of a page: a bounded `type`, an integer
    `position` scoped to its parent, `checked`/`metadata` validated against the type by
    `Samen.Scopes.Docs.BlockShape`, and its own `text`/`text_secure` pair.
  - **`DocLink`** — one RESOLVED `[[Title]]` edge between two same-org pages.

  All four distinct from CMS `Page`/`Post` (no shared table, no publish workflow — see
  `Samen.Scopes.Docs.Blueprint` moduledoc).

  ## PII map (INV-1)

  `body` is plain, write-guarded by `Samen.Pii.FreeTextScan` (refuses a bare
  email/SSN/phone-shaped value). `secure_body` is the vaulted alternative for content the
  caller has classified as carrying subject PII. `DocBlock` carries the SAME pair one
  level down (`text` / `text_secure`, `vault: :pii_block_text`), so a single sensitive
  paragraph is a vaulted COLUMN rather than an unclassified element of a jsonb blob. See
  `Samen.Scopes.Docs.Blueprint` moduledoc for the full posture table.

  ## Object-ref attachment

  `subject_key`/`subject_id` are plain scalars (never a CRM/host FK), mirroring
  `Samen.Scopes.Work.Task` exactly (ADR-041 §4.1). Org-scope enforcement rides the
  samen_web `Samen.Web.ObjectRef.resolve/3` write boundary (`Samen.Web.Docs.attach/5`),
  not a substrate-level FK check — there is no CRM/host contact in this scope.

  ## Soft-delete (ADR-040 §5.9)

  `Doc`, `Note` and `DocBlock` are `archivable: true`. `DocLink` is NOT — it is a pure
  edge row (a link is destroyed, not archived).

  ## Mounting the Docs scope (the host side)

      defmodule Demo.DocsScope do
        use Ash.Domain, validate_config_inclusion?: false

        use Samen.Scopes.Docs,
          otp_app: :demo,
          repo: Demo.Repo,
          namespace: Demo.DocsScope,
          abbrevs: %{doc: "ddd", note: "ddn", doc_block: "ddb", doc_link: "ddl"}
      end

  This defines, in the host's namespace:

    * `Demo.DocsScope.Doc`
    * `Demo.DocsScope.Note`
    * `Demo.DocsScope.DocBlock`
    * `Demo.DocsScope.DocLink`

  ## Abbrevs (permanent, registry-checked)

  Each resource carries a permanent 3-letter abbrev, reserved in
  `samen_core/priv/abbrev_registry.json` under the HOST module name via
  `mix samen.abbrev.reserve` (ADR-023 — the macro does NOT invent abbrevs). Unlike
  Work (which claimed demo-owned defaults `wpj`/`wtk`), Docs has no scope-default —
  every host takes a fresh allocator-proposed abbrev (mirrors Calendar's `event`
  precedent), passed via `abbrevs:`:

    * `Demo.DocsScope.Doc`         → `ddd` · `Demo.DocsScope.Note`        → `ddn`
    * `Demo.DocsScope.DocBlock`    → `ddb` · `Demo.DocsScope.DocLink`      → `ddl`
    * `Driftwood.Docs.Doc`         → `fdd` · `Driftwood.Docs.Note`         → `fdn`
    * `Driftwood.Docs.DocBlock`    → `fdb` · `Driftwood.Docs.DocLink`      → `fdl`
    * `PawChart.Docs.Doc`          → `pdd` · `PawChart.Docs.Note`          → `pdn`
    * `PawChart.Docs.DocBlock`     → `pdb` · `PawChart.Docs.DocLink`       → `pdl`
    * `SamenCore.Support.DocsFixture.Doc`       → `sdd`
    * `SamenCore.Support.DocsFixture.Note`      → `sdn`
    * `SamenCore.Support.DocsFixture.DocBlock`  → `sdb`
    * `SamenCore.Support.DocsFixture.DocLink`   → `sdl`
    * `Samen.WebTest.Docs.Doc`     → `wdd` · `Samen.WebTest.Docs.Note`     → `wdn`
    * `Samen.WebTest.Docs.DocBlock` → `wdb` · `Samen.WebTest.Docs.DocLink` → `wdl`
    * `Samenerp.Docs.Doc`          → `edd` · `Samenerp.Docs.Note`          → `edn`
    * `Samenerp.Docs.DocBlock`     → `edb` · `Samenerp.Docs.DocLink`       → `edl`
  """

  defmacro __using__(opts) do
    otp_app = Keyword.fetch!(opts, :otp_app) |> Macro.expand(__CALLER__)
    repo = Keyword.fetch!(opts, :repo) |> Macro.expand(__CALLER__)
    namespace = Keyword.fetch!(opts, :namespace) |> Macro.expand(__CALLER__)
    domain = __CALLER__.module

    abbrevs = resolve_abbrevs(Keyword.fetch!(opts, :abbrevs), __CALLER__)

    doc_mod = Module.concat(namespace, Doc)
    note_mod = Module.concat(namespace, Note)
    doc_block_mod = Module.concat(namespace, DocBlock)
    doc_link_mod = Module.concat(namespace, DocLink)

    quote do
      require Samen.Scopes.Docs.Blueprint

      resources do
        resource(unquote(doc_mod))
        resource(unquote(note_mod))
        resource(unquote(doc_block_mod))
        resource(unquote(doc_link_mod))
      end

      Samen.Scopes.Docs.Blueprint.define_doc(
        unquote(doc_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.doc)
      )

      Samen.Scopes.Docs.Blueprint.define_note(
        unquote(note_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.note)
      )

      Samen.Scopes.Docs.Blueprint.define_doc_block(
        unquote(doc_block_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.doc_block),
        unquote(doc_mod)
      )

      Samen.Scopes.Docs.Blueprint.define_doc_link(
        unquote(doc_link_mod),
        unquote(otp_app),
        unquote(domain),
        unquote(repo),
        unquote(abbrevs.doc_link),
        unquote(doc_mod)
      )
    end
  end

  # No scope-default: `abbrevs:` is REQUIRED for ALL FOUR resources (mirrors
  # Calendar's "no pre-claimed scope-default" precedent — every host takes a fresh
  # allocator-proposed abbrev; WS-Notes' `doc_block`/`doc_link` are allocator-reserved
  # per host in ADR-053 Phase 1 unit 1.3).
  defp resolve_abbrevs({:%{}, _, pairs}, caller) do
    Map.new(pairs, fn {k, v} -> {Macro.expand(k, caller), Macro.expand(v, caller)} end)
  end

  defp resolve_abbrevs(other, _caller) do
    raise ArgumentError,
          "use Samen.Scopes.Docs, abbrevs: must be a compile-time map literal " <>
            "(%{doc: \"ddd\", note: \"ddn\", doc_block: \"ddb\", doc_link: \"ddl\"}). " <>
            "Got: #{Macro.to_string(other)}"
  end
end
