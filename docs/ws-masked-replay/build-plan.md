# WS-Masked-Replay — build plan

**Sizing rule (operator standing order):** SMALL serialized units — **one deliverable per `agent()` call**, each banking in ~10–20 min, each independently committable and gate-able. Fan-out concurrency 1. Model routing per unit (`sonnet` = mechanical port/tests; `opus` = the sanitizer, the resolver, the renderer, and every adversarial gate).

**Gate discipline:** every phase ends with an adversarial gate (findings fixed in-phase). All suites + the relevant `ci.sh` green before/after each phase; `./ci.sh` before a milestone. Sabotage patches numbered from **350** (**349** is shipped — the ADR-index gate,
`samen_core/test/adr_index_test.exs`, claimed it while this plan was in review) and replayed with
`scripts/sabotage.sh --range 350-<n>`.

**Design inputs:** `docs/ws-masked-replay/design.md`, ADR-021 (analytics capture), ADR-015 (CDC default-deny), ADR-038 §5.5 (masking proofs). Read-only inspiration: `phoenix_replay` v0.6.2 and the upstream ADR-052 record — neither is a dependency of Lane B.

**Dependency spine:** P0 (spike, independent) · P1 (vocabulary + schema + verifier) → P2 (capture) → P3 (resolve + player) → P4 (mounts, retention, docs). P1 must land before P2; P3 can start against manufactured frames once P1's vocabulary exists. No host turns capture on before P4.

---

## Phase 0 — the literal `phoenix_replay` spike (Lane A, ~0.5 day)

Goal: engineers can see a real phoenix_replay dashboard on seeded dev data, and the build proves it cannot exist in a deployed environment.

**As built (2026-10-17).** The persistence question is answered: the default backend writes compressed term files (`PhoenixReplay.Storage.File`), default path `priv/replay_recordings` relative to the cwd — **no migration, no table**. Recordings live in `driftwood/priv/replay_recordings/` (gitignored), pruned by the package's own retention (48 h / 200 files).

1. `driftwood/mix.exs`: `{:phoenix_replay, "~> 0.6", only: :dev}` — fetched and compiled in `:dev` alone. It brings `ua_parser`, `lumis` (+2 wasm highlighters), `ex2ms`, `phoenix_iconify`; none of them appears in the prod dependency list.
2. `driftwood/mix.exs`: `elixirc_paths(:dev) -> ["lib", "dev_only"]`. The dev-only code sits **outside `lib/`** because `elixirc_paths` compiles a path recursively — a `lib/dev_only/` subdirectory would still be compiled by the `"lib"` entry in `:test`/`:prod` (learned by failing: `import PhoenixReplay.Router` broke the test compile).
3. `driftwood/dev_only/driftwood_web/dev_replay_router.ex`: its own `use Phoenix.Router` + `phoenix_replay("/")`, because the dashboard is a router macro and must be expanded where it is mounted. `DriftwoodWeb.Router` reaches it with `forward("/dev/replay", …)` inside a compile-time-false `if @dev_replay` branch — an atom reference only, so no non-dev build needs the dependency. Declared in a **bare** scope: inside `scope "/", DriftwoodWeb` the `:alias` prefix expands the target to `DriftwoodWeb.DriftwoodWeb.DevReplayRouter`.
4. Recording: `PhoenixReplay.Recorder` is appended to the broker `live_session`'s `on_mount` through a compile-time literal (`@tenant_mount_hooks`), so only `/broker` is recorded — a `live_session` takes a literal `:on_mount` list, not a function call.
5. JS (`replayParams` / `replayRecorder`): **not wired in P0.** The dashboard works without it; the browser channel records form values, which is the one extra plaintext channel a dev probe does not need. Wire it only if pointer/form fidelity is actually wanted for the spike.
5a. **Mounting has to survive the dashboard's own link building.** `phoenix_replay/2` derives every link from `Phoenix.Router.scoped_path(__MODULE__, path)`, so a `forward("/dev/replay", DevReplayRouter)` mount (which strips the prefix and leaves the dev router with an empty scope) produced a dashboard whose session links were `/3RPG…` → a 404 page titled "Not Found". The shipped shape: the dev router wraps `phoenix_replay("/")` in `scope "/dev/replay"` so it generates full paths, and the host router mounts it **last**, as `forward("/", …)` inside a `:browser`-piped `scope "/"` — a prefix of `/` preserves `path_info`, so the forwarded router still matches its own `/dev/replay` scope, and being last it never shadows a real route. 
5b. **`/broker` alone cannot produce a session.** `PhoenixReplay.Session.TailSampling.decision/3` keeps a session only after a handled event or a *second* `handle_params`; the freight board is read-only and its panel links are plain anchors (a full reload, i.e. a fresh mount). So the recorder is attached to the operator impersonation console too — the one driftwood-local surface with a real `phx-submit`. Verified end to end: submit → `priv/replay_recordings/<id>.<node>.part` appears → the dashboard lists the session (`1 session · 37 events`) and recovers it after a node restart.
5c. **`127.0.0.1` is not `localhost` for the socket.** The endpoint's `check_origin` rejected the websocket when the browser used `127.0.0.1`, so the page was a dead render that recorded nothing. Open `http://localhost:<port>/…`; a dead-render-only visit is indistinguishable from "the recorder is not attached".
6. `driftwood/config/dev.exs`: `config :driftwood, dev_replay_dashboard: true` + the file storage path + retention. `config/config.exs`, `test.exs` and `prod.exs` carry neither key.
7. `driftwood/test/replay_dev_only_test.exs` (4 tests): the dependency is not loaded, the dev-only module is not compiled, the route table has no `/dev/replay`, and the probe is enabled **by dev config alone** (the positive control — an always-off flag would satisfy the other three and deliver nothing).

**Gate P0:** `mix test test/replay_dev_only_test.exs` → 4 passed; `MIX_ENV=dev mix compile --warnings-as-errors` green and `mix phx.routes` lists the five `/dev/replay*` routes; `MIX_ENV=prod mix compile --warnings-as-errors` green, `_build/prod/lib` has no `phoenix_replay`, and the prod route table has zero `/dev/replay` entries; driftwood's `MIX_ENV=test bash ci.sh` green. Deliverable is a note in `docs/guides/session-replay.md` §"Engineer-only tool": *where it lives, why it is dev-only, and that it must never be pointed at a tenant org in a deployed environment.*

**Finding, diagnosed and closed — the player was slow, not hung.** `GET /dev/replay/<id>` appeared to block: no response, no error, the list still serving. A remote stacktrace dump (`elixir --sname drift …`, then `:rpc.call/4` over `Process.info/2`) caught the request in `PhoenixReplay.Storage.Codec.decode/2 → load_available_modules/0 → :code.ensure_loaded/1`.

The cause is documented in that module: the codec first tries `:erlang.binary_to_term(term, [:safe])`; safe decoding refuses atoms the VM has not created yet, and a recording names modules (the structs in assigns). On a fresh dev node the first decode therefore fails and the codec runs `:code.ensure_loaded/1` for **every** available module — dependencies included, one synchronous `:code_server` call each. Measured here: first `GET /dev/replay/<id>` **~90 s**, every later one **0.36 s**.

Fix: `driftwood/dev_only/driftwood_web/dev_replay_warmup.ex`, a one-plug pipeline in the dev-replay router that pre-loads this host's apps (`driftwood`, `samen_web`, `samen_core`) once per node, so the first `:safe` decode succeeds and the sweep never runs. Measured after: first hit **0.75 s**, second **0.32 s**, and the frame endpoint renders the recorded page ("Operator plane", "Driver roster", "Start session") in 0.27 s. The spike's earlier guess (a blocking call inside a Samen `render/1`) was wrong — worth recording, because the same symptom would otherwise send P3 hunting in the wrong layer.

## Phase 1 — vocabulary, schema, verifier (~1.5 days)

| Unit | Deliverable |
|---|---|
| 1.1 | `samen_core/lib/samen/replay/values.ex` — `Ref`, `Redacted`, `Placeholder` structs; the closed bounded-type vocabulary; `sanitize/2` stub raising `:not_implemented` (fail-honest, ADR-014). |
| 1.2 | `samen_core/lib/samen/replay/frame_schema.ex` — declared frame kinds, per-kind allowed keys, max payload bytes, and `validate/1` returning `{:ok, frame} | {:error, reason}`. Rejects raw strings, unknown kinds, and anything carrying a `vt_`-prefixed value. |
| 1.3 | `samen_core/lib/mix/tasks/samen.verify.replay_schema.ex` — walks the schema and every capture call site; fails on a raw-string field, an unregistered kind, or a keep-list entry that is not a bounded key. Mirrors `samen.verify.sink_schema`. |
| 1.4 | Tests: schema accepts each vocabulary term; refuses a raw string, a `vt_*`, an unknown kind, an oversized payload; verifier flips when the schema is neutered (sabotage 350). |

**Gate P1:** `cd samen_core && mix test` green with `--warnings-as-errors`; `mix samen.verify.replay_schema` passes and its sabotage twin flips. No `samen_web` change yet.

## Phase 2 — capture (~3–4 days)

| Unit | Deliverable |
|---|---|
| 2.1 | `Replay.Session` + `Replay.Frame` resources (replay scope), `jsonb` payload column, org-scoped policy, abbreviations allocated through `mix samen.abbrev.reserve` — **never** hand-edited. |
| 2.2 | `m_mount_replay_scope.eex` template + host migration; `gen_app` probe + templates-parity golden updated. |
| 2.3 | `replay/buffer.ex` (ETS, per-process session, caps) and `replay/monitor.ex` (finalize on exit, persist via `Store`). |
| 2.4 | `replay/sanitizer.ex` — the allowlist of design §4, including `Cdc.Projection.classify_columns/2` and `PiiValueShape.classify_value/1`; defaults to `Redacted`. This is the load-bearing unit (`opus`). |
| 2.5 | `replay/capture.ex` — `open/1`, `record/3`, the `handle_event` telemetry handler (`:start`, so halted events are seen), all rescuing to `:ok`. |
| 2.6 | `samen_web/lib/samen/web/replay/recorder.ex` — `on_mount` + `attach_hook(:handle_params)` + `attach_hook(:after_render)`; attached from `Samen.Web.TenantAuthz`'s two tenant legs only (the existing `record_visit` call sites), never the operator leg; refuses a non-tenant `%Mount{}`; detaches every hook when the flag is off. |
| 2.7 | `Samen.Observability.child_specs(app, replay: opts)` — one supervisor (buffer owner + monitor + handler); child list unchanged without the option. |
| 2.8 | Flag + caps config (`samen.replay`: sample rate, max frames, max bytes, max sessions/node, retention days), seeded nowhere by default (unknown ⇒ off); retention spec registered with `Samen.Retention`. |

Tests: flag-on mount writes exactly one session; flag-off writes zero rows **and** leaves no telemetry handler attached; a halted event is still recorded; caps truncate with `truncated?: true`; sanitizer byte-scan proves a `pii_*` plaintext appears nowhere in the table; freeform → shape; keep-list smuggling refused. Sabotages 351–358.

**Gate P2:** `samen_core` + `samen_web` suites green; the byte-scan test and the flag-detach test both flip under their sabotages; `MIX_ENV=prod` compile has capture children absent unless configured.

## Phase 3 — resolution, player, access (~4–5 days)

| Unit | Deliverable |
|---|---|
| 3.1 | `replay/decoder.ex` — stored JSONB → vocabulary; every frame re-validated through `FrameSchema.validate/1` (decode safety). |
| 3.2 | `replay/resolver.ex` — resolves `Ref`s on the **viewer's** scope through `Samen.Api.PiiResolution`; emits `Masked` / `:shredded` / `:gone` / `:denied` placeholders; batches per frame; never caches plaintext across requests. |
| 3.3 | `replay/player.ex` — session list, load, fold to frame N, timeline, drift marker (module MD5), and the `replay.viewed` audit write. |
| 3.4 | `samen_web/lib/samen/web/replay/access.ex` — operator requires an active impersonation session (`Samen.Impersonation.active?/3`, re-checked per batch); tenant admin may view its own org. |
| 3.5 | `samen_web/lib/samen/web/replay/renderer.ex` — inert re-render of the recorded view in an isolated LiveView with rebuilt assigns; handlers never run; unknown module ⇒ explicit "undecodable recording" state, never a crash. |
| 3.6 | `player_live.ex` + `index_live.ex` + `live.ex` chrome, mounted beside the existing `/operator/replay/:org_id` page; the timeline row links to the detail when the org is opted in. |
| 3.7 | Masking three proofs via `Samen.MaskingCase` (`resolve_on_plane/4`, `assert_plane_clear!/2`, `assert_plane_masked!/2`, `assert_leak_detected!/2`), plus a shred game-day test: shred the subject ⇒ every `Ref` to them renders `:shredded`, with zero replay rows rewritten. |

Sabotages 359–369 (R7–R12).

**Gate P3:** `samen_web` suite green; all three masking proofs and their twin flip; `./ci-fast.sh` green.

## Phase 4 — mounts, retention, docs (~1.5–2 days)

1. Opt in **one** host in dev (driftwood broker), seed the flag there; assert the tenant plane writes frames and the operator plane writes none.
2. Retention sweep wired into the host scheduler; test prunes a session past TTL and leaves one inside it.
3. `docs/guides/session-replay.md` rewritten: the two lanes, what is and is not recorded, how to opt an org in, how to read a replay, the shred behaviour, and the "step list vs recording" distinction the page must always state.
4. `README`/ADR index updated. **The decision record (`docs/adr/ADR-052-masked-session-replay.md`) was filed 2026-10-17, ahead of the build** (`PROPOSED`, §8 D1–D5 open) — so P4 **appends as-built notes** to it (the `§2.x.1 as built — and where it deviates` shape) instead of writing it from what shipped.
5. Round-2 whole-workstream re-gate.

**Final gate:** `./ci.sh` → `ROOT CI: ALL PASSED`; `scripts/sabotage.sh --range 350-<last>` all flip and restore byte-exact (run backgrounded or in chunks — the full harness exceeds the 600 s single-call ceiling).

---

## Definition of done

- No deployed environment can render a `phoenix_replay` route, and the dep is not compiled there (P0 test).
- An org without the flag writes zero replay rows and its LiveViews pay nothing after the first decision (handler detached, asserted).
- A stored frame contains no plaintext of a vault-routed attribute and no `vt_*` — proven by a byte-scan of the table, not by inspecting the payload builder.
- Operator-without-grant sees `••••`; with a reveal grant, clear; after shred, `:shredded`. All three plus the refutability twin.
- Opening a replay without an active impersonation session is denied and reads nothing; every open writes exactly one token-only audit row.
- `./ci.sh` green, sabotage range green, zero compile warnings.

## Risks, with the mitigation we actually have

| Risk | Mitigation |
|---|---|
| Buffer memory on a busy node | per-session byte/frame caps + `max_sessions` per node, all in config; truncation is visible, never silent. |
| A new scope assigns something nobody classified | default-deny: unknown term types are dropped, strings redacted; the schema verifier fails a raw-string field at build time. |
| Keep-lists become the new leak surface | keep-list entries are bounded keys, and their *values* still pass `PiiValueShape`; R5 is a named red path. |
| Stored frames decode into something explosive (atoms, large terms) | decode re-validates every frame through `FrameSchema`; no `binary_to_term`, JSONB only. |
| Code drift makes old frames undecodable | MD5 marker + visible banner + 14-day TTL; the player states it rather than guessing. |
| Host migration burden | `m_mount_replay_scope.eex` + gen probe + parity golden, so a generated app gets it for free. |
| Sabotage numbering collides with a concurrent branch | numbers are assigned at build time from `scripts/sabotages/`, same as every other gate. |

## Effort (serialized, includes the phase gates)

| Phase | Days |
|---|---|
| P0 spike | 0.5 |
| P1 vocabulary + schema + verifier | 1.5 |
| P2 capture | 3–4 |
| P3 resolve + player + access | 4–5 |
| P4 mounts, retention, docs, re-gate | 1.5–2 |
| **Total** | **~11–13** |

Add ~1 day if the `phoenix_replay` spike's persistence default turns out to need a migration in driftwood's dev repo; add ~1 day for the shred game-day if no existing host fixture can be shredded cheaply.
