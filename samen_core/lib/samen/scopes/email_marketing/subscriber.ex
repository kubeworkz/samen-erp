defmodule Samen.Scopes.EmailMarketing.Subscriber do
  @moduledoc """
  Email Subscriber (WS-ERP E33;).

  Mailing list subscriber with opt-in/opt-out management.

  ## Design

  - `email` — subscriber email (vaulted)
  - `name` — subscriber name (optional)
  - `list_id` — mailing list identifier
  - `status` — :active | :unsubscribed | :bounced | :complained
  - `opt_in_source` — :form | :import | :manual | :api
  - `opted_in_at` — when subscribed
  - `opted_out_at` — when unsubscribed
  - `tags` — segment tags for targeting
  - `open_count` — total emails opened
  - `click_count` — total links clicked
  - `last_opened_at` — last open timestamp
  - `last_clicked_at` — last click timestamp
  - `subject_key` / `subject_id` — object-ref attachment

  Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "ems",
    archivable: true

  postgres do
    table("ems_subscriber")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :email, :string, allow_nil?: false
    attribute :name, :string
    attribute :list_id, :string
    attribute :status, :atom, default: :active,
      constraints: [one_of: [:active, :unsubscribed, :bounced, :complained]]
    attribute :opt_in_source, :atom, default: :form,
      constraints: [one_of: [:form, :import, :manual, :api]]
    attribute :opted_in_at, :utc_datetime_usec
    attribute :opted_out_at, :utc_datetime_usec
    attribute :tags, {:array, :string}, default: []
    attribute :open_count, :integer, default: 0
    attribute :click_count, :integer, default: 0
    attribute :last_opened_at, :utc_datetime_usec
    attribute :last_clicked_at, :utc_datetime_usec
    attribute :subject_key, :string
    attribute :subject_id, :string

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :unsubscribe do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :status, :unsubscribed)
        Ash.Changeset.force_change_attribute(changeset, :opted_out_at, DateTime.utc_now())
      end
    end

    update :resubscribe do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :status, :active)
        Ash.Changeset.force_change_attribute(changeset, :opted_out_at, nil)
      end
    end

    update :mark_bounced do
      require_atomic? false
      change set_attribute(:status, :bounced)
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
