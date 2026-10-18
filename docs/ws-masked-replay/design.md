# WS-Masked-Replay — design

**Status:** proposed (2026-10-17). No Lane B code yet (Lane A's P0 dev probe is built — see `build-plan.md`). Decision record: [`docs/adr/ADR-052-masked-session-replay.md`](../adr/ADR-052-masked-session-replay.md) — filed 2026-10-17, **PROPOSED**, §8 D1–D5 open (our next free ADR number; deliberately the same number + subject as the upstream record this design re-derives — see §9 there).

**Design inputs read:** `phoenix_replay` v0.6.2 (Hex, MIT, by Danila Poyarkov) — its docs and the 0.6 announcement; the upstream `ckluis/samen` record `docs/adr/ADR-052-observability-wiring-and-masked-replay.md` (read-only inspiration, not in this tree); our own `Samen.Analytics.Replay`, `Samen.Web.Replay`, `Samen.Web.Operator.{ReplayLive,ReplayReads}`.

---

## 1. What we are actually trying to build

The operator question is *"what was on their screen when it broke?"*. Today's Replay answers a smaller, cheaper question: *"which surfaces did they open, in what order"* (`nav.visited` rows: org, bounded surface token, HMAC actor, timestamp). That is honest and token-blind, but it cannot show state, so it cannot answer the question that gets asked in a support thread.

`phoenix_replay` answers it by recording **LiveView state and events** and then **re-rendering the app's templates with the recorded assigns**. It is not a pixel recording. Its shape is:

- an `on_mount` hook plus `attach_hook` on `:handle_params` / `:after_render`;
- `[:phoenix, :live_view, :handle_event, :start]` telemetry so even halted events are seen;
- an ETS buffer written from the LiveView process, finalized by a monitor on exit;
- persistence + a dashboard (`/dev/replay`) that rebuilds assigns and calls the view's current `render/1`;
- optionally, a browser channel for form values, pointer, viewport, plus telemetry (Ecto/Finch/logs) and MP4 export.

That shape is good. Its **privacy model is the problem**, and on this foundry it is fatal: tenant-plane LiveViews resolve rows through `Samen.Api.PiiResolution` *before* they land in assigns, so recorded assigns are **plaintext**; form events carry what the user typed *before* any vault write. Stored in a file or an uncatalogued table, that is the largest plaintext store in the system — outside `Samen.Pii.WriteGuard`, outside `no_plaintext_pii`, outside crypto-shred, viewable without a reveal grant. `mix samen.verify.no_plaintext_pii` would be right to fail it.

**So: take the capture shape, refuse the storage model.** That is the whole design.

## 2. Two lanes, and which one is a dependency

**Lane A — `phoenix_replay` as an engineer's tool (dev only).** Install it in `driftwood` (the vertical with a real UI + dev seeds), mounted only in `:dev`, recording only seeded fake data. It is a debugging tool for framework authors, compiled out of prod, with a test asserting its absence. One evening. It is *not* a product surface and it is **never** pointed at a tenant org in a deployed environment.

**Lane B — first-party masked replay (`Samen.Replay`).** The product feature: reference-only capture, viewer-plane resolution, inert re-render, governed access. This is the workstream below. Lane A may inform Lane B's ergonomics but shares no code and no tables.

Lane B is not "phoenix_replay with a sanitizer". A sanitizer at the storage boundary is a blocklist: it has to guess every future shape a value can take. Reference-only capture is an allowlist: a raw value has nowhere to be written. Only the second survives a new scope, a new field, or a host that assigns something new.

## 3. Capture vocabulary

Three terms explain every stored value:

| Term | Means | Rendered as |
|---|---|---|
| `%Samen.Replay.Ref{resource, pk, attribute, label}` | a vault-routed attribute of an Ash record: the pointer replaces the value at capture | resolved at view time on the **viewer's** plane |
| `%Samen.Replay.Redacted{kind, length}` | a value we deliberately do not keep (`:string`, `:free_text`) | shape only: `"•••• (42 chars)"` |
| `%Samen.Replay.Placeholder{kind}` | a reference that could not be resolved **now** (`:shredded`, `:gone`, `:denied`) | an explicit gap, never a blank |

Plus a bounded vocabulary for everything else: numbers, booleans, dates, decimals, ids, atoms from closed sets, and maps/lists that recurse. Everything not in the vocabulary is dropped (`%Redacted{kind: :dropped}`), never stringified "just in case".

**Frames** are `:mount` (the assign map at mount, sanitized), `:params` (`handle_params` params, shape only), `:render` (changed assigns), `:event` (event name + per-param shape), `:info` (message *tag* only). No DOM, no HTML, no screenshots, no client JS channel in v1.

## 4. Capture rules (the allowlist)

1. **Vault-routed attributes become `Ref`s.** Ask the resource's PII metadata (`pii_*` / `Samen.Type.VaultField` declarations), not a name heuristic.
2. **Other record attributes** are kept only if `Samen.Cdc.Projection.classify_columns/2` would project them (ADR-015 default-deny reused verbatim). Freeform columns → `Redacted{kind: :free_text, length: n}`.
3. **Bare strings** are dropped unless the assign key is on the view's declared keep-list (`:page_title`, `:tab`, `:sort`, `:page`) — a keep-list entry must itself pass a PII shape check (`Samen.PiiValueShape.classify_value/1`), so a keep-list cannot smuggle an email.
4. **Event params** carry key, type, length, class; values only for keep-listed keys.
5. **The actor** is stored only as the wide-event HMAC pseudonym (`Samen.WideEvent.for_subject/2`) — erasure makes a replay unlinkable for free.
6. **`%Samen.Masked{}`** is kept as-is (it carries a token, never plaintext).

## 5. Storage

Two framework-owned resources in a replay scope, `jsonb` payloads so the existing DB tiers and the destruction oracle can scan them:

- `Replay.Session` — org, actor pseudonym, view module + MD5 (code-drift marker), started/ended, frame count, byte count, `truncated?`, redaction counts.
- `Replay.Frame` — session ref, index, kind, occurred_at, sanitized payload.

Off by default, **opt-in per org** via `Samen.FeatureFlags.evaluate("samen.replay", %{org_id: org})` plus a sample draw. Caps: max frames/session, max bytes/session, max sessions/node, and a TTL through `Samen.Retention` (default 14 days, bounded max). Only sessions with at least one user interaction persist, so passive page-loads do not fill the table.

## 6. Resolution — at view time, on the viewer's plane

The player never stores plaintext, so it must resolve on read:

- operator without a grant → `%Masked{}` → `••••`, never a `vt_*` token in DOM;
- operator with a live reveal grant on that subject → clear, through the one vault chokepoint;
- subject crypto-shredded → `Placeholder{kind: :shredded}` — **erasure reaches replays with zero replay-specific deletion**;
- referenced row deleted → `Placeholder{kind: :gone}`;
- anything else failing → `Placeholder{kind: :denied}`, never a partial render of a half-resolved frame.

Values are **late-bound**: a replay shows what the user did, with each referenced field's *current* value. Historical values (versioning) are out of scope.

## 7. Player and who may watch

**Rendering is inert.** The player rebuilds assigns frame by frame and calls the recorded view's current `render/1` in an isolated LiveView process: no event handlers run, no `handle_params`, no `mount` of the real page, no side effects. A module-level MD5 marker plus a visible "code has changed since recording" banner handles drift.

**Access is impersonation.** An operator opens a replay only while holding an active `Samen.Impersonation` session for that org (`Samen.Impersonation.active?/3` + `scope/3`), re-checked per frame batch — the same T150 gate the existing Replay tab already enforces. A tenant admin may replay its own org. Every open writes one token-only `aud_event` (`replay.viewed`: replay ref, viewer pseudonym, impersonation session ref) — no reason text beyond the impersonation session's own.

**The masking watch-list applies.** This is a surface rendering vault-routed fields, so it ships the three proofs via `Samen.MaskingCase`: green (tenant plane + operator-with-grant resolves clear), red (operator-without-grant renders `••••`, never plaintext, never `vt_*`), sabotage twin (the mask assertion is refutable).

## 8. What happens to today's Replay

Nothing is thrown away. The `nav.visited` ledger stays as the **index**: it is cheap, already shipped, token-blind, and it covers every org whether or not replay is enabled. Opted-in orgs get a "detail available" badge on a session row and a detail view that opens the frame player for that session. Orgs without the flag keep exactly today's timeline, and the page says which kind of replay it is showing — a step list must never look like a recording.

## 9. Invariants and red paths

Every row ships with a sabotage patch (next free number at build time: `349`).

| # | Red path | Must fail when |
|---|---|---|
| R1 | Capture is off unless the org flag is on **and** the sample was drawn | the flag check is bypassed |
| R2 | A vault-routed attribute is captured as `Ref`, never plaintext, never `vt_*` | the sanitizer keeps the value |
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

**ADR-number collision, stated up front:** our tree's next free number is 052 and the upstream line's ADR-052 is this exact subject with a different tail (theirs also lands observability wiring). Reusing the number keeps a future merge of the two lines legible; it does not mean the two records are the same document. If the lines merge, the observability half gets its own number here.

## 10. Non-goals (v1)

Client-side pointer/viewport/scroll capture; form-value encryption; video/MP4 export; LiveView streams and uploads (counted, not recorded); historical field values; operator-plane replay; replays crossing org boundaries; any file-backed storage.
