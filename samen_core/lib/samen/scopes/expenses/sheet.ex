defmodule Samen.Scopes.Expenses.Sheet do
  @moduledoc """
  Expense Sheet (WS-ERP E31;).

  An expense report grouping multiple expenses for submission and approval.

  ## Design

  - `name` — report name/title
  - `employee_id` — who submitted the report
  - `manager_id` — direct manager for approval
  - `accountant_id` — accountant for reimbursement
  - `period_start` — reporting period start
  - `period_end` — reporting period end
  - `status` — :draft | :submitted | :under_review | :approved | :rejected | :reimbursed | :cancelled
  - `total_amount_cents` — sum of all expenses in sheet
  - `expense_count` — number of expenses in sheet
  - `rejected_reason` — reason for rejection
  - `submitted_at` — when submitted
  - `approved_at` — when approved
  - `reimbursed_at` — when reimbursed
  - `payment_ref` — reimbursement payment reference
  - `subject_key` / `subject_id` — object-ref attachment

  Lifecycle: draft → submitted → under_review → approved/rejected → reimbursed
  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "exs",
    archivable: true

  postgres do
    table("exs_sheet")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false
    attribute :employee_id, :uuid
    attribute :manager_id, :uuid
    attribute :accountant_id, :uuid
    attribute :period_start, :date
    attribute :period_end, :date
    attribute :status, :atom, default: :draft,
      constraints: [one_of: [:draft, :submitted, :under_review, :approved, :rejected, :reimbursed, :cancelled]]
    attribute :total_amount_cents, :integer, default: 0
    attribute :expense_count, :integer, default: 0
    attribute :rejected_reason, :string
    attribute :submitted_at, :utc_datetime_usec
    attribute :approved_at, :utc_datetime_usec
    attribute :reimbursed_at, :utc_datetime_usec
    attribute :payment_ref, :string
    attribute :subject_key, :string
    attribute :subject_id, :string

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :submit do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :status, :submitted)
        Ash.Changeset.force_change_attribute(changeset, :submitted_at, DateTime.utc_now())
      end
    end

    update :start_review do
      require_atomic? false
      change set_attribute(:status, :under_review)
    end

    update :approve do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :status, :approved)
        Ash.Changeset.force_change_attribute(changeset, :approved_at, DateTime.utc_now())
      end
    end

    update :reject do
      require_atomic? false
      change set_attribute(:status, :rejected)
    end

    update :reimburse do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :status, :reimbursed)
        Ash.Changeset.force_change_attribute(changeset, :reimbursed_at, DateTime.utc_now())
      end
    end

    update :cancel do
      require_atomic? false
      change set_attribute(:status, :cancelled)
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
