defmodule Samen.Scopes.Quality.Check do
  @moduledoc """
  Quality Check (WS-ERP E19;).

  A single quality check performed against a control point. Each check
  records the result (pass/fail), measured value, and who performed it.

  ## Design

  - `control_point_id` — which control point triggered this check
  - `production_id` — optional: manufacturing order
  - `product_id` — product being checked
  - `lot_id` — optional: lot/batch
  - `serial_number_id` — optional: serial number
  - `status` — :todo | :pass | :fail
  - `result` — for pass_fail: :pass or :fail; for measure: numeric value
  - `measure_value` — measured value (for measure type)
  - `uom` — unit of measurement (for measure type)
  - `user_id` — who performed the check
  - `done_at` — when the check was performed
  - `notes` — any observations

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "qck",
    archivable: true

  postgres do
    table("qck_check")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:control_point_id, :uuid, public?: true, allow_nil?: false)
    attribute(:production_id, :uuid, public?: true)
    attribute(:product_id, :uuid, public?: true, allow_nil?: false)
    attribute(:lot_id, :uuid, public?: true)
    attribute(:serial_number_id, :uuid, public?: true)
    attribute(:status, :atom, public?: true, allow_nil?: false, default: :todo)
    attribute(:result, :atom, public?: true)
    attribute(:measure_value, :float, public?: true)
    attribute(:uom, :string, public?: true)
    attribute(:user_id, :uuid, public?: true)
    attribute(:done_at, :utc_datetime_usec, public?: true)
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
      authorize_if(always())
    end
  end
end
