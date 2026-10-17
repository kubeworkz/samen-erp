# Session replay — what a support session review is, and is not

An operator can watch a tenant's session back on **`/operator/replay/:org_id`**: which surfaces
that session opened, in the order it opened them, played with a playhead. It is reached from the
account drill-down's **Replay →** link, next to Deliverability / Automation health / Activity.

This page is the operator-facing truth about that screen: what is recorded, what is deliberately
NOT, how a host turns it on, and where the proofs live.

---

## 1 · What a replay is

A replay is a **timeline of the surfaces a signed-in tenant opened**, plus the product events the
host's analytics ledger already records — reconstructed, per org, from that ledger.

| Step kind | Comes from | Example label |
|---|---|---|
| `nav` | `nav.visited` — the framework's tenant-mount recorder | *Opened Broker* |
| `event` | a registered product event (`record.created`, `search.used`, `session.signed_in`, `first_run.completed`, `flag.assignment`) | *Created a record* |

Steps are grouped into **sessions** by actor and an **idle gap of 30 minutes**: a new session
starts when the actor changes or when more than half an hour passes between steps. That gap is a
reading convention, not a recorded fact — the ledger stores instants, and `ReplayReads` derives
the sessions.

### What it deliberately never holds

No DOM, no keystrokes, no form values, no screenshots, no URL, no query string, no path
parameter, no entity id from a page address. The only thing a visit records is a **bounded
surface token** (`broker`, `crm_dashboard`) derived from the LiveView module name.

That is the whole design, and it is why the screen needs no masking: a true screen recorder would
have to capture what the tenant typed, which is exactly the data this foundry refuses to hold in
cleartext (vault routing, `Samen.Pii.WriteGuard`). A surface token is not PII, so there is
nothing to reveal, nothing to grant, and nothing to leak.

---

## 2 · Turning it on (a host wiring step, ≈0 authored LOC)

Recording rides the tenant `on_mount` every framework tenant route already carries, so a host
adds **no per-page call and no per-page opt-in**. What a host does need is the analytics ledger
it is already asked to mount for product analytics:

```elixir
# config/config.exs — the SAME seam Samen.Analytics.track/1 writes through
config :samen_core, Samen.Analytics,
  product_event_resource: MyApp.Analytics.ProductEvent
```

* **Wired** ⇒ every connected tenant mount writes one `nav.visited` row (and the operator screen
  shows the timeline).
* **Unwired** ⇒ recording is INERT (`{:ok, :dropped}`) and the operator screen says so —
  *"the ledger could not be read"* — rather than implying the tenant did nothing.

A tenant on a host with **no JS client** records nothing: a LiveView mounts twice (the HTTP dead
render, then the connected mount over the websocket) and the recorder fires only on the connected
mount. There is no client session to replay, and the screen's empty state is honest about that.

---

## 3 · The operator screen

* **Gated like every other drill-in.** `/operator/replay/:org_id` rides the operator
  `live_session`, so it carries the `:require_operator` role gate; and reading one tenant's
  session is itself a per-tenant drill-in, so it requires a short-TTL, **reason-required**
  `Samen.Impersonation` session — recorded in the tenant's ledger. A session review is at least as
  sensitive as the activity feed next to it, so it uses the same gate, not a lighter one.
* **Player.** Select a session in the left column, then play / pause / step / seek / change speed.
  The playhead is server state rendered into the page:
  `#replay-player[data-playhead]`, the current step's `data-current="true"`, and
  `#replay-progress[data-percent]`. It needs no client JS, so it works on a Class B render.
* **Window.** 24h / 7d / 30d, defaulting to 7d.
* **A note on the page states the scope and the caps** — window, idle gap, and the reader's
  bounds (newest 2,000 events, 50 sessions, 200 steps per session) — so a short-looking session is
  never read as a short visit, and a truncated timeline says `truncated`.

### Getting there (and the two ids in the URL)

1. **Operator plane → Accounts** → open an account (`/operator/accounts/:id`).
2. The account page's action row carries **`Replay →`**, next to Deliverability / Automation
   health / Agent health / Activity.
3. The first visit renders the deny state; enter a reason and **Start session**, then pick a
   session and press **Play**.

The two URLs use **different columns of the same Org row**, and mixing them is the bug this
screen's tests pin:

| URL | Key | Why |
|---|---|---|
| `/operator/accounts/:id` | account Org `id` | the book-of-business row |
| `/operator/replay/:org_id` | `tenant_org_id` (Org `slug`) | the value the impersonation session, `aud_event.subject_id` and the analytics ledger's `org_id` all carry |

So the account page's drill-in links are built from `tenant_org_id`, and the replay page's
`← Account` link resolves the Org `id` back from it (one bounded `limit(1)` lookup, rendered only
when it resolves). A link built from the wrong column still navigates — it just shows an empty
timeline or "Account not found", which is why both directions are asserted.

### The four silences are four different facts

| Rendered | Means |
|---|---|
| *No sessions recorded in this window.* | The ledger **answered** and this org has no recorded visits in the window. |
| *The replay ledger could not be read.* (`replay-unread`) | No `product_event_resource` is wired, or the read RAISED. This is **not** "the tenant did nothing". |
| *No tenant org resolved.* | No org id was handed in. |
| *Access denied — no active impersonation session…* | The drill-in gate refused; the reason form is offered (and withheld-control copy names which roles may open one). |

---

## 4 · Where the code lives

| Concern | File |
|---|---|
| Capture boundary (bounded surface, refusal matrix) | `samen_core/lib/samen/analytics/replay.ex` |
| The registered event + its prop schema | `samen_core/lib/samen/analytics/catalog.ex` |
| The tenant recorder (rides the authz hook) | `samen_web/lib/samen/web/replay.ex` |
| Sessionization + the org-scoped read | `samen_web/lib/samen/web/operator/replay_reads.ex` |
| The screen + playhead | `samen_web/lib/samen/web/operator/replay_live.ex` |
| The route (inherited by every operator host) | `samen_web/lib/samen/web/router.ex` — `samen_operator_routes/2` |

### Proofs

| Proof | Test |
|---|---|
| Bounded surface: a path/URL/label/`vt_*` is REFUSED as a surface | `samen_core/test/analytics_replay_test.exs` |
| Exactly one step per CONNECTED visit; nothing on the dead render | `samen_web/test/samen/web/operator_replay_test.exs` |
| A subject is recorded as an HMAC pseudonym — never a raw id; a shredded subject records no actor at all | same file |
| Sessionization, offsets, window, org isolation | same file |
| Fail-honest: unread ≠ empty | same file |
| The player advances / stops / clamps | same file |
| No `vt_` token, no email-shaped sentinel ever renders — and the same scan catches an injected leak | same file |
| The route is declared by the mount macro (0-LOC inheritance) | same file |
| The recorder's exactly-once guard, proven refutable | `scripts/sabotages/345-replay-double-records-the-dead-render.patch` |

Run one of them directly:

```bash
cd samen_web && mix test test/samen/web/operator_replay_test.exs
cd samen_core && mix test test/analytics_replay_test.exs
```

Replay the sabotage (the named test MUST fail, then revert byte-exact):

```bash
./scripts/sabotage.sh --range 345-345
```

---

## 5 · Honest limits

* **Granularity is the ledger's.** A step is a surface or a registered event — not a click, not a
  value, not a rendered fragment. A support engineer still cannot see *what a field said*; that
  question goes to the vault, under a reveal grant, on the record's own surface.
* **Pseudonymous actors.** Sessions are grouped by an HMAC handle. After a subject is shredded the
  handle is unreconstructable, so their steps remain org-scoped facts with no actor linkage — by
  design, and asserted.
* **Locally-computed sessions.** The 30-minute gap and the caps are read-time conventions; changing
  them changes the grouping, which is why the page states them.
* **No recording on a Class B (no-JS) client.** A dead render is not a session.
* **An operator's own acting-as visit records as that org's step**, with the operator's principal
  as the actor handle — support access shows up in the tenant's timeline, which is the point.

---

## 6 · Engineer-only tool: `phoenix_replay` (dev, dev-only)

The framework's Replay (§1–§5) is a **token-only timeline**: it never stores what a screen said.
For framework work there is a second, much higher-fidelity tool: the third-party
[`phoenix_replay`](https://hex.pm/packages/phoenix_replay) package, which records LiveView assigns
and events and re-renders the recorded view with them (design + build plan:
`docs/ws-masked-replay/`). It is an **engineer's tool, in dev, over seeded data** — not a product
surface.

**Where it lives.** `driftwood` only (the vertical with a real UI and dev seeds):

| Concern | Where |
|---|---|
| The dependency | `driftwood/mix.exs` — `{:phoenix_replay, "~> 0.6", only: :dev}` |
| The dashboard router (compiled in `:dev` alone) | `driftwood/dev_only/driftwood_web/dev_replay_router.ex` |
| The mount + the recorder hook | `driftwood/lib/driftwood_web/router.ex` (`@dev_replay`, `@tenant_mount_hooks`) |
| Storage + retention | `driftwood/config/dev.exs` → `priv/replay_recordings/` (gitignored, 48 h / 200 files) |
| The absence proofs | `driftwood/test/replay_dev_only_test.exs` |

**How to use it.** `cd driftwood && mix phx.server`, note the port it prints (`Access … at
http://localhost:<port>`, a free port), then open `http://localhost:<port>/dev/replay` — **use
`localhost`, not `127.0.0.1`**: the endpoint's `check_origin` refuses the `127.0.0.1` websocket, so
the page is a dead render that silently records nothing.

Walk the **operator impersonation console** (`/operator/impersonate?org=…`), type a reason and
start a session: it is the one driftwood-local surface with a real `phx-submit`. `/broker` alone
records nothing on purpose — the package discards sessions with no interaction
(`TailSampling.decision/3` needs a handled event or a second `handle_params`), and the freight
board's panel links are plain anchors. A recording appears under "Live now" and is saved when the
node exits (`priv/replay_recordings/`).

A note on the first open: the package's codec tries a `:safe` decode first, and a recording names
modules the fresh dev node may not have loaded — so on the very first recording it loads every
available module, which measured **~90 s** here. The dev-replay router pre-loads this host's own
apps (`DriftwoodWeb.DevReplayWarmup`) to avoid that sweep: first open is now **0.75 s**. If a
new host adds the dashboard, copy that plug or expect the one-time cost.

**Why it can never be a deployed surface.** Its recordings are **raw** — mount assigns (which on a
foundry tenant plane are already PII-resolved *plaintext*), `handle_params` params, and (with the
browser recorder) form values typed before any vault write. That is precisely the store §1–§5
exists to avoid. So the probe is excluded three ways: the dependency is `only: :dev`, the
dashboard module is compiled from `dev_only/` (outside `lib/`), and the route sits in a
compile-time-false branch elsewhere. A `:prod` build does not fetch the dependency at all.

**Never point it at a real tenant org in a deployed environment.** The product mechanism in this
workstream is the masked first-party `Samen.Replay` (record by reference, resolve on the viewer's
plane), not this package — see `docs/ws-masked-replay/design.md` §1.
