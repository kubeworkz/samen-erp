# ADR-052 — Masked session replay: record references, never values (Lane B), with `phoenix_replay` confined to a dev probe (Lane A)

- **Status:** **PROPOSED (2026-10-17)** — design complete; the five decisions in **§8** carry a
  recommendation each and are **all OPEN**. Nothing here is ratified, and the point of filing it
  now is that no Lane B code may land until they are. The build plan's Phase 4.4 ("the decision
  record written from what shipped") is deliberately **superseded**: this record is authored
  *ahead* of the build so its invariants bind the first line of code, not the last.
- **Date:** 2026-10-17
- **Build status:** **Lane A (the P0 `phoenix_replay` spike) BUILT 2026-10-17. Lane B NOT
  STARTED — zero code.** The spike lives where it cannot ship: `{:phoenix_replay, "~> 0.6",
  only: :dev}` in `driftwood/mix.exs`, `elixirc_paths(:dev) -> ["lib", "dev_only"]` (outside
  `lib/` on purpose — `elixirc_paths` recurses, so `lib/dev_only/` would still compile in
  `:test`/`:prod`), the dashboard router forwarded behind a compile-time-false branch, and
  `driftwood/test/replay_dev_only_test.exs`'s four tests asserting the dep, the module, the route
  and the config key are all absent outside dev. Lane B has no `Samen.Replay.*` module, no replay
  scope, no migration, no abbrev-registry row, and no sabotage patch of its own (the highest in
  the tree is **349**, the ADR-index gate's — not Lane B's).
- **Task:** the operator question is *"what was on their screen when it broke?"*. Today's Replay
  answers a smaller one — *"which surfaces did they open, in what order"* — and cannot answer the
  question actually asked in a support thread. Adopting a stock recorder to close that gap would
  create **the largest plaintext store in the system**, outside `Samen.Pii.WriteGuard`, outside
  `no_plaintext_pii`, outside crypto-shred, viewable without a reveal grant.
- **Deciders:** the operator, for **§8 D1–D5**. The two genuine tradeoffs are (a) whether a
  **tenant admin** (not only an impersonating operator) may replay its own org's sessions, and
  (b) whether a replay shows **current** field values or must carry history. This record
  recommends an answer to both; it does not take them.
- **Consumes (binding inputs):**
  - **ADR-021** — the product-event ledger (`<abbrev>_product_event`): closed prop schema,
    PII-refusing value oracle, per-subject HMAC `actor_ref`. The existing `nav.visited` replay is
    this ledger's only reader; this ADR adds a *second kind of record*, not a second ledger.
  - **ADR-015** — default-deny CDC/aggregate classification. Its
    `Samen.Cdc.Projection.classify_columns/2` is reused **verbatim** as the allowlist for
    non-vault-routed record attributes (§2.3 rule 2), so a freeform column cannot be mirrored
    into a replay by forgetting to flag it twice.
  - **ADR-020** — the flag engine: `Samen.FeatureFlags.evaluate/3`, deterministic bucketing,
    non-PII targeting keys, fail-safe kill switch. Capture is off unless the flag says otherwise
    (§2.4).
  - **ADR-046** — erasure completeness. A reference-only store inherits erasure **for free**: the
    `Ref` names a vaulted attribute, so key-shred makes it unresolvable (§2.5). No
    replay-specific deletion path is written.
  - **ADR-038 §5.5** — the masking watch-list discipline. A replay player is a surface rendering
    vault-routed fields, so it ships the three proofs via `Samen.MaskingCase` (§6).
  - **ADR-042** — LiveView client adoption. Capture is connected-mount only, so a Class B (no-JS)
    tenant has no recording; the existing recorder already takes that posture
    (`Samen.Web.Replay.record_visit/2` records only `connected?`).
  - **ADR-014** — fail-honest adapters/stubs: the sanitizer's first form raises
    `:not_implemented` rather than returning `{:ok, frame}` for work it does not do.
- **Inspiration, not a dependency:** `phoenix_replay` v0.6.2 (Hex, MIT, by Danila Poyarkov). Its
  capture *shape* is taken — an `on_mount` hook plus `handle_params`/`after_render` hooks, the
  `:handle_event, :start` telemetry (so even halted events are seen), a per-process buffer
  finalized on exit, a dashboard that re-renders the view with rebuilt assigns. Its **storage and
  privacy model is refused**, and Lane B shares no code and no table with it.
- **Long-form design:** [`docs/ws-masked-replay/design.md`](../ws-masked-replay/design.md) ·
  **execution:** [`docs/ws-masked-replay/build-plan.md`](../ws-masked-replay/build-plan.md).

---

## 1. Context

### 1.1 What Replay is today — honest, cheap, and state-blind

`Samen.Analytics.Replay.record_visit/1` writes exactly one governed catalog event, `nav.visited`,
whose closed prop schema is `%{"surface" => token}`. The surface is a **bounded token** derived
from the LiveView module (`BrokerLive` → `"broker"`, `~r/\A[a-z][a-z0-9_]{0,63}\z/`); anything
else — a path, a URL, an id, a `vt_*` token — is refused as `{:error, :unbounded_surface}`, never
coerced. The actor is the ledger's HMAC pseudonym. `Samen.Web.Replay.record_visit/2` attaches that
call to the tenant mount hook every framework tenant route already carries, so adoption is
inherited rather than remembered.

`Samen.Web.Operator.ReplayLive` (`/operator/replay/:org_id`) plays it back as a step list behind a
reason-required, short-TTL `Samen.Impersonation` session, and says on the page that it is a step
list. That design is the moat: there is nothing to mask because nothing sensitive is written. It
is also the ceiling: no assigns, no state, no event payloads.

### 1.2 Why `phoenix_replay`'s model cannot be adopted here

`phoenix_replay` records **LiveView state and events** and re-renders with the recorded assigns.
On this foundry that is fatal, for a reason that is structural rather than a matter of care:

- Tenant-plane LiveViews resolve rows through `Samen.Api.PiiResolution` **before** they land in
  assigns, so recorded assigns are **plaintext by the time the recorder sees them**.
- Form events carry what the user typed *before* any vault write — the pre-chokepoint value.
- Its default file backend writes compressed term files next to the app (the P0 spike confirmed:
  no table, no migration, `priv/replay_recordings`, package-managed retention). An uncatalogued
  table would be no better.

Either store is a plaintext archive of exactly the data the vault exists to keep out of Postgres.
`mix samen.verify.no_plaintext_pii` would be right to fail it, and a sanitizer bolted onto that
storage boundary starts from the wrong side (§1.4).

### 1.3 What already exists to build on

This is not a from-scratch feature; every primitive the design needs is shipped:

| Need | Existing seam |
|---|---|
| resolve a vaulted attribute on a plane | `Samen.Api.PiiResolution` |
| decide whether a column is projectable at all | `Samen.Cdc.Projection.classify_columns/2` (ADR-015) |
| decide whether a bare value is PII-shaped | `Samen.PiiValueShape.classify_value/1` |
| opt-in, deterministically, per org | `Samen.FeatureFlags.evaluate/3` |
| bound retention | `Samen.Retention` spec + sweep worker |
| gate an operator per tenant, with a reason | `Samen.Impersonation.active?/3`, `scope/3`, the `ReplayLive` gate |
| make an actor unlinkable on shred | `Samen.WideEvent.for_subject/2` |
| proof shape for a masking surface | `Samen.MaskingCase` (ADR-038 §5.5) |

### 1.4 The asymmetry that decides everything

A **sanitizer at the storage boundary is a blocklist**: it has to guess every future shape a value
can take, and it fails open on the shape nobody imagined. **Reference-only capture is an
allowlist**: a raw value has nowhere to be written, and an unrecognised shape is dropped rather
than serialized "just in case". Only the second survives a new scope, a new field, or a host that
assigns something new — which is why the decision below is a vocabulary, not a filter.

## 2. Decision

Replay becomes two lanes that share no code and no table, and the product lane records
**references and shapes, never values**, resolving them at view time on the viewer's plane.

### 2.1 Two lanes, and which is a dependency

- **Lane A** — `phoenix_replay` as an **engineer's tool**, `:dev` only, seeded fake data,
  compiled out everywhere else, never pointed at a tenant org in a deployed environment. **Built
  (P0).** It is not a product surface and nothing in Lane B depends on it.
- **Lane B** — first-party `Samen.Replay`: reference-only capture, viewer-plane resolution, inert
  re-render, governed access. The rest of this record.

### 2.2 The capture vocabulary — three terms and a closed world

| Term | Means | Rendered as |
|---|---|---|
| `%Samen.Replay.Ref{resource, pk, attribute, label}` | a vault-routed attribute of an Ash record: the **pointer** replaces the value at capture | resolved at view time on the **viewer's** plane |
| `%Samen.Replay.Redacted{kind, length}` | a value deliberately not kept (`:string`, `:free_text`) | shape only: `"•••• (42 chars)"` |
| `%Samen.Replay.Placeholder{kind}` | a reference that cannot be resolved **now** (`:shredded`, `:gone`, `:denied`) | an explicit gap, never a blank |

Everything else is a bounded type: numbers, booleans, dates, decimals, ids, atoms from closed
sets, and maps/lists that recurse. Anything outside the vocabulary becomes
`%Redacted{kind: :dropped}`; it is never stringified.

**Frames** are `:mount` (the assign map at mount, sanitized), `:params` (shape only),
`:render` (changed assigns), `:event` (event name + per-param shape), and `:info` (message **tag**
only). No DOM, no HTML, no screenshots, no client JS channel in v1.

### 2.3 The allowlist (six rules)

1. **Vault-routed attributes become `Ref`s.** Decided from the resource's PII metadata
   (`pii_*` / `Samen.Type.VaultField` declarations) — never a name heuristic.
2. **Other record attributes** are kept only if `Samen.Cdc.Projection.classify_columns/2` would
   project them (ADR-015 default-deny, reused verbatim). Freeform columns →
   `Redacted{kind: :free_text, length: n}`.
3. **Bare strings are dropped** unless the assign key is on the view's declared keep-list
   (`:page_title`, `:tab`, `:sort`, `:page`), and a keep-list entry must itself pass
   `Samen.PiiValueShape.classify_value/1` — a keep-list cannot smuggle an email.
4. **Event params** carry key, type, length and class; values only for keep-listed keys.
5. **The actor** is stored only as the wide-event HMAC pseudonym
   (`Samen.WideEvent.for_subject/2`), so erasure makes a replay unlinkable for free.
6. **`%Samen.Masked{}`** is kept as-is — it carries a token, never plaintext.

### 2.4 Storage: two resources, opt-in, capped, expiring

Two framework-owned resources in a replay scope, `jsonb` payloads so the existing DB tiers and
the destruction oracle can scan them:

- `Replay.Session` — org, actor pseudonym, view module + MD5 (code-drift marker), started/ended,
  frame count, byte count, `truncated?`, redaction counts.
- `Replay.Frame` — session ref, index, kind, occurred_at, sanitized payload.

Capture is off by default, **opt-in per org** via
`Samen.FeatureFlags.evaluate("samen.replay", %{org_id: org})` plus a sample draw. Caps: max
frames/session, max bytes/session, max sessions/node; TTL through `Samen.Retention` (default 14
days, bounded max). **Only sessions with at least one user interaction persist**, so passive page
loads do not fill the table. Abbreviations are allocated through `mix samen.abbrev.reserve` at
build time — never hand-edited (ADR-023).

### 2.5 Resolution at view time, on the viewer's plane

Because nothing plaintext is stored, the player **must** resolve on read:

| Situation | Rendered |
|---|---|
| operator without a grant | `%Masked{}` → `••••`, never a `vt_*` token in the DOM |
| operator with a live reveal grant on that subject | clear, through the one vault chokepoint |
| subject crypto-shredded | `Placeholder{kind: :shredded}` — **erasure reaches replays with zero replay-specific deletion** |
| referenced row deleted | `Placeholder{kind: :gone}` |
| anything else failing | `Placeholder{kind: :denied}` — never a partial render of a half-resolved frame |

Values are **late-bound**: a replay shows what the user *did*, with each referenced field's
*current* value. Historical values are out of scope (§9, and **§8 D2**).

### 2.6 The player re-renders inertly

The player folds frames to index *N* and calls the recorded view's **current** `render/1` in an
isolated LiveView process: no event handlers run, no `handle_params`, no real `mount`, no side
effects. A module-level MD5 marker plus a visible "code has changed since recording" banner
handles drift; an unknown module yields an explicit "undecodable recording" state, never a crash.
Every stored frame is **re-validated** through `Samen.Replay.FrameSchema.validate/1` on decode —
`jsonb`, no `binary_to_term`, no atom creation from stored data.

### 2.7 Who may watch, and the audit row

**Access is impersonation.** An operator opens a replay only while holding an active
`Samen.Impersonation` session for that org (`Samen.Impersonation.active?/3` + `scope/3`),
**re-checked per frame batch** — the same gate `ReplayLive` already enforces today. A tenant
admin may replay **its own** org (open: **§8 D1**). Every open writes exactly one token-only
`aud_event` (`replay.viewed`: replay ref, viewer pseudonym, impersonation session ref) — no
reason text beyond the impersonation session's own.

### 2.8 The ledger stays the index

Nothing is thrown away. `nav.visited` remains the **index**: cheap, shipped, token-blind, and
present for every org whether or not replay is enabled. An opted-in org gets a "detail available"
badge on a session row and a detail view that opens the frame player; an org without the flag
keeps exactly today's timeline. **The page always says which kind of replay it is showing** — a
step list must never look like a recording.

### 2.9 Lane A's posture (as built)

- dependency `only: :dev`; dev-only modules **outside** `lib/`; dashboard reached through a
  compile-time-false `forward`, mounted **last** in a `:browser`-piped `scope "/"`;
- storage is the package's file backend under `priv/replay_recordings` (gitignored), no
  migration, package retention 48 h / 200 files;
- four tests assert the dep, the module, the route and the flag are absent outside dev — and a
  positive control that the probe *is* on in dev (an always-off flag would satisfy the other
  three and deliver nothing);
- the first decode cost on a fresh node was measured at ~90 s (the codec's `:safe` path
  `:code.ensure_loaded/1`-sweeping every module); a one-plug warmup of the host's own apps brings
  it to ~0.75 s. Recorded because the same symptom would otherwise send P3 hunting in the wrong
  layer.

## 3. Red paths

Each row ships with a sabotage patch; numbers are assigned at build time from `scripts/sabotages/`
(next free is **350** — 349 was taken by the ADR-index gate, `test/adr_index_test.exs`, while this
record was in review; the ranges below are the build plan's provisional allocation and shift with it).

| # | Red path | Must fail when |
|---|---|---|
| R1 | Capture is off unless the org flag is on **and** the sample was drawn | the flag check is bypassed |
| R2 | A vault-routed attribute is captured as `Ref` — never plaintext, never `vt_*` | the sanitizer keeps the value |
| R3 | A freeform column is shape only | the CDC classifier check is bypassed |
| R4 | A non-keep-listed bare string is dropped | the keep-list check is dropped |
| R5 | A PII-shaped value cannot enter through a keep-list | the shape check is bypassed |
| R6 | The frame schema refuses unknown kinds, raw strings, oversized payloads | `mix samen.verify.replay_schema` is neutered |
| R7 | Operator without grant `••••`, with grant clear, after shred `:shredded` | resolution uses the recording actor's plane or caches plaintext |
| R8 | Opening without an active impersonation session is denied and reads nothing | the session check is removed |
| R9 | Every open writes exactly one token-only `replay.viewed` | the audit write is dropped |
| R10 | Retention prunes sessions past TTL | the replay spec leaves the sweep |
| R11 | The recorder never attaches on the operator plane | the plane check is dropped |
| R12 | A forged/corrupt stored frame renders an inert placeholder and cannot execute a handler | decode re-validation is skipped |

## 4. Phasing

Dependency spine: **P0** (spike, independent) · **P1** → **P2** → **P3** → **P4**; P3 can start
against manufactured frames once P1's vocabulary exists. No host turns capture on before P4.

| Phase | Scope | Gate |
|---|---|---|
| **P0** *(built)* | Lane A: the literal `phoenix_replay` probe, dev only | 4/4 dev-only tests; prod compile has no `phoenix_replay` and no `/dev/replay` route; driftwood `MIX_ENV=test bash ci.sh` green |
| **P1** | `Samen.Replay.{Values,FrameSchema}` + `mix samen.verify.replay_schema` (mirrors `samen.verify.sink_schema`) | `samen_core` green with `--warnings-as-errors`; verifier passes and its twin flips (350) |
| **P2** | Session/Frame resources, replay-scope migration template + gen probe/parity golden, ETS buffer, exit monitor, the sanitizer (the load-bearing unit), capture + telemetry handler, `samen_web` recorder hooks on the tenant legs only, `Samen.Observability.child_specs(…, replay: opts)`, flag/caps/retention | flag-on writes one session, flag-off writes zero rows **and leaves no handler attached**; a halted event is still recorded; caps truncate visibly; a byte-scan of the table finds no `pii_*` plaintext; sabotages 351–358 |
| **P3** | decoder, resolver, player (fold/timeline/drift/audit), access gate, inert renderer, index+detail LiveViews beside `/operator/replay/:org_id` | `samen_web` green; the three masking proofs and their twins flip; shred game-day: every `Ref` renders `:shredded` with **zero replay rows rewritten**; sabotages 359–369, `./ci-fast.sh` green |
| **P4** | one host (driftwood broker) opted in **in dev**, retention sweep wired, `docs/guides/session-replay.md` rewritten (two lanes, what is/is not recorded, how to read, shred behaviour, the step-list-vs-recording statement), index updated, whole-workstream re-gate | `./ci.sh` → `ROOT CI: ALL PASSED`; `scripts/sabotage.sh --range 350-<last>` flips and restores byte-exact |

## 5. Consequences

**Buys.** A support thread can be answered with what the screen showed, without a second
plaintext store; the masking guarantee is structural (a value has no representation to leak);
erasure is free (shred → `:shredded` placeholders, no replay deletion path); a new scope needs no
replay work, because the vocabulary drops what it does not recognise; and the floor — today's
token-blind step list — is never removed, so an org that never opts in loses nothing.

**Costs, stated plainly.** A replay shows **current** values, so it can differ from what the user
saw if data changed afterwards (§8 D2). Code drift makes old recordings approximate — handled by
a visible banner plus TTL, not by pretending. Frames are real storage: caps and truncation are
user-visible, and a truncated session says so. Replay becomes a governed, audited surface with
its own access gate, which is more surface to get right than a step list. And a tenant admin
watching its own org's session is a genuine privacy ruling, not a default (§8 D1).

**Residues.** (a) A recording and the ledger can legitimately disagree — the ledger records a
visit even when capture was sampled out or capped; the page must say which it is showing.
(b) Keep-lists are the one place a human asserts "this string is safe": R5 exists because that
assertion is exactly where a leak would enter. (c) The player calls the *current* `render/1`; a
view that starts reading a new vaulted field makes that field `Ref`-resolved like any other, and a
view that stops naming it simply stops showing it.

## 6. Verification beyond the sabotages

- **Byte-scan, not payload inspection**: a test scans the stored table for a seeded `pii_*`
  plaintext and any `vt_*` substring. The claim is about what is *in the database*, not about
  what the builder intended.
- **Flag-detach**: flag off means zero rows **and** no telemetry handler left attached — the
  second half is what makes "off" mean off.
- **Decode safety**: every frame re-validated on read; corrupt/hostile frames render an inert
  placeholder.
- **Masking three proofs** (`Samen.MaskingCase`): green (tenant plane and operator-with-grant
  resolve clear), red (operator-without-grant renders `••••`, never plaintext, never `vt_*`),
  sabotage twin (the mask assertion is refutable).
- **Shred game-day**: shred a referenced subject ⇒ `:shredded` at every `Ref`, with the replay
  rows byte-identical (proving no replay-specific deletion happened).
- **Prod compile**: capture children and the replay scope absent unless configured.

## 7. Numbering — the ADR-052 collision, stated up front

Our tree's next free number is 052, and the upstream `ckluis/samen` line's ADR-052 is this exact
subject with a different tail (theirs also lands observability wiring). Reusing the number keeps
a future merge of the two lines legible; it does **not** mean the two documents are the same
record, and nothing here is ported from it. If the lines merge, the observability half gets its
own number in this tree.

## 8. Decisions — all OPEN (recommended answer first)

- **D1 — May a tenant admin replay its own org, or is replay operator-only?**
  **Recommended: yes**, tenant admin, own org only, no impersonation session required for that
  leg. Rationale: the admin already reads those fields on the tenant plane; refusing them would
  make the feature support-only while the data is theirs. Cost: one more access path to prove,
  and a member's session is visible to their admin.
- **D2 — Late-bound current values, or historical snapshots?**
  **Recommended: late-bound.** Historical values would require a versioned value store inside the
  replay envelope — a second archive of PII, which is the thing this ADR exists to avoid.
- **D3 — Default retention: 14 days, bounded max?**
  **Recommended: 14 days default, bounded max enforced in the retention spec**, with truncation
  and TTL visible on the page.
- **D4 — Which host opts in first, and only in dev?**
  **Recommended: driftwood's broker**, dev only in P4; no deployed environment turns capture on
  in this workstream.
- **D5 — Does `nav.visited` keep being written for opted-in orgs?**
  **Recommended: yes, unchanged** — it is the index every org has, and dropping it for opted-in
  orgs would make the timeline's availability depend on a flag.

## 9. Out of scope (v1)

Client-side pointer/viewport/scroll capture; form-value encryption; video/MP4 export; LiveView
streams and uploads (counted, not recorded); historical field values; operator-plane replay;
replays crossing org boundaries; any file-backed storage.

**Binds:** `docs/ws-masked-replay/build-plan.md` — units 1.1–1.4, 2.1–2.8, 3.1–3.7, P4 items
1–5. Ratifying §8 authorises the build in that order; it authorises nothing about a deployed
opt-in.
