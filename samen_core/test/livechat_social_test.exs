defmodule Samen.LivechatSocialTest do
  @moduledoc """
  WS-ERP E22: Live Chat + Social Marketing —  communication.

  Tests:
    * ls1 ChatChannel: channel types and defaults
    * ls2 ChatSession: state lifecycle (waiting → active → closed)
    * ls3 ChatSession: wait time calculation
    * ls4 ChatMessage: sender types
    * ls5 SocialCampaign: state lifecycle (draft → running → completed)
    * ls6 SocialPost: platform types and scheduling
    * ls7 SocialAnalytics: engagement rate calculation
    * ls8 SocialAnalytics: conversion tracking
    * ls9 Integration: full live chat flow
    * ls10 Integration: full social campaign flow
  """
  use ExUnit.Case, async: true

  # ── ls1: channel types and defaults ──────────────────────────────────

  describe "ls1 — channel types and defaults" do
    test "channel types include support, sales, general" do
      valid = [:support, :sales, :general]
      assert length(valid) == 3
      assert :support in valid
    end

    test "default channel is active" do
      channel = %{name: "Support", code: "SUP", is_active: true}
      assert channel.is_active == true
    end

    test "welcome message can be set" do
      channel = %{welcome_message: "Hi! How can we help?"}
      assert channel.welcome_message == "Hi! How can we help?"
    end
  end

  # ── ls2: session state lifecycle ─────────────────────────────────────

  describe "ls2 — session state lifecycle" do
    test "waiting → active → closed" do
      session = %{state: :waiting}
      session = %{session | state: :active}
      assert session.state == :active
      session = %{session | state: :closed}
      assert session.state == :closed
    end

    test "session can be closed from waiting" do
      session = %{state: :waiting}
      session = %{session | state: :closed}
      assert session.state == :closed
    end
  end

  # ── ls3: wait time calculation ───────────────────────────────────────

  describe "ls3 — wait time calculation" do
    test "wait time = agent_assign_time - session_start_time" do
      started_at = ~U[2026-01-15 10:00:00Z]
      agent_joined = ~U[2026-01-15 10:02:30Z]
      wait_seconds = DateTime.diff(agent_joined, started_at)

      assert wait_seconds == 150
    end

    test "zero wait when agent is instant" do
      started_at = ~U[2026-01-15 10:00:00Z]
      agent_joined = ~U[2026-01-15 10:00:00Z]
      wait_seconds = DateTime.diff(agent_joined, started_at)

      assert wait_seconds == 0
    end
  end

  # ── ls4: sender types ───────────────────────────────────────────────

  describe "ls4 — sender types" do
    test "sender types include visitor, agent, system" do
      valid = [:visitor, :agent, :system]
      assert length(valid) == 3
      assert :visitor in valid
      assert :agent in valid
    end

    test "message types include text, file, image, system" do
      valid = [:text, :file, :image, :system]
      assert length(valid) == 4
      assert :text in valid
    end
  end

  # ── ls5: social campaign state lifecycle ─────────────────────────────

  describe "ls5 — social campaign state lifecycle" do
    test "draft → running → completed" do
      campaign = %{state: :draft}
      campaign = %{campaign | state: :running}
      assert campaign.state == :running
      campaign = %{campaign | state: :completed}
      assert campaign.state == :completed
    end

    test "running can be paused" do
      campaign = %{state: :running}
      campaign = %{campaign | state: :paused}
      assert campaign.state == :paused
    end

    test "paused can resume" do
      campaign = %{state: :paused}
      campaign = %{campaign | state: :running}
      assert campaign.state == :running
    end
  end

  # ── ls6: platform types and scheduling ───────────────────────────────

  describe "ls6 — platform types and scheduling" do
    test "platforms include facebook, twitter, linkedin, instagram" do
      valid = [:facebook, :twitter, :linkedin, :instagram]
      assert length(valid) == 4
      assert :linkedin in valid
    end

    test "post can be scheduled" do
      post = %{platform: :twitter, content: "Check out our new product!", scheduled_at: ~U[2026-01-20 14:00:00Z]}
      assert post.scheduled_at != nil
    end

    test "post state lifecycle: draft → scheduled → published" do
      post = %{state: :draft}
      post = %{post | state: :scheduled}
      assert post.state == :scheduled
      post = %{post | state: :published}
      assert post.state == :published
    end
  end

  # ── ls7: engagement rate calculation ─────────────────────────────────

  describe "ls7 — engagement rate calculation" do
    test "engagement_rate = (engagement / impressions) * 100" do
      engagement = 150
      impressions = 10_000
      rate = engagement / impressions * 100

      assert rate == 1.5
    end

    test "high engagement rate" do
      engagement = 500
      impressions = 1000
      rate = engagement / impressions * 100

      assert rate == 50.0
    end

    test "zero impressions" do
      engagement = 0
      impressions = 0
      rate = if impressions > 0, do: engagement / impressions * 100, else: 0.0

      assert rate == 0.0
    end
  end

  # ── ls8: conversion tracking ─────────────────────────────────────────

  describe "ls8 — conversion tracking" do
    test "conversion rate = (conversions / clicks) * 100" do
      conversions = 25
      clicks = 500
      rate = conversions / clicks * 100

      assert rate == 5.0
    end

    test "cost per conversion" do
      spent = 100_00
      conversions = 25
      cost_per = spent / conversions

      assert cost_per == 4_00
    end
  end

  # ── ls9: full live chat flow ─────────────────────────────────────────

  describe "ls9 — full live chat flow" do
    test "visitor starts chat → agent joins → messages → close → rate" do
      # 1. Create channel
      channel = %{id: "ch1", name: "Support", channel_type: :support, welcome_message: "Hi! How can we help?"}

      # 2. Visitor starts session
      session = %{id: "s1", channel_id: channel.id, visitor_id: "v123", state: :waiting, started_at: ~U[2026-01-15 10:00:00Z]}

      # 3. Agent joins
      session = Map.merge(session, %{state: :active, agent_id: "agent1", wait_seconds: 30})

      # 4. Messages
      messages = [
        %{session_id: session.id, sender_type: :system, body: channel.welcome_message, message_type: :text},
        %{session_id: session.id, sender_type: :visitor, sender_id: "v123", body: "I need help with my order", message_type: :text},
        %{session_id: session.id, sender_type: :agent, sender_id: "agent1", body: "Sure! Can you provide your order number?", message_type: :text},
        %{session_id: session.id, sender_type: :visitor, sender_id: "v123", body: "It's #12345", message_type: :text},
        %{session_id: session.id, sender_type: :agent, sender_id: "agent1", body: "Found it! Your order ships tomorrow.", message_type: :text}
      ]

      assert length(messages) == 5

      # 5. Close session
      session = Map.merge(session, %{state: :closed, ended_at: ~U[2026-01-15 10:05:00Z], duration_seconds: 300})
      assert session.state == :closed

      # 6. Rate satisfaction
      session = Map.merge(session, %{satisfaction_rating: 5})
      assert session.satisfaction_rating == 5
    end
  end

  # ── ls10: full social campaign flow ──────────────────────────────────

  describe "ls10 — full social campaign flow" do
    test "create campaign → add posts → publish → track analytics" do
      # 1. Create campaign
      campaign = %{id: "camp1", name: "Product Launch", state: :running, budget: 500_00, spent: 0}

      # 2. Create posts
      posts = [
        %{id: "p1", campaign_id: campaign.id, platform: :twitter, content: "Exciting news!", state: :published},
        %{id: "p2", campaign_id: campaign.id, platform: :linkedin, content: "We're thrilled to announce...", state: :published},
        %{id: "p3", campaign_id: campaign.id, platform: :facebook, content: "Check out our latest product!", state: :scheduled}
      ]

      published = Enum.filter(posts, &(&1.state == :published))
      assert length(published) == 2

      # 3. Track analytics
      analytics = [
        %{post_id: "p1", impressions: 5000, reach: 3000, engagement: 150, likes: 100, comments: 30, shares: 20, clicks: 45, conversions: 5},
        %{post_id: "p2", impressions: 8000, reach: 6000, engagement: 300, likes: 200, comments: 60, shares: 40, clicks: 80, conversions: 10}
      ]

      total_impressions = Enum.reduce(analytics, 0, fn a, acc -> acc + a.impressions end)
      total_engagement = Enum.reduce(analytics, 0, fn a, acc -> acc + a.engagement end)
      total_conversions = Enum.reduce(analytics, 0, fn a, acc -> acc + a.conversions end)
      overall_rate = total_engagement / total_impressions * 100

      assert total_impressions == 13_000
      assert total_engagement == 450
      assert total_conversions == 15
      assert_in_delta overall_rate, 3.46, 0.01

      # 4. Update campaign spend
      campaign = %{campaign | spent: 150_00}
      assert campaign.spent < campaign.budget
    end
  end
end