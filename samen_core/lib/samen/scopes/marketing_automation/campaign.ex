defmodule Samen.Scopes.MarketingAutomation.Campaign do
  @moduledoc """
  Marketing Automation Campaign (WS-ERP E28; Flectra-inspired).

  A marketing automation campaign.

  ## Design

  - `name` — campaign name
  - `description` — campaign description
  - `status` — :draft | :running | :paused | :completed | :archived
  - `target_segment` — target audience segment
  - `start_at` — campaign start datetime
  - `end_at` — campaign end datetime
  - `total_recipients` — total target recipients
  - `total_sent` — emails/messages sent
  - `total_opened` — emails opened
  - `total_clicked` — links clicked
  - `total_converted` — conversions tracked

  Lifecycle: draft → running → paused → completed → archived
  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "mcn",
    archivable: true

  postgres do
    table("mcn_campaign")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :description, :string
    attribute :status, :atom, default: :draft, constraints: [one_of: [:draft, :running, :paused, :completed, :archived]]
    attribute :target_segment, :string
    attribute :start_at, :utc_datetime_usec
    attribute :end_at, :utc_datetime_usec
    attribute :total_recipients, :integer, default: 0
    attribute :total_sent, :integer, default: 0
    attribute :total_opened, :integer, default: 0
    attribute :total_clicked, :integer, default: 0
    attribute :total_converted, :integer, default: 0

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :start do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :status, :running)
        Ash.Changeset.force_change_attribute(changeset, :start_at, DateTime.utc_now())
      end
    end

    update :pause do
      require_atomic? false
      change set_attribute(:status, :paused)
    end

    update :resume do
      require_atomic? false
      change set_attribute(:status, :running)
    end

    update :complete do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :status, :completed)
        Ash.Changeset.force_change_attribute(changeset, :end_at, DateTime.utc_now())
      end
    end

    update :mark_archived do
      require_atomic? false
      change set_attribute(:status, :archived)
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
