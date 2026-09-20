defmodule Samen.Scopes.MarketingAutomation.Workflow do
  @moduledoc """
  Marketing Automation Workflow (WS-ERP E28;).

  A workflow definition within a campaign.

  ## Design

  - `campaign_id` — reference to Campaign
  - `name` — workflow name
  - `description` — workflow description
  - `status` — :draft | :active | :paused | :completed
  - `trigger_type` — :form_submit | :page_visit | :email_open | :email_click | :tag_added | :manual
  - `trigger_config` — JSON map for trigger-specific config
  - `entry_count` — number of contacts that entered the workflow
  - `completion_count` — number that completed all steps

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "mwf",
    archivable: true

  postgres do
    table("mwf_workflow")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :campaign_id, :uuid, allow_nil?: false
    attribute :name, :string, allow_nil?: false
    attribute :description, :string
    attribute :status, :atom, default: :draft, constraints: [one_of: [:draft, :active, :paused, :completed]]
    attribute :trigger_type, :atom, default: :manual, constraints: [one_of: [:form_submit, :page_visit, :email_open, :email_click, :tag_added, :manual]]
    attribute :trigger_config, :map, default: %{}
    attribute :entry_count, :integer, default: 0
    attribute :completion_count, :integer, default: 0

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
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
