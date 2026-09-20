defmodule Samen.Scopes.Work.TimesheetEntry do
  @moduledoc """
  Timesheet Entry (WS-ERP E15; project management).

  A time log against a task. Each entry records hours spent by a user
  on a specific task on a specific date.

  ## Design

  - `task_id` — the task being tracked (FK to Work.Task)
  - `user_id` — who logged the time
  - `date` — the date the work was done (not the entry date)
  - `hours` — decimal hours (e.g., 2.5 = 2h 30m)
  - `description` — what was done
  - `billable` — whether this time is billable to a client
  - `approved` — whether a manager has approved the entry

  ## Invariants

  - **No future entries.** You cannot log time for a future date.
  - **Max 24h per day.** Total hours across all entries for a user on
    a single day cannot exceed 24.
  - **No negative hours.** Hours must be positive.
  - **Approved entries are frozen.** An approved entry cannot be edited
    or deleted (same immutability posture as posted journal entries).

  ## PII map — EMPTY (INV-1)

  `description` is freeform user content — default-deny-CDC-excluded,
  not vaulted. All other fields are bounded ids, dates, or decimals.
  """

  use Samen.Resource,
    otp_app: :samen_core,
    domain: Samen.Core.Domain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer],
    abbrev: "tse",
    archivable: true

  postgres do
    table("tse_timesheet_entry")
    repo(SamenCore.TestRepo)
  end

  attributes do
    attribute(:task_id, :uuid, public?: true, allow_nil?: false)
    attribute(:user_id, :uuid, public?: true, allow_nil?: false)
    attribute(:date, :date, public?: true, allow_nil?: false)

    # Decimal hours (e.g., 2.5 = 2h 30m). Stored as float for simplicity;
    # the guard enforces precision to 0.25h (15-minute increments).
    attribute(:hours, :float, public?: true, allow_nil?: false)

    attribute(:description, :string, public?: true)
    attribute(:billable, :boolean, public?: true, allow_nil?: false, default: true)
    attribute(:approved, :boolean, public?: true, allow_nil?: false, default: false)
    attribute(:approved_by, :uuid, public?: true)
    attribute(:approved_at, :utc_datetime, public?: true)
  end

  actions do
    defaults([:read])

    create :create do
      accept([:org_id, :task_id, :user_id, :date, :hours, :description, :billable])
      change(Samen.Scopes.Work.TimesheetGuard)
    end

    update :update_entry do
      accept([:hours, :description, :billable])
      change(Samen.Scopes.Work.TimesheetGuard)
    end

    update :approve do
      accept([:approved_by])
      change(Samen.Scopes.Work.TimesheetGuard)
    end
  end

  policies do
    policy action_type(:read) do
      authorize_if(Samen.Policy.OrgScope)
    end

    policy action_type([:create, :update]) do
      forbid_unless(Samen.Policy.OrgScope)
      forbid_unless({Samen.Policy.RoleAtLeast, role: :member})
      authorize_if(always())
    end
  end
end
