defmodule Samen.Scopes.SmsMarketing.Template do
  @moduledoc """
  SMS Marketing Template (WS-ERP E29;).

  A reusable SMS message template with variable support.

  ## Design

  - `name` — template name
  - `body` — message body with {{variable}} placeholders
  - `variables` — list of supported variable names
  - `category` — template category (promotion, reminder, notification, etc.)
  - `status` — :active | :inactive
  - `use_count` — number of times used in campaigns

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "smt",
    archivable: true

  postgres do
    table("smt_template")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :body, :string, allow_nil?: false
    attribute :variables, {:array, :string}, default: []
    attribute :category, :string, default: "general"
    attribute :status, :atom, default: :active, constraints: [one_of: [:active, :inactive]]
    attribute :use_count, :integer, default: 0

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :activate do
      require_atomic? false
      change set_attribute(:status, :active)
    end

    update :deactivate do
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
