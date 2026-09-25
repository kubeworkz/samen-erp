# Samen Assistant — OpenClaw-lite Plan (HuggingFace BYOK)

**Date:** 2026-09-25
**Status:** Draft for review — no code yet
**Source ref:** https://github.com/lotsoftick/openclaw_client (React19/Vite/Express/SQLite multi-agent streaming chat)
**Host:** `samenerp` adopts; kernel lives in `samen_core` + `samen_web` (framework-first, ≈0 LOC per vertical)

## 1. Goal

Build a **lean, governed AI assistant** inside Samen — streaming chat + file-grounded answers + conversation history + optional tool turns — **reusing the shipped AI plane** (ADR-043 chokepoint, kernel, embeddings, agent loop, HF BYOK) and the existing router/mount seams. Explicitly **not** a full OpenClaw clone: no CLI gateway, no desktop auto-start, no 14 themes/PWA, no per-agent OS workspace.

> Leverage > novelty: every provider byte goes through `Samen.AI.Chokepoint` (INV-7). Samenerp authors ~1 router line + 1 assistant definition in P3.

## 2. Non-goals (v1)

- No Express/SQLite/JWT reimplementation — we already have Phoenix/Ash/Postgres/Oban + `Samen.Web.Auth` (`samen_session_token`, `Samen.Web.Auth.Plug`, `AuthGate`/`Operator.Authz` — just fixed in `b4e135f`).
- No CLI → model gateway (OpenClaw's `openclaw --version` + `openclaw auth status`). HF lives behind `Samen.AI.Provider` already.
- No theming/PWA. One Samen shell theme; installability is a later PWA pass if wanted.
- No unlimited agents. V1: **1 default `General` assistant per org** + up to 3 org-scoped custom assistants (cap enforced by policy). Not N agentic workspaces with isolated file trees.

## 3. OpenClaw feature map → Samen decision

| OpenClaw | What it is | Samen today | Plan |
|---|---|---|---|
| Multi-agent (model+identity+history) | N agents, each model/identity/history | `Samen.AI.Agent` durable loop (`Agent.Run`/`Turn`, `next_turn_at` watchdog, budgets, cancel) + `Driftwood.Support.TriageAgent` (13 LOC via `use Samen.AI.Agent` at `driftwood/lib/driftwood/support/triage_agent.ex`) — ADR-047 A1-A5 shipped. No tenant UX. | **Reuse loop.** New `Samen.AI.Assistant` resource (org-scoped, `name`/`goal_prompt`/`model_id`/`tools` allowlist). Mounted via `samen_ai_routes` — no new macro. |
| Streaming chat (thinking/output split) | SSE, separate thinking pane | `samen_core/lib/samen/scopes/ai/streamer.ex` (SSE `stream:true`, `{:hf_stream_chunk}` → pid) + `client.ex` BYOK proxy | **Wire to LiveView** (`push_event "chunk"` + JS hook). Split = model `reasoning` delta when provider gives it, else collapsed meta. |
| File uploads → workspace | Files saved to agent workspace for context | `Samen.Scopes.Primitives` `File` (vault-routed, `Samen.Files.upload/3` + `ChokepointGuard`, `samen_files_routes`) | **Reuse.** Composer drop → `Samen.Files` → attach as grounding context (allowlisted fields/embeddings; vault fields stay `••••` — EG3 grants never unlock embeddings per ADR-043 §7.2). |
| Conversations/title/search | Multi-convo/agent, editable title, searchable sidebar | `Samen.Scopes.Ai.Conversation` (`aic_conversation`, `title`/`model_id`/`status`/`message_count`/`total_tokens`) + `Samen.AI.Prompt` versioned + `samen_search_routes`/`command_palette` (⌘K) | **Extend Conversation → AssistantConversation** (or add `assistant_id` to existing). Title auto via `Generate` verb. Search via `Embeddings.search/3` + tsvector. |
| Auth | JWT admin `admin@admin.com/123456` | `Samen.Web.Auth` + `TenantGate`/`TenantAuthz` + operator `AuthGate` (spine-aware after `b4e135f`) | **Keep ours.** Assistant lives inside existing `live_session` `require_tenant` / `require_operator` gates. |
| Theming/PWA | 14 themes, installable | `Samen.UI` app shell, no PWA | **Defer.** |

## 4. What we already own (do not rebuild)

- **Chokepoint** `samen_core/lib/samen/ai/chokepoint.ex` — only minter of `%MaskedPayload{}` (Inspect-redacting), egress-mode `PiiResolution`, `vt_*` refusal `{:error,:pii_egress_refused}`, per-turn history re-scrub §3.2a, EG6 masked logs/telemetry, probe `Samen.AI.ChokepointAntiBypassProbeTest`.
- **Kernel** `Samen.AI.complete/4` (scope + prompt_ref + bindings + opts) + `Samen.AI.Provider` (Fake deterministic / `samen_anthropic` fail-honest `{:error,:not_configured}`), `SAMEN_AI_LIVE=1` live lane.
- **Catalog** `Samen.AI.Catalog` (runtime parity with `schema.dict.json`, metadata-only, §8) — grounding context fed to chokepoint.
- **Embeddings** pgvector REQUIRED (M3), `Samen.AI.Embeddings` org-scoped HNSW, `Embedder.Deterministic` for CI, `ai_prompt_masking` verifier cross-check.
- **Verbs** `Samen.AI.Verbs` (6) + `Samen.AI.Prompt` versioned resource — `Server.run_verb` already behind `Samen.Web.AI.Server`.
- **Agent loop** `Samen.AI.Agent` (checkpoint-per-turn, batch-per-job via `TurnWorker` + `agent_turn_due` watchdog, `next_turn_at` never-nil, transcript vault-routed under run DEK, budgets fail-honest, breaker/kill-switch, write via `Approvals.Gate` requester≠approver).
- **HF BYOK** `samen_core/lib/samen/scopes/ai/{api_key,crypto,client,streamer,token_validator,verify_credentials_worker}` + `/settings/huggingface` LiveView + daily Oban sweep — AES-256-GCM, SSE, usage via `prompt_log`/`analytics`.
- **Mount/router** `Samen.Web.Mount` + `Samen.Web.Router.samen_ai_routes/3` (currently mounts 6 AI surfaces: verbs/search/crm/analytics/support/agent) — existing `Samen.Web.AI.AgentLive` (`/ai/agents`) proves the `samen_ai_routes` adoption pattern (`driftwood` ≈0 LOC, `gate_a6_agent_slice_test.exs`).
- **Files/Search** primitives + `Samen.UI`.

Leverage target: new assistant adds **no new egress surface** — assistant is a chokepoint caller like verbs/agent.

## 5. Target design — Samen Assistant

**Tenancy:** Tenant `/ai/assistant` (primary) + optional operator `/operator/assistant` (same LiveView, operator plane actor, audited). Org-scoped, `OrgScope` + `PiiResolution` on every read.

**Assistant =** `Samen.AI.Assistant` row: `org_id`, `name` (`assistant.general` validated `~r/\A[a-z0-9][a-z0-9_.\-]*\z/` like agent), `title`, `system_prompt` (PII-scanned at write like `Prompt` body), `model_id` FK→ `Samen.Scopes.Ai.Model` (e.g. `meta-llama/Llama-3.1-8B-Instruct` default), `tools: {:array,:string}` closed enum from `ToolSurface` (T183, 4 surfaces), `status`. Seed `General` per org.

**Conversation:** `Samen.AI.AssistantConversation` (or evolve `aic_conversation` — add `assistant_id` + `messages` normalized) — `assistant_id`, `org_id`, `title`, `status: :active/:archived/:deleted`, `message_count`, `total_tokens`, vault-routed `messages` or child `AssistantMessage` rows (`role: user/assistant/tool`, `content`, `tool_calls`, `grounding_refs`, `token_counts`). Transcript inside same DEK envelope as `Agent.Run` (shred 90d, ADR-046). Title auto: first user msg → `Generate` verb (keyless in CI, live behind `SAMEN_AI_LIVE=1`).

**Turns:** P1 = direct `Samen.AI.complete/4` per message (history = prior messages, re-scrubbed). P2 = optional `Agent.run/start` per conversation turn (4-way tool intersection `Tools.resolve_definition` → `Max` — registry ∩ `tool_schema/0` ∩ surface ∩ declared ∩ policy; read executes, write → `WriteProposal` → `Approvals.Gate` → `:awaiting_approval`).

**Streaming:** LiveView `handle_event "send"` → resolve scope via `CurrentOrg` → `Chokepoint.seal` (allowlist `grounding` from `Catalog` + file/context) → `Provider.complete` routed to HF adapter (`Samen.Scopes.Ai.Client/Streamer` behind `Provider` behaviour) → `push_event "chunk"` → JS hook appends. Thinking pane = provider `reasoning`/`thinking` delta; HF inference (no native thinking) → collapsed meta.

## 6. Architecture (thin, one diagram)

```
Browser (Samen.Web.AI.AssistantLive, S6/6 of AI kit)
  │  live_session `require_tenant` + `Samen.Web.Auth.Plug` remember-me
  ├── send: scope = Mount.scope(mount, org_id)  (real actor, INV-2)
  ├── grounding: Catalog.grounding(scope) + file/context via allowlisted fields
  ├── Chokepoint.seal(scope, prompt, bindings, history, tools)  → MaskedPayload (egress masked, grant_egress? false, EG3 vault never embeds)
  ├── Provider.complete(MaskedPayload) — Fake in test, HF-Anthropic in prod (HF via samenerp BYOK key decrypt in-mem)
  │     └── HF inference: Samen.Scopes.Ai.Streamer.stream_generation/4 → {:hf_stream_chunk} → push_event
  ├── (P2) Agent.run/start(AssistantAgent, scope, goal, tools: assistant.tools) → Turn cursor → ToolResult → history
  └── persistence: Assistant/Conversation/Message (Postgres, OrgScope, vault-routed transcript, vector sidecar for recall)
```

No new egress probe surface — `ChokepointAntiBypassProbeTest` already crawls `samen_core/lib` + `samen_web/lib` for raw `Provider` calls / `MaskedPayload` construction.

## 7. Data model (2 resources, 1 migration, reuse 2)

- **New `Samen.AI.Assistant`** (`ast_assistant`, abbrev `ast`) — attributes above, `OrgScope` policy, `Pii` scan on `system_prompt`, `tool_schema` allowlist check. Domain: `Samen.AI.Domain` (host adds `Samen.AI.Domain` to `:ash_domains` — INV-5, already done for driftwood).
- **New `Samen.AI.AssistantConversation` + `AssistantMessage`** (or extend `aic_conversation` — prefer new to avoid mixing BYOK chat shape) — `org_id`, `assistant_id`, `title`, counters, `last_message_at`, vault-routed `transcript` JSON (`{goal, lines}` like `Agent.Run`), `archivable: true`. Policy `OrgScope`.
- **Reuse** `Samen.Scopes.Ai.Model` (model registry) + `PromptLog`/`Analytics` for usage.
- **Vector sidecar** — no new table; existing embedding pipeline over allowlisted non-PII fields, org-scoped HNSW, deterministic in CI.

## 8. Router / mount (framework-first, ≈0 LOC vertical)

Extend existing `samen_ai_routes :ai` table — add:

```
live "/assistant"              → Samen.Web.AI.AssistantLive (list)
live "/assistant/:id"          → Samen.Web.AI.AssistantLive (chat)
live "/assistant/:id/:conv_id" → Samen.Web.AI.AssistantLive (conversation)
```

Inside `samen_web/lib/samen/web/router.ex` `samen_ai_routes` macro's `__routes__(:ai, path)` table (same place `AgentLive` lives). Vertical keeps **one line**: `samen_ai_routes(:ai, Driftwood.Crm, repo: Driftwood.Repo, labels: %{ai_crm_resource: ..., ai_aggregate_resource: ...})` — already present in `driftwood/lib/driftwood_web/router.ex:335`. Zero new macro.

Auth: inherits `on_mount [{TenantAuthz, :require_tenant}]` (tenant) / operator variant inherits `require_operator`. HF key gate: if tenant has no valid `ApiKey`, render honest empty state linking to `/settings/huggingface` (same honesty as `Server.configuration_hint()` for `:not_configured`).

## 9. UI (LiveView, not React)

- **Left rail:** assistant picker (General + custom, create ≤3) + conversation list (search input = `Embeddings.search` + tsvector, editable title via `:rename`, archive/delete).
- **Center:** streaming chat. Message list: user bubble, assistant bubble (thinking collapsible, output markdown), tool cards (read inline, write proposal → “Request approval” → approvals UI). Composer: textarea + file drop zone (→ `Samen.Files` upload → grounding chip) + model picker (disabled if no key) + send. Streaming via `handle_info({:hf_stream_chunk, text})` + `push_event`.
- **Header:** model badge, token/price hint from `PromptLog`, `grant_plaintext_egress` badge (`••••` masked-by-default per §6.1; explicit opt-in surfaces the grant notice).
- **Honesty:** `SIMULATED` pill when `%Completion{simulated:true}` (Fake), `not_configured` hint verbatim from `Server.configuration_hint/0`, never fabricated answer.

Reuse `Samen.UI` (`app_shell`, `sidebar`, `topbar`, `pill`, `data_table`, `empty_state`, `ai_sidebar_nav`/`ai_tabs` from `samen_web/lib/samen/web/ai/components.ex`).

## 10. HuggingFace wiring (BYOK, no new vendor)

Do not add HF HTTP client to `samen_core` vendor-free core. Implement **`Samen.HuggingFace.Provider`** as a `Samen.AI.Provider` adapter **inside `samen_core`** behind the existing `Samen.Scopes.Ai.HttpAdapter` abstraction (INV-4: `samen_core` stays vendor-free of Anthropic SDK; same for HF). Resolution like `Server` → kernel:

```
AssistantLive → Server.assistant_run(scope, assistant, history, input, files)
  → Samen.AI.complete(scope, [assistant.system_prompt, Catalog grounding], bindings, provider: hf_provider)
  → Chokepoint → MaskedPayload → HuggingFace.Provider.complete (decrypts tenant ApiKey in-mem via KMS, calls Inference API, streams)
```

Key lifecycle: `/settings/huggingface` `ApiKey` (AES-256-GCM) → `TokenValidator.verify_key/1` at connect → `VerifyCredentialsWorker` daily sweep (02:00) → `Client`/`Streamer` decrypt-per-request + GC. 401 → flag `Setup Required` + honest UI; 429/5xx → fail-honest `{:error,:tenant_quota_exhausted/:upstream_error}`.

Model IDs: HF text-generation `meta-llama/Llama-3.1-8B-Instruct`, `mistralai/Mistral-7B-Instruct-v0.3`, `gpt2` (CI smoke). Registry in `Samen.Scopes.Ai.Model`.

## 11. Governance (ADR-043, no exceptions)

- Every assistant message → `Chokepoint` (`kind: :complete`, egress masked, history re-scrub §3.2a, `safe_segment?` check).
- Embeddings: only allowlisted non-PII fields via `Catalog` (`ai_prompt_masking` verifier); grants never unlock embedding (vectors outlive grants — crypto-shred per §7.2).
- Tools (P2): four-way intersection + `validate/2` + `vt_*` arg gate + `Agent.Context.build` + `ToolResult.render` ingress `Sanitize→Secrets.redact` (T182). Writes → `WriteProposal` → E3 approval (requester=AI principal, decider≠requester, CHECK).
- Org isolation: `OrgScope` on every read/vector/tool. Cross-org red test required.
- EG6: logs/telemetry = ids/counts only; `MaskedPayload` Inspect redacts.

## 12. Phased plan + acceptance

**P1 — MVP chat (no agent loop) — target: samenerp can chat streaming**
- Tasks: `Assistant` resource + seed General + `AssistantConversation/Message` + `AssistantLive` (list/chat, streaming, history, title auto) + HF provider adapter + file-drop grounding + model picker + honest empty states.
- Accept: `mix compile --warnings-as-errors` (3 apps) + `mix samen.verify.ai_prompt_masking` green + `MaskingCase` 3-proof on transcript (tenant clear→masked, `vt_*` refusal) + streaming integration test (Fake recording, no live key) + `templates_parity` still green (no new macro drift).
- Loc: ~400-500 LOC (2 resources, 1 LiveView, 1 Server func, 1 provider adapter, 1 migration).

**P2 — Tool-aware (activate loop) — assistant can read + propose writes**
- Tasks: wire `assistant.tools` → `Agent.Tools` resolver → `Agent.run/start` per turn → 2 read tools (`search_records`, `fetch_record`) opt-in via `tool_schema/0` → write path `WriteProposal` → approvals card (reuse `AgentLive` decision card) → operator assistant variant.
- Accept: `ToolSurface` verifier + `Agent` MaskingCase on tool result (`••••` vault field in rendered result) + cross-org tool red (foreign org → `:not_found`) + `Approvals` distinct-party CHECK not weakened + no new `samen.verify.*` bypass.
- Loc: ~300 LOC (tools opt-in, result render, LiveView tool cards).

**P3 — Memory & polish — assistant recalls like OpenClaw**
- Tasks: embedding-backed recall (allowlisted fields, org-scoped HNSW, deterministic in CI) + `PromptLog` analytics per assistant (tokens/cost) + conversation search ranking badge (simulated vs live) + budgeting/Cancel parity with `Agent` loop.
- Accept: `no-PII-in-vector` verifier still green + org-isolation vector test + analytics red (zero fabricated cost) + budget exhaustion `budget_exhausted` terminal never promotes partial answer.
- Loc: ~200 LOC.

**Total P1-P3:** ~1k LOC, zero vertical LOC beyond `samen_ai_routes` already present.

## 13. Verification (CI)

- Existing tiers keep running: `no_pan_columns`, `ai_prompt_masking` (RP-AI-1/2/4), `agent_coverage` (A7 raw-spawn lock), red-team tier (EG1-EG6, grant+multi-turn), `aggregate_privacy`.
- New assertions (inside `samen_web`): assistant transcript MaskingCase 3-proof + tool-result masking + org-scope + streaming `Fake` recording assert (zero canary/`vt_*` in payloads, vector rows, captured `CaptureLog`/telemetry).
- Sabotage: 1 patch that forces assistant to call `Provider` raw → probe flips; 1 that embeds vault field → verifier flips. Reverts byte-exact.

## 14. Risks

- **HF inference is not Chat Completions** — adapter must map `inputs`/`parameters` + SSE `data: {"token":{}}` shape to `Completion{text, usage, tool_calls, simulated}`. Mitigated: our `Streamer` already does this shape; add `tool_calls` shim for JSON `TOOL:` envelope fallback (agent loop's text parser).
- **Key per-tenant decrypt per chunk** — GC after request, no key in `MaskedPayload`/logs (EG6). Existing BYOK discipline.
- **Streaming LiveView backpressure** — bounded chunks, `push_event` + client hook, no PubSub in P1 (re-read on nav like `AgentLive` today — §8/A5 precedent).
- **Context growth** — P1 history = last N messages (bounded), re-scrubbed; compaction not in v1 (ADR-048 drafts, no code — budget exhaustion is terminal and honest).

## 15. Open decisions (need owner)

- Default model for General: `meta-llama/Llama-3.1-8B-Instruct` vs `mistralai/Mistral-7B-Instruct-v0.3` (HF availability + cost).
- Max assistants per org (3 vs 5) + max conversations per assistant (bounded?).
- Write approver: org-admin only vs operator — existing `approver_membership` seam at `driftwood/config.exs:321` already decides.

---
*Next action upon approval:* cut `_orch/tasks/` BATON for P1 (resources → provider adapter → LiveView) and open branch; keep this doc as traceability anchor for ADR-043 §10 eval.
