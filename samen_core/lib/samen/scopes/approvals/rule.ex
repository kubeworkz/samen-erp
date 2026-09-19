defmodule Samen.Scopes.Approvals.Rule do
  @moduledoc """
  Approval Rule (WS-ERP E35; Flectra-inspired).

  Defines approval policies — what requires approval and by whom.

  ## Design

  - `name` — rule name
  - `description` — rule description
  - `category` — :purchase_order | :expense | :invoice | :leave | :general
  - `amount_threshold_cents` — minimum amount requiring approval (nil = always)
  - `approver_type` — :direct_manager | :department_head | :specific_user | :any
  - `approver_id` — specific approver user ID (when approver_type = :specific_user)
  - `require_all_approvers` — true = all must approve, false = any one
  - `max_steps` — maximum approval steps allowed
  - `is_active` — whether rule is enforced
  - `auto_approve_below` — auto-approve if below threshold
  - `subject_key` / `subject_id` — object-ref attachment

  Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "apx",
    archivable: true

  postgres do
    table("apx_rule")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :description, :string
    attribute :category, :atom, default: :general,
      constraints: [one_of: [:purchase_order, :expense, :invoice, :leave, :general]]
    attribute :amount_threshold_cents, :integer
    attribute :approver_type, :atom, default: :direct_manager,
      constraints: [one_of: [:direct_manager, :department_head, :specific_user, :any]]
    attribute :approver_id, :uuid
    attribute :require_all_approvers, :boolean, default: false
    attribute :max_steps, :integer, default: 3
    attribute :is_active, :boolean, default: true
    attribute :auto_approve_below, :boolean, default: false
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
