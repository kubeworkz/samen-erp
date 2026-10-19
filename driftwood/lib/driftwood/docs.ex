defmodule Driftwood.Docs do
  @moduledoc """
  Driftwood's Docs domain — mounted from the samen_core Docs scope blueprint
  (ADR-004; F3, T45), exactly as `Driftwood.Calendar` mounts the Calendar scope.

  One `use Samen.Scopes.Docs` expands into four host-owned resources:

    * `Driftwood.Docs.Doc`  — a titled rich-text document (e.g. a lane/carrier
      runbook), 🔒 vaulted `secure_body` (`vault: :pii_doc_body`) for
      PII-classified content, attachable to any Freight/CRM object via the
      generic object-ref anchor. Archivable (ADR-040 §5.9). WS-Notes adds
      `parent_doc_id`/`icon`/`position`/`revision`.
    * `Driftwood.Docs.Note`  — a short annotation, same posture (`vault:
      :pii_note_body`).
    * `Driftwood.Docs.DocBlock` — one typed block row of a page, shaped by
      `Samen.Scopes.Docs.BlockShape`, 🔒 `text_secure` (`vault:
      :pii_block_text`). Archivable.
    * `Driftwood.Docs.DocLink` — one resolved `[[Title]]` edge (not archivable).

  ## Abbrev allocation (fresh abbrev)

  Docs has no scope-default abbrev (unlike Work's demo-claimed `wpj`/`wtk`) —
  every host takes a fresh allocator-proposed abbrev. Driftwood's initial
  proposal (`ddd`/`ddn`) collided with demo's own proposal (both host names
  start with "d" — the deterministic proposer is host-name-blind to OTHER
  host sections, the SAME collision class `dce`/`fce` hit for Calendar), so
  Driftwood took `fdd`/`fdn` instead (same f-prefixed collision-avoidance
  convention `Driftwood.Support`/`Driftwood.Calendar` use).
  """
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Docs,
    otp_app: :driftwood,
    repo: Driftwood.Repo,
    namespace: Driftwood.Docs,
    abbrevs: %{doc: "fdd", note: "fdn", doc_block: "fdb", doc_link: "fdl"}
end
