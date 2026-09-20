defmodule Samen.Scopes.Expenses.Approver do
  @moduledoc """
  Expense Approver (WS-ERP E31;).

  Defines the approval chain for expense sheets.

  ## Design

  - `sheet_id` — reference to ExpenseSheet
  - `approver_id` — user who can approve
  - `sequence` — approval order (1 = first approver)
  - `status` — :pending | :approved | :rejected | :skipped
  - `approved_at` — when approved
  - `rejected_at` — when rejected
  - `comments` — approval/rejection comments
  - `is_final` — whether this is the final approval step
  - `subject_key` / `subject_id` — object-ref attachment

  Lifecycle: pending → approved/rejected/skipped
  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "exa",
    archivable: true

  postgres do
    table("exa_approver")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :sheet_id, :uuid, allow_nil?: false
    attribute :approver_id, :uuid, allow_nil?: false
    attribute :sequence, :integer, default: 1
    attribute :status, :atom, default: :pending,
      constraints: [one_of: [:pending, :approved, :rejected, :skipped]]
    attribute :approved_at, :utc_datetime_usec
    attribute :rejected_at, :utc_datetime_usec
    attribute :comments, :string
    attribute :is_final, :boolean, default: false
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
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
