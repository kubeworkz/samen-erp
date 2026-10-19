# WS-Notes — build plan

**Sizing rule (operator standing order):** SMALL serialized units — **one deliverable per `agent()`
call**, each banking in ~10–20 min, each independently committable and gate-able. Fan-out
concurrency 1. Model routing per unit (`sonnet` = mechanical ports/tests; `opus` = the validator, the
inline renderer, the ordering/revision writes, and every adversarial gate).

**Gate discipline:** every phase ends with an adversarial gate (findings fixed in-phase). All suites
+ the relevant host `ci.sh` green before/after each phase; `./ci.sh` before the milestone. Sabotage
patches numbered from **352** (**351** is the highest shipped — the delivery chokepoint probe) and
replayed with `scripts/sabotage.sh --range 352-<n>`.

**Design inputs:** [`design.md`](design.md), [`ADR-053`](../adr/ADR-053-block-pages.md). Binding
substrate: ADR-004 (blueprints), ADR-023 (abbrev allocator), ADR-036/INV-1 (vault pair), ADR-038 §5.5
(masking proofs), ADR-040 §5.9/§6.5 (archivable/versioned), ADR-042 C2 (`SamenHooks`), ADR-012
(id-only realtime).

**Dependency spine:** P0 (mechanics spike, independent) · P1 (model) → P2 (reads/writes + dialect) →
P3 (surface) → P4 (search/backlinks) → P5 (presence + proofs) → P6 (hosts + docs). P2 can start
against P1's resources the moment they compile; P3 needs P2's write path. **No host mounts the route
before P5.**

---

## Phase 0 — the mechanics spike (~0.5 day)

The one thing that could invalidate the whole design is the editing mechanic, so prove it first, on
one throwaway page in the `samen_web` test host.

1. A single LiveView rendering three `<textarea>` rows with `phx-change` + `phx-debounce="400"` and a
   `phx-hook="NoteBlock"` stub in `app.js`.
2. Prove on a real socket: (a) typing does not lose the caret across a debounced round trip;
   (b) a second socket's broadcast does not alter the focused control (`editing_block_id` skip);
   (c) `Enter` at a caret offset splits server-side and focus lands in the new block; (d) `Backspace`
   at offset 0 merges.
3. Record the measured round-trip and what the hook needed to know that the server could not.

**Gate P0:** the spike's four assertions pass against a live socket, and the finding note says
exactly which parts of the §4.1 hook contract were load-bearing. If (a) or (b) cannot be made to
hold, **stop and escalate to ADR-053 §2 D3** — the rest of the plan assumes them.

**As built (2026-10-18) — PASSED, GO on §2 D3.** Findings: [`p0-findings.md`](p0-findings.md).

| # | Result |
|---|---|
| (a) | the server echoes the submitted text byte-identically; a browser probe measured caret `5 → 5` on an identical re-write and `5 → 18` on a different one (the control that makes the first number mean something) |
| (b) | two real sockets: the focused block keeps its text, records the skip, re-reads on blur |
| (c) | split at a client-supplied offset; new row ordered after its parent; `push_event("focus_block")` emitted |
| (d) | merge restores the joined text; merging the first block is a no-op |

8/8 tests green in `test/samen/web/notes_spike_mechanics_test.exs`; **1.95–2.15 ms** server-side
processing per debounced change. Deviations and follow-ons, all recorded rather than silently taken:

1. **The hook was NOT added to `app.js`.** It lives in `test/support/notes_spike/spike.js` as the
   candidate body. Shipping ~45 lines of untested JS into a 2.2 KB hand-authored bundle would have
   been a change with no proof behind it; the contract it must satisfy is now measured instead.
2. **`{:lazy_html, ">= 0.1.0", only: :test}` was added to `samen_web`** (+4 lockfile lines). Without
   it NO test in this app could drive a connected socket with element selectors (or
   `live_isolated/3`) — the repo's only real-socket suite avoided selectors entirely, so the gap was
   invisible. This is a fix to the harness, not a convenience for the spike.
3. **The full browser pass is blocked by design:** `samen_web` ships no webserver adapter, so
   `server: true` cannot bind (`Plug.Cowboy.child_spec/1 is undefined`). `serve.exs` refuses with the
   two ways to run it (add a test-only `:bandit`, or mount the spike router in a host that has one).
   The caret was measured directly instead (§5 of the findings).
4. **Contract changes for Phase 3:** focus/blur reporting **drops** (declarative `phx-focus`/`phx-blur`
   already carries the id); "focus this block" **is added** as the one server→client message; the
   hook is ~45 lines (keydown + auto-grow + one handled event); `phx-change` moves onto the control
   so a debounce does not post every block.
5. **One open contract question:** `selectionStart` is UTF-16 code units, `String.split_at/2` is
   graphemes — identical for ASCII, divergent for emoji/combining marks. Settle it with a single
   offset helper in Phase 2 (findings §3).

## Phase 1 — the model (~1.5 days)

| Unit | Deliverable |
|---|---|
| 1.1 | `Docs.Blueprint.define_doc_block/6` + `define_doc_link/6` (as built: `/6` — the owning `Doc` module is passed, so the `belongs_to` destinations are not guessed from the namespace); `Doc` gains `parent_doc_id`, `icon`, `position`, `revision`; all policies mirror `Doc`'s shipped posture (`OrgScope` read; org + `RoleAtLeast :member` write); `DocBlock` `archivable: true`, `DocLink` a pure edge row (not archivable). |
| 1.2 | `Samen.Scopes.Docs.BlockShape` — the closed per-type allowlist (`type` → allowed `metadata` keys, `checked` only on `to_do`), `validate/1` returning `{:ok, attrs} \| {:error, reason}`; no `raw` map passthrough. |
| 1.3 | Abbrev allocation through `mix samen.abbrev.reserve` for `DocBlock`/`DocLink` in **every** host namespace that `use`s Docs (demo, driftwood, pawchart, samen_web test, samenerp); registry restored SHA-256 byte-exact by the allocator, never hand-edited. |
| 1.4 | Host migrations (DONE — `demo`, `driftwood`, `pawchart`, `samen_web` test host, `samen_core` test fixture, plus `samenerp`'s first full Docs mount): additive columns on `<abbrev>_doc`, new `<abbrev>_doc_block` / `<abbrev>_doc_link` tables, indexes on `(doc_id, position)`, `(parent_block_id)`, `(target_doc_id)` + a unique `(source_doc_id, target_doc_id)`, `catalog_sync/1` in the same transaction, each declared `phase: :expand` so the tree down-check exercises its `down/0`. **DONE for all six hosts (2026-10-18).** |
| 1.5 | **DONE (2026-10-18) — the whole scope is scaffolded, not just a migration.** A generated app mounted `Primitives`/`Billing`/`Support`/`Identity` and did NOT `use Samen.Scopes.Docs`, so a migration template alone would have created `*_doc_block`/`*_doc_link` tables for resources the app never defines. Landed: `docs_ex.eex` (the `<App>.Docs` domain + four prefix-derived abbrevs) + `m_mount_docs_scope.eex` (four tables, catalog-in-tx, real `down/0`), both on the **web** set with the domain registered in BOTH emitted `ash_domains` lists; `Samen.Gen.App` gained the Docs abbrev family (derived only when `web?`, so `reserved_pairs` 46 → 50 and headless stays byte-identical) and the `d_*` template bindings; `gen_app_test` carries the new file-set rows + 46/50 reservations. Goldens: exactly the 8 new artifacts across `web`/`web_api`/`web_api_deploy`/`web_api_modules`, no other byte moved. Proven by the flagship probe (generated app → its own full `ci.sh` green, seeded, booted, both sabotages flipped, registry restored byte-exact). **The load-bearing finding:** without the `ash_domains` registration the app's own `vault_declared_parity` fails closed on the three `pii_*` columns — a vault column with no discoverable route — which is what made the omission visible instead of shipping a silently unverifiable mount (ADR-053 §3.1 item 5). |

Tests: `docs_scope_test.exs` extended (block CRUD + org scope + archive), `BlockShape` accepts each
type and refuses `checked` on `paragraph` / `language` on `callout` / an unknown key; catalog parity
and prefixes green; `abbrev_registry_test` green.

**Gate P1:** `cd samen_core && mix test` green with `--warnings-as-errors`; each host's migration runs
up/down on a scratch DB; catalog regenerated and drift test green.

## Phase 2 — reads, writes, and the inline dialect (~1.5 days)

| Unit | Deliverable |
|---|---|
| 2.1 | **DONE (2026-10-19)** — `Samen.Web.Notes.Reads` — the ONE read seam: `page/3` (doc + blocks ordered by `(position, id)`, every text resolved through `Samen.Api.PiiResolution` on the actor's plane) and `block/3` (the id-only realtime re-read path); the legacy `body` fallback decision lives here and nowhere else. |
| 2.2 | **DONE (2026-10-19)** — `Samen.Web.Notes.Writes` — `insert_block/4`, `update_text/5`, `split/5`, `merge/3`, `move/4`, `indent/4`, `archive/3`/`restore/3`; position gaps + in-transaction rebalance **within a parent** (ADR-053 §8 O2 — the parent is always the doc root in M1, but no clause may assume it); `revision` compare-and-set (stale → `{:error, :stale}`). |
| 2.3 | **DONE (2026-10-19)** — `Samen.Web.Notes.Inline` — the constrained dialect tokeniser + renderer to constructed HEEx (`**bold**`, `*italic*`, `` `code` ``, `~~strike~~`, `[text](https://…)`, `[[Page]]`, `@Name`); unknown syntax literal; **no `raw/1`**. Plus `Samen.Web.Notes.Offset` — the P0 findings §3 helper both the write path and the tokeniser share. |
| 2.4 | `Samen.Web.Notes.Export` — Markdown/CSV rendering that resolves through `Reads` (not the field), so a masked plane exports masks. **NOT in the 2026-10-19 unit** (2.5's export-masking row stays open with it). |
| 2.5 | **PARTIAL (2026-10-19)** — tests for ordering (gaps, rebalance, stale write refused), split/merge at boundaries, type-specific metadata/shape refusal, and the dialect table (every token + every near-miss twin). Export masking remains with 2.4. |

**Gate P2:** `samen_web` suite green; the dialect test table is the spec and every row has a
near-miss twin; sabotage 352 (R9 concurrency) and 353 (R11 unknown type token) flip.

**As built (2026-10-19) — units 2.1/2.2/2.3 + the 2.5 non-export tests. Gate P2 GREEN** for that
scope: `samen_web` green (`notes_inline_test.exs` 37, `notes_reads_writes_test.exs` 36), the
dialect table asserts 13 recognised forms AND 16 near-misses that must stay literal, and **352 +
353 flip and restore byte-exact** (`scripts/sabotage.sh --range 352-353`). Findings and
deviations, recorded rather than silently taken:

1. **Arities follow the framework reads-layer convention**, so the mount and scope are explicit
   (`Reads.page/3`, `merge/3`, `move/4`, `indent/4`) rather than the plan's `page/2`/`merge/2`/
   `move/3`/`indent/3`. `insert_block/4`, `update_text/5` and `split/5` match as planned.
2. **The block `text` column must NOT be trimmed** (a Phase 1 model amendment made here, because
   only this unit could see it). Ash's `:string` trims by DEFAULT, so `" world"` came back as
   `"world"`: a debounced round trip would eat a trailing space (contradicting P0's byte-identical
   echo) and a split at a whitespace boundary would drop it. `DocBlock.text` now declares
   `constraints: [trim?: false, allow_empty?: true]`. The vaulted half never trimmed (it does not
   pass through the string caster), so the vault/plain pair stays symmetric.
3. **A stale CAS rolls the WHOLE transaction back from inside Ash.** The `StaleRecord` becomes a
   `DBConnection` rollback throw that unwinds to `Writes.in_tx/2` — it never reaches
   `cas_update/4`'s own error clause. The classification therefore lives at the transaction
   boundary (`normalize_error/1` + `stale_error?/1`), which is also the correct semantics: a
   refused stale write must leave every other write in that operation unapplied.
4. **A page's block fan-out is explicitly bounded** (`@block_limit 2000`): `reads_lint_test`
   caught the first version as an unbounded read (AC-G1-5) — the gate working as designed. The
   bound is a DoS/row-transfer cap, not a UI page size.
5. **Classification never downgrades on merge**: if EITHER side is vaulted the survivor stays
   vaulted, and a masked operator-plane split/merge is REFUSED (`{:error, :masked}`) instead of
   writing `••••` into content.
6. **The dialect's emphasis forms require non-space edges** (`2 * 3 * 4` stays literal) and
   mentions require a word boundary (`a@b.test` stays literal); both have near-miss rows, so
   loosening either rule is a failing test, not a silent behaviour change.

## Phase 3 — the surface (~2 days)

| Unit | Deliverable |
|---|---|
| 3.1 | `samen_notes_routes/3` in `Samen.Web.Router` + `__routes__(:notes, path)` → `/pages`, `/pages/:id`; `{Samen.Web.TenantAuthz, :require_tenant}` on the `live_session` (the default leg, no exception). |
| 3.2 | `Samen.Web.Notes.IndexLive` + `PageLive` — both `use Samen.Web.Tenant.Live` (page-owned `render/1` is a compile error); tree, breadcrumb, block list, slash palette, move controls. |
| 3.3 | `Samen.UI.NoteBlock` components in the kit (block row, palette, conflict banner, empty state), styled in `samen_ui.css` — no new CSS framework. |
| 3.4 | `pages_path` in `Mount.@label_keys` + `Samen.UI.Nav.nav_paths/2`'s tenant module list; `label_keys_completeness_test` and the nav dead-link guard updated in the same pass. |
| 3.5 | The `NoteBlock` hook in `app.js` registered on `window.SamenHooks` — the §4.1 contract table verbatim; no DOM writes beyond its own `rows`. |
| 3.6 | `tenant_shell_coverage_test` picks up both pages automatically; add any `Page`-specific coverage row it demands. |

**Gate P3:** `samen_web` suite green; both pages render through the wrapper; a keyboard-only pass
(insert → type → split → indent → move → archive) is scripted as a test, not a manual note;
sabotage 354 (R12 `raw/1` introduced in the render path) flips.

## Phase 4 — search and backlinks (~1 day)

| Unit | Deliverable |
|---|---|
| 4.1 | Register `Doc` + `DocBlock` in the host `SearchIndex` over `title`/`text` only; a test asserts `text_secure` registration is **refused** by `SearchIndexGuard` (R14). |
| 4.2 | Block-level search results (page link + snippet from `text`); archived docs excluded (R15). |
| 4.3 | `DocLink` resolution on write (org-scoped), backlink list on the target page, unresolved `[[Title]]` affordance, re-resolution on save, stale-title hint. |

**Gate P4:** search finds a block by its text and does **not** find a vaulted block; a cross-org
title does not resolve (R13 flips under sabotage 355); archived pages vanish from tree, search and
backlinks (sabotage 356).

## Phase 5 — presence, conflict UX, and the masking proofs (~1 day)

| Unit | Deliverable |
|---|---|
| 5.1 | `Samen.Web.Notes.PubSub` — `notes:page:<id>` topic, id-only envelopes, subscribe-on-mount, unsubscribe-on-terminate. |
| 5.2 | `PageLive`'s `handle_info` re-reads the named block through `Reads` (plane-correct), skips `editing_block_id`, and shows the conflict banner on a stale write. |
| 5.3 | The three `Samen.MaskingCase` proofs: green (tenant + operator-with-grant clear), red (operator-without-grant `••••`, DOM-asserted, no `vt_*`), sabotage twin (plane flip clears / a modeled leak is detected). Plus the byte-scan assertion that no `text_secure` plaintext appears in the PubSub envelope or the export. |

**Gate P5:** the masking trio and its refutability twin green; a broadcast into a focused block does
not change its rendered value (sabotage 357); the envelope byte-scan test fails when the envelope
starts carrying text (sabotage 358).

## Phase 6 — hosts, docs, and the milestone gate (~1 day)

1. `samenerp`: `Samenerp.Docs` domain, `ash_domains` entry, migration, `samen_notes_routes`, nav label;
   `demo` second (it already `use`s Docs, so only the migration + route apply). Record both in
   `docs/samenerp-mount-ledger.md`.
1a. `mix samen.docs.materialize` (ADR-053 §8 O3) — the opt-in per-host converter: `body` → one plain
   paragraph block, `secure_body` → one vaulted block **through** `WriteGuard`/`Vault.Change`, nulling
   each column only after the block commits; idempotent (a doc with blocks is skipped and reported),
   exercised against a seeded legacy doc in `demo`. Regression: the per-host task is NOT run by any
   migration, so a host that never invokes it keeps the read-only fallback.
2. `docs/guides/cookbook.md` recipe ("mount the pages surface in a vertical") + a row in
   `docs/README.md`'s guide table.
3. `docs/adr/ADR-053` gets its **as-built** notes appended (the `§x.y as built — and where it
   deviates` shape), and §8's operator decisions stay marked TAKEN with their rationale.
4. Round-2 whole-workstream re-gate.

**Final gate:** `./ci.sh` → `ROOT CI: ALL PASSED`; `scripts/sabotage.sh --range 352-<last>` all flip
and restore byte-exact (backgrounded or chunked — the full harness exceeds the 600 s single-call
ceiling); `samen_core` + `samen_web` + `samenerp` + `demo` suites green with zero warnings.

---

## Sabotage allocation

| # | Red path (ADR-053 §6) |
|---|---|
| 352 | R9 — stale `revision` write applied instead of refused |
| 353 | R11 — `insert_block` accepts an unknown type token |
| 354 | R12 — `raw/1` introduced in the notes render path |
| 355 | R13 — backlink title resolution runs without `OrgScope` |
| 356 | R15 — archive filter dropped (tree, search, or backlinks) |
| 357 | R10 — `editing_block_id` skip dropped (broadcast overwrites the focused block) |
| 358 | R8 — PubSub envelope carries text instead of ids |
| 359 | R1 — page read bypasses `OrgScope` |
| 360 | R2 — block write skips the same-org `doc_id` check |
| 361 | R3 — a block can be re-parented to another doc/org on update |
| 362 | R4 — `parent_doc_id` graft/cycle guard removed |
| 363 | R5 — `text_secure` plane resolution bypassed / hand-masked |
| 364 | R6 — export reads the field instead of the resolver |
| 365 | R7 — `FreeTextScan` removed from `text` |
| 366 | R14 — `SearchIndexGuard` neutered (a `pii_attribute` enters the index) |

## Definition of done

- A member of `samenerp` can create a nested page, type blocks, insert types from the slash menu,
  split/merge/move/indent them with the keyboard, find a paragraph by its text, and follow a
  `[[page]]` backlink — with no page reload.
- An operator without a grant opening the same page sees `••••` on every vaulted block, never
  plaintext, never a `vt_*` token — DOM-asserted, with its refutability twin.
- `text_secure` appears in no search result, no export, no embedding, and no PubSub frame.
- A stale block write is refused with a visible conflict, not silently applied; a broadcast cannot
  overwrite the block being typed into.
- `samenerp`'s authored LOC for the whole surface is the domain module + one migration + one router
  line (the leverage guard's ≈0-LOC claim, re-measured).
- `./ci.sh` green, sabotage range 352–366 green, zero compile warnings.

## Risks, with the mitigation we actually have

| Risk | Mitigation |
|---|---|
| The textarea mechanic fails on a real socket (P0) | P0 is four assertions, not a build; if the caret or the focus-guard cannot hold, escalate D3 before any model code lands |
| Five host migrations drift | one template + probe + parity golden; every migration is additive and reversible |
| Ordinal bugs under concurrent reorder | one writer (`Notes.Writes`), CAS `revision`, idempotent rebalance, and a stale-write test that flips under 352 |
| The dialect grows into a parser project | closed token list, table-driven spec with near-miss twins, unknown syntax literal |
| The hook grows into an editor | the §4.1 contract table is the review rubric; it writes no DOM but its own `rows` |
| Legacy `Doc.body` and blocks disagree | one read seam decides; legacy render is read-only; materialize unit is optional + idempotent |
| Someone reaches for Tiptap and forks the model | `DocBlock` rows stay authoritative; the editor is a view (design §10) |

## Effort (serialized, includes the phase gates)

| Phase | Days |
|---|---|
| P0 mechanics spike | 0.5 |
| P1 model + migrations | 1.5 |
| P2 reads/writes + dialect | 1.5 |
| P3 surface + hook | 2 |
| P4 search + backlinks | 1 |
| P5 presence + proofs | 1 |
| P6 hosts + docs + gate | 1 |
| **Total** | **~8.5** |

Add ~1.5 days if §8 O2 is later revised to *nesting in M1* (toggle/callout containers exercise
`parent_block_id`); add ~3 days if D3 is taken as the Tiptap island instead (toolchain + JS-owned
rendering boundary).
