defmodule Samen.Scopes.Expenses.Expense do
  @moduledoc """
  Expense (WS-ERP E31;).

  An individual expense line item.

  ## Design

  - `sheet_id` — reference to ExpenseSheet
  - `category_id` — reference to ExpenseCategory
  - `employee_id` — who incurred the expense
  - `description` — expense description
  - `amount_cents` — expense amount in minor currency units
  - `currency` — ISO 4217 currency code (default: "USD")
  - `date` — date expense was incurred
  - `payment_method` — :cash | :card | :bank_transfer | :personal_card
  - `receipt_url` — URL to attached receipt image
  - `receipt_required` — whether receipt is required by policy
  - `receipt_attached` — whether receipt has been attached
  - `tax_amount_cents` — tax amount (auto-calculated or manual)
  - `tax_rate` — tax rate as decimal (e.g. 0.07 for 7%)
  - `is_billable` — whether expense is billable to a client
  - `client_id` — reference to client/project if billable
  - `status` — :draft | :submitted | :approved | :rejected | :reimbursed | :cancelled
  - `rejected_reason` — reason for rejection
  - `subject_key` / `subject_id` — object-ref attachment

  Lifecycle: draft → submitted → approved/rejected → reimbursed
  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "exp",
    archivable: true

  postgres do
    table("exp_expense")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :sheet_id, :uuid
    attribute :category_id, :uuid
    attribute :employee_id, :uuid
    attribute :description, :string, allow_nil?: false
    attribute :amount_cents, :integer, allow_nil?: false
    attribute :currency, :string, default: "USD"
    attribute :date, :date, allow_nil?: false
    attribute :payment_method, :atom, default: :personal_card,
      constraints: [one_of: [:cash, :card, :bank_transfer, :personal_card]]
    attribute :receipt_url, :string
    attribute :receipt_required, :boolean, default: false
    attribute :receipt_attached, :boolean, default: false
    attribute :tax_amount_cents, :integer, default: 0
    attribute :tax_rate, :float, default: 0.0
    attribute :is_billable, :boolean, default: false
    attribute :client_id, :uuid
    attribute :status, :atom, default: :draft,
      constraints: [one_of: [:draft, :submitted, :approved, :rejected, :reimbursed, :cancelled]]
    attribute :rejected_reason, :string
    attribute :subject_key, :string
    attribute :subject_id, :string

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :submit do
      require_atomic? false
      change set_attribute(:status, :submitted)
    end

    update :approve do
      require_atomic? false
      change set_attribute(:status, :approved)
    end

    update :reject do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :status, :rejected)
      end
    end

    update :reimburse do
      require_atomic? false
      change set_attribute(:status, :reimbursed)
    end

    update :cancel do
      require_atomic? false
      change set_attribute(:status, :cancelled)
    end

    update :attach_receipt do
      require_atomic? false
      change set_attribute(:receipt_attached, true)
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
