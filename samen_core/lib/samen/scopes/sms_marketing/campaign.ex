defmodule Samen.Scopes.SmsMarketing.Campaign do
  @moduledoc """
  SMS Marketing Campaign (WS-ERP E29; Flectra-inspired).

  An SMS marketing campaign.

  ## Design

  - `name` — campaign name
  - `description` — campaign description
  - `status` — :draft | :scheduled | :sending | :sent | :completed | :cancelled
  - `scheduled_at` — when to send
  - `sent_at` — when sent
  - `completed_at` — when all messages processed
  - `target_segment` — target audience
  - `total_recipients` — total target count
  - `total_sent` — messages sent
  - `total_delivered` — messages delivered
  - `total_failed` — messages failed
  - `total_replies` — replies received
  - `template_id` — reference to SmsTemplate

  Lifecycle: draft → scheduled → sending → sent → completed
  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "stc",
    archivable: true

  postgres do
    table("stc_campaign")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :description, :string
    attribute :status, :atom, default: :draft, constraints: [one_of: [:draft, :scheduled, :sending, :sent, :completed, :cancelled]]
    attribute :scheduled_at, :utc_datetime_usec
    attribute :sent_at, :utc_datetime_usec
    attribute :completed_at, :utc_datetime_usec
    attribute :target_segment, :string
    attribute :total_recipients, :integer, default: 0
    attribute :total_sent, :integer, default: 0
    attribute :total_delivered, :integer, default: 0
    attribute :total_failed, :integer, default: 0
    attribute :total_replies, :integer, default: 0
    attribute :template_id, :uuid

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
