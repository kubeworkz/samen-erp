defmodule Samen.Scopes.Dataclean.Merge do
  @moduledoc """
  Data Cleaning Merge (WS-ERP E23;).

  Records a merge operation when duplicate records are resolved.

  ## Design

  - `rule_id` — which rule found the duplicates
  - `table_name` — which table was cleaned
  - `primary_id` — the record to keep (survivor)
  - `duplicate_ids` — JSON array of record IDs to merge/remove
  - `field_values` — JSON map of resolved field values
  - `state` — :pending | :merged | :cancelled
  - `merged_by` — who performed the merge
  - `merged_at` — when the merge was performed
  - `notes` — merge notes

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "mrg",
    archivable: true

  postgres do
    table("dcm_merge")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:rule_id, :uuid, public?: true, allow_nil?: false)
    attribute(:table_name, :string, public?: true, allow_nil?: false)
    attribute(:primary_id, :uuid, public?: true, allow_nil?: false)
    attribute(:duplicate_ids, :map, public?: true, allow_nil?: false)
    attribute(:field_values, :map, public?: true)
    attribute(:state, :atom, public?: true, allow_nil?: false, default: :pending)
    attribute(:merged_by, :uuid, public?: true)
    attribute(:merged_at, :utc_datetime_usec, public?: true)
    attribute(:notes, :string, public?: true)
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
