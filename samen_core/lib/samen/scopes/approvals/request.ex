defmodule Samen.Scopes.Approvals.Request do
  @moduledoc """
  Approval Request (WS-ERP E35;).

  An approval request submitted for review.

  ## Design

  - `rule_id` — reference to ApprovalRule
  - `requester_id` — who submitted
  - `subject_type` — type of record being approved (e.g. "purchase_order")
  - `subject_id` — ID of record being approved
  - `title` — request title
  - `description` — request description
  - `amount_cents` — amount requiring approval (if applicable)
  - `currency` — ISO 4217 currency
  - `status` — :draft | :pending | :approved | :rejected | :cancelled | :expired
  - `submitted_at` — when submitted
  - `resolved_at` — when approved/rejected
  - `expires_at` — when request expires
  - `current_step` — current step number in the chain
  - `total_steps` — total steps required
  - `comments` — resolution comments
  - `subject_key` / `subject_id` — object-ref attachment

  Lifecycle: draft → pending → approved/rejected/cancelled/expired
  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "apq",
    archivable: true

  postgres do
    table("apq_request")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :rule_id, :uuid
    attribute :requester_id, :uuid, allow_nil?: false
    attribute :subject_type, :string
    attribute :title, :string, allow_nil?: false
    attribute :description, :string
    attribute :amount_cents, :integer
    attribute :currency, :string, default: "USD"
    attribute :status, :atom, default: :draft,
      constraints: [one_of: [:draft, :pending, :approved, :rejected, :cancelled, :expired]]
    attribute :submitted_at, :utc_datetime_usec
    attribute :resolved_at, :utc_datetime_usec
    attribute :expires_at, :utc_datetime_usec
    attribute :current_step, :integer, default: 0
    attribute :total_steps, :integer, default: 1
    attribute :comments, :string
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
        Ash.Changeset.force_change_attribute(changeset, :status, :pending)
        Ash.Changeset.force_change_attribute(changeset, :submitted_at, DateTime.utc_now())
      end
    end

    update :approve do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :status, :approved)
        Ash.Changeset.force_change_attribute(changeset, :resolved_at, DateTime.utc_now())
      end
    end

    update :reject do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :status, :rejected)
        Ash.Changeset.force_change_attribute(changeset, :resolved_at, DateTime.utc_now())
      end
    end

    update :cancel do
      require_atomic? false
      change set_attribute(:status, :cancelled)
    end

    update :expire do
      require_atomic? false
      change set_attribute(:status, :expired)
    end

    update :advance_step do
      require_atomic? false

      change fn changeset, _context ->
        current = Ash.Changeset.get_attribute(changeset, :current_step) || 0
        Ash.Changeset.force_change_attribute(changeset, :current_step, current + 1)
      end
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
