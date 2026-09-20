defmodule Samen.Scopes.SmsMarketing.Message do
  @moduledoc """
  SMS Marketing Message (WS-ERP E29;).

  An individual SMS message sent to a recipient.

  ## Design

  - `campaign_id` — reference to SmsCampaign
  - `template_id` — reference to SmsTemplate (optional)
  - `recipient_phone` — recipient phone number (vaulted PII)
  - `body` — rendered message body
  - `status` — :pending | :queued | :sent | :delivered | :failed | :replied
  - `sent_at` — when sent
  - `delivered_at` — when delivered
  - `failed_reason` — failure reason
  - `reply_body` — reply content (if replied)
  - `reply_at` — when reply received

  PII: phone number is vaulted. Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "sme",
    archivable: true

  postgres do
    table("sme_message")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :campaign_id, :uuid, allow_nil?: false
    attribute :template_id, :uuid

    pii do
      vault :pii_sms_message
      attribute :recipient_phone, :string, allow_nil?: false
    end

    attribute :body, :string, allow_nil?: false
    attribute :status, :atom, default: :pending, constraints: [one_of: [:pending, :queued, :sent, :delivered, :failed, :replied]]
    attribute :sent_at, :utc_datetime_usec
    attribute :delivered_at, :utc_datetime_usec
    attribute :failed_reason, :string
    attribute :reply_body, :string
    attribute :reply_at, :utc_datetime_usec

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :mark_sent do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :status, :sent)
        Ash.Changeset.force_change_attribute(changeset, :sent_at, DateTime.utc_now())
      end
    end

    update :mark_delivered do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :status, :delivered)
        Ash.Changeset.force_change_attribute(changeset, :delivered_at, DateTime.utc_now())
      end
    end

    update :mark_failed do
      require_atomic? false
      change set_attribute(:status, :failed)
    end

    update :record_reply do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :status, :replied)
        Ash.Changeset.force_change_attribute(changeset, :reply_at, DateTime.utc_now())
      end
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
