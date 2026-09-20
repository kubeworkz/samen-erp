defmodule Samen.Scopes.Consolidation.ConsolidationRule do
  @moduledoc """
  Multi-Company Consolidation Rule (WS-ERP E24;).

  Defines how to eliminate intercompany transactions during
  consolidation. Rules can be based on account pairs, transaction
  types, or custom conditions.

  ## Design

  - `group_id` — parent company group
  - `name` — rule name (e.g., "Eliminate Intercompany Sales")
  - `rule_type` — :account_pair | :transaction_type | :custom
  - `from_account_pattern` — account pattern for the sender side
  - `to_account_pattern` — account pattern for the receiver side
  - `transaction_type_filter` — optional: filter by transaction type
  - `elimination_entry_template` — JSON template for the elimination journal entry
  - `is_active` — whether this rule is active
  - `priority` — execution order (lower = first)
  - `description` — what this rule eliminates

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "ccr",
    archivable: true

  postgres do
    table("ccr_consolidation_rule")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:group_id, :uuid, public?: true, allow_nil?: false)
    attribute(:name, :string, public?: true, allow_nil?: false)
    attribute(:rule_type, :atom, public?: true, allow_nil?: false, default: :account_pair)
    attribute(:from_account_pattern, :string, public?: true)
    attribute(:to_account_pattern, :string, public?: true)
    attribute(:transaction_type_filter, :atom, public?: true)
    attribute(:elimination_entry_template, :map, public?: true)
    attribute(:is_active, :boolean, public?: true, allow_nil?: false, default: true)
    attribute(:priority, :integer, public?: true, allow_nil?: false, default: 100)
    attribute(:description, :string, public?: true)
  end

  actions do
    defaults([:read, create: :*, update: :*])
  end

  policies do
    policy action_type(:read) do
      authorize_if(Samen.Policy.OrgScope)
    end

    policy action_type([:create, :update, :destroy]) do
      forbid_unless(Samen.Policy.OrgScope)
      forbid_unless({Samen.Policy.RoleAtLeast, role: :admin})
      authorize_if(always())
    end
  end
end
