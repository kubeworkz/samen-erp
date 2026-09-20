defmodule Samen.Scopes.MarketingAutomation.Trigger do
  @moduledoc """
  Marketing Automation Trigger (WS-ERP E28;).

  A trigger condition that starts a workflow.

  ## Design

  - `workflow_id` — reference to Workflow
  - `name` — trigger name
  - `event_type` — :form_submission | :page_visit | :email_opened | :email_clicked | :tag_applied | :date_reached | :manual
  - `conditions` — JSON map of trigger conditions (field, operator, value)
  - `delay_minutes` — delay before triggering (0 = immediate)
  - `status` — :active | :inactive
  - `fire_count` — number of times this trigger has fired

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "mtr",
    archivable: true

  postgres do
    table("mtr_trigger")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :workflow_id, :uuid, allow_nil?: false
    attribute :name, :string, allow_nil?: false
    attribute :event_type, :atom, allow_nil?: false, constraints: [one_of: [:form_submission, :page_visit, :email_opened, :email_clicked, :tag_applied, :date_reached, :manual]]
    attribute :conditions, :map, default: %{}
    attribute :delay_minutes, :integer, default: 0
    attribute :status, :atom, default: :active, constraints: [one_of: [:active, :inactive]]
    attribute :fire_count, :integer, default: 0

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :enable do
      require_atomic? false
      change set_attribute(:status, :active)
    end

    update :disable do
      require_atomic? false
      change set_attribute(:status, :inactive)
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
