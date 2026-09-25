defmodule Samen.AI.AssistantToolFilter do
  @moduledoc """
  Per-assistant tool allowlist gate (P2) — a `Samen.AI.Agent.Hook` that
  narrows `Samen.AI.AssistantAgent`'s maximal `:tenant` tool set to the
  assistant row's declared `tools` (docs/plans/ai-assistant-openclaw-lite.md).

  `AssistantAgent` declares the maximal `:tenant` surface (all opted-in
  tenant tools: `search_records`, `fetch_record`, `assign_record_owner`). An
  assistant row may declare any SUBSET — enforced at write by
  `Samen.AI.AssistantChange`. The loop itself resolves `AssistantAgent`'s
  definition, so without this hook a model offered the superset could still
  call a tool the assistant did not declare — widening. This hook closes
  that by blocking any `kind` not in the per-run allowlist the Server seam
  publishes before `Agent.run/4`.

  The allowlist rides the process dictionary (`:assistant_allowed_tools`)
  because hooks are modules, not instances — `Agent.run/4` is synchronous on
  the calling process, so the store is per-run. `nil`/missing allowlist
  means \"no restriction\" (the hook defers) so the module is safe to leave
  in host config without breaking non-assistant agent runs. A durable
  `Agent.start/4` path would need the allowlist on the Run row — not shipped
  in P2; tool-aware assistant turns are synchronous `run/4` only.

  Only `{:block, reason}` is used — the honest refusal turn `:hook_blocked`
  (the run continues under budgets — never a silent skip). `:halt` is not
  issued from here; a non-allowlisted kind is a per-call narrowing, not a
  per-run policy decision. `vt_`-bearing reason strings cannot arise here.
  """

  @behaviour Samen.AI.Agent.Hook

  @impl true
  def call(:after_tool_request, %{kind: kind}) when is_binary(kind) do
    if allowed?(kind), do: :ok, else: {:block, "assistant_tool_not_declared"}
  end

  def call(:before_tool_call, %{kind: kind}) when is_binary(kind) do
    if allowed?(kind), do: :ok, else: {:block, "assistant_tool_not_declared"}
  end

  def call(_point, _ctx), do: :ok

  defp allowed?(kind) do
    case Process.get(:assistant_allowed_tools) do
      nil -> true
      allowed when is_list(allowed) -> kind in allowed
      _ -> true
    end
  end
end
