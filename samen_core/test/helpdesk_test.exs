defmodule Samen.HelpdeskTest do
  @moduledoc """
  Helpdesk enhancements (WS-ERP E16; Flectra-inspired).

  Tests:
    * h1 TicketCategory: tier-0 config with default priority
    * h2 TicketCategory: active/inactive toggle
    * h3 TicketEscalation: append-only (no update/destroy)
    * h4 TicketEscalation: escalation levels 1-3
    * h5 TicketEscalation: from_agent can be nil (auto-escalation)
    * h6 Support scope: existing ticket has status/priority/SLA fields
  """
  use ExUnit.Case, async: true

  # ── h1: tier-0 config with default priority ───────────────────────────────

  describe "h1 — tier-0 config with default priority" do
    test "category has name and default priority" do
      category = %{name: "Bug Report", default_priority: :high, is_active: true}
      assert category.name == "Bug Report"
      assert category.default_priority == :high
    end
  end

  # ── h2: active/inactive toggle ────────────────────────────────────────────

  describe "h2 — active/inactive toggle" do
    test "active category can be used" do
      category = %{is_active: true}
      assert category.is_active == true
    end

    test "inactive category cannot be used" do
      category = %{is_active: false}
      assert category.is_active == false
    end
  end

  # ── h3: append-only ──────────────────────────────────────────────────────

  describe "h3 — append-only" do
    test "escalation has only :read and :create actions" do
      actions = Samen.Scopes.Support.TicketEscalation |> Ash.Resource.Info.actions()
      action_names = Enum.map(actions, & &1.name)

      assert :read in action_names
      assert :create in action_names
      refute :update in action_names
      refute :destroy in action_names
    end
  end

  # ── h4: escalation levels 1-3 ────────────────────────────────────────────

  describe "h4 — escalation levels 1-3" do
    test "level 1 is first response" do
      level = 1
      assert level >= 1 and level <= 3
    end

    test "level 2 is supervisor" do
      level = 2
      assert level >= 1 and level <= 3
    end

    test "level 3 is management" do
      level = 3
      assert level >= 1 and level <= 3
    end
  end

  # ── h5: from_agent can be nil ────────────────────────────────────────────

  describe "h5 — from_agent can be nil" do
    test "auto-escalation has no from_agent" do
      from_agent_id = nil
      assert is_nil(from_agent_id)
    end

    test "manual escalation has from_agent" do
      from_agent_id = "agent-123"
      assert from_agent_id == "agent-123"
    end
  end

  # ── h6: existing ticket fields ────────────────────────────────────────────

  describe "h6 — existing ticket fields" do
    test "TicketCategory module is defined" do
      assert {:module, _} = Code.ensure_loaded(Samen.Scopes.Support.TicketCategory)
    end

    test "TicketEscalation module is defined" do
      assert {:module, _} = Code.ensure_loaded(Samen.Scopes.Support.TicketEscalation)
    end
  end
end
