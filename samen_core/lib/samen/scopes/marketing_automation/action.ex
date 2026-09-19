defmodule Samen.Scopes.MarketingAutomation.Action do
  @moduledoc """
  Marketing Automation Action (WS-ERP E28; Flectra-inspired).

  An action within a workflow step.

  ## Design

  - `workflow_id` — reference to Workflow
  - `name` — action name
  - `action_type` — :send_email | :send_sms | :wait | :condition | :update_contact | :add_tag | :remove_tag | :notify_team
  - `config` — JSON map of action-specific configuration
  - `sequence` — execution order within the workflow
  - `status` — :active | :inactive
  - `execution_count` — number of times this action was executed
  - `success_count` — successful executions
  - `failure_count` — failed executions

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "mac",
    archivable: true

  postgres do
    table("mac_action")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :workflow_id, :uuid, allow_nil?: false
    attribute :name, :string, allow_nil?: false
    attribute :action_type, :atom, allow_nil?: false, constraints: [one_of: [:send_email, :send_sms, :wait, :condition, :update_contact, :add_tag, :remove_tag, :notify_team]]
    attribute :config, :map, default: %{}
    attribute :sequence, :integer, allow_nil?: false
    attribute :status, :atom, default: :active, constraints: [one_of: [:active, :inactive]]
    attribute :execution_count, :integer, default: 0
    attribute :success_count, :integer, default: 0
    attribute :failure_count, :integer, default: 0

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
