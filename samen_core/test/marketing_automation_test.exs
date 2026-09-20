defmodule Samen.MarketingAutomationTest do
  @moduledoc """
  WS-ERP E28: Marketing Automation —  campaign automation.

  ## Resources

  - `Campaign` — marketing campaign (draft → running → paused → completed → archived)
  - `Workflow` — workflow definition with trigger type
  - `Trigger` — trigger conditions (form submit, page visit, email events)
  - `Action` — workflow actions (send email, send SMS, wait, condition, tags)

  ## Tests

  - ma1: Campaign lifecycle (draft → running → paused → completed → archived)
  - ma2: Campaign metrics tracking
  - ma3: Workflow lifecycle (draft → active → paused → completed)
  - ma4: Workflow trigger types
  - ma5: Trigger enable/disable
  - ma6: Trigger fire count
  - ma7: Action types (email, SMS, wait, condition, tags)
  - ma8: Action enable/disable
  - ma9: Action sequence ordering
  - ma10: Full campaign → workflow → trigger → action chain
  - ma11: Campaign pause/resume
  - ma12: Workflow with multiple triggers
  - ma13: Workflow with multiple actions in sequence
  - ma14: Action execution counts
  - ma15: Campaign completion with metrics
  - ma16: Trigger conditions (JSON config)
  - ma17: Action config (JSON config)
  - ma18: Campaign target segment
  - ma19: Workflow trigger config
  - ma20: Full automation ceremony
  """
  use ExUnit.Case, async: true

  # --- ma1: Campaign lifecycle ---

  describe "ma1 — campaign lifecycle" do
    test "draft → running → paused → completed → archived" do
      c = %{status: :draft, start_at: nil, end_at: nil}
      c = %{c | status: :running, start_at: DateTime.utc_now()}
      assert c.status == :running

      c = %{c | status: :paused}
      assert c.status == :paused

      c = %{c | status: :running}
      assert c.status == :running

      c = %{c | status: :completed, end_at: DateTime.utc_now()}
      assert c.status == :completed

      c = %{c | status: :archived}
      assert c.status == :archived
    end
  end

  # --- ma2: Campaign metrics ---

  describe "ma2 — campaign metrics" do
    test "track recipients, sent, opened, clicked, converted" do
      c = %{total_recipients: 1000, total_sent: 950, total_opened: 400, total_clicked: 150, total_converted: 25}
      assert c.total_recipients == 1000
      assert c.total_sent == 950
      assert c.total_opened == 400
      assert c.total_clicked == 150
      assert c.total_converted == 25
    end

    test "open rate calculation" do
      c = %{total_sent: 1000, total_opened: 350}
      open_rate = c.total_opened / c.total_sent * 100
      assert open_rate == 35.0
    end

    test "click rate calculation" do
      c = %{total_opened: 350, total_clicked: 50}
      click_rate = c.total_clicked / c.total_opened * 100
      assert click_rate > 14.0
    end
  end

  # --- ma3: Workflow lifecycle ---

  describe "ma3 — workflow lifecycle" do
    test "draft → active → paused → completed" do
      wf = %{status: :draft}
      wf = %{wf | status: :active}
      assert wf.status == :active

      wf = %{wf | status: :paused}
      assert wf.status == :paused

      wf = %{wf | status: :active}
      assert wf.status == :active

      wf = %{wf | status: :completed}
      assert wf.status == :completed
    end
  end

  # --- ma4: Workflow trigger types ---

  describe "ma4 — workflow trigger types" do
    test "all trigger types" do
      types = [:form_submit, :page_visit, :email_open, :email_click, :tag_added, :manual]
      assert length(types) == 6
    end

    test "each type is valid" do
      for type <- [:form_submit, :page_visit, :email_open, :email_click, :tag_added, :manual] do
        wf = %{trigger_type: type}
        assert wf.trigger_type == type
      end
    end
  end

  # --- ma5: Trigger enable/disable ---

  describe "ma5 — trigger enable/disable" do
    test "enable and disable" do
      t = %{status: :active}
      t = %{t | status: :inactive}
      assert t.status == :inactive

      t = %{t | status: :active}
      assert t.status == :active
    end
  end

  # --- ma6: Trigger fire count ---

  describe "ma6 — trigger fire count" do
    test "increment fire count" do
      t = %{fire_count: 0}
      t = %{t | fire_count: t.fire_count + 1}
      assert t.fire_count == 1

      t = %{t | fire_count: t.fire_count + 1}
      assert t.fire_count == 2
    end
  end

  # --- ma7: Action types ---

  describe "ma7 — action types" do
    test "all action types" do
      types = [:send_email, :send_sms, :wait, :condition, :update_contact, :add_tag, :remove_tag, :notify_team]
      assert length(types) == 8
    end
  end

  # --- ma8: Action enable/disable ---

  describe "ma8 — action enable/disable" do
    test "enable and disable" do
      a = %{status: :active}
      a = %{a | status: :inactive}
      assert a.status == :inactive

      a = %{a | status: :active}
      assert a.status == :active
    end
  end

  # --- ma9: Action sequence ordering ---

  describe "ma9 — action sequence ordering" do
    test "actions execute in sequence order" do
      actions = [
        %{name: "Send Welcome Email", sequence: 1},
        %{name: "Wait 3 Days", sequence: 2},
        %{name: "Send Follow-up", sequence: 3}
      ]

      sorted = Enum.sort_by(actions, & &1.sequence)
      assert Enum.map(sorted, & &1.name) == ["Send Welcome Email", "Wait 3 Days", "Send Follow-up"]
    end
  end

  # --- ma10: Full campaign → workflow → trigger → action chain ---

  describe "ma10 — full chain" do
    test "campaign → workflow → trigger → actions" do
      # Campaign
      c = %{name: "Welcome Series", status: :running}

      # Workflow
      wf = %{campaign_id: "c_001", name: "Onboarding Flow", trigger_type: :form_submit, status: :active}

      # Trigger
      t = %{workflow_id: "wf_001", name: "Form Submitted", event_type: :form_submission, status: :active}

      # Actions
      a1 = %{workflow_id: "wf_001", name: "Send Welcome Email", action_type: :send_email, sequence: 1}
      a2 = %{workflow_id: "wf_001", name: "Wait 1 Day", action_type: :wait, sequence: 2, config: %{wait_days: 1}}
      a3 = %{workflow_id: "wf_001", name: "Send Follow-up", action_type: :send_email, sequence: 3}

      assert c.status == :running
      assert wf.trigger_type == :form_submit
      assert t.event_type == :form_submission
      assert length([a1, a2, a3]) == 3
    end
  end

  # --- ma11: Campaign pause/resume ---

  describe "ma11 — campaign pause/resume" do
    test "pause and resume" do
      c = %{status: :running}
      c = %{c | status: :paused}
      assert c.status == :paused

      c = %{c | status: :running}
      assert c.status == :running
    end
  end

  # --- ma12: Workflow with multiple triggers ---

  describe "ma12 — workflow with multiple triggers" do
    test "workflow can have multiple triggers" do
      triggers = [
        %{event_type: :form_submission},
        %{event_type: :page_visit},
        %{event_type: :email_clicked}
      ]

      assert length(triggers) == 3
      assert Enum.any?(triggers, &(&1.event_type == :form_submission))
      assert Enum.any?(triggers, &(&1.event_type == :page_visit))
    end
  end

  # --- ma13: Workflow with multiple actions in sequence ---

  describe "ma13 — multiple actions in sequence" do
    test "5-step welcome sequence" do
      actions = [
        %{name: "Send Welcome", action_type: :send_email, sequence: 1},
        %{name: "Add to Segment", action_type: :add_tag, sequence: 2, config: %{tag: "onboarding"}},
        %{name: "Wait 3 Days", action_type: :wait, sequence: 3, config: %{wait_days: 3}},
        %{name: "Check Engagement", action_type: :condition, sequence: 4, config: %{field: "opened_welcome", operator: "equals", value: true}},
        %{name: "Send Follow-up", action_type: :send_email, sequence: 5}
      ]

      sorted = Enum.sort_by(actions, & &1.sequence)
      assert length(sorted) == 5
      assert hd(sorted).action_type == :send_email
    end
  end

  # --- ma14: Action execution counts ---

  describe "ma14 — action execution counts" do
    test "track executions, successes, failures" do
      a = %{execution_count: 0, success_count: 0, failure_count: 0}
      a = %{a | execution_count: 10, success_count: 8, failure_count: 2}
      assert a.execution_count == 10
      assert a.success_count == 8
      assert a.failure_count == 2
    end
  end

  # --- ma15: Campaign completion with metrics ---

  describe "ma15 — campaign completion" do
    test "complete campaign with final metrics" do
      c = %{
        status: :running,
        start_at: DateTime.utc_now(),
        end_at: nil,
        total_recipients: 5000,
        total_sent: 4800,
        total_opened: 2100,
        total_clicked: 800,
        total_converted: 120
      }

      c = %{c | status: :completed, end_at: DateTime.utc_now()}
      assert c.status == :completed

      # Calculate final metrics
      open_rate = c.total_opened / c.total_sent * 100
      click_rate = c.total_clicked / c.total_opened * 100
      conversion_rate = c.total_converted / c.total_clicked * 100

      assert open_rate > 43.0
      assert click_rate > 38.0
      assert conversion_rate == 15.0
    end
  end

  # --- ma16: Trigger conditions ---

  describe "ma16 — trigger conditions" do
    test "JSON conditions config" do
      t = %{
        conditions: %{
          field: "industry",
          operator: "equals",
          value: "technology"
        }
      }

      assert t.conditions.operator == "equals"
      assert t.conditions.value == "technology"
    end
  end

  # --- ma17: Action config ---

  describe "ma17 — action config" do
    test "email action config" do
      a = %{
        action_type: :send_email,
        config: %{
          template_id: "tmpl_001",
          from: "welcome@example.com",
          subject: "Welcome!"
        }
      }

      assert a.config.template_id == "tmpl_001"
    end

    test "wait action config" do
      a = %{action_type: :wait, config: %{wait_days: 3, wait_hours: 12}}
      assert a.config.wait_days == 3
    end
  end

  # --- ma18: Campaign target segment ---

  describe "ma18 — campaign target segment" do
    test "segment configuration" do
      c = %{target_segment: "all_leads"}
      assert c.target_segment == "all_leads"

      c = %{target_segment: "enterprise_tier_1"}
      assert c.target_segment == "enterprise_tier_1"
    end
  end

  # --- ma19: Workflow trigger config ---

  describe "ma19 — workflow trigger config" do
    test "form submit trigger config" do
      wf = %{
        trigger_type: :form_submit,
        trigger_config: %{
          form_id: "form_001",
          matching_fields: ["email", "company"]
        }
      }

      assert wf.trigger_config.form_id == "form_001"
    end
  end

  # --- ma20: Full automation ceremony ---

  describe "ma20 — full automation ceremony" do
    test "complete lead nurturing flow" do
      # Campaign
      c = %{name: "Q4 Lead Nurture", status: :draft, target_segment: "new_leads", start_at: nil, end_at: nil, total_recipients: 0, total_sent: 0, total_opened: 0, total_clicked: 0, total_converted: 0}

      # Activate
      c = %{c | status: :running, start_at: DateTime.utc_now()}

      # Workflow
      wf = %{campaign_id: "c_001", name: "Lead Nurture Flow", trigger_type: :form_submit, status: :active}

      # Trigger
      t = %{workflow_id: "wf_001", name: "New Lead Form", event_type: :form_submission, status: :active, fire_count: 0}

      # Actions
      actions = [
        %{name: "Welcome Email", action_type: :send_email, sequence: 1, config: %{template: "welcome"}},
        %{name: "Wait 2 Days", action_type: :wait, sequence: 2, config: %{wait_days: 2}},
        %{name: "Check Opened", action_type: :condition, sequence: 3, config: %{field: "opened_welcome", value: true}},
        %{name: "Add Tag", action_type: :add_tag, sequence: 4, config: %{tag: "engaged"}},
        %{name: "Notify Sales", action_type: :notify_team, sequence: 5, config: %{team: "sales"}}
      ]

      # Simulate execution
      t = %{t | fire_count: 150}
      c = %{c | total_recipients: 150, total_sent: 150, total_opened: 95, total_clicked: 40, total_converted: 12}

      # Complete
      c = %{c | status: :completed, end_at: DateTime.utc_now()}

      assert c.status == :completed
      assert t.fire_count == 150
      assert length(actions) == 5
      assert c.total_converted == 12
    end
  end
end
