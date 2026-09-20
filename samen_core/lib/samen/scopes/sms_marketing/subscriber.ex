defmodule Samen.Scopes.SmsMarketing.Subscriber do
  @moduledoc """
  SMS Marketing Subscriber (WS-ERP E29;).

  An SMS marketing subscriber with consent management.

  ## Design

  - `phone` — subscriber phone number (vaulted PII)
  - `name` — subscriber display name
  - `status` — :active | :unsubscribed | :blocked
  - `opt_in_at` — when opted in
  - `opt_out_at` — when opted out
  - `opt_in_source` — how they opted in (web_form, keyword, import, manual)
  - `opt_out_reason` — reason for unsubscribing
  - `tags` — segmentation tags
  - `last_message_at` — last message sent

  PII: phone number is vaulted. Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "sms",
    archivable: true

  postgres do
    table("sms_subscriber")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id

    pii do
      vault :pii_sms_subscriber
      attribute :phone, :string, allow_nil?: false
    end

    attribute :name, :string
    attribute :status, :atom, default: :active, constraints: [one_of: [:active, :unsubscribed, :blocked]]
    attribute :opt_in_at, :utc_datetime_usec
    attribute :opt_out_at, :utc_datetime_usec
    attribute :opt_in_source, :string
    attribute :opt_out_reason, :string
    attribute :tags, {:array, :string}, default: []
    attribute :last_message_at, :utc_datetime_usec

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :unsubscribe do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :status, :unsubscribed)
        Ash.Changeset.force_change_attribute(changeset, :opt_out_at, DateTime.utc_now())
      end
    end

    update :block do
      require_atomic? false
      change set_attribute(:status, :blocked)
    end

    update :reactivate do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :status, :active)
        Ash.Changeset.force_change_attribute(changeset, :opt_out_at, nil)
      end
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
