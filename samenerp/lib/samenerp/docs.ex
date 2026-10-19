defmodule Samenerp.Docs do
  @moduledoc """
  Samenerp's Docs domain — mounts the samen_core Docs scope blueprint
  (ADR-004; F3, T45) into the target host for WS-Notes (ADR-053 Phase 1).

  Samenerp is the workstream's TARGET host: it never mounted Docs, so this is
  the scope's FIRST full mount here — four resources in one `use`:

    * `Samenerp.Docs.Doc` — a titled page (`edd`), plus WS-Notes' `parent_doc_id`
      (the tree), `icon`, `position` and `revision`. `secure_body` is 🔒
      (`vault: :pii_doc_body`). Archivable.
    * `Samenerp.Docs.Note` — the untitled annotation (`edn`), same posture
      (`vault: :pii_note_body`).
    * `Samenerp.Docs.DocBlock` — one typed block row of a page (`edb`), shaped by
      `Samen.Scopes.Docs.BlockShape`; `text` is plain + `FreeTextScan`-guarded,
      `text_secure` is 🔒 `vault: :pii_block_text`. Archivable.
    * `Samenerp.Docs.DocLink` — one resolved `[[Title]]` edge (`edl`); both
      endpoints same-org (`Samen.Policy.SameOrgFk`). Not archivable.

  ## Abbrevs

  All four allocated through `mix samen.abbrev.reserve` under host `samenerp`
  (ADR-023), never hand-edited into `priv/abbrev_registry.json`.

  ## Leverage

  This module plus one migration (`MountDocsScope`, catalog-in-tx) is the whole
  host footprint for the substrate — the same ≈0-authored-LOC shape every other
  mount in this app has.
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Docs,
    otp_app: :samenerp,
    repo: Samenerp.Repo,
    namespace: Samenerp.Docs,
    abbrevs: %{doc: "edd", note: "edn", doc_block: "edb", doc_link: "edl"}
end
