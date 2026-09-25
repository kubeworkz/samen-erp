defmodule Samen.AI.AssistantAgentTest do
  @moduledoc """
  AssistantAgent's `Samen.AgentCase` proof (ADR-047 §7.2 check 1) — every
  `use Samen.AI.Agent` definition ships a non-vacuous scripted proof.

  This is the framework definition `Samen.AI.AssistantAgent` behind the
  per-assistant allowlist (P2): the row declares a SUBSET of its maximal
  `:tenant` surface, narrowed per-run by `Samen.AI.AssistantToolFilter`
  (`Samen.Web.AI.Server`). The proof below drives the definition directly
  through `Samen.AgentCase`/`Samen.AI.Provider.Scripted` — no assistant row,
  no HTTP — proving the loop, the EG2 `:tools` membership/history
  re-scrub, and the budget-honest floor on this definition.
  """

  use ExUnit.Case, async: false
  use Samen.AgentCase

  alias Samen.AI.Provider.Scripted
  alias SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
    Ecto.Adapters.SQL.Sandbox.mode(TestRepo, {:shared, self()})
    Scripted.reset()
    Samen.AI.Agent.Breaker.reset()

    on_exit(fn ->
      Scripted.reset()
      Samen.AI.Agent.Breaker.reset()
    end)

    :ok
  end

  defp scope(org_id) do
    %Samen.Scope{actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, plane: :tenant}}
  end

  defp new_scope, do: scope(Ash.UUID.generate())

  test "Samen.AI.AssistantAgent completes a simple goal via the scripted provider" do
    s = new_scope()
    script(final: "assistant done")

    assert {:ok, %{answer: "assistant done", run: run}} =
             run_scripted(Samen.AI.AssistantAgent, s, "hello assistant")

    run = assert_terminal!(run, :succeeded)
    assert run.current_turn == 1
    assert_masked_only_payloads!()
    assert_no_text_at_rest!(run, ["hello assistant", "assistant done"])
  end

  test "Samen.AI.AssistantAgent history re-scrub: turn 2's payload carries turn 1 through the chokepoint" do
    s = new_scope()
    script(continue: "step one", final: "assistant done")

    assert {:ok, %{answer: "assistant done", run: run}} =
             run_scripted(Samen.AI.AssistantAgent, s, "work the goal step by step")

    assert_history_accumulated!(2, ["step one"])
    assert_masked_only_payloads!()
    assert_no_text_at_rest!(run, ["step one", "assistant done"])
  end

  test "Samen.AI.AssistantAgent offers the resolved static defs on every turn (EG2 §4.2)" do
    s = new_scope()
    script(continue: "thinking", final: "done")

    assert {:ok, %{run: _run}} = run_scripted(Samen.AI.AssistantAgent, s, "goal")

    defs = Samen.AI.Agent.Tools.static_defs()
    sent = sent_tool_defs()
    assert length(sent) == 2

    # Declaration order is the resolved order; static_defs is registry-enumeration
    # order — compare as sets (sorted by name) so the gate does not bind to map
    # iteration order.
    sort_by_name = &Enum.sort_by(&1, fn %{"name" => n} -> n; %{name: n} -> n end)

    assert Enum.map(sent, sort_by_name) == [sort_by_name.(defs), sort_by_name.(defs)]
  end
end
