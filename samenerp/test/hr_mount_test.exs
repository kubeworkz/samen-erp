defmodule Samenerp.HrMountTest do
  @moduledoc """
  WS-ACCT Phase 16 — the Kubeworkz host's HR mount.

  The first slice proves the host domain is real (employee + the in-transaction
  `:hired` ledger row + a pending leave request) and that the existing grant
  personnel report resolves the name through `:personnel_namespace` on both
  planes: clear for the tenant, masked for the operator.
  """

  use Samenerp.DataCase, async: false

  require Ash.Query

  alias Samen.Web.{GrantPersonnel, Mount, Plane}
  alias Samenerp.Erp
  alias Samenerp.Hr.{Employee, EmploymentEvent, LeaveRequest}

  @first "Kube"
  @last "Worker"

  setup do
    org = Ecto.UUID.generate()

    scope = %Samen.Scope{
      actor: %{id: "a:#{org}", org_id: org, role: :admin, kind: :tenant, plane: :tenant}
    }

    {:ok, org: org, scope: scope}
  end

  test "the host HR mount persists the person and the grant report resolves the name", %{
    org: org,
    scope: scope
  } do
    employee =
      Employee
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org,
          employee_number: "KUBE-001",
          hired_at: ~D[2026-01-05],
          employment_type: :full_time,
          full_name: %Samen.Type.FullName{first: @first, last: @last},
          work_emails: [%{label: "work", address: "kube.worker@example.test"}],
          dob: ~D[1990-01-01]
        },
        scope: scope
      )
      |> Ash.create!()

    assert employee.employee_number == "KUBE-001"

    events =
      EmploymentEvent
      |> Ash.Query.filter(employee_id == ^employee.id)
      |> Ash.read!(scope: scope)

    assert [%{kind: :hired}] = events

    leave =
      LeaveRequest
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org,
          employee_id: employee.id,
          kind: :vacation,
          start_date: ~D[2026-10-05],
          end_date: ~D[2026-10-09]
        },
        scope: scope
      )
      |> Ash.create!()

    assert leave.status == :pending

    fund =
      Erp.CostObject
      |> Ash.Changeset.for_create(
        :create,
        %{org_id: org, code: "FUND-HR", name: "HR grant fund", kind: :fund},
        scope: scope
      )
      |> Ash.create!()

    grant =
      Erp.Grant
      |> Ash.Changeset.for_create(
        :create,
        %{
          org_id: org,
          funder: "Kubeworkz Foundation",
          program: "Workforce",
          award_ref: "KW-HR-001",
          award_cents: 120_000,
          period_start: ~D[2026-01-01],
          period_end: ~D[2026-12-31],
          fund_cost_object_id: fund.id
        },
        scope: scope
      )
      |> Ash.create!()

    Erp.GrantPersonnel
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: org,
        grant_id: grant.id,
        employee_id: employee.id,
        effort_pct: 40,
        effective_on: ~D[2026-01-01]
      },
      scope: scope
    )
    |> Ash.create!()

    labels = %{grants_path: "/grants", personnel_namespace: Samenerp.Hr}

    mount = Mount.new(:erp, Samenerp.Erp, Samenerp.Repo, labels: labels)

    assert {:ok, report} = GrantPersonnel.load(mount, org, grant.id)
    assert report.personnel_wired?
    assert [row] = report.rows
    assert row.name =~ @first
    assert row.name =~ @last

    operator_mount =
      Mount.new(:erp, Samenerp.Erp, Samenerp.Repo,
        plane: Plane.operator("op-1", org, "hr-mount-session"),
        labels: labels
      )

    assert {:ok, operator_report} = GrantPersonnel.load(operator_mount, org, grant.id)
    assert operator_report.personnel_wired?
    assert [operator_row] = operator_report.rows
    assert operator_row.name == "••••"
    refute operator_row.name =~ @first
  end
end
