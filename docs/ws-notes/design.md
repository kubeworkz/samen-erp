# WS-Notes — design

**Status:** ratified (2026-10-18), not built. No code yet — this is the design the build plan
executes. Decision record: [`docs/adr/ADR-053-block-pages.md`](../adr/ADR-053-block-pages.md) — filed
**PROPOSED** and **ACCEPTED the same day**, all six §8 decisions TAKEN (scope placement, nesting,
legacy body, surface name, history, write roles), following the ADR-052 precedent that the record is
written *before* the first line of code so its invariants bind it.

**Design inputs read:** `Samen.Scopes.Docs` + its blueprint; `Samen.Web.Docs.attach/5` and
`samen_web/test/samen/web/docs_masking_test.exs`; the CMS `Block`/`versioned: :snapshot` precedent;
`Samen.Web.Chat.PubSub` (id-only realtime); `Samen.Search` + `Samen.Scopes.Primitives.SearchIndexGuard`;
`Samen.Web.Mount.@label_keys` + `Samen.UI.Nav.nav_paths/2`; `samen_web/priv/static/assets/app.js`
(ADR-042 C2); `Samen.Ai.Embeddings` + `Samen.Verifiers.EmbeddableNoPii`; external research on
LiveView editor substrates (Tiptap/ProseMirror island vs server-rendered blocks, `y_ex`/Yjs) — see
§10.

---

## 1. The gap, stated precisely

The framework already has the **substrate** for internal documents and none of the **surface**:

| Exists | Does not exist |
|---|---|
| `Samen.Scopes.Docs` → `Doc` (title, `body`, `secure_body` 🔒, object-ref anchor) + `Note` | any LiveView, route kind, or nav label |
| `Samen.Web.Docs.attach/5` — org-scoped anchor write boundary | a block model, a page tree, ordering |
| `docs_masking_test.exs` — the `secure_body` three-proof + cross-org attach red path | backlinks, page history, slash menu |
| mounted in demo · driftwood · pawchart · samen_web test | **not** mounted in `samenerp` (the target host) |

So this workstream is not "build a notes app". It is: **give Docs a block model and a surface, then
mount it in `samenerp` at ≈0 authored LOC** — the same shape every other module shipped. §8's six
operator decisions (O1–O6) are taken, so the sections below are binding rather than options.

## 2. What "Notion-like" means in this tree

Notion is three separable things, and only one of them is cheap:

1. **A page tree with typed blocks.** Cheap, server-side, and the whole of M1.
2. **An inline rich-text editing engine.** Expensive: it is a client engine (ProseMirror-class), and
   this repo has no JS build at all — `app.js` is 2.2 KB of hand-authored transport shim and
   `window.SamenHooks` is an empty registration seam.
3. **Multiplayer CRDT.** Expensive again, and orthogonal to 1 and 2.

M1 buys 1 completely, plus a *constrained* slice of 2 (block-level types + a small inline dialect
resolved server-side). It does not pretend to buy the rest; §10 records the upgrade path so the M1
model does not have to be thrown away to get it.

## 3. Model

Extends `Samen.Scopes.Docs` (ADR-053 §2 D1/D2) — same scope, same PII map, new resources.

```text
Docs.Doc       + parent_doc_id · icon · position · revision          (additive)
Docs.DocBlock    doc_id · parent_block_id · position · type · text · text_secure 🔒 · checked · metadata · revision
Docs.DocLink     source_doc_id · target_doc_id · anchor_text         (resolved on write)
```

**`Doc.body` is legacy, not dead** (ADR-053 §8 O3). A doc with zero blocks renders `body` through the
same inline dialect, read-only; a doc with one block ignores it. The rule is *"blocks win whenever
blocks exist"*, enforced by a single `Samen.Web.Notes.Reads.page/2` — the two sources of truth are
reconciled at ONE seam rather than by a renderer that has to know which shape it is looking at.
Conversion is a separate, opt-in, per-host `mix samen.docs.materialize` task (idempotent), and it is
a **governed write**, not a copy: `body` → a plain block is text, but `secure_body` → `text_secure`
must run through `Samen.Pii.WriteGuard` + `Samen.Vault.Change` like any other vault write.

**Ordering** is an integer `position` scoped to its **parent** (ADR-053 §8 O2), with gaps of 1024 and a
rebalance inside the same transaction when a gap closes. M1 only ever writes the doc root, so the
per-parent definition is carried unused until M2's containers — the point is that ordering semantics
never have to be migrated. Fractional indexes were considered and rejected: they are a string column,
an invitation to lexical-comparison bugs, and unnecessary at page scale.

**Type is a bounded enum**, and `metadata` is validated *against* the type (`language` only on
`code`, `icon` only on `callout`, `checked` only on `to_do`). A single `Samen.Scopes.Docs.BlockShape`
validator — mirroring `Samen.Replay.FrameSchema`'s closed-allowlist discipline — is the one place
that knows which keys a type may carry, and it is what the block-write action runs.

## 4. The editing surface (and why it is not `contenteditable`)

Each block renders as a row. The editable part is a native control:

```heex
<textarea
  name={"block[#{@block.id}][text]"}
  phx-change="block_text"
  phx-debounce="400"
  phx-hook="NoteBlock"        data-block-id={@block.id}
  data-type={@block.type}
  rows="1"
  aria-label={block_label(@block)}
>{resolved_text}</textarea>
```

Five properties this buys, each of which a hand-rolled `contenteditable` would have to earn:

1. **The browser owns the value.** LiveView value-diffs a form control instead of patching DOM the
   user has mutated. No caret to restore, because the caret is never destroyed.
2. **IME/composition is native.** Composition text is provisional in every engine; in a `<textarea>`
   the platform handles it, and no `compositionstart`/`compositionend` reconciliation is written.
3. **Paste needs no policy.** The clipboard lands as text; block splitting on paste is a server
   decision (split on `\n\n`), not an HTML-vs-plain-text negotiation.
4. **Stored text is never HTML**, so stored XSS is structurally impossible: the renderer tokenises
   and *constructs* HEEx. There is no `raw/1` in the render path (an invariant, R12).
5. **The client script stays a keydown reporter.** No DOM writes, no innerHTML, no selection API.

The cost is equally concrete: no inline marks beyond the dialect, no cross-block selection, no
floating toolbars over a live range. That is the trade ADR-053 §2 D3 takes, and it is why M2/M3 exist.

### 4.1 The hook contract (`window.SamenHooks.NoteBlock`)

The hook never reads a value, never writes the DOM, and reports intent only:

| Event | Payload | Server does |
|---|---|---|
| `Enter` | `{block_id, offset, split?}` | split at offset; new sibling keeps the type (list items) or becomes `paragraph` |
| `Backspace` at 0 | `{block_id}` | merge into previous sibling, delete this row |
| `Tab` / `Shift+Tab` | `{block_id, direction}` | indent/outdent (list types only; no-op otherwise) |
| `Alt+↑` / `Alt+↓` | `{block_id, direction}` | move within the doc |
| `/` at 0 | `{block_id}` | open the server-rendered palette anchored to that block |
| `focus` / `blur` | `{block_id \| nil}` | set/clear `editing_block_id` (the remote-patch guard) |

Auto-grow is the one DOM write the hook makes, and only to its own element's `rows`/`height` — no
sibling, no parent, no text node.

### 4.2 Remote changes

One topic per page (`notes:page:<doc_id>`), the chat shape: broadcast `{:block_changed, id,
revision}` / `{:page_structure_changed, revision}`, subscribers re-read through
`Samen.Api.PiiResolution` on their own plane. The server skips re-rendering the block named by
`editing_block_id`, so a broadcast can never clobber a block being typed into; the skipped block is
re-read on blur. No text and no token on the wire (R8).

## 5. PII — the pair, the plane, and the export

Per block, mirroring `Doc.body`/`secure_body` exactly:

| Attribute | Guard | Render |
|---|---|---|
| `text` | `Samen.Pii.FreeTextScan` (refuses a bare email/SSN/phone-shaped value) | clear on every plane |
| `text_secure` | `Samen.Vault.Change` + `Samen.Pii.WriteGuard` (`vault: :pii_block_text`) | `••••` unless the plane grants |

Every render resolves through `Samen.Api.PiiResolution` — the notes LiveView never touches the field
directly, and neither does the export path (R6). The three proofs ship via `Samen.MaskingCase`:

- **green** — tenant own-org (and operator *with* grant) renders the clear text;
- **red** — operator without grant renders `••••`, never plaintext, never `vt_*`, asserted on the
  DOM (`assert_masked_dom!/2`) as well as at the resolver;
- **sabotage twin** — the mask assertion flips when the plane is flipped, proving it can fail.

A "sensitive page" toggle is a UI affordance only: it sets `text_secure` on blocks as they are
written and migrates existing plaintext through the governed chokepoint. It is **not** a second
storage mode, and it cannot reclassify at read time.

## 6. Search and backlinks

- Registration: `Doc` + `DocBlock` in the host's `SearchIndex` over `title`/`text` only.
  `SearchIndexGuard` refuses a `pii_attribute` column structurally, so `text_secure` cannot be
  indexed by mistake (R14) — and that refusal is exercised by a test, not assumed.
- Results are block-level: title, page link, snippet from `text`.
- Backlinks: `[[Title]]` resolves on write, org-scoped, into `DocLink`; the target page lists its
  reverse rows. Unresolved links render a "create page" affordance and create nothing until clicked.
  A rename leaves stale link rows until the page's next save re-resolves them (M1 behaviour,
  documented in the UI as "link may point at an older title").
- `text_secure` is unsearchable, unembeddable, and absent from every aggregate. The page says so
  where a user would expect to search it.

## 7. Where it mounts

Framework side (shipped once, every host inherits):

| Piece | File |
|---|---|
| Route macro (`/pages`, `/pages/:id`) | `samen_web/lib/samen/web/router.ex` — `samen_notes_routes/3`, the `samen_files_routes` shape |
| Reads / writes | `samen_web/lib/samen/web/notes/reads.ex`, `.../writes.ex` (the only place block ordering + revision live) |
| Realtime | `samen_web/lib/samen/web/notes/pub_sub.ex` (chat precedent, id-only) |
| Inline dialect | `samen_web/lib/samen/web/notes/inline.ex` + `Samen.UI.NoteBlock` in the kit |
| LiveViews | `.../notes/index_live.ex` (tree + recent), `.../notes/page_live.ex` (editor) |
| Nav | `pages_path` label in `Mount.@label_keys` + `Samen.UI.Nav.nav_paths/2` |
| Client | ~120 lines in `priv/static/assets/app.js`, registered on `window.SamenHooks` |

Host side (`samenerp` — the target — plus `demo` as the second adopter):

```elixir
# samenerp/lib/samenerp/docs.ex
defmodule Samenerp.Docs do
  use Ash.Domain, validate_config_inclusion?: false

  use Samen.Scopes.Docs,
    otp_app: :samenerp,
    repo: Samenerp.Repo,
    namespace: Samenerp.Docs,
    abbrevs: %{doc: "…", note: "…", doc_block: "…", doc_link: "…"}   # allocator-proposed
end

# samenerp/lib/samenerp_web/router.ex
samen_notes_routes :notes, Samenerp.Docs, repo: Samenerp.Repo, path: "/pages"
```

plus one migration (`priv/repo/migrations/*_add_notes_blocks.exs`, `catalog_sync/1` in-tx) and the
`ash_domains` entry. That is the whole host footprint — the leverage guard's ≈0 authored LOC holds.

## 8. Gates this must keep green

| Gate | Why it is in the way |
|---|---|
| `samen.verify.prefixes` / `catalog_parity` | new abbreviated tables + `fld_field` rows; catalog-in-tx is the only legal path |
| `samen.verify.migrations` | additive `Doc` columns and two new tables across every host |
| `samen.verify.pii_classify` / `no_plaintext_pii` / `pii_reads` | the `text`/`text_secure` pair and every read seam |
| `samen.verify.same_org_fk` | `doc_id`, `parent_doc_id`, `source_doc_id`/`target_doc_id` are cross-row references |
| `templates_parity_test.exs` + the `gen_app` probes (`priv/gen_app_*_probe.exs`) | the new migration template and any route-macro change appear in generated apps (there is no `samen.verify.templates` task — parity is a test, not a verifier) |
| `samen.verify.nav_links` + `label_keys_completeness_test` | `pages_path` is read by `nav_paths/2`, so it must be whitelisted |
| `tenant_shell_coverage_test` | the two LiveViews must `use Samen.Web.Tenant.Live` (a page-owned `render/1` is a compile error) |
| `schema_dict_drift_test` | `demo/schema.dict.json` regenerates; a hand-edited dict fails |
| `abbrev_registry_test` | the four new abbrevs are allocator-reserved, never hand-written |
| `adr_index_test` | this ADR is listed in `docs/adr/README.md` with the total bumped |

## 9. Risks, with the mitigation we actually have

| Risk | Mitigation |
|---|---|
| Five hosts need a migration | one template + `gen_app` probe + parity golden; the mutation is additive (no data rewrite) |
| Ordinal drift on concurrent reorder | per-doc `position` write inside a transaction + `revision` guard; a rebalance is idempotent and tested against a stale write |
| Two sources of truth (`body` vs blocks) | one read seam (`Reads.page/2`) decides; the legacy render is read-only; the materialize unit is optional and idempotent |
| The dialect becomes a parser project | closed token list, no nesting, unknown syntax renders literally; a table-driven test is the spec |
| Remote broadcast clobbers typing | `editing_block_id` skip + re-read on blur (R10), proven by a test that broadcasts into a focused block |
| The hook grows into an editor | contract table in §4.1 is the review rubric; the hook writes no DOM but its own `rows` |
| `text_secure` silently unsearchable | stated in the UI and asserted by a test that a vaulted block is absent from search results |
| Someone later reaches for Tiptap and forks the model | §10's upgrade path keeps `DocBlock` rows authoritative; the editor is a view |

## 10. The editor upgrade path (why M1 is not a dead end)

Researched, not assumed. The community position is consistent: a JS-owned editor (Tiptap/ProseMirror)
inside a `phx-update="ignore"` island is the established way to get rich text next to LiveView, with
`pushEvent`/`handleEvent` as the only channel; `contenteditable` hand-rolled around LiveView patching
is where caret/IME/paste bugs live. For multiplayer, Yjs (with `y_ex` 0.13 on the Elixir side, or a
Node provider behind Channels) is the route, and CRDTs are the only thing that solves simultaneous
character edits.

None of that changes the storage model: **`DocBlock` rows stay authoritative**; an editor island
would own the *view* of a block subtree and push `{block_id, text, revision}` the same way the hook
does today. That is the seam M1 deliberately leaves open — and the reason the milestone order is
model → surface → engine → CRDT rather than surface → model.

## 11. Non-goals (M1)

Inline marks beyond the dialect; cross-block selection; comments/mentions-as-notifications;
databases/views; templates; drag-and-drop; AI summarise/ask-your-notes (M3 over
`Samen.Ai.Embeddings`, bounded by `EmbeddableNoPii`); Notion import; public share links.
