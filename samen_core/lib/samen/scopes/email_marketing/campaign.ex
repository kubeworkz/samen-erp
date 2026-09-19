defmodule Samen.Scopes.EmailMarketing.Campaign do
  @moduledoc """
  Email Campaign (WS-ERP E33; Flectra-inspired).

  Email marketing campaign with lifecycle and analytics.

  ## Design

  - `name` — campaign name
  - `subject` — email subject line
  - `description` — campaign description
  - `template_id` — reference to EmailTemplate
  - `sender_name` — from name
  - `sender_email` — from email address
  - `reply_to` — reply-to address
  - `status` — :draft | :scheduled | :sending | :sent | :completed | :cancelled
  - `scheduled_at` — when to send
  - `sent_at` — when sent
  - `completed_at` — when all emails processed
  - `total_recipients` — target count
  - `total_sent` — emails sent
  - `total_delivered` — delivered
  - `total_opened` — unique opens
  - `total_clicked` — unique clicks
  - `total_bounced` — bounced
  - `total_unsubscribed` — unsubscribed
  - `ab_test_enabled` — A/B testing flag
  - `ab_test_variant` — :a | :b | nil
  - `ab_test_split` — percentage split (e.g. 50)
  - `subject_key` / `subject_id` — object-ref attachment

  Lifecycle: draft → scheduled → sending → sent → completed
  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "emc",
    archivable: true

  postgres do
    table("emc_campaign")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :subject, :string
    attribute :description, :string
    attribute :template_id, :uuid
    attribute :sender_name, :string
    attribute :sender_email, :string
    attribute :reply_to, :string
    attribute :status, :atom, default: :draft,
      constraints: [one_of: [:draft, :scheduled, :sending, :sent, :completed, :cancelled]]
    attribute :scheduled_at, :utc_datetime_usec
    attribute :sent_at, :utc_datetime_usec
    attribute :completed_at, :utc_datetime_usec
    attribute :total_recipients, :integer, default: 0
    attribute :total_sent, :integer, default: 0
    attribute :total_delivered, :integer, default: 0
    attribute :total_opened, :integer, default: 0
    attribute :total_clicked, :integer, default: 0
    attribute :total_bounced, :integer, default: 0
    attribute :total_unsubscribed, :integer, default: 0
    attribute :ab_test_enabled, :boolean, default: false
    attribute :ab_test_variant, :atom, constraints: [one_of: [:a, :b]]
    attribute :ab_test_split, :integer
    attribute :subject_key, :string
    attribute :subject_id, :string

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :schedule do
      require_atomic? false
      change set_attribute(:status, :scheduled)
    end

    update :send_now do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :status, :sending)
        Ash.Changeset.force_change_attribute(changeset, :sent_at, DateTime.utc_now())
      end
    end

    update :mark_sent do
      require_atomic? false
      change set_attribute(:status, :sent)
    end

    update :complete do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :status, :completed)
        Ash.Changeset.force_change_attribute(changeset, :completed_at, DateTime.utc_now())
      end
    end

    update :cancel do
      require_atomic? false
      change set_attribute(:status, :cancelled)
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
