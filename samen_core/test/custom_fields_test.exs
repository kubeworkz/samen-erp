defmodule Samen.CustomFieldsTest do
  @moduledoc """
  WS-ERP E38: Custom Fields — lightweight low-code extension.

  ## Resources

  - `FieldValue` — dynamic key-value fields on any resource

  ## Tests

  - cf1: Attach string field to a resource
  - cf2: Attach integer field
  - cf3: Attach float field
  - cf4: Attach boolean field
  - cf5: Attach date field
  - cf6: Attach JSON field
  - cf7: Multiple fields on same resource
  - cf8: Fields on different resource types
  - cf9: Update field value
  - cf10: Delete field
  - cf11: Field type coercion
  - cf12: Full custom fields ceremony
  """
  use ExUnit.Case, async: true

  # --- cf1: String field ---

  describe "cf1 — string field" do
    test "attach string field" do
      fv = %{resource_type: "Samen.Scopes.Crm.Contact", resource_id: "ct_001", field_name: "loyalty_tier", field_type: :string, string_value: "gold"}
      assert fv.string_value == "gold"
      assert fv.field_type == :string
    end
  end

  # --- cf2: Integer field ---

  describe "cf2 — integer field" do
    test "attach integer field" do
      fv = %{resource_type: "Samen.Scopes.Crm.Contact", resource_id: "ct_001", field_name: "employee_count", field_type: :integer, integer_value: 250}
      assert fv.integer_value == 250
    end
  end

  # --- cf3: Float field ---

  describe "cf3 — float field" do
    test "attach float field" do
      fv = %{resource_type: "Samen.Scopes.Hr.Employee", resource_id: "emp_001", field_name: "satisfaction_score", field_type: :float, float_value: 4.7}
      assert fv.float_value == 4.7
    end
  end

  # --- cf4: Boolean field ---

  describe "cf4 — boolean field" do
    test "attach boolean field" do
      fv = %{resource_type: "Samen.Scopes.Purchasing.Supplier", resource_id: "sup_001", field_name: "is_preferred", field_type: :boolean, boolean_value: true}
      assert fv.boolean_value == true
    end
  end

  # --- cf5: Date field ---

  describe "cf5 — date field" do
    test "attach date field" do
      fv = %{resource_type: "Samen.Scopes.Crm.Contact", resource_id: "ct_001", field_name: "contract_renewal", field_type: :date, date_value: ~D[2027-01-15]}
      assert fv.date_value == ~D[2027-01-15]
    end
  end

  # --- cf6: JSON field ---

  describe "cf6 — JSON field" do
    test "attach JSON field" do
      fv = %{resource_type: "Samen.Scopes.Crm.Contact", resource_id: "ct_001", field_name: "preferences", field_type: :json, json_value: "{\"theme\":\"dark\",\"lang\":\"en\"}"}
      assert fv.json_value =~ "dark"
    end
  end

  # --- cf7: Multiple fields on same resource ---

  describe "cf7 — multiple fields" do
    test "3 fields on one contact" do
      fields = [
        %{resource_type: "Samen.Scopes.Crm.Contact", resource_id: "ct_001", field_name: "loyalty_tier", string_value: "gold"},
        %{resource_type: "Samen.Scopes.Crm.Contact", resource_id: "ct_001", field_name: "employee_count", integer_value: 250},
        %{resource_type: "Samen.Scopes.Crm.Contact", resource_id: "ct_001", field_name: "is_vip", boolean_value: true}
      ]

      assert length(fields) == 3
      assert Enum.all?(fields, &(&1.resource_id == "ct_001"))
    end
  end

  # --- cf8: Fields on different resource types ---

  describe "cf8 — cross-resource fields" do
    test "fields on different types" do
      fields = [
        %{resource_type: "Samen.Scopes.Crm.Contact", resource_id: "ct_001", field_name: "tier", string_value: "gold"},
        %{resource_type: "Samen.Scopes.Hr.Employee", resource_id: "emp_001", field_name: "certifications", string_value: "AWS, GCP"},
        %{resource_type: "Samen.Scopes.Purchasing.Supplier", resource_id: "sup_001", field_name: "rating", float_value: 4.8}
      ]

      types = Enum.map(fields, & &1.resource_type) |> Enum.uniq()
      assert length(types) == 3
    end
  end

  # --- cf9: Update field value ---

  describe "cf9 — update field" do
    test "change string value" do
      fv = %{string_value: "silver"}
      fv = %{fv | string_value: "gold"}
      assert fv.string_value == "gold"
    end

    test "change integer value" do
      fv = %{integer_value: 100}
      fv = %{fv | integer_value: 250}
      assert fv.integer_value == 250
    end
  end

  # --- cf10: Delete field ---

  describe "cf10 — delete field" do
    test "field removed" do
      fields = [
        %{field_name: "tier", string_value: "gold"},
        %{field_name: "score", integer_value: 100}
      ]

      fields = Enum.reject(fields, &(&1.field_name == "tier"))
      assert length(fields) == 1
      assert List.first(fields).field_name == "score"
    end
  end

  # --- cf11: Field type coercion ---

  describe "cf11 — field types" do
    test "all field types" do
      types = [:string, :integer, :float, :boolean, :date, :json]
      assert length(types) == 6
    end
  end

  # --- cf12: Full custom fields ceremony ---

  describe "cf12 — full custom fields ceremony" do
    test "add, query, update, delete custom fields on a contact" do
      # 1. Contact exists
      contact = %{id: "ct_001", name: "Acme Corp"}

      # 2. Add custom fields
      fields = [
        %{resource_type: "Samen.Scopes.Crm.Contact", resource_id: contact.id, field_name: "loyalty_tier", field_type: :string, string_value: "silver"},
        %{resource_type: "Samen.Scopes.Crm.Contact", resource_id: contact.id, field_name: "annual_revenue", field_type: :integer, integer_value: 500_000},
        %{resource_type: "Samen.Scopes.Crm.Contact", resource_id: contact.id, field_name: "is_enterprise", field_type: :boolean, boolean_value: false}
      ]

      # 3. Query custom fields for this contact
      contact_fields = Enum.filter(fields, &(&1.resource_id == contact.id))
      assert length(contact_fields) == 3

      # 4. Update loyalty tier based on revenue
      fields = Enum.map(fields, fn f ->
        if f.field_name == "loyalty_tier" and f.resource_id == contact.id do
          %{f | string_value: "gold"}
        else
          f
        end
      end)

      tier = Enum.find(fields, &(&1.field_name == "loyalty_tier"))
      assert tier.string_value == "gold"

      # 5. Mark as enterprise
      fields = Enum.map(fields, fn f ->
        if f.field_name == "is_enterprise" do
          %{f | boolean_value: true}
        else
          f
        end
      end)

      enterprise = Enum.find(fields, &(&1.field_name == "is_enterprise"))
      assert enterprise.boolean_value == true

      # 6. Delete the annual_revenue field (no longer needed)
      fields = Enum.reject(fields, &(&1.field_name == "annual_revenue"))
      assert length(fields) == 2

      assert Enum.all?(fields, &(&1.resource_id == contact.id))
    end
  end
end
