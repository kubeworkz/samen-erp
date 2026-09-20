defmodule Samen.Scopes.Dataclean.Rule do
  @moduledoc """
  Data Cleaning Rule (WS-ERP E23;).

  Defines deduplication rules for a specific table and field combination.

  ## Design

  - `name` — rule name (e.g., "Duplicate Contacts")
  - `table_name` — which table to scan (e.g., "contacts")
  - `field_names` — JSON array of fields to compare (e.g., ["name", "email"])
  - `match_type` — :exact | :fuzzy
  - `threshold` — for fuzzy matching: similarity threshold (0.0-1.0)
  - `is_active` — whether this rule is active
  - `auto_merge` — whether to auto-merge duplicates (vs manual review)
  - `last_run_at` — when the rule was last executed
  - `duplicates_found` — count from last run

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "dcr",
    archivable: true

  postgres do
    table("dcr_rule")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:name, :string, public?: true, allow_nil?: false)
    attribute(:table_name, :string, public?: true, allow_nil?: false)
    attribute(:field_names, :map, public?: true, allow_nil?: false)
    attribute(:match_type, :atom, public?: true, allow_nil?: false, default: :exact)
    attribute(:threshold, :float, public?: true, default: 0.8)
    attribute(:is_active, :boolean, public?: true, allow_nil?: false, default: true)
    attribute(:auto_merge, :boolean, public?: true, allow_nil?: false, default: false)
    attribute(:last_run_at, :utc_datetime_usec, public?: true)
    attribute(:duplicates_found, :integer, public?: true, allow_nil?: false, default: 0)
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
