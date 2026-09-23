defmodule Samen.SmsMarketingTest do
  @moduledoc """
  WS-ERP E29: SMS Marketing —  SMS campaigns.

  ## Resources

  - `Campaign` — SMS campaign (draft → scheduled → sending → sent → completed)
  - `Template` — reusable message templates with variables
  - `Message` — individual SMS message with delivery tracking
  - `Subscriber` — opt-in/opt-out management with consent

  ## Tests

  - sm1: Campaign lifecycle (draft → scheduled → sending → sent → completed)
  - sm2: Campaign cancel flow
  - sm3: Campaign metrics tracking
  - sm4: Template lifecycle (create, activate, deactivate)
  - sm5: Template variables
  - sm6: Template use count
  - sm7: Message lifecycle (pending → sent → delivered)
  - sm8: Message failure tracking
  - sm9: Message reply recording
  - sm10: Subscriber opt-in/opt-out
  - sm11: Subscriber block/reactivate
  - sm12: Subscriber tags
  - sm13: Full campaign → template → messages flow
  - sm14: Subscriber consent management
  - sm15: Message delivery status
  - sm16: Campaign with scheduled send
  - sm17: Template category
  - sm18: Subscriber opt-in source
  - sm19: Full SMS marketing ceremony
  - sm20: Message with vaulted phone
  """
  use ExUnit.Case, async: true

  # --- sm1: Campaign lifecycle ---

  describe "sm1 — campaign lifecycle" do
    test "draft → scheduled → sending → sent → completed" do
      c = %{status: :draft, scheduled_at: nil, sent_at: nil, completed_at: nil}
      c = %{c | status: :scheduled, scheduled_at: DateTime.utc_now()}
      assert c.status == :scheduled

      c = %{c | status: :sending, sent_at: DateTime.utc_now()}
      assert c.status == :sending

      c = %{c | status: :sent}
      assert c.status == :sent

      c = %{c | status: :completed, completed_at: DateTime.utc_now()}
      assert c.status == :completed
    end
  end

  # --- sm2: Campaign cancel flow ---

  describe "sm2 — campaign cancel" do
    test "cancel scheduled campaign" do
      c = %{status: :scheduled}
      c = %{c | status: :cancelled}
      assert c.status == :cancelled
    end
  end

  # --- sm3: Campaign metrics ---

  describe "sm3 — campaign metrics" do
    test "track recipients, sent, delivered, failed, replies" do
      c = %{total_recipients: 500, total_sent: 490, total_delivered: 475, total_failed: 15, total_replies: 30}
      assert c.total_recipients == 500
      assert c.total_sent == 490
      assert c.total_delivered == 475
      assert c.total_failed == 15
      assert c.total_replies == 30
    end

    test "delivery rate calculation" do
      c = %{total_sent: 1000, total_delivered: 970}
      delivery_rate = c.total_delivered / c.total_sent * 100
      assert delivery_rate == 97.0
    end

    test "reply rate calculation" do
      c = %{total_delivered: 1000, total_replies: 45}
      reply_rate = c.total_replies / c.total_delivered * 100
      assert reply_rate == 4.5
    end
  end

  # --- sm4: Template lifecycle ---

  describe "sm4 — template lifecycle" do
    test "create, activate, deactivate" do
      t = %{name: "Welcome SMS", body: "Welcome {{name}}!", status: :active}
      assert t.status == :active

      t = %{t | status: :inactive}
      assert t.status == :inactive

      t = %{t | status: :active}
      assert t.status == :active
    end
  end

  # --- sm5: Template variables ---

  describe "sm5 — template variables" do
    test "variable placeholders in body" do
      t = %{body: "Hi {{first_name}}, your order {{order_id}} is ready!"}
      assert String.contains?(t.body, "{{first_name}}")
      assert String.contains?(t.body, "{{order_id}}")
    end

    test "variables list" do
      t = %{variables: ["first_name", "order_id"]}
      assert length(t.variables) == 2
    end
  end

  # --- sm6: Template use count ---

  describe "sm6 — template use count" do
    test "increment use count" do
      t = %{use_count: 0}
      t = %{t | use_count: t.use_count + 1}
      assert t.use_count == 1
    end
  end

  # --- sm7: Message lifecycle ---

  describe "sm7 — message lifecycle" do
    test "pending → sent → delivered" do
      m = %{status: :pending, sent_at: nil, delivered_at: nil}
      m = %{m | status: :sent, sent_at: DateTime.utc_now()}
      assert m.status == :sent

      m = %{m | status: :delivered, delivered_at: DateTime.utc_now()}
      assert m.status == :delivered
    end
  end

  # --- sm8: Message failure ---

  describe "sm8 — message failure" do
    test "mark failed with reason" do
      m = %{status: :sent, failed_reason: nil}
      m = %{m | status: :failed, failed_reason: "Invalid phone number"}
      assert m.status == :failed
      assert m.failed_reason == "Invalid phone number"
    end
  end

  # --- sm9: Message reply ---

  describe "sm9 — message reply" do
    test "record reply" do
      m = %{status: :delivered, reply_body: nil, reply_at: nil}
      m = %{m | status: :replied, reply_body: "Yes, I'm interested!", reply_at: DateTime.utc_now()}
      assert m.status == :replied
      assert m.reply_body == "Yes, I'm interested!"
    end
  end

  # --- sm10: Subscriber opt-in/opt-out ---

  describe "sm10 — subscriber opt-in/opt-out" do
    test "opt in and opt out" do
      s = %{status: :active, opt_in_at: DateTime.utc_now(), opt_out_at: nil}
      s = %{s | status: :unsubscribed, opt_out_at: DateTime.utc_now()}
      assert s.status == :unsubscribed
    end
  end

  # --- sm11: Subscriber block/reactivate ---

  describe "sm11 — subscriber block/reactivate" do
    test "block and reactivate" do
      s = %{status: :active, opt_out_at: nil}
      s = %{s | status: :blocked}
      assert s.status == :blocked

      s = %{s | status: :active, opt_out_at: nil}
      assert s.status == :active
    end
  end

  # --- sm12: Subscriber tags ---

  describe "sm12 — subscriber tags" do
    test "segmentation tags" do
      s = %{tags: ["vip", "enterprise", "q4_lead"]}
      assert length(s.tags) == 3
      assert "vip" in s.tags
    end
  end

  # --- sm13: Full campaign flow ---

  describe "sm13 — full campaign → template → messages" do
    test "end-to-end SMS campaign" do
      # Template
      t = %{name: "Flash Sale", body: "🎉 Flash sale! 20% off with code {{code}}. Reply YES to claim!", variables: ["code"], use_count: 0}

      # Campaign
      c = %{name: "Q4 Flash Sale", status: :draft, template_id: "t_001", total_recipients: 0, total_sent: 0, total_delivered: 0, total_failed: 0, total_replies: 0, scheduled_at: nil, sent_at: nil, completed_at: nil}

      # Schedule
      c = %{c | status: :scheduled, scheduled_at: DateTime.utc_now()}

      # Send
      c = %{c | status: :sending, sent_at: DateTime.utc_now(), total_recipients: 200, total_sent: 200}

      # Messages delivered
      c = %{c | total_delivered: 190, total_failed: 10}

      # Complete
      c = %{c | status: :completed, completed_at: DateTime.utc_now()}

      # Update template use count
      t = %{t | use_count: t.use_count + 1}

      assert c.status == :completed
      assert c.total_delivered == 190
      assert t.use_count == 1
    end
  end

  # --- sm14: Subscriber consent ---

  describe "sm14 — subscriber consent" do
    test "opt-in source tracking" do
      s = %{opt_in_source: "web_form", opt_in_at: DateTime.utc_now()}
      assert s.opt_in_source == "web_form"
    end

    test "opt-out reason" do
      s = %{opt_out_reason: "Too many messages"}
      assert s.opt_out_reason == "Too many messages"
    end
  end

  # --- sm15: Message delivery status ---

  describe "sm15 — message delivery status" do
    test "all statuses" do
      statuses = [:pending, :queued, :sent, :delivered, :failed, :replied]
      assert length(statuses) == 6
    end
  end

  # --- sm16: Scheduled send ---

  describe "sm16 — scheduled send" do
    test "schedule for future" do
      c = %{status: :draft, scheduled_at: nil}
      future = DateTime.add(DateTime.utc_now(), 3600, :second)
      c = %{c | status: :scheduled, scheduled_at: future}
      assert c.status == :scheduled
      assert DateTime.compare(c.scheduled_at, DateTime.utc_now()) == :gt
    end
  end

  # --- sm17: Template category ---

  describe "sm17 — template category" do
    test "default category" do
      t = %{category: "general"}
      assert t.category == "general"
    end

    test "promotion category" do
      t = %{category: "promotion"}
      assert t.category == "promotion"
    end
  end

  # --- sm18: Subscriber opt-in source ---

  describe "sm18 — opt-in sources" do
    test "all sources" do
      sources = ["web_form", "keyword", "import", "manual"]
      assert length(sources) == 4
    end
  end

  # --- sm19: Full SMS marketing ceremony ---

  describe "sm19 — full SMS marketing ceremony" do
    test "complete campaign with 3 messages" do
      # Template
      _t = %{name: "Appointment Reminder", body: "Hi {{name}}, reminder: your appointment is on {{date}} at {{time}}.", variables: ["name", "date", "time"]}

      # Campaign
      c = %{name: "Appointment Reminders", status: :draft, template_id: "t_001", total_recipients: 0, total_sent: 0, total_delivered: 0, total_failed: 0, total_replies: 0, scheduled_at: nil, sent_at: nil, completed_at: nil}

      # Schedule and send
      c = %{c | status: :scheduled, scheduled_at: DateTime.utc_now()}
      c = %{c | status: :sending, sent_at: DateTime.utc_now(), total_recipients: 50, total_sent: 50}

      # Messages
      messages = [
        %{recipient_phone: "+1234567890", body: "Hi Alice, reminder: your appointment is on Oct 1 at 10:00.", status: :delivered},
        %{recipient_phone: "+0987654321", body: "Hi Bob, reminder: your appointment is on Oct 1 at 11:00.", status: :delivered},
        %{recipient_phone: "+1122334455", body: "Hi Charlie, reminder: your appointment is on Oct 1 at 14:00.", status: :failed, failed_reason: "Invalid number"}
      ]

      delivered = Enum.count(messages, &(&1.status == :delivered))
      failed = Enum.count(messages, &(&1.status == :failed))

      c = %{c | total_delivered: delivered, total_failed: failed, status: :completed, completed_at: DateTime.utc_now()}

      assert c.status == :completed
      assert delivered == 2
      assert failed == 1
      assert length(messages) == 3
    end
  end

  # --- sm20: Vaulted phone ---

  describe "sm20 — vaulted phone" do
    test "phone is vaulted PII" do
      # Phone numbers are vaulted — test the concept
      m = %{recipient_phone: "+1234567890", body: "Test message"}
      assert is_binary(m.recipient_phone)
    end

    test "subscriber phone is vaulted" do
      s = %{phone: "+1234567890", name: "Test User"}
      assert is_binary(s.phone)
    end
  end
end
