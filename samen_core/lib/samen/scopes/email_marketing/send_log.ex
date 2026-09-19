defmodule Samen.Scopes.EmailMarketing.SendLog do
  @moduledoc """
  Email Send Log (WS-ERP E33; Flectra-inspired).

  Immutable audit trail for individual email sends.

  ## Design

  - `campaign_id` — reference to EmailCampaign
  - `subscriber_id` — reference to EmailSubscriber
  - `email` — recipient email (vaulted)
  - `subject` — email subject sent
  - `status` — :pending | :sent | :delivered | :opened | :clicked | :bounced | :unsubscribed | :complained
  - `sent_at` — when email was sent
  - `delivered_at` — when delivered
  - `opened_at` — when first opened
  - `clicked_at` — when first clicked
  - `bounce_type` — :hard | :soft | nil
  - `bounce_reason` — bounce error message
  - `open_count` — total opens
  - `click_count` — total clicks
  - `user_agent` — last known user agent
  - `ip_address` — last known IP (for abuse detection)
  - `subject_key` / `subject_id` — object-ref attachment

  Create-only (immutable audit). No PII (INV-1).
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "eml"

  postgres do
    table("eml_send_log")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :campaign_id, :uuid, allow_nil?: false
    attribute :subscriber_id, :uuid
    attribute :email, :string, allow_nil?: false
    attribute :subject, :string
    attribute :status, :atom, default: :pending,
      constraints: [one_of: [:pending, :sent, :delivered, :opened, :clicked, :bounced, :unsubscribed, :complained]]
    attribute :sent_at, :utc_datetime_usec
    attribute :delivered_at, :utc_datetime_usec
    attribute :opened_at, :utc_datetime_usec
    attribute :clicked_at, :utc_datetime_usec
    attribute :bounce_type, :atom, constraints: [one_of: [:hard, :soft]]
    attribute :bounce_reason, :string
    attribute :open_count, :integer, default: 0
    attribute :click_count, :integer, default: 0
    attribute :user_agent, :string
    attribute :ip_address, :string
    attribute :subject_key, :string
    attribute :subject_id, :string

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read]

    update :mark_delivered do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :status, :delivered)
        Ash.Changeset.force_change_attribute(changeset, :delivered_at, DateTime.utc_now())
      end
    end

    update :mark_opened do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :status, :opened)
        Ash.Changeset.force_change_attribute(changeset, :opened_at, DateTime.utc_now())
        count = Ash.Changeset.get_attribute(changeset, :open_count) || 0
        Ash.Changeset.force_change_attribute(changeset, :open_count, count + 1)
      end
    end

    update :mark_clicked do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :status, :clicked)
        Ash.Changeset.force_change_attribute(changeset, :clicked_at, DateTime.utc_now())
        count = Ash.Changeset.get_attribute(changeset, :click_count) || 0
        Ash.Changeset.force_change_attribute(changeset, :click_count, count + 1)
      end
    end

    update :mark_bounced do
      require_atomic? false
      change set_attribute(:status, :bounced)
    end

    update :mark_unsubscribed do
      require_atomic? false
      change set_attribute(:status, :unsubscribed)
    end

    update :mark_complained do
      require_atomic? false
      change set_attribute(:status, :complained)
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
