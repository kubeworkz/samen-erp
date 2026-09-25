defmodule Samen.AI.AssistantAgent do
  @moduledoc """
  The assistant's tool-aware agent definition (P2 — docs/plans/ai-assistant-openclaw-lite.md).

  P1 chats via `Samen.AI.complete/4` directly. P2 activates the durable
  `Samen.AI.Agent` loop when `assistant.tools != []`: the assistant's
  declared tools narrow the loop's five-way intersection
  (`Samen.AI.Agent.Tools` — registry ∩ opt-in ∩ surface ∩ declared ∩ policy).

  This module is the **single static definition** the tool-aware branch runs
  through. Its `tools:` is the superset of the assistant's allowed values
  (the closed `:tenant` surface, validated at write by `Samen.AI.AssistantChange`);
  per-assistant narrowing is enforced before the run (subset check) so the
  model is never offered a tool the assistant did not declare. The definition's
  `goal_prompt` is generic — the per-assistant `system_prompt` rides the run's
  `goal` (prepended, re-scrubbed per turn) so the vault-routed `system_prompt`
  stays an authored, validated label without forking a module per row.

  The 13-line `Driftwood.Support.TriageAgent` remains the vertical slice's
  authored definition; this module is framework — the assistant row is the
  tenant's definition, mounted via `samen_ai_routes`.
  """

  use Samen.AI.Agent,
    name: "assistant.chat",
    goal_prompt: """
    You are the assistant for this organization. Work the goal step by step.
    Use search_records to find relevant records, fetch_record to read them, and — if the request needs an owner — propose one with assign_record_owner. Personal fields read back masked (••••); never guess a masked value and never ask for one.
    assign_record_owner does NOT take effect when you call it: it opens an approval that a person must approve. Reply FINAL: <answer> when done.
    """,
    tools: ["search_records", "fetch_record", "assign_record_owner"]
end
