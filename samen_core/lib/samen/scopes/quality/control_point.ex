defmodule Samen.Scopes.Quality.ControlPoint do
  @moduledoc """
  Quality Control Point (WS-ERP E19;).

  Defines WHERE and WHEN quality checks occur. Control points can be
  attached to manufacturing operations, receipts, or deliveries.

  ## Design

  - `title` — descriptive name for the control point
  - `product_id` — optional: specific product (nil = all products)
  - `product_category_id` — optional: category filter
  - `operation_type` — :manufacturing | :receipt | :delivery | :transfer
  - `work_order_operation` — optional: Manual Assembly, Packing, Testing, etc.
  - `control_type` — :all | :random | :periodic
  - `check_type` — :instructions | :picture | :pass_fail | :measure
  - `team_id` — quality team responsible
  - `responsible_id` — individual responsible
  - `is_active` — whether this control point is active
  - `norm` — for measure type: target value
  - `tolerance_min` — for measure type: minimum acceptable
  - `tolerance_max` — for measure type: maximum acceptable
  - `instructions` — what to check
  - `failure_message` — what to do if check fails
  - `notes` — additional info

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "qcp",
    archivable: true

  postgres do
    table("qcp_control_point")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:title, :string, public?: true, allow_nil?: false)
    attribute(:product_id, :uuid, public?: true)
    attribute(:product_category_id, :uuid, public?: true)
    attribute(:operation_type, :atom, public?: true, allow_nil?: false)
    attribute(:work_order_operation, :string, public?: true)
    attribute(:control_type, :atom, public?: true, allow_nil?: false, default: :all)
    attribute(:check_type, :atom, public?: true, allow_nil?: false, default: :pass_fail)
    attribute(:team_id, :uuid, public?: true)
    attribute(:responsible_id, :uuid, public?: true)
    attribute(:is_active, :boolean, public?: true, allow_nil?: false, default: true)
    attribute(:norm, :float, public?: true)
    attribute(:tolerance_min, :float, public?: true)
    attribute(:tolerance_max, :float, public?: true)
    attribute(:instructions, :string, public?: true)
    attribute(:failure_message, :string, public?: true)
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
