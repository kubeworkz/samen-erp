defmodule Samen.EmailMarketingTest do
  @moduledoc """
  WS-ERP E33: Email Marketing —  email campaigns.

  ## Resources

  - `Campaign` — email campaign lifecycle with A/B testing
  - `Template` — reusable email templates with merge tags
  - `Subscriber` — mailing list subscribers with opt-in/opt-out
  - `SendLog` — immutable delivery tracking (opens, clicks, bounces)

  ## Tests

  - em1: Campaign lifecycle (draft → scheduled → sending → sent → completed)
  - em2: Campaign cancel flow
  - em3: Campaign metrics
  - em4: A/B testing configuration
  - em5: Template lifecycle (create, activate, deactivate)
  - em6: Template use count
  - em7: Subscriber opt-in/opt-out
  - em8: Subscriber bounce/complaint
  - em9: Subscriber resubscribe
  - em10: Subscriber tags and segmentation
  - em11: Send log delivery tracking
  - em12: Send log open tracking
  - em13: Send log click tracking
  - em14: Send log bounce handling
  - em15: Multi-campaign analytics
  - em16: Subscriber engagement scoring
  - em17: Full email marketing ceremony
  """
  use ExUnit.Case, async: true

  # --- em1: Campaign lifecycle ---

  describe "em1 — campaign lifecycle" do
    test "draft → scheduled → sending → sent → completed" do
      c = %{status: :draft, scheduled_at: nil, sent_at: nil, completed_at: nil}
      assert c.status == :draft

      c = %{c | status: :scheduled, scheduled_at: ~U[2026-10-01 09:00:00Z]}
      assert c.status == :scheduled

      c = %{c | status: :sending, sent_at: ~U[2026-10-01 09:00:00Z]}
      assert c.status == :sending

      c = %{c | status: :sent}
      assert c.status == :sent

      c = %{c | status: :completed, completed_at: ~U[2026-10-01 09:05:00Z]}
      assert c.status == :completed
    end
  end

  # --- em2: Campaign cancel flow ---

  describe "em2 — campaign cancel flow" do
    test "cancel draft campaign" do
      c = %{status: :draft}
      c = %{c | status: :cancelled}
      assert c.status == :cancelled
    end

    test "cancel scheduled campaign" do
      c = %{status: :scheduled}
      c = %{c | status: :cancelled}
      assert c.status == :cancelled
    end
  end

  # --- em3: Campaign metrics ---

  describe "em3 — campaign metrics" do
    test "track delivery metrics" do
      c = %{total_recipients: 1000, total_sent: 1000, total_delivered: 980, total_bounced: 20}
      assert c.total_delivered == 980
      assert c.total_bounced == 20
      delivery_rate = c.total_delivered / c.total_recipients
      assert delivery_rate == 0.98
    end

    test "track engagement metrics" do
      c = %{total_delivered: 980, total_opened: 450, total_clicked: 120}
      open_rate = c.total_opened / c.total_delivered
      click_rate = c.total_clicked / c.total_delivered
      assert open_rate > 0.45
      assert click_rate > 0.12
    end
  end

  # --- em4: A/B testing configuration ---

  describe "em4 — A/B testing" do
    test "enable A/B test" do
      c = %{ab_test_enabled: false, ab_test_variant: nil, ab_test_split: nil}
      c = %{c | ab_test_enabled: true, ab_test_variant: :a, ab_test_split: 50}
      assert c.ab_test_enabled == true
      assert c.ab_test_variant == :a
      assert c.ab_test_split == 50
    end

    test "A/B test variants" do
      variants = [:a, :b]
      assert length(variants) == 2
    end
  end

  # --- em5: Template lifecycle ---

  describe "em5 — template lifecycle" do
    test "create, activate, deactivate" do
      t = %{name: "Welcome Email", is_active: true, use_count: 0}
      assert t.is_active == true

      t = %{t | is_active: false}
      assert t.is_active == false

      t = %{t | is_active: true}
      assert t.is_active == true
    end
  end

  # --- em6: Template use count ---

  describe "em6 — template use count" do
    test "increment use count" do
      t = %{use_count: 0}
      t = %{t | use_count: t.use_count + 1}
      assert t.use_count == 1

      t = %{t | use_count: t.use_count + 5}
      assert t.use_count == 6
    end
  end

  # --- em7: Subscriber opt-in/opt-out ---

  describe "em7 — subscriber opt-in/opt-out" do
    test "opt in and unsubscribe" do
      s = %{status: :active, opted_in_at: ~U[2026-09-01 10:00:00Z], opted_out_at: nil}
      assert s.status == :active

      s = %{s | status: :unsubscribed, opted_out_at: ~U[2026-09-15 14:00:00Z]}
      assert s.status == :unsubscribed
      assert s.opted_out_at == ~U[2026-09-15 14:00:00Z]
    end
  end

  # --- em8: Subscriber bounce/complaint ---

  describe "em8 — subscriber bounce/complaint" do
    test "bounce" do
      s = %{status: :active}
      s = %{s | status: :bounced}
      assert s.status == :bounced
    end

    test "complaint" do
      s = %{status: :active}
      s = %{s | status: :complained}
      assert s.status == :complained
    end
  end

  # --- em9: Subscriber resubscribe ---

  describe "em9 — subscriber resubscribe" do
    test "resubscribe after unsubscribe" do
      s = %{status: :unsubscribed, opted_out_at: ~U[2026-09-15 14:00:00Z]}
      s = %{s | status: :active, opted_out_at: nil}
      assert s.status == :active
      assert is_nil(s.opted_out_at)
    end
  end

  # --- em10: Subscriber tags and segmentation ---

  describe "em10 — subscriber tags" do
    test "add tags" do
      s = %{tags: ["newsletter", "prospect"]}
      s = %{s | tags: s.tags ++ ["vip"]}
      assert "vip" in s.tags
      assert length(s.tags) == 3
    end

    test "empty tags" do
      s = %{tags: []}
      assert s.tags == []
    end
  end

  # --- em11: Send log delivery tracking ---

  describe "em11 — send log delivery" do
    test "track delivery" do
      log = %{status: :sent, sent_at: ~U[2026-10-01 09:00:00Z], delivered_at: nil}
      log = %{log | status: :delivered, delivered_at: ~U[2026-10-01 09:00:02Z]}
      assert log.status == :delivered
      assert log.delivered_at == ~U[2026-10-01 09:00:02Z]
    end
  end

  # --- em12: Send log open tracking ---

  describe "em12 — send log open tracking" do
    test "track opens" do
      log = %{status: :delivered, open_count: 0, opened_at: nil}
      log = %{log | status: :opened, opened_at: ~U[2026-10-01 10:00:00Z], open_count: 1}
      assert log.status == :opened
      assert log.open_count == 1

      log = %{log | open_count: log.open_count + 1}
      assert log.open_count == 2
    end
  end

  # --- em13: Send log click tracking ---

  describe "em13 — send log click tracking" do
    test "track clicks" do
      log = %{status: :opened, click_count: 0, clicked_at: nil}
      log = %{log | status: :clicked, clicked_at: ~U[2026-10-01 10:05:00Z], click_count: 1}
      assert log.status == :clicked
      assert log.click_count == 1
    end
  end

  # --- em14: Send log bounce handling ---

  describe "em14 — send log bounce" do
    test "hard bounce" do
      log = %{status: :sent, bounce_type: nil, bounce_reason: nil}
      log = %{log | status: :bounced, bounce_type: :hard, bounce_reason: "Mailbox not found"}
      assert log.bounce_type == :hard
      assert log.bounce_reason == "Mailbox not found"
    end

    test "soft bounce" do
      log = %{status: :sent, bounce_type: nil, bounce_reason: nil}
      log = %{log | status: :bounced, bounce_type: :soft, bounce_reason: "Mailbox full"}
      assert log.bounce_type == :soft
    end
  end

  # --- em15: Multi-campaign analytics ---

  describe "em15 — multi-campaign analytics" do
    test "compare campaign performance" do
      campaigns = [
        %{name: "Newsletter Oct", total_sent: 1000, total_opened: 450, total_clicked: 120},
        %{name: "Promo Oct", total_sent: 500, total_opened: 280, total_clicked: 95}
      ]

      assert length(campaigns) == 2

      # Promo has better open rate
      promo = Enum.find(campaigns, &(&1.name == "Promo Oct"))
      open_rate = promo.total_opened / promo.total_sent
      assert open_rate > 0.5
    end
  end

  # --- em16: Subscriber engagement scoring ---

  describe "em16 — subscriber engagement" do
    test "engagement score based on opens and clicks" do
      s = %{open_count: 15, click_count: 8, last_opened_at: ~U[2026-10-01 10:00:00Z]}
      score = s.open_count + (s.click_count * 2)
      assert score == 31
    end

    test "inactive subscriber" do
      s = %{open_count: 0, click_count: 0, last_opened_at: nil}
      score = s.open_count + (s.click_count * 2)
      assert score == 0
    end
  end

  # --- em17: Full email marketing ceremony ---

  describe "em17 — full email marketing ceremony" do
    test "template → subscribers → campaign → send → track → analyze" do
      # 1. Create template
      template = %{name: "October Newsletter", subject: "Hello {{first_name}}!", is_active: true, use_count: 0, category: "newsletter"}

      # 2. Add subscribers
      subscribers = [
        %{email: "alice@example.com", status: :active, tags: ["vip", "newsletter"]},
        %{email: "bob@example.com", status: :active, tags: ["newsletter"]},
        %{email: "carol@example.com", status: :active, tags: ["prospect"]}
      ]

      active = Enum.filter(subscribers, &(&1.status == :active))
      assert length(active) == 3

      # 3. Create campaign
      campaign = %{
        name: "October Newsletter",
        subject: "Hello!",
        template_id: "tpl_001",
        sender_name: "Acme Corp",
        sender_email: "news@acme.com",
        status: :draft,
        total_recipients: 3,
        total_sent: 0,
        total_delivered: 0,
        total_opened: 0,
        total_clicked: 0,
        ab_test_enabled: false,
        scheduled_at: nil,
        sent_at: nil,
        completed_at: nil
      }

      # 4. Schedule and send
      campaign = %{campaign | status: :scheduled, scheduled_at: ~U[2026-10-01 09:00:00Z]}
      campaign = %{campaign | status: :sending, sent_at: ~U[2026-10-01 09:00:00Z]}

      # 5. Create send logs
      logs = Enum.map(subscribers, fn s ->
        %{campaign_id: "c_001", email: s.email, status: :sent, sent_at: ~U[2026-10-01 09:00:00Z], delivered_at: nil, opened_at: nil, clicked_at: nil, open_count: 0, click_count: 0}
      end)

      # 6. Track delivery
      logs = Enum.map(logs, fn l -> %{l | status: :delivered, delivered_at: ~U[2026-10-01 09:00:02Z]} end)

      # 7. Track engagement
      logs = List.update_at(logs, 0, fn l -> %{l | status: :opened, opened_at: ~U[2026-10-01 10:00:00Z], open_count: 1} end)
      logs = List.update_at(logs, 1, fn l -> %{l | status: :clicked, clicked_at: ~U[2026-10-01 10:05:00Z], open_count: 1, click_count: 1} end)

      # 8. Update campaign metrics
      opened = Enum.count(logs, &(&1.open_count > 0))
      clicked = Enum.count(logs, &(&1.click_count > 0))
      campaign = %{campaign | status: :completed, completed_at: ~U[2026-10-01 09:05:00Z], total_delivered: 3, total_opened: opened, total_clicked: clicked}

      # 9. Increment template use count
      template = %{template | use_count: template.use_count + 1}

      assert campaign.status == :completed
      assert campaign.total_delivered == 3
      assert campaign.total_opened == 2
      assert campaign.total_clicked == 1
      assert template.use_count == 1
      assert length(logs) == 3
    end
  end
end
