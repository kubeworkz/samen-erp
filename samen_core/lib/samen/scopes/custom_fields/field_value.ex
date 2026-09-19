defmodule Samen.Scopes.CustomFields.FieldValue do
  @moduledoc """
  Custom Field Value (WS-ERP E38; lightweight low-code extension).

  Dynamic key-value fields attached to any existing resource.

  ## Design

  - `resource_type` — the Ash resource module name (e.g. "Samen.Scopes.Crm.Contact")
  - `resource_id` — UUID of the specific record
  - `field_name` — custom field name (e.g. "loyalty_tier")
  - `field_type` — :string | :integer | :float | :boolean | :date | :json
  - `string_value` — value when field_type = :string
  - `integer_value` — value when field_type = :integer
  - `float_value` — value when field_type = :float
  - `boolean_value` — value when field_type = :boolean
  - `date_value` — value when field_type = :date
  - `json_value` — value when field_type = :json
  - `subject_key` / `subject_id` — object-ref attachment

  This is a lightweight alternative to Studio — no schema changes needed.
  Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "cfv",
    archivable: true

  postgres do
    table("cfv_field_value")
    repo(SamenCore.TestRepo)
  end

  attributes do
    uuid_primary_key :id
    attribute :resource_type, :string, allow_nil?: false
    attribute :resource_id, :uuid, allow_nil?: false
    attribute :field_name, :string, allow_nil?: false
    attribute :field_type, :atom, default: :string,
      constraints: [one_of: [:string, :integer, :float, :boolean, :date, :json]]
    attribute :string_value, :string
    attribute :integer_value, :integer
    attribute :float_value, :float
    attribute :boolean_value, :boolean
    attribute :date_value, :date
    attribute :json_value, :string
    attribute :subject_key, :string
    attribute :subject_id, :string

    create_timestamp :inserted_at
    update_timestamp :updated_at
  end

  actions do
    defaults [:create, :read, :update, :destroy]

    update :set_string do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :field_type, :string)
        Ash.Changeset.force_change_attribute(changeset, :string_value, Ash.Changeset.get_attribute(changeset, :new_value))
      end
    end

    update :set_integer do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :field_type, :integer)
        Ash.Changeset.force_change_attribute(changeset, :integer_value, Ash.Changeset.get_attribute(changeset, :new_value))
      end
    end

    update :set_boolean do
      require_atomic? false

      change fn changeset, _context ->
        Ash.Changeset.force_change_attribute(changeset, :field_type, :boolean)
        Ash.Changeset.force_change_attribute(changeset, :boolean_value, Ash.Changeset.get_attribute(changeset, :new_value))
      end
    end
  end

  policies do
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if always()
    end
  end
end
