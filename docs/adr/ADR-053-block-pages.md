# ADR-053 — Block pages for internal notes: typed block rows in the Docs scope, a server-rendered editor, and no second content store

- **Status:** **ACCEPTED (2026-10-18)** — all six §8 operator decisions (O1–O6) were
  TAKEN by the operator on 2026-10-18; §8 records each decision and the rationale it was taken on.
  **Numbering:** §2 carries the DESIGN decisions D1–D6; §8 carries the OPERATOR decisions O1–O6, and
  every reference says which section it means. Filed ahead of the build on
  the ADR-052 precedent, so the invariants bind the first line of code rather than the last.
- **Date:** 2026-10-18 (decisions ratified the same day)
- **Build status:** **P0–P5 BUILT (2026-10-18/19); P6 not started.** Landed: the mechanics
  spike (P0, 8/8 green, [findings](../ws-notes/p0-findings.md)); the MODEL (P1) — `define_doc_block/6`,
  `define_doc_link/6`, `Doc.parent_doc_id`/`icon`/`position`/`revision`,
  `Samen.Scopes.Docs.BlockShape`, allocator-reserved abbrevs, and the additive migration in all six
  hosts (`demo`, `driftwood`, `pawchart`, `samen_web` test, `samen_core` test fixture, `samenerp`'s
  first full Docs mount) INCLUDING P1 unit 1.5, the `gen_app` Docs scaffold (§D1's template +
  suite/probe/golden mitigation — see §3.1 item 5); and the READ/WRITE SEAM (P2) -
  `Samen.Web.Notes.Reads` (`page/3`, `block/3`), `Samen.Web.Notes.Writes` (ordered insert/update_text/
  split/merge/move/indent/archive/restore, revision CAS, `{:error, :stale}`), `Samen.Web.Notes.Inline`
  (the constrained dialect to constructed HEEx, no `raw/1`) and `Samen.Web.Notes.Offset`. P2 unit 2.4
  (`Export`) is NOT built, so 2.5's export-masking row stays open with it. Then the SURFACE (P3) —
  `samen_notes_routes/3` + `IndexLive`/`PageLive` behind `Samen.Web.Tenant.Live`, the `NoteBlock`
  kit and `app.js` hook; SEARCH + BACKLINKS (P4) — `Samen.Web.Notes.Search` over the host
  `SearchIndex` (`:search_index` mount seam) and org-scoped `DocLink` resolution; and PRESENCE +
  THE MASKING PROOFS (P5) — `Samen.Web.Notes.PubSub` (per-page topic, **id-only** envelopes), the
  `editing_block_id` re-read skip (deferred to blur), and the `Samen.MaskingCase` trio. **P5 added
  one MODEL piece `§1` owed:** `Doc`/`DocBlock` now declare reveal actions
  (`reveal_secure_body`/`reveal_text_secure`), because `Samen.Api.PiiResolution` refuses to
  operator-reveal a resource with no declared reveal action — so §6's R5 green half (operator
  WITH a grant reads clear) had no mechanism until P5 added one. See §3.1 and
  [the build plan](../ws-notes/build-plan.md) for every deviation. NOT landed: the host mounts +
  the opt-in materialize task (P6). Sabotages **352** (stale revision CAS, R9), **353** (unknown
  type token, R11), **354** (R12 `raw/1` in the render path), **355** (R13 cross-org resolution),
  **356** (R15 search liveness JOIN), **357** (R10 focused-block skip) and **358** (R8 envelope
  carries text) all flip and restore byte-exact.
- **Task:** give a Samen host a Notion-shaped note surface — nested pages, typed blocks, a slash
  menu, search across them, and `[[page]]` backlinks — on the substrate that already exists, without
  inventing a second content store and without importing a client-side editor engine the repo has
  no toolchain for.
- **Deciders:** the operator. All six §8 operator decisions (O1–O6) were taken on 2026-10-18; the
  operator is named on each row because the rationale is theirs, recorded rather than inferred.
- **Consumes (binding inputs):**
  - **ADR-004** — library-authored scope blueprints (`use Samen.Scopes.*` expands into host-owned
    resources). This ADR adds resources to an existing blueprint; it does not add a scope package.
  - **ADR-023** — the abbrev allocator. `DocBlock`/`DocLink` get **allocator-proposed** abbrevs per
    host; no `priv/abbrev_registry.json` row is ever hand-written.
  - **ADR-036 / INV-1** — the vault `text` / `text_secure` classification pair, `FreeTextScan` on
    the plain path, `Samen.Pii.WriteGuard` + `Samen.Vault.Change` on the vaulted one, and
    `Samen.Api.PiiResolution` as the only read seam.
  - **ADR-038 §5.5** — the three `Samen.MaskingCase` proofs every vault-rendering surface ships.
  - **ADR-040 §5.9 / §6.5** — `archivable` and `versioned` as substrate flags, not per-resource code.
  - **ADR-042** — the dependency-free client runtime: `priv/static/assets/app.js` and its
    `window.SamenHooks` registration seam are the ONLY place client behaviour is added.
  - **ADR-012** — the chat realtime shape: a topic per object, an **id-only** broadcast envelope,
    and every subscriber re-reading through the plane resolver.

---

## 1. Context — what already exists, and what does not

`Samen.Scopes.Docs` (F3) is shipped and mounted in `demo`, `driftwood`, `pawchart` and the
`samen_web` test host. It defines two resources per host:

| Resource | Shape | PII posture |
|---|---|---|
| `Doc` | `title`, `body`, `subject_key`/`subject_id` anchor, `custom`, `owner_id`, archivable | `body` plain + `FreeTextScan`; `secure_body` vaulted (`:pii_doc_body`) |
| `Note` | same anchor, no title, archivable | `body` plain + `FreeTextScan`; `secure_body` vaulted (`:pii_note_body`) |

`Samen.Web.Docs.attach/5` is the org-scoped write boundary for the anchor, and
`samen_web/test/samen/web/docs_masking_test.exs` already proves the `secure_body` three-proof plus
the cross-org attach red path.

What Docs does **not** have: any UI. There is no `docs` route kind in `Samen.Web.Router`, no
`docs_path`/`pages_path` nav label, no LiveView, no block model, no hierarchy, no backlinks, no
search registration. Docs today is a substrate with an API and a masking proof — a Notion surface
is the missing half, not a missing concept.

Two near-neighbours are deliberately **not** reused:

- **CMS `Page`/`Post`/`Block`** (`cbl_block`, `content` jsonb, `versioned: :snapshot`) is the
  product's *published* output with a draft→publish workflow. Internal notes have no publish step
  and must not share that table or that status machine.
- **`Samen.Analytics.Replay` frames** solve a different problem (inert re-render of a screen); the
  closed-allowlist *shape* of `Samen.Replay.FrameSchema` is reusable discipline, not reusable code.

## 2. Decisions

### D1 — Extend the Docs scope; do not add a `Notes` scope

`Docs` is already the internal-document concept, already mounted in four hosts, and already carries
the `text`/`text_secure` classification pair this feature needs. A separate `Notes` scope would
re-declare that posture and split "an internal document" into two nouns that differ only by which
week they were built.

**Cost, stated honestly:** adding resources to a shipped blueprint forces a migration in every host
that `use`s it (`demo`, `driftwood`, `pawchart`, `samen_web` test) plus the new host (`samenerp`).
Mitigation is the ordinary one: a shared migration template + a `gen_app` probe + the
templates-parity golden, so a generated app gets it for free and the burden is mechanical.

**Rejected alternative:** a new `Samen.Scopes.Notes` (Pages + Blocks) that only interested hosts
mount. Cheaper for the four existing hosts, but it makes two scopes own "internal document" and two
PII maps describe the same content — the duplication the foundry exists to prevent.

### D2 — Blocks are rows, not one JSON body

`DocBlock` is a child resource: one row per block, ordered by an integer `position`, typed by a
bounded enum, carrying its own `text`/`text_secure` pair.

Why rows over a single `blocks` jsonb column (the CMS `Block.content` shape):

- **Masking granularity.** A vaulted block is a vaulted *column*; a jsonb blob cannot carry
  `pii_attribute` classification per element, so a sensitive paragraph inside an otherwise plain
  page would have no classified home. Rows keep INV-1 at the column level, where the verifiers
  (`pii_classify`, `no_plaintext_pii`, `pii_reads`) already look.
- **Audit granularity.** `archivable` + `versioned` are per-resource substrate flags; a block row
  inherits them, a jsonb element does not.
- **Ordering and partial writes.** Reordering one block, or editing one paragraph, is one row write
  guarded by a per-block revision — not a whole-document rewrite that loses a concurrent edit.
- **Search.** Block-level hits link to the paragraph, not just the page.

**Cost:** N rows per page, an ordinal that needs rebalancing, and a render that loads a list instead
of one field. All three are ordinary; none touches a chokepoint.

### D3 — The editor is server-rendered; no client editor engine, no JS build

Each block's editing surface is a **native form control** (`<textarea>`, auto-grown), persisted on a
`phx-debounce` change. There is no `contenteditable` anywhere in the milestone, and therefore no
selection model, caret restoration, IME reconciliation, or paste normalisation to implement.

This is the load-bearing decision, and it is a *deliberate narrowing of the feature*:

- The browser owns the value of a focused `<textarea>`; LiveView value-diffs it instead of patching
  DOM it did not author. The class of bugs that makes hand-rolled `contenteditable` fail
  (caret jumps, composition text treated as committed keystrokes, cross-block selection) cannot
  arise because there is no editable DOM to reconcile.
- Inline formatting is a **constrained dialect parsed server-side** (`**bold**`, `*italic*`,
  `` `code` ``, `~~strike~~`, `[text](https://…)`, `[[Page]]`, `@Name`) rendered into HEEx that the
  framework *constructs*. Stored text is never HTML, so stored-XSS is structurally impossible
  rather than sanitizer-dependent, and there is no `raw/1` to audit.
- Inserting, splitting, merging and moving blocks are **server events** carrying a block id and a
  bounded type token. Client JS is limited to a keydown hook that reports intent — it never mutates
  the DOM and never reads a stored value.

**Rejected for M1, not for ever:** a Tiptap/ProseMirror island (`phx-update="ignore"` + a JS-owned
editor) gives true rich text and is the documented route to CRDT multiplayer, but it introduces the
repo's first npm/esbuild toolchain and moves a rendering boundary into JavaScript — while every gate
this repo owns is Elixir-side. The upgrade seam is explicit: `DocBlock` rows are the source of
truth either way, so replacing the per-block `<textarea>` with a JS editor later is a UI change,
not a model change.

### D4 — Concurrency is per-block revision plus id-only presence, not a CRDT

Every block write carries the revision the client last saw; a stale write returns a conflict the UI
shows ("this block changed while you were typing — reload it") instead of silently overwriting.
Realtime rides `Samen.Web.Chat.PubSub`'s shape exactly: one topic per page, an **id-only** envelope
(`{:block_changed, block_id, revision}`, `{:page_structure_changed, revision}`), and each
subscriber re-reads through `Samen.Api.PiiResolution` on its own plane. No text and no token ever
transits PubSub.

**Rejected:** Yjs/`y_ex` CRDT. It is the right answer for simultaneous character-level typing and is
recorded as the M3 path; it is not required to let two people have a page open, and it would put a
merge engine (and a JS dependency) in front of the masking seam before the seam has shipped once.

### D5 — The PII pair is per block, and every read resolves on the actor's plane

`DocBlock.text` is plain and `FreeTextScan`-guarded (a bare email/SSN/phone-shaped value is refused
at the write boundary — the caller must use the other attribute). `DocBlock.text_secure` is
`pii_attribute` with `vault: :pii_block_text`, written only through `Samen.Pii.WriteGuard` +
`Samen.Vault.Change`.

Reads go through `Samen.Api.PiiResolution` on the actor's plane, never a direct field read: an
operator without a grant renders `••••`, never plaintext and never a `vt_*` token; a tenant on its
own org renders clear. Exports (Markdown/CSV/clipboard-copy) resolve through the same seam, so a
masked plane exports masks. "Sensitive page" is a UX affordance that writes `text_secure` at the
write site — it is not a second storage mode and not a runtime reclassification.

### D6 — History is page-level snapshots, not per-keystroke paper trail

`Doc` carries `revision` and (per host) `versioned: :changes_only` so metadata changes are audited by
the existing substrate. **Content** history is a `DocSnapshot` resource (M2): a `:checkpoint` action
captures the ordered block list as a validated, closed-schema jsonb frame with the author and
revision, fired by an explicit save-version **and** automatically every N block writes (§8 O5,
N configurable, default 20). Per-block paper trail on every debounced keystroke would write a version
row per edit burst — cost without a reader.

---

## 3. Model (as designed)

```text
Docs.Doc          (existing table, additive columns)
  parent_doc_id   uuid, nullable, same-scope same-org FK   — the tree
  icon            bounded token (nil | a closed emoji set)
  position        integer ordinal among siblings
  revision        integer, optimistic concurrency
  title           already exists
  body            already exists — LEGACY, read only when the doc has zero blocks (§8 O3)
  secure_body     already exists — unchanged; converted only by the opt-in materialize task

Docs.DocBlock     (new)
  doc_id          -> Docs.Doc (same-org, FK)
  parent_block_id uuid, nullable (M2: toggle/callout containers; M1 always nil)
  position        integer ordinal within its parent (M1: the doc root — see §8 O2)
  type            bounded enum: paragraph | heading_1 | heading_2 | heading_3 |
                  bulleted_list_item | numbered_list_item | to_do | quote | code |
                  divider | callout | page_link
  text            plain, FreeTextScan-guarded
  text_secure     pii_attribute, vault: :pii_block_text
  checked         boolean (to_do only; refused on other types)
  metadata        bounded map: `%{"language" => token}` for code, `%{"icon" => token}` for callout
  revision        integer

Docs.DocLink      (new, M1)
  source_doc_id   -> Docs.Doc
  target_doc_id   -> Docs.Doc   (resolved on write; unresolved links are not rows)
  anchor_text     the text the author typed (for "renamed page" hints)
```

`DocLink` is resolved on write (the `Samen.Web.ObjectRef` discipline) so backlinks are an indexed
reverse query, never a full-text scan; resolution is org-scoped, so a title that exists in another
org is not linkable and does not resolve.

### 3.1 As built — Phase 1 (2026-10-18), and where it deviates

The model above landed as `define_doc/5`'s four additive `Doc` columns plus two new macros in
`Samen.Scopes.Docs.Blueprint`. Deviations, each a decision rather than an omission:

1. **The macros take `/6` — the owning `Doc` module is an argument** (`define_doc_block/6`,
   `define_doc_link/6`). Deriving the destination from the namespace would re-guess what the host
   already knows at mount time. It is also the shape `belongs_to` needs to stay a same-scope FK
   rather than a bare uuid.
2. **`DocBlock.type` is guarded twice, deliberately.** The Ash `one_of` constraint and
   `Samen.Scopes.Docs.BlockShape` (installed as a resource `change`) both read the SAME
   `BlockShape.types/0` list, so the enum and the shape validator cannot drift; the change is what
   refuses an attribute the type does not name (`checked` on a paragraph, `language` on a callout),
   which a constraint cannot express.
3. **`DocLink` is not archivable.** It is a pure edge row: a re-resolution updates `anchor_text`, a
   deleted page's links are destroyed with it. `Doc`/`Note`/`DocBlock` stay `archivable: true`.
4. **`doc_id` is accepted on create only** (`accept([...])` differs between the create and update
   actions), which is R3's substrate half: a block cannot be re-parented into another doc — or org —
   because no update action will accept the field at all.
5. **§D1's mitigation is CLOSED — `gen_app` scaffolds the whole scope, not just a migration.**
   As first committed, the scaffold was OPEN: a generated app mounts
   `Primitives`/`Billing`/`Support`/`Identity` and did not `use Samen.Scopes.Docs` at all, so a
   migration template shipped alone would have created `*_doc_block`/`*_doc_link` tables for
   resources the app never defines — dead schema, not a freebie. Closed the same day by scaffolding
   the scope: `priv/templates/docs_ex.eex` (the `<App>.Docs` domain over `use Samen.Scopes.Docs`
   with four prefix-derived abbrevs) + `priv/templates/m_mount_docs_scope.eex` (the four tables,
   `catalog_sync/1` in the same transaction, real `down/0`), both riding the **web** set beside the
   Primitives/Operator mounts, with the domain registered in BOTH `ash_domains` lists of the
   emitted `config/config.exs`. Two things that were load-bearing and are worth naming:

   - **The domain registration is not cosmetic.** With the tables migrated but the domain absent
     from `ash_domains`, the app's own `samen.verify.vault_declared_parity` fails CLOSED with
     three findings — `pii_gdd_secure_body`, `pii_gdn_secure_body`, `pii_gdb_text_secure` are
     "de-vaulted PII columns" (a vault column with no discoverable route) — because a domain the
     verifiers cannot see is a domain whose `pii_attribute` routes do not exist. That failure is
     the honest one; it is what made the missing registration visible instead of shipping a
     silently unverifiable mount.
   - **Headless stays byte-identical.** The scaffold rides `web_new` (zero change to
     `files(false, false)`), preserving AC-G4-10's frozen headless output; the four abbrevs are
     derived only when `web?` (so `reserved_pairs/1` grows 46 → 50), which keeps the whole derived
     family collision-checked in `validate!/1` and in `Samen.Gen.ProbeAbbrev`.

   Proof: all THREE generator probes pass with the scaffold (each wrapped by the interrupt-safe
   guard, run serialized — they share one scratch-sweep glob, so two at once delete each other's
   app dir). The flagship probe (`priv/gen_app_flagship_probe.exs`) generated
   `--web --api --seeds --observability` `GenflagGA` and, with ZERO hand-edits, ran its FULL `ci.sh`
   green (abbrevs `gdd`/`gdn`/`gdb`/`gdl`; `gdd_doc`/`gdn_note`/`gdb_doc_block`/`gdl_doc_link` and
   the three `pii_*` vault columns all present in the emitted `schema.dict.json`), seeded
   vault-aware, booted and served `/healthz` + the framework LiveViews + the bounded
   deny-by-default JSON:API over real HTTP, and flipped BOTH sabotages; the deploy probe ran the
   same gate for a `--deploy` app (fail-closed runtime intact); the post-app probe generated a
   SECOND scope + resource over the scaffold and re-ran the gate green with its RBAC sabotage
   flipping. Every probe restored the committed registry byte-exact (asserted, unchanged) and left
   zero scratch. `templates_parity_test`'s golden trees gained exactly the eight new artifacts
   (`web`, `web_api`, `web_api_deploy`, `web_api_modules` × domain + migration) plus the four
   `config/config.exs` goldens' domain lists, and no other golden byte moved (the headless set is
   untouched — AC-G4-10 holds). The six hosts keep their hand-written migrations (all additive,
   all `phase: :expand`, all with a real `down/0` exercised by the tree down-check).
6. **The `icon` token is a bounded string, not an enum.** `max_length: 8` holds one emoji sequence
   plus a short ASCII token; a closed emoji set as an Ash enum would couple the model to a Unicode
   release. `BlockShape` never sees it (it shapes `metadata`, not `Doc` columns).

### 3.2 As built — Phase 5: the realtime envelope, and the reveal actions §2 D5 assumed

**The wire.** `Samen.Web.Notes.PubSub` is one topic per page (`samen:notes:page:<id>`) carrying a
closed set of id-only envelopes — `{:block_changed, %{block_id, revision}}` and
`{:page_structure_changed, %{doc_id, revision}}` — exactly §2 D4's shape. The editor subscribes on
connect, unsubscribes on terminate, and every subscriber re-reads the named row through
`Samen.Web.Notes.Reads` with its own scope, so the text resolves on the RECEIVING viewer's plane.
R8 is asserted two ways rather than described: the envelope's `Map.keys/1` set, and a byte scan of
`:erlang.term_to_binary/1` for the plaintext and for `vt_`. Sabotage **358** adds the text to the
builder and both assertions fail; that is the proof the scan is not decorative.

**The skip.** A broadcast never patches the `<textarea>` the user has focused (§2 D4's
`editing_block_id`). The incoming id is DEFERRED (`deferred_block_id`) and re-read when that
control blurs, so a remote change is applied late rather than dropped. Sabotage **357** re-reads
immediately and the focused value changes under the typist. One consequence is worth naming: with
R8/R10 working, the control being typed into is the only place a stale `revision` can still exist —
every other block is patched as the broadcast lands — so R9's conflict banner is realistically
triggered by exactly that deferred tab, which is how the P3 stale-write proof is now driven.

**The reveal actions (a model addition this phase could not avoid).** §2 D5 and §6 R5 state the
operator posture as "`••••` WITHOUT a grant", which implies "clear WITH one". `Doc` and `DocBlock`
shipped no `reveal` action, and `Samen.Api.PiiResolution.operator_granted?/6` refuses to reveal a
resource that declares none — so the granted half was unreachable by construction. Both resources
therefore declare one (`reveal_secure_body`, `reveal_text_secure`) in the Primitive
notifications/webhook shape: an actor-carrying action that CONSULTS `Samen.Reveal.grant_checker/0`
and returns a status map, never plaintext (the decrypt stays inside `PiiResolution`, behind the
same `opts[:repo]` seam as every other governed read). No migration: an action is not a column.
This is a model change, not a UI one, and it is recorded here rather than buried in the build plan.

## 4. Editor mechanics (M1)

| Concern | Mechanism |
|---|---|
| Typing | `<textarea phx-change="block_text" phx-debounce="400">`, one per text-bearing block |
| Enter | Hook reports `split_block` (block id, caret offset); server splits text at the offset and inserts a sibling |
| Backspace at offset 0 | Hook reports `merge_block`; server appends to the previous block and deletes this one |
| Indent / outdent | Hook reports `indent`/`outdent` on list types only; server swaps `type` between bulleted/numbered and adjusts `position` |
| Slash menu | `/` at offset 0 opens a server-rendered palette of the bounded type tokens; selection sends `insert_block(type)` |
| Reorder | M1: explicit move-up/move-down + `Alt+↑/↓` → `move_block`. Drag-and-drop is M2 (needs a vendored library, not a toolchain) |
| Remote change | Id-only broadcast; the client's focus state is reported as `editing_block_id`, and the server skips re-rendering that one block's control while it is focused |
| Inline render | Constrained dialect → constructed HEEx; unknown syntax stays literal text |
| A11y | Every control is a labelled form element; the palette is a list with roving focus; no keyboard-only dead ends |

The hook is ~120 lines appended to the existing `app.js` and registered on `window.SamenHooks` — the
seam ADR-042 C2 left empty. It holds no value and resolves nothing.

## 5. Search, backlinks, and what is deliberately not indexed

- `Doc`/`DocBlock` register in the host's `SearchIndex` for **`title` and `text` only**.
  `Samen.Scopes.Primitives.SearchIndexGuard` structurally refuses a `pii_attribute` column, so
  `text_secure` cannot enter the index even by mistake — the guard is the proof, not a convention.
- Backlinks: `DocLink` reverse rows rendered on the target page; an unresolved `[[Title]]` renders as
  a "create this page" affordance and is not persisted as a link until it resolves.
- `text_secure` content is invisible to search, to `Samen.Ai.Embeddings`, and to every aggregate.
  That is the cost of vaulting it and it is stated in the UI, not quietly omitted.

## 6. Invariants and red paths

Each row ships with a committed sabotage patch (numbers assigned at build time from **352**).

| # | Invariant | Must fail when |
|---|---|---|
| R1 | A page read is org-scoped; another org's page is `:not_found`, never a partial render | `OrgScope` is bypassed on `Doc` |
| R2 | A block write is org-scoped AND its `doc_id` must resolve on the same org | the same-org check on `doc_id` is dropped |
| R3 | A block cannot be re-parented into another doc/org | `doc_id` immutability is dropped on update |
| R4 | A page's `parent_doc_id` must be same-org (no cross-org tree graft, no cycle) | the parent check / cycle guard is removed |
| R5 | `text_secure` renders `••••` for operator-without-grant; never plaintext, never `vt_*` in DOM | the plane resolution is bypassed or hand-masked |
| R6 | An export on a masked plane contains masks, not plaintext | the export path reads the field directly |
| R7 | `text` refuses a PII-shaped value (`FreeTextScan`), while the SAME value into `text_secure` succeeds | the scan is removed (positive control keeps it from being a tautology) |
| R8 | The PubSub envelope carries ids and revisions only — no text, no token | the envelope builder starts carrying a payload |
| R9 | A stale `revision` write is refused, not applied last-write-wins | the concurrency check is removed |
| R10 | A remote broadcast cannot overwrite the block currently being edited | the `editing_block_id` skip is dropped |
| R11 | `insert_block` accepts only bounded type tokens; an unknown token is refused | the enum validation is bypassed |
| R12 | The inline renderer emits only constructed HEEx — stored text is never `raw/1`'d | a `raw/1` is introduced in the notes render path |
| R13 | A backlink never crosses orgs (title resolution is org-scoped) | resolution runs without `OrgScope` |
| R14 | A `pii_attribute` cannot enter the search index | `SearchIndexGuard` is neutered |
| R15 | Archived pages and their blocks leave the tree, the search index, and backlink results | the archive filter is dropped on one of the three |

## 7. Consequences

**Good:** one document concept, one PII map, block-level masking with the existing verifiers, a
Notion-shaped surface with zero new runtime dependencies, and a model a real editor can be dropped
into later without a data migration.

**Costly, and accepted:** no true inline rich text in M1 (block-level styling + a constrained
dialect only); no simultaneous character-level editing; a migration in five hosts; an ordinal that
must be rebalanced; `text_secure` content is unsearchable by design.

**Reversibility:** high for the UI (§2 D3 can be replaced behind the same rows), low for the model
(rows are the durable commitment). §2 D1's migration burden is paid once and is mechanical.

## 8. Operator decisions O1–O6 (taken 2026-10-18; each row keeps the option NOT taken)

The six questions §2 left to the operator. They are numbered **O** so that a bare "D3" never has to
mean two different things in one document.

- **O1 — scope placement. TAKEN (2026-10-18): extend the shipped `Docs` scope.** `Doc` gains
  `parent_doc_id`/`icon`/`position`/`revision`; `DocBlock` and `DocLink` are new resources in the same
  blueprint. *Rationale:* `Docs` already IS the internal-document concept and already carries the
  `text`/`text_secure` classification pair this feature needs; a second scope would re-declare that
  PII map and split one noun into two that differ only by build date. The cost — an additive
  migration in `demo`, `driftwood`, `pawchart`, the `samen_web` test host and `samenerp` — is
  accepted as mechanical (one template + `gen_app` probe + parity golden), not as a reason to
  duplicate the model. Consequence: §2 D1 is now binding, and Phase 1 unit 1.4 owns all five
  migrations.
- **O2 — block nesting. TAKEN (2026-10-18): flat in M1, with per-parent ordering from day one.**
  `parent_block_id` ships in the model and `position` is ALWAYS scoped to its parent (M1 only ever
  writes the doc root). Toggle/callout containers arrive in M2 as a UI change. *Rationale:* the
  expensive half of nesting is not the recursive render, it is ordering semantics — `position`
  scoped per-document now and per-parent later is a data migration over every block row, while
  shipping the per-parent definition unused costs nothing. Deferring the containers themselves keeps
  M1's split/merge/indent semantics flat and testable, which is exactly the surface P0 proves.
  *(Rejected: shipping containers in M1 — ~+1.5 days and a recursive render/split/merge surface on
  top of the flat mechanics P0 has not proven yet.)*
- **O3 — legacy body. TAKEN (2026-10-18): read-only fallback now, opt-in per-host materialization
  task later.** A doc with zero blocks renders `body` through the same inline dialect, read-only; a
  `mix samen.docs.materialize` task (per host, idempotent) converts it when the operator asks.
  *Rationale:* the two sources of truth are reconciled by ONE read seam rather than by a destructive
  write in four hosts with live rows — and the conversion is not a plain copy: `body` → a plain
  block is text, but `secure_body` → `text_secure` is a **vault write** that must run through
  `Samen.Pii.WriteGuard` + `Samen.Vault.Change`, so automating it is a governed operation, not a
  SQL `UPDATE`. Nothing is destroyed without a deliberate per-host call, and the fallback path is
  itself a named test (a legacy doc renders its body; a doc with one block ignores it).
- **O4 — surface name and place. TAKEN (2026-10-18): "Pages" at `/pages`, in the tenant nav's
  workspace group.** *Rationale:* "Page" is the noun the block model actually implements, and the two
  alternatives both collide with something already in the tree — `Notes` with the `Docs.Note`
  resource (an untitled annotation in the SAME scope), and `docs_base` with the external documentation
  URL prefix `Mount` already carries. The CMS `Page` collision is a different scope with no tenant
  nav surface today, so it is the cheapest of the three to live with. Mechanics: `pages_path` goes
  into `Mount.@label_keys` + `Samen.UI.Nav.nav_paths/2`, which means `label_keys_completeness_test`
  and the nav dead-link guard are updated in the same pass (Phase 3 unit 3.4). *(An object-tethered
  CRM/ERP tab remains a natural M2 addition — it is additive, not a different surface.)*
- **O5 — history depth. TAKEN (2026-10-18): auto every N edits plus an explicit checkpoint.**
  *Rationale:* history that depends on the team remembering to click "save version" is history that
  is absent exactly when it is needed (the incident nobody knew was coming). A counter on the
  page's write path bounds the cost to one snapshot per N block writes (N configurable, default 20)
  and an explicit checkpoint stays available for "before I try this". Interval-based checkpointing
  was rejected because a burst of changes inside the window collapses into a single version — the
  opposite of what a restore point is for.
- **O6 — who may write. TAKEN (2026-10-18): any member — the posture `Doc` already ships.**
  Read is `OrgScope`; create/update/destroy require `OrgScope` + `Samen.Policy.RoleAtLeast role:
  :member`, on `Doc`, `DocBlock` and `DocLink` alike. *Rationale:* the Docs scope must not hold two
  answers to "who may write a document" — a `Doc` a member can edit and a `DocBlock` they cannot is a
  policy split nobody could explain to a user. Member-write also matches the product's actual use
  (internal notes are a member activity, not an administrative one), and destructive safety is
  already carried by the substrate: `archivable` means a deleted page is recoverable, not gone. A
  per-page ACL is therefore explicitly out of M1 (and remains an additive later option). *(Rejected:
  admin-only creation — it splits the Docs scope's write posture in two and treats note-taking as an
  administrative act, which is not what the feature is for.)*

## 9. Non-goals (M1)

Real-time character-level collaboration; inline marks beyond the constrained dialect; comments and
mentions-as-notifications; databases/views/tables; page templates; drag-and-drop reorder; AI
summarise/ask-your-notes (M3, over `Samen.Ai.Embeddings`, with `Samen.Verifiers.EmbeddableNoPii`
deciding what may be embedded); import from Notion; public share links.
