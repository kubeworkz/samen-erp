defmodule Samen.Scopes.SocialMarketing.Campaign do
  @moduledoc """
  Social Marketing Campaign (WS-ERP E30;).

  A social media marketing campaign.

  ## Design

  - `name` — campaign name
  - `description` — campaign description
  - `status` — :draft | :active | :paused | :completed | :archived
  - `start_date` — campaign start date
  - `end_date` — campaign end date
  - `budget` — campaign budget in minor units
  - `target_audience` — target audience description
  - `goals` — campaign goals (JSON map)

  Lifecycle: draft → active → paused → completed → archived
  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "son",
    archivable: true

  postgres do
    table("son_campaign")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :description, :string
    attribute :status, :atom, default: :draft, constraints: [one_of: [:draft, :active, :paused, :completed, :archived]]
    attribute :start_date, :date
    attribute :end_date, :date
    attribute :budget, :integer, default: 0
    attribute :target_audience, :string
    attribute :goals, :map, default: %{}

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :activate do
      require_atomic? false
      change set_attribute(:status, :active)
    end

    update :pause do
      require_atomic? false
      change set_attribute(:status, :paused)
    end

    update :complete do
      require_atomic? false
      change set_attribute(:status, :completed)
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
