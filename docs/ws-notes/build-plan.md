# WS-Notes — build plan

**Sizing rule (operator standing order):** SMALL serialized units — **one deliverable per `agent()`
call**, each banking in ~10–20 min, each independently committable and gate-able. Fan-out
concurrency 1. Model routing per unit (`sonnet` = mechanical ports/tests; `opus` = the validator, the
inline renderer, the ordering/revision writes, and every adversarial gate).

**Gate discipline:** every phase ends with an adversarial gate (findings fixed in-phase). All suites
+ the relevant host `ci.sh` green before/after each phase; `./ci.sh` before the milestone. Sabotage
patches numbered from **352** (**351** was the highest shipped before this workstream; **358** is
the highest after P5) and replayed with `scripts/sabotage.sh --range 352-<n>`.

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
| 2.4 | **DONE (2026-10-21)** — `Samen.Web.Notes.Export` + `ExportController` + the `samen_notes_routes/3` mounts: Markdown/CSV/clipboard rendering that resolves through `Reads` (never the field), so a masked plane exports masks. `GET /pages/:id/export.md` (title as the one `#`, blocks shifted down; every block type) and `/export.csv` (`position,type,text,checked`, serialized by `Samen.Web.Csv`); "Copy page" (`Export.copy_text/3` pushed to the requester, `CopyText` hook → `navigator.clipboard`, `Copied` only after the client acks). |
| 2.5 | **DONE (2026-10-21 for the export-masking row; the rest 2026-10-19)** — tests for ordering (gaps, rebalance, stale write refused), split/merge at boundaries, type-specific metadata/shape refusal, the dialect table (every token + every near-miss twin), and now the export-masking proof: `samen_web/test/samen/web/notes_export_masking_test.exs` (19 — downloads, CSV, the clipboard, org scope, the route, legacy pages). |

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

**As built (2026-10-21) — unit 2.4 (the R6 download).** `samen_web` green;
`notes_export_masking_test.exs` (19, including the clipboard half added with **372**) is the proof,
and **sabotages 364 and 372 both flip and restore byte-exact**. Findings and deviations, recorded
rather than silently taken:

1. **The plane is the sabotage's target, not the read seam.** 364 keeps `Reads.page/3` and forges the
   actor it is called with, which is what a real regression looks like here: the renderer is shared,
   so the only way to leak through it is to resolve on the wrong plane. It flips four tests (both
   masking proofs, the route proof, the anti-tautology twin) and leaves the tenant/GREEN halves
   passing — the positive control that proves the failure is the plane, not a broken export.
2. **A download is a second render path, so the mask assertion is over the ARTIFACT body**, not a
   DOM: `assert_masked_dom!/2` runs on the Markdown/CSV bytes (mask present, no plaintext, no
   `vt_*`), with the unvaulted blocks asserted present so a blank or refused download cannot pass.
3. **Markdown escapes stored text (R12's export half).** Block text is text: `&`, `<`, `>` are
   escaped, so a paragraph reading `<script>` downloads as those characters instead of a live tag in
   whichever Markdown viewer opens the file. Nothing is stripped — the export still says what the
   page says — and a fenced `code` block keeps its bytes, since a fence is already a literal context.
   The mask is resolved BEFORE this step, so `••••` is never escaped into or out of anything.
4. **CSV reuses `Samen.Web.Csv.serialize/1`** rather than a second escaper: RFC-4180 quoting for an
   embedded comma/newline and the formula-injection neutralization (`'=1+1`) come from the same
   chokepoint the catalog-driven export uses, and the test round-trips through `Csv.parse/1`.
5. **The routes sit OUTSIDE the `live_session`** (plain controller `get/4` with
   `assigns: %{samen_mount: mount}`), matching the CSV and ICS export controllers — a bare `get/4`
   leaves `conn.assigns[:samen_mount]` nil and every download 503s.
6. **Both planes are served, and the link is on both.** Offering the download only on the tenant
   plane would be posture, not protection: the masked plane's file contains masks, so the honest
   surface is one button whose content depends on the plane (the same rule `Files.Live` follows).
7. **A legacy body is quoted, literal text.** A zero-block page exports its `body`/`secure_body`
   (ADR-053 §8 O3) inside the existing quote form, so its `#` cannot become a second H1 and its
   `<script>` is escaped like any other block text.
8. **Classification is sticky on the edit path — the declassification review (2026-10-21).**
   `Writes.update_text/5` chose the column from the caller's `:secure` option, which defaulted
   `false`, and `PageLive`'s debounced `block_text` passes no option at all: editing a 🔒 block
   wrote its plaintext into `text` and cleared `text_secure`, so one keystroke declassified it, the
   operator plane stopped masking it, and the ciphertext was lost. `keep_classification/2` now
   reads the ROW (a set `text_secure` keeps the edit in the vault) and `:secure` is raise-only.
   Proven at the module and through the real form; sabotage **374** (`vaulted?/1` answers false)
   flips both, while the split/merge stickiness tests stay green because they classify on their own
   path.
8a. **The same rule moved into the MODEL (2026-10-21) — the helper was never the guarantee.**
   `Samen.Scopes.Docs.BlockVault`, an `Ash.Resource.Change` installed on `DocBlock`'s `:update`
   action beside `BlockShape`, refuses any governed write that would clear `text_secure` on a row
   that holds a vaulted value, OR give a vaulted block a plain `text` twin (the vault column is its
   only text). A changeset with no original data cannot clear it either — unknown fails closed. The
   edit path stays open (writing `text_secure` again is how vaulted text changes) and a write that
   touches neither text column is untouched, so ordering churn pays nothing. `docs_scope_test.exs`
   **c10** carries the red paths (loaded clear, bare clear, twin, pure no-data clear) and three
   controls (re-vault accepted, plain-block edit accepted, `position` write on an unloaded row
   accepted); the suite also pins the layer BENEATH the guard — Ash drops a `text_secure: nil`
   change it cannot attribute to a `%Ash.NotLoaded{}` column, so a caller that never selected the
   classification cannot null it by accident. Sabotage **375** (`stored_classification/1` answers
   `:plain`) flips all four reds while 374 still flips the helper's own tests.
9. **The clipboard is the third path, and it got its own proof and its own sabotage.**
   `Export.copy_text/3` shares `load/3` with the downloads but is plain text (no `#`/bullets/fences,
   no HTML escaping — a clipboard is text, so `&lt;` must not be pasted), and the page's "Copy page"
   PUSHES it to the requesting socket (never the topic) for the `CopyText` hook to
   `navigator.clipboard.writeText`. The page only says "Copied" after the client acks. Proven at the
   module (`copy_text/3` bytes) and at the socket (the pushed payload, on a real operator-plane
   socket), plus the   plane flip and the leak-scan refutability; **372** forges the copy's plane and
   flips exactly those three tests while every download test stays green, and **364**
   (re-anchored) still flips the downloads. Each way out has its own gate because each
   is its own leak.
10. **Leaving the vault is a named action, not a flag (2026-10-21).** `BlockVault` shuts the
   ordinary edit path on purpose; without a sanctioned exception, "a block never leaves the vault"
   would also mean content that was over-classified at authoring can never be corrected. So the
   door is `DocBlock.:declassify_text` (`Samen.Scopes.Docs.BlockDeclassify`): a DIFFERENT action
   from `:update`, so `BlockVault` needs no exception and no edit path can reach it. It accepts no
   attributes — the plaintext it writes to `text` is the vault's own, revealed server-side and bound
   to the block's subject — requires a `reason`, refuses an operator-plane actor, bumps
   `revision`, re-enters `FreeTextScan` (a bare-email vaulted value cannot be laundered into the
   plain column), and writes its `aud_event` + chain row in the SAME transaction (an unauditable
   declassify fails). The role gate is policy: `RoleAtLeast, role: :admin`, additive to the broad
   update policy (`Identity.Invitation.:revoke` precedent), so a member may still edit the page but
   cannot change what it stores at rest. Proven at the model in `docs_scope_test.exs` c11 — member
   denied (row vaulted, no audit row), admin control succeeds with one audit row naming block,
   actor, revision and reason and carrying no text, plain block / operator plane / bare-email value
   all refused; **376** drops the role gate and flips exactly the member denial, **377** makes the
   audit writer a no-op and flips the audited control.
11. **The door has a form, and the surface never adopts the role gate's answer as the guarantee
   (2026-10-21).** A model-only exit would leave the editor's only way out a console command, so
   `PageLive` renders ONE control on a vaulted block — “Move out of the vault” — which opens
   `NoteBlock.note_declassify_form/1`: a reason textarea and a submit, no value on screen. The form
   posts `declassify_block`, whose write goes through `Writes.declassify/4` with
   `TenantRole.admin_scope/2` (the REAL membership role on an armed host — `Mount.scope/2`
   fabricates `:member`, so a role check on it would gate nothing) and returns `:forbidden` /
   `:no_reason` as distinct refusals. Whether the control is OFFERED is decided by the same
   `admin_scope/2` + tenant-plane check, and that decision is only posture: the member and operator
   red paths drive what the model does with a crafted event. Proven in
   `notes_declassify_ui_test.exs` through the real router (admin: control → form → clear text, the
   control gone, DB + `aud_event` agree; member on an ARMED host: no control, crafted event
   refused, ciphertext byte-identical, no audit; operator plane: `••••`, no control). The ARMED
   ADMIN leg is driven with a REAL membership too — `Register`/`Invite` (the S1a harness shape) put
   the principal in the org at `:admin`, and `TenantRole` resolves it through the notes mount's
   `:identity_namespace` seam (wired in the security host exactly as samenerp's shared label map
   wires it; without the seam an armed module mount fails CLOSED to `:member`). The paired real
   `:member` drives the same route and gets no control plus a refused pushed event. **378** drops
   the surface's role gate and flips both member denials, while the model's own refusals (376) stay
   green. And because the seam is what makes the control reachable at all, an ARMABLE tenant mount
   without it no longer compiles at all — for notes AND the other admin-rank surfaces
   (`:billing`/`:marketing`/`:support` module routes, `samen_flags_routes/3`,
   `samen_tenant_analytics_routes/2`, `samen_chat_routes/3`; the list is `@identity_seam_surfaces`).
   The refusal names the dead capability and the fix; `identity_seam_compile_guard_test.exs` proves
   it per surface with the legitimate shapes as controls, and **379** neutralises the guard. The
   check runs in the quoted module body, so a `@current_org_labels` attribute is seen through —
   which is why the four real host apps still compile unchanged.

## Phase 3 — the surface (~2 days)

| Unit | Deliverable |
|---|---|
| 3.1 | **DONE (2026-10-19)** — `samen_notes_routes/3` in `Samen.Web.Router` + `__routes__(:notes, path)` → `/pages`, `/pages/:id`; `{Samen.Web.TenantAuthz, :require_tenant}` on the `live_session` (the default leg, no exception). The macro threads `:pages_path` itself, so mounting it IS the nav/dead-link bookkeeping. |
| 3.2 | **DONE (2026-10-19)** — `Samen.Web.Notes.IndexLive` + `PageLive` — both `use Samen.Web.Tenant.Live` (page-owned `render/1` is a compile error); tree, breadcrumb, block list, slash palette, move controls. |
| 3.3 | **DONE (2026-10-19)** — `Samen.UI.NoteBlock` components in the kit (block row, palette, conflict banner, empty state), styled in `samen_ui.css` — no new CSS framework. `NoteBlock.types/0` delegates to `BlockShape.types/0`, so the palette cannot drift from the model's closed vocabulary. |
| 3.4 | **DONE (2026-10-19)** — `pages_path` in `Mount.@label_keys` + `Samen.UI.Nav`'s tenant module list (inside the existing Documents group); `label_keys_completeness_test` and the nav dead-link guard updated in the same pass. |
| 3.5 | **DONE (2026-10-19)** — The `NoteBlock` hook in `app.js` registered on `window.SamenHooks` — the §4.1 contract table verbatim; no DOM writes beyond its own `rows`. |
| 3.6 | **DONE (2026-10-19)** — `tenant_shell_coverage_test` picks up both pages automatically; no `Page`-specific row was demanded. |

**Gate P3:** `samen_web` suite green; both pages render through the wrapper; a keyboard-only pass
(insert → type → split → indent → move → archive) is scripted as a test, not a manual note;
sabotage 354 (R12 `raw/1` introduced in the render path) flips.

**As built (2026-10-19) — units 3.1–3.6. Gate P3 GREEN for that scope.** Tests:
`notes_surface_test.exs` (10) and `notes_keyboard_test.exs` (3) drive the REAL router + endpoint
(`SecurityEndpoint`), plus `nav_path_roundtrip_test`, `tenant_shell_coverage_test`,
`label_keys_completeness_test`, `crumbs_test` and the nav-links verifier (35 tests across the last
five files). **354 flips** (`a legacy body … can never become markup`) and restores byte-exact; 321
re-anchors and still flips. Findings and deviations, recorded rather than silently taken:

1. **The keyboard pass is driven through the socket, not a browser.** The `phx-hook` body is
   shipped, but `samen_web` still has no webserver adapter (P0 finding 3), so the test delivers the
   hook's events with `render_hook` on the element that carries it. The browser-only half — that a
   real keydown reaches `pushEvent` — remains the P0 finding's unmeasured line; the contract the
   hook must satisfy (an id plus an offset or direction token, never block text) is what the test
   pins.
2. **The hook registers AFTER the `LiveSocket` is constructed.** That is safe (and was checked
   against the vendored LV 1.2.12 source): `this.hooks = opts.hooks` is a REFERENCE, no copy, so a
   property added later is visible. Reordering it earlier would have been cosmetic.
3. **The Documents nav group gained a Pages item, which shifted sabotage 321's anchor AND widened
   the group its defect deletes.** The re-anchor keeps the defect (the whole Documents group goes,
   Files AND Pages become nav islands) and the MUST_FAIL target identical; the context was widened
   to the Marketing group above because the original 3-line leading context also occurs right
   before the surviving Workspace group, which made the deletion-only hunk reverse-apply cleanly
   and the residue preflight (correctly) call the tree dirty. A narrower anchor cannot distinguish
   "not applied" from "applied" for a pure deletion; the widened one can.
4. **The editor's only write on `phx-change` is the block text**; structural intents are separate
   events carrying bounded tokens, so a crafted `insert_block` can name only a type the model
   already validates (R11), and every text write carries the revision the client saw (R9).
5. **`PageLive` shows the legacy body only when `Reads` says the page has zero blocks.** That is
   the one place the inline dialect runs in the editor, which is why 354 aims there: a `raw/1`
   shortcut in the block renderer would have been masked by the textarea branch.

## Phase 4 — search and backlinks (~1 day)

| Unit | Deliverable |
|---|---|
| 4.1 | **DONE (2026-10-19)** — `Samen.Web.Notes.Search.register_index/2` registers `Doc.title` + `DocBlock.text` in the host `SearchIndex` over `title`/`text` only; a test asserts `text_secure` registration is **refused** by `SearchIndexGuard` (R14), with the plain columns as the positive control. |
| 4.2 | **DONE (2026-10-19)** — block-level search results (page link + snippet from `text`) via `Notes.Search.search/4`; a vaulted block is dropped even if a plain column is also set; archived docs excluded through the explicit live-page JOIN (R15). The index surface renders the hits and states the vault trade-off. |
| 4.3 | **DONE (2026-10-19)** — `DocLink` resolution on write (org-scoped `Links.resolve_all/3`), backlink list on the target page, unresolved `[[Title]]` affordance (create-on-click), re-resolution on save, stale-title hint. The reconcile is a set operation inside the writing transaction. |

**Gate P4:** search finds a block by its text and does **not** find a vaulted block; a cross-org
title does not resolve (R13 flips under sabotage 355); archived pages vanish from tree, search and
backlinks (sabotage 356).

**As built (2026-10-19) — units 4.1–4.3. Gate P4 GREEN for that scope.**
`notes_search_links_test.exs` (13) covers guarded registration, block + title hits, vaulted-block
exclusion, org isolation, archived-page exclusion from all three views, cross-org resolution,
stale-then-re-resolve, and the unresolved-affordance click through the REAL router; the existing
Notes suites (102 tests) stay green. **355 and 356 both flip and restore byte-exact.** Findings and
deviations, recorded rather than silently taken:

1. **The registry lives in the host's PRIMITIVES namespace, not the Docs one.** `samen_notes_routes`
   receives the Docs namespace, which has no `SearchIndex` resource, so search resolves the module
   from a `:search_index` mount-label seam (threaded by the macro and whitelisted in `Mount`). An
   absent seam is fail-closed (`[]`, registration refuses) — never a guessed module. This is the
   same seam shape as `identity_namespace`; it rides the signed session as a compiled module atom.
2. **Registration writes with `authorize?: false`.** `SearchIndex`'s create policy is
   `RoleAtLeast :admin`, but registration is HOST SETUP (the same posture as the hosts'
   `mk_search_index/1` seed helpers), not a member's page action. The check that carries the
   security guarantee is `SearchIndexGuard.assert_no_pii_column/2`, which runs BEFORE the write for
   both fields.
3. **`vector_column` is the convention name (`<abbrev>_search_vector`), not a required physical
   column.** `Samen.Search` builds the tsvector at QUERY time over the registered non-PII fields;
   Docs adds no migration for its own GIN/trigger (the File precedent remains the index-backed
   one). Recorded here so it is not mistaken for a populated column.
4. **A page's blocks are NOT archived with the page.** The kernel engine therefore returns a block
   whose DOC is archived; search adds an explicit live-page JOIN (`live_docs/3`, an org-scoped,
   archive-filtered `Doc` read) and drops any hit whose page is absent. That join is the R15 leg
   sabotage 356 targets — the tree and backlink legs rely on AshArchival's read preparation and are
   asserted separately in the same test.
5. **Only the PLAIN `text` creates link edges and search snippets.** `text_secure` never enters the
   index (guard) and `Links.page_titles/3` parses only `text`. A vaulted block must not leak through
   a non-PII `DocLink` row visible on the target page; that is a deliberate narrowing beyond the
   plan's "title/text only", and the tests pin it.
6. **Link reconciliation is a SET operation inside the write transaction:** every text/structure
   write calls `Writes.sync_links/3`, which resolves all page titles, keeps existing rows (refreshing
   `anchor_text`), destroys stale ones and creates missing ones. A rename therefore leaves a stale
   hint until the source is saved, and that save drops the link if the typed title no longer resolves
   — the documented M1 behaviour, not a background re-index.
7. **The index surface is `IndexLive`'s `?q=` mode**, not a second LiveView: it uses the same route,
   the same one read seam (`Notes.Search`), and renders an honest empty state plus the explicit
   "vaulted blocks are not searchable" note. Block hits deep-link to `#note-block-<id>`.

## Phase 5 — presence, conflict UX, and the masking proofs (~1 day)

| Unit | Deliverable |
|---|---|
| 5.1 | **DONE (2026-10-19)** — `Samen.Web.Notes.PubSub` — `notes:page:<id>` topic, id-only envelopes, subscribe-on-mount, unsubscribe-on-terminate. |
| 5.2 | **DONE (2026-10-19; R8 subscriber half 2026-10-21)** — `PageLive`'s `handle_info` re-reads the named block through `Reads` (plane-correct), skips `editing_block_id`, and shows the conflict banner on a stale write (the banner itself shipped with P3). The skip DEFERS: the id is recorded and re-read on blur. R8's consequence is now proven on TWO REAL SOCKETS (a tenant tab and an operator tab through the real router): one broadcast, each tab re-reads on its own plane, for both the block and the structure envelope (sabotage **373**). |
| 5.3 | **DONE (2026-10-19; export 2026-10-21)** — The three `Samen.MaskingCase` proofs: green (tenant + operator-with-grant clear), red (operator-without-grant `••••`, DOM-asserted, no `vt_*`), sabotage twin (plane flip clears / a modeled leak is detected). Plus the byte-scan assertion that no `text_secure` plaintext (and no `vt_*` token) appears in the PubSub envelope. The **export** half of the same proof ships with unit 2.4 (`notes_export_masking_test.exs`, sabotages **364**/**372**), and the realtime half's per-subscriber plane proof is 5.2's sabotage **373**. |

**Gate P5:** the masking trio and its refutability twin green; a broadcast into a focused block does
not change its rendered value (sabotage 357); the envelope byte-scan test fails when the envelope
starts carrying text (sabotage 358).

**As built (2026-10-19) — units 5.1–5.3. Gate P5 GREEN for that scope.**
`notes_realtime_masking_test.exs` (11) drives the REAL router + endpoint (`SecurityEndpoint`): two
live sockets on one page, a focus/typing/blur sequence, a split's two block envelopes + one
structure envelope, the closed envelope key set, and the four-plane masking proofs. `samen_web`
green; **357, 358 and (since 2026-10-21) 373 flip and restore byte-exact**
(`scripts/sabotage.sh --range 357-358`, `--range 373-373`).
Findings and deviations, recorded rather than silently taken:

1. **The wave required a MODEL addition: `Doc` and `DocBlock` declare reveal actions.**
   `Samen.Api.PiiResolution.operator_granted?/6` refuses to operator-reveal a resource with no
   declared `reveal` action ("a resource with no declared reveal action can never be
   operator-revealed"), so the trio's GREEN half — operator-WITH-grant reads the vaulted paragraph
   clear — was **impossible by construction** for the Docs scope as shipped. Landed in
   `Docs.Blueprint`: `reveal(:reveal_secure_body)` on `Doc`, `reveal(:reveal_text_secure)` on
   `DocBlock`, each with the Primitive notifications/webhook reveal action shape (an
   actor-carrying request answered by `Samen.Reveal.grant_checker/0`, returning a STATUS — never
   the plaintext) and its `authorize_if(always())` policy. No migration (an action is not a
   column). Without this, 5.3's first row could only have been written as a deviation.
2. **The skip DEFERS rather than drops.** `handle_info({:block_changed, …})` for the focused block
   stores `deferred_block_id`; `blur_block` re-reads that block. The test asserts both halves (the
   focused value is unchanged after the remote write, and blur applies it), so a "skip forever"
   implementation would fail the second assertion. 357 flips the first by re-reading immediately.
3. **`block_text` broadcasts only the block envelope; structural writes broadcast both.** A text
   edit does not bump `Doc.revision` (P2's decision), so it must not send a structure signal — a
   structure reload would defeat the `editing_block_id` skip wholesale. Split/merge/insert/move/
   indent/toggle/archive publish the changed block(s) AND `{:page_structure_changed, doc_id,
   revision}`; the writer's own view takes one extra reload from its own structure broadcast
   (idempotent read; no write loop, since a reload never writes).
4. **The envelope's key set is the assertion, not the prose.** R8 is "ids and revisions only"; the
   test asserts `Map.keys(payload) |> Enum.sort() == [:block_id, :revision]` (and
   `[:doc_id, :revision]` for the structure envelope) plus `:erlang.term_to_binary/1` scans for the
   plaintext and for `vt_`. The plaintext scan is vacuously safe *by construction* (`%Samen.Masked{}`
   carries no plaintext), which is exactly why the token scan is there too: a vaulted block's struct
   holds a `%Masked{}` with a `vt_*` token, and sabotage 358 ships it on the wire.
5. **The realtime path re-pointed P3's stale-write test at the focused client.** Once a broadcast
   patches every NON-focused block, a socket sitting in the same block can no longer be made stale
   by an external write — the write patches it and the DOM's `block_revision` moves with it (the
   `LiveViewTest` form API then refuses to submit the old value at all). So the test now plays the
   client that is genuinely stale: it FOCUSES the block first, the remote write is deferred (R10),
   the DOM keeps the old revision, and the submit is refused with the banner. The rewrite is
   stronger than what it replaced, not weaker: it fails if the deferral is dropped (sabotage 357)
   *and* if the CAS is dropped (352, through the write seam's own test).
6. **A test that leaves a broadcast queued at teardown poisons a NEIGHBOUR test's connection.**
   Every notes write now fans out to subscribed sockets, so a test that writes and then ends still
   has a `handle_info` re-read in the socket's mailbox; the process outlives the test body, the
   sandbox owner exits mid-query, and Postgrex disconnects the shared protocol — surfacing as an
   unrelated test's `connection is closed` failure (observed once in a full `samen_web` run). The
   discipline is one synchronous `render/1` after the last write (or `drain/1` in the realtime
   test); it is written down because the failure it prevents does not name the test that caused it.
7. **The test host threads `:pubsub` explicitly.** `Samen.WebTest.SecurityRouter` names
   `Samen.WebTest.PubSub` on the notes mount's `:pubsub` label (the host-fact seam chat and
   notifications already ride; `test_helper.exs` starts that server once for the VM). A host that
   mounts `samen_notes_routes/3` without the label gets `Driftwood.PubSub` — the documented
   framework default — and the P6 mount note must say so.
8. **A failed broadcast never loses data and never raises.** `subscribe/broadcast/unsubscribe` are
   best-effort (`:ok | {:error, term}`, rescued), so a dead-rendered socket or a seed without a
   running PubSub still renders and still writes; the write is committed before the broadcast.

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

**As built (2026-10-20) — unit 1 for samenerp only; P6 is PARTIAL.** `samen_notes_routes(:notes,
Samenerp.Docs, repo:, search_index: Samenerp.Primitives.SearchIndex, labels: @current_org_labels)`
serves `/pages` + `/pages/:id` through the host endpoint, and the shared `:pages_path` label is what
carries Documents → Pages onto every other tenant page (the macro's own label only rides its mount).
Proof: `samenerp/test/notes_surface_mount_test.exs` (5, real router, incl. another org's page id
rendering `Page not found`), plus Documents → Pages in `nav_reachability_test.exs`, plus
`mix samen.verify.nav_links` green. **`demo` is deliberately NOT mounted** — its API-only posture
(`Demo.DocsScope`'s moduledoc) makes a tenant LiveView there a posture change, not a one-liner.
**Unit 1b — search actually answers (2026-10-20).** `Samenerp.Seeds.ensure_notes_search_index!/1`
registers `Doc.title` + `DocBlock.text` through `Notes.Search.register_index/2` (guard-first), is
called from `seed_notes_pages!/1` and from `seed!/0,1` OUTSIDE the `already_seeded` short-circuit (a
re-run repairs a missing row), and `seed_notes_pages!/1` seeds the demo page (two plain blocks + one
vaulted) — reached from `mix samenerp.seed` in `MIX_ENV=dev` only, so a checkout demonstrates a hit
while the release entrypoint's direct `Seeds.seed!()` call registers the index and seeds nothing.
Proof: `samenerp/test/notes_search_test.exs` (5) drives `GET /pages?q=…` through the real
router — a plain block is a block hit with a deep link, `?q=vaulted` is the honest empty state with
the vaulted plaintext absent from the body AND a positive control proving the same page answers for
its plain block, the registry is exactly the two non-PII fields (idempotent), `SearchIndexGuard`
refuses `text_secure`, and another org's page is not searchable from here (positive control: it is a
hit from the org that owns it). Adversarial twin: sabotage **368** drops the seed's registration
call → the "found by its plain block text" test flips, restore byte-exact.

**Unit 1c — provisioned at CREATION, not only by the seeder (2026-10-21).** Unit 1b fixed search
for the org the seeder knew about, which left the real gap open: every tenant org created afterwards
— self-serve `/signup`, or an operator's New-account write — got no registry rows, so its
`/pages?q=` answered the fail-closed empty state forever. Registration now ALSO runs on the
creation path through the framework seam `Samen.Web.OrgProvisioning`
(`config :samenerp, :org_provisioning, [{Samenerp.Seeds, :ensure_notes_search_index!, []}]`, called
as `apply(mod, fun, args ++ [org_id])`): `Samen.Web.Auth.AccountController.register/2` after the A1
transaction commits, and `Samen.Web.Operator.AccountsLive.save_new`. The seam is NON-FATAL (the org
row is already committed — a registry hiccup is not "signup failed") and LOUD (`{:error, [{mod,
fun, reason}]}` plus a `Logger.error` per failure; a raise or an unexpected return counts as a
failure). `Samenerp.Seeds.backfill_notes_search_index!/0`, called by `seed!/0,1` on EVERY boot, is
the deploy half: orgs that predate the wiring are repaired on the next release. Proof:
`samenerp/test/notes_org_provisioning_test.exs` (4 — a real `POST /signup` through the router, the
new org's rows, its own block as a genuine hit, the backfill, and a directly-created org as the
anti-tautology control) + `samen_web/test/samen/web/org_provisioning_test.exs` (4 — unwired =
no-op, the operator path fires for the org that write created, and every failure shape is reported
rather than raised). Adversarial twins: sabotages **369** (host config line removed), **370**
(operator path drops the call) and **371** (signup path drops the call).

Still open: 1a (`mix samen.docs.materialize`), 2 (cookbook recipe + README row), 3 (ADR as-built —
§3.3 now covers the host mount, the search registration, and its creation-time provisioning), 4
(round-2 re-gate).

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
| 364 | R6 — the download resolves the page on the WRONG plane (a masked operator-plane export carries plaintext); the read seam itself is left intact |
| 372 | R6 (clipboard half) — "Copy page" resolves on the tenant plane regardless of who is asking, so the masked operator's clipboard gets the plaintext; the download tests stay green |
| 373 | R8 (subscriber half) — a receiving tab re-reads the broadcast on the TENANT plane (`refresh_block/2` and the structure reload), so an operator tab paints plaintext from a colleague's edit while every envelope test stays green |
| 374 | R5 / D5 — classification is not sticky: `vaulted?/1` answers false, so an ordinary edit (the `block_text` form) writes a 🔒 block's plaintext into `text` and clears `text_secure` |
| 376 | R17 / D5 — the declassify action's `RoleAtLeast, role: :admin` gate is dropped, so a `member` can move a 🔒 block's plaintext into the plain column and clear the vault |
| 377 | R17 / D5 — the declassification audit writer becomes a no-op: the block still leaves the vault, but no `aud_event` row records who did it, to which revision, or why |
| 378 | R17 / D5 (surface half) — `PageLive.can_declassify?/2` drops its admin-rank clause, so on an ARMED host every member is offered the vault-exit control and its reason form; the model's policy is left intact, so the crafted write is still refused |
| 379 | R17 / D5 / ADR-045 §4.4 (wiring half) — the compile guard goes inert (`armable?` is `false`), so an armable tenant host that forgets `:identity_namespace` compiles quietly and ships dead admin-rank capabilities (vault exit, billing, campaign/KB writes, flag toggles, the analytics role gate, the disclosure flip); the disarmed/member-rank/operator exemptions were never guarded, so only the three refusal probes flip |
| 375 | R16 / D5 (model half) — `BlockVault.stored_classification/1` answers `:plain`, so the governed write path accepts a `text_secure` clear (or a plaintext twin) on a vaulted block; the helper's own stickiness is left intact, so this is the layer BELOW 374 |
| 365 | R7 — `FreeTextScan` removed from `text` |
| 366 | R14 — `SearchIndexGuard` neutered (a `pii_attribute` enters the index) |
| 368 | host wiring (outside the R-numbering) — `samenerp` seeds seed the page but skip `register_index`, so a mounted surface answers `?q=` with the empty state while every other test stays green (367 is the `samen_core` boot-verifier twin) |
| 369 | host wiring (unit 1c) — the `:org_provisioning` config line is removed, so a NEW org (created by signup or by the operator plane) is never registered and its `/pages?q=` is silently empty while every other test stays green |
| 370 | host wiring (unit 1c) — the OPERATOR creation path drops the `OrgProvisioning.run/2` call: a sales-assisted account exists and lists, but its Pages search never answers |
| 371 | host wiring (unit 1c) — the SELF-SERVE path drops the `OrgProvisioning.run/2` call: signup still succeeds and every other signup assertion passes, but the org's own block is not findable |

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
