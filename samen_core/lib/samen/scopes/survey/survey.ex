defmodule Samen.Scopes.Survey.Survey do
  @moduledoc """
  Survey (WS-ERP E20; Flectra-inspired).

  A survey definition with questions, response collection, and
  optional certification support.

  ## Design

  - `title` — survey title
  - `description` — survey description
  - `state` — :draft | :open | :closed
  - `is_certification` — whether this is a certification exam
  - `passing_score` — minimum score to pass (percentage, 0-100)
  - `time_limit_minutes` — optional time limit
  - `allow_anonymous` — whether anonymous responses are allowed
  - `max_attempts` — optional max attempts per user
  - `start_date` — when the survey opens
  - `end_date` — when the survey closes

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "svy",
    archivable: true

  postgres do
    table("svy_survey")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:title, :string, public?: true, allow_nil?: false)
    attribute(:description, :string, public?: true)
    attribute(:state, :atom, public?: true, allow_nil?: false, default: :draft)
    attribute(:is_certification, :boolean, public?: true, allow_nil?: false, default: false)
    attribute(:passing_score, :integer, public?: true, allow_nil?: false, default: 70)
    attribute(:time_limit_minutes, :integer, public?: true)
    attribute(:allow_anonymous, :boolean, public?: true, allow_nil?: false, default: false)
    attribute(:max_attempts, :integer, public?: true)
    attribute(:start_date, :utc_datetime_usec, public?: true)
    attribute(:end_date, :utc_datetime_usec, public?: true)
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
