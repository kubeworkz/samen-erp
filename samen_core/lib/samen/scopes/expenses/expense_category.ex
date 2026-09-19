defmodule Samen.Scopes.Expenses.ExpenseCategory do
  @moduledoc """
  Expense Category (WS-ERP E31; Flectra-inspired).

  Defines expense types with GL account mapping and policy limits.

  ## Design

  - `name` — category name (e.g. "Travel", "Meals", "Office Supplies")
  - `description` — category description
  - `gl_account_code` — default GL account for posting
  - `requires_receipt` — whether receipts are mandatory
  - `requires_approver` — whether manager approval is needed
  - `max_amount_cents` — per-expense limit (nil = unlimited)
  - `max_daily_amount_cents` — daily spending cap (nil = unlimited)
  - `is_active` — whether category accepts new expenses
  - `subject_key` / `subject_id` — object-ref attachment

  Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "exc",
    archivable: true

  postgres do
    table("exc_category")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :description, :string
    attribute :gl_account_code, :string
    attribute :requires_receipt, :boolean, default: false
    attribute :requires_approver, :boolean, default: true
    attribute :max_amount_cents, :integer
    attribute :max_daily_amount_cents, :integer
    attribute :is_active, :boolean, default: true
    attribute :subject_key, :string
    attribute :subject_id, :string

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :deactivate do
      require_atomic? false
      change set_attribute(:is_active, false)
    end

    update :activate do
      require_atomic? false
      change set_attribute(:is_active, true)
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
