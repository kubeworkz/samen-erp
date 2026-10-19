# WS-Notes — P0 mechanics findings

**Phase 0 verdict: GO on ADR-053 §2 D3** (server-rendered `<textarea>` blocks, no `contenteditable`,
no JS build). All four assertions hold on real connected sockets; the one property a server cannot
see — the caret — was measured in a browser, with a control that proves the measurement can fail.

Date 2026-10-18. Artifacts:

| What | Where |
|---|---|
| the spike LiveView (throwaway) | [`samen_web/test/support/notes_spike.ex`](../../samen_web/test/support/notes_spike.ex) |
| the four assertions (8 tests, real sockets) | [`samen_web/test/samen/web/notes_spike_mechanics_test.exs`](../../samen_web/test/samen/web/notes_spike_mechanics_test.exs) |
| the candidate hook body | [`samen_web/test/support/notes_spike/spike.js`](../../samen_web/test/support/notes_spike/spike.js) |
| the browser-pass launcher (blocked, see §5) | [`samen_web/test/support/notes_spike/serve.exs`](../../samen_web/test/support/notes_spike/serve.exs) |
| the caret probe page | [`samen_web/test/support/notes_spike/caret_probe.html`](../../samen_web/test/support/notes_spike/caret_probe.html) |

---

## 1. Evidence

| # | Assertion | How it is proven | Result |
|---|---|---|---|
| (a) | the debounced round trip does not disturb the caret, because the **value node is never patched** | two-part: the server stores and returns the submitted text **byte-identically** (incl. leading/trailing space, `<`, `&`, a non-ASCII grapheme); a browser probe then measures what a re-write does to the caret | **holds** — echo exact; caret `5 → 5` on an identical write, `5 → 18` on a different one (control) |
| (b) | a remote change to the block being edited does **not** overwrite it | two real sockets on one PubSub topic; socket B writes a row + broadcasts `{:block_changed, id, rev}`; socket A has that block focused | **holds** — A keeps its text, records the skip, and picks the remote value up **on blur** |
| (c) | `Enter` splits server-side at the caret offset and the client is told to focus the new block | `render_hook("split", %{id, offset})` — the exact shape the hook pushes | **holds** — `"First line."` @6 → `"First "` + `"line."`, new row ordered directly after, `push_event("focus_block", …)` emitted |
| (d) | `Backspace` at offset 0 merges into the previous block | `render_hook("merge", %{id})` | **holds** — `"First line.Second line."`, row removed, focus nominated on the survivor; merging the **first** block is a no-op |

Measured: **1.95–2.15 ms** server-side processing per debounced change (LiveView process time inside
the test VM — *not* a network RTT; the debounce is 400 ms by choice, so this is not on the critical
path). 8/8 tests green.

The caret probe's control matters as much as its result: writing a *different* value moved the caret
to the end (18), so "the caret did not move" is a falsifiable observation rather than a tautology.

## 2. What the hook actually has to do (the contract, corrected)

P0's real output is a shorter contract than the one designed in `design.md` §4.1. Three items
**drop out**, one is **added**:

| Contract item | Verdict |
|---|---|
| hook reports **focus/blur** | **DROPPED.** `phx-focus` / `phx-blur` + `phx-value-id` are declarative, and they carry the id — no JS, no messages to reconstruct. Proven by (b): the focus guard works with zero hook involvement. |
| hook reports **caret offset on Enter** | **KEPT — load-bearing.** The caret exists only in the browser. |
| hook reports **"Backspace at 0"** | **KEPT**, but only as a *predicate* (`selectionStart === 0 && selectionEnd === 0`), not an offset. |
| hook auto-grows the textarea | **KEPT** — and it is the only DOM write the hook is allowed (its own element's height; no sibling, no text node). |
| **server → client "focus this block"** | **ADDED.** After a split/merge the server can only *nominate* a block; the caret cannot be moved from the server. `push_event("focus_block", %{id})` is the one message in that direction. |

Two mechanical facts worth recording because they cost time:

- a `phx-hook` element **must carry an `id`** — it is a compile-time `ParseError`, not a runtime
  surprise;
- form-level `phx-change` posts **every** textarea in the form, so the changed block has to be
  identified by diffing against the store. Fine at three blocks; at 200 it is 200 values per
  debounce. **Decision for Phase 3:** move `phx-change` onto the individual control (which posts only
  its own `name`/`value`) and carry the block id on `phx-value-id`, keeping the form only for markup.

## 3. Open contract question — offset units

`selectionStart` counts **UTF-16 code units**. `String.split_at/2` counts **graphemes**. They agree
for ASCII and diverge for emoji, many CJK cases and combining marks — so a split mid-emoji puts the
halves in the wrong place (it does not crash: the offset is clamped).

Two viable fixes, to be chosen in Phase 3:

1. **client converts** (`Array.from(text.slice(0, n)).length` → code points) and the server documents
   that it counts graphemes — but code points ≠ graphemes for combining marks either;
2. **send UTF-16 units** and convert server-side with a single helper that the dialect tokeniser also
   uses, so one module owns "offset" for the whole feature.

Recommendation: (2), one `Samen.Web.Notes.Offset` module, unit-tested against a table of
ASCII / accented / emoji / combining-mark strings. It is not in M1's assertions because ASCII pages
work today — but it must be settled before the editor is used for real text.

## 4. A bug the spike caught (and why split/merge need their own tests)

The first implementation of `split` **dropped the anchor row**: `Enum.split_while/2` excludes the
matching element, so re-inserting only the head + new block + tail silently deleted the block being
split. The symptom was not a crash — it was a split that "succeeded" into nothing (the surviving
block was `nil`). This is exactly the class Phase 2 unit 2.5's split/merge boundary tests must cover:
`nil`-after-the-fact is the failure shape, not an exception.

## 5. Test-infrastructure findings (both real, both permanent)

1. **`Phoenix.LiveViewTest` needs `lazy_html` at test time** and this app never declared it, so no
   test in `samen_web` could drive a *connected* socket with element selectors or `live_isolated/3`
   (`DOM.ensure_loaded!/0` raised). Added as `{:lazy_html, ">= 0.1.0", only: :test}` — **4 lockfile
   lines** (`lazy_html`, `cc_precompiler`, `elixir_make`, `fine`). Router-driven `live/2` without
   selectors did work before this; selectors and isolated mounts did not.
2. **The live-browser pass is blocked by design, not by a bug.** `samen_web` is a library and
   depends on **no** webserver adapter (its only endpoint runs `server: false`), so
   `server: true` cannot bind: `function Plug.Cowboy.child_spec/1 is undefined`. `serve.exs` now
   **refuses up front** with the two ways to run it (add `{:bandit, "~> 1.0", only: :test}` +
   `adapter: Bandit.PhoenixAdapter`, or mount the spike router in a host that already ships one —
   driftwood, samenerp and pawchart all have `bandit`).

   Rather than add a server dependency to a library for a throwaway spike, the caret was measured
   directly in a browser (§1). **Residual:** the full page-level browser pass (real LiveSocket,
   typing by hand, two tabs) has not been run; it is written and one command away on a host with an
   adapter.

## 6. What this does NOT prove (carried forward, not hidden)

- **IME / composition input** was not exercised. The design's claim is that a `<textarea>` delegates
  it to the platform; P0 did not test a composition session.
- **Cross-block selection** (select from block 1 into block 2) is out of M1 by design, and the
  textarea model cannot support it — this is the single strongest reason someone will later want the
  Tiptap island (design §10), and it should not be discovered as a surprise.
- **Drag-reorder** is M2 and needs a vendored library; keyboard move was not exercised end-to-end
  (the server-side `move` is Phase 2's unit, not P0's).
- Two people typing in the **same** block simultaneously is explicitly out of scope (ADR-053 §2 D4:
  `revision` CAS + a visible conflict, not merge).

## 7. Consequence for the plan

- Phase 3 unit 3.5 shrinks: the hook is ~45 lines (keydown + auto-grow + one handled event), and
  focus is declarative.
- Phase 2 unit 2.2 gains the offset module decision (§3) and the `nil`-after-split test shape (§4).
- Phase 1 unit 1.5 gains nothing; Phase 6's browser pass (if wanted) needs the adapter decision.
