defmodule Samen.Scopes.Approvals.Step do
  @moduledoc """
  Approval Step (WS-ERP E35;).

  An individual step in an approval chain.

  ## Design

  - `request_id` — reference to ApprovalRequest
  - `step_number` — order in the chain (1, 2, 3...)
  - `approver_id` — user who must approve
  - `approver_type` — :direct_manager | :department_head | :specific_user | :any
  - `status` — :pending | :approved | :rejected | :skipped
  - `approved_at` — when approved
  - `rejected_at` — when rejected
  - `comments` — approval/rejection comments
  - `is_final` — whether this is the final step
  - `delegation_id` — user delegated to (if any)
  - `subject_key` / `subject_id` — object-ref attachment

  Lifecycle: pending → approved/rejected/skipped
  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "apo",
    archivable: true

  postgres do
    table("apv_step")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :request_id, :uuid, allow_nil?: false
    attribute :step_number, :integer, allow_nil?: false
    attribute :approver_id, :uuid, allow_nil?: false
    attribute :approver_type, :atom, default: :direct_manager,
      constraints: [one_of: [:direct_manager, :department_head, :specific_user, :any]]
    attribute :status, :atom, default: :pending,
      constraints: [one_of: [:pending, :approved, :rejected, :skipped]]
    attribute :approved_at, :utc_datetime_usec
    attribute :rejected_at, :utc_datetime_usec
    attribute :comments, :string
    attribute :is_final, :boolean, default: false
    attribute :delegation_id, :uuid
    attribute :subject_key, :string
    attribute :subject_id, :string

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :approve do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :status, :approved)
        Ash.Changeset.force_change_attribute(changeset, :approved_at, DateTime.utc_now())
      end
    end

    update :reject do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :status, :rejected)
        Ash.Changeset.force_change_attribute(changeset, :rejected_at, DateTime.utc_now())
      end
    end

    update :skip do
      require_atomic? false
      change set_attribute(:status, :skipped)
    end

    update :delegate do
      require_atomic? false

      change fn changeset, _context ->
        delegtee = Ash.Changeset.get_attribute(changeset, :new_delegation_id)
        Ash.Changeset.force_change_attribute(changeset, :delegation_id, delegtee)
      end
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
