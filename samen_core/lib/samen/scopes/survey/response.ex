defmodule Samen.Scopes.Survey.Response do
  @moduledoc """
  Survey Response (WS-ERP E20;).

  A respondent's completed survey submission. Tracks score,
  completion time, and pass/fail status.

  ## Design

  - `survey_id` — which survey
  - `user_id` — respondent (nil for anonymous)
  - `state` — :in_progress | :completed
  - `score` — total score earned
  - `max_score` — maximum possible score
  - `percentage` — score as percentage (0-100)
  - `passed` — whether the respondent passed
  - `started_at` — when the respondent started
  - `completed_at` — when the respondent finished
  - `duration_seconds` — time taken in seconds
  - `attempt_number` — which attempt this is

  No PII (INV-1). Archivable.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "svr",
    archivable: true

  postgres do
    table("svr_response")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:survey_id, :uuid, public?: true, allow_nil?: false)
    attribute(:user_id, :uuid, public?: true)
    attribute(:state, :atom, public?: true, allow_nil?: false, default: :in_progress)
    attribute(:score, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:max_score, :integer, public?: true, allow_nil?: false, default: 0)
    attribute(:percentage, :float, public?: true, allow_nil?: false, default: 0.0)
    attribute(:passed, :boolean, public?: true, allow_nil?: false, default: false)
    attribute(:started_at, :utc_datetime_usec, public?: true)
    attribute(:completed_at, :utc_datetime_usec, public?: true)
    attribute(:duration_seconds, :integer, public?: true)
    attribute(:attempt_number, :integer, public?: true, allow_nil?: false, default: 1)
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
