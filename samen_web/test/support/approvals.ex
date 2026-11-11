defmodule Samen.WebTest.Approvals do
  @moduledoc """
  Test-only approvals domain.

  The web test host intentionally wires no production `Approval` resource, so
  this ETS-backed stand-in lets the AP detail tests drive the REAL
  `Samen.Approvals` engine without adding another SQL table (and without
  changing the production host's approval wiring).
  """

  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource(Samen.WebTest.Approvals.Approval)
  end
end

defmodule Samen.WebTest.Approvals.Approval do
  @moduledoc false

  use Ash.Resource,
    domain: Samen.WebTest.Approvals,
    validate_domain_inclusion?: false,
    data_layer: Ash.DataLayer.Ets

  ets do
    private?(true)
  end

  attributes do
    uuid_primary_key(:id)
    attribute(:org_id, :uuid, public?: true, allow_nil?: true)
    attribute(:kind, :string, public?: true, allow_nil?: false)
    attribute(:subject_ref, :string, public?: true, allow_nil?: false)
    attribute(:steps, {:array, :map}, public?: true, allow_nil?: false, default: [])
    attribute(:requested_by, :string, public?: true, allow_nil?: false)
    attribute(:decided_by, :string, public?: true)
    attribute(:reason, :string, public?: true)
    attribute(:deadline_at, :utc_datetime_usec, public?: true)
    attribute(:requested_at, :utc_datetime_usec, public?: true)
    attribute(:decided_at, :utc_datetime_usec, public?: true)

    attribute(:state, :atom,
      public?: true,
      allow_nil?: false,
      default: :pending,
      constraints: [one_of: [:pending, :approved, :rejected, :expired, :cancelled]]
    )
  end

  actions do
    defaults([:read, :destroy])

    create :open do
      accept([
        :org_id,
        :kind,
        :subject_ref,
        :requested_by,
        :reason,
        :deadline_at,
        :requested_at,
        :steps
      ])
    end

    update :approve do
      accept([:decided_by, :steps])
      require_atomic?(false)
      change(set_attribute(:state, :approved))
      change(set_attribute(:decided_at, &DateTime.utc_now/0))
    end

    update :reject do
      accept([:decided_by, :steps])
      require_atomic?(false)
      change(set_attribute(:state, :rejected))
      change(set_attribute(:decided_at, &DateTime.utc_now/0))
    end

    update :advance do
      accept([:steps])
      require_atomic?(false)
    end

    update :cancel do
      accept([:steps])
      require_atomic?(false)
      change(set_attribute(:state, :cancelled))
      change(set_attribute(:decided_at, &DateTime.utc_now/0))
    end
  end
end
