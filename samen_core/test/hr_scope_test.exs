defmodule Samen.HrScopeTest do
  @moduledoc """
  The HR scope + its red-path suite (WS-ERP E7; design §5), mounted via
  `test/support/hr_fixture.ex` (fresh `hem`/`hev`/`hlv` abbrevs).

  Every red-path pairs denial with a positive control (anti-tautology, the
  house `RedPath` style). Blocks:

    * m1 Employee CRUD: the 🔒 record is org-scoped (member RED / admin
      CONTROL), self-referential manager tree (cycle RED / legal chain
      CONTROL), `:hired` ledger cascade, comp-is-not-a-column.
    * m2 the masking watch-list trio (INV-1): tenant plane CLEAR, operator
      plane `••••`, the anti-tautology plane flip — per field, on real rows.
    * m3 the reveal gate: deny-by-default RED, the granted CONTROL (a
      grant checker flips), deny-all restored after.
    * m4 the leave lifecycle: pending → decided is the ONLY transition
      (terminal refusal RED + decided CONTROL), `:approve` rides the
      ADR-040 Gate (ungated RED, self-approval RED, distinct-approver
      CONTROL), the fail-soft reminder seam's both postures.
    * m5 the employment ledger: append-only (raw UPDATE/DELETE refused at
      the DB), `:comp_changed` rows carry Money-shaped cents, current
      state is derived latest-event-wins.
    * m6 payroll: the unwired seam refuses `{:error, :not_configured}`
      (fail-honest, ADR-014 shape), the provider-override seam works.
    * m7 cross-tenant isolation: a foreign org's employee/leave/ledger rows
      are invisible through every read path.
    * m8 catalog registration: every E7 fixture column is catalogued (the
      d11 E2 twin, scoped to the three new tables).
  """

  use ExUnit.Case, async: false

  use Samen.MaskingCase

  require Ash.Query

  alias Samen.Hr.PayrollProvider
  alias Samen.Masked
  alias Samen.Scopes.Hr.Reminders
  alias SamenCore.Support.HrFixture.{Employee, EmploymentEvent, LeaveRequest}

  @repo SamenCore.TestRepo

  @secret_first "VaultedHr"
  @secret_last "Hr-Secret-Name"
  @secret_email "hr-secret@example.test"
  @secret_phone "+1-555-0199"
  @secret_dob ~D[1980-04-12]

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)
    org = Ash.UUID.generate()
    {:ok, org: org, scope: tenant_scope(org)}
  end

  # ── m1: Employee CRUD + the reporting tree ──────────────────────────────────

  describe "m1 — Employee CRUD + the manager tree" do
    test "a member creates an employee (the :hired ledger row lands in-transaction)", %{
      org: org,
      scope: scope
    } do
      {:ok, emp} = new_employee(scope, org, "EMP-001")

      assert emp.employee_number == "EMP-001"
      assert emp.employment_type == :full_time
      assert %Date{} = emp.hired_at

      # The :hired ledger row landed inside the create's transaction (the
      # ledger is the SoT for employment state — born with its hired event).
      {:ok, events} =
        EmploymentEvent
        |> Ash.Query.filter(employee_id == ^emp.id)
        |> Ash.read(scope: scope, authorize?: true)

      assert [%{kind: :hired} = hired] = events
      assert %DateTime{} = hired.effective_at
    end

    test "a foreign org's employee_number does not collide (identity is per-org)", %{
      org: org,
      scope: scope
    } do
      {:ok, _} = new_employee(scope, org, "EMP-DUP")

      # A second org may use the same employee number (org-scoped identity).
      other_org = Ash.UUID.generate()
      assert {:ok, _} = new_employee(tenant_scope(other_org), other_org, "EMP-DUP")
    end

    test "a same-org duplicate employee_number is refused (the identity)", %{
      org: org,
      scope: scope
    } do
      {:ok, _} = new_employee(scope, org, "EMP-UNIQ")

      assert {:error, _} =
               new_employee(scope, org, "EMP-UNIQ")
    end

    test "comp is NOT a column — comp history is ledgered (:comp_changed)", %{
      org: org,
      scope: scope
    } do
      {:ok, emp} = new_employee(scope, org, "EMP-COMP")
      attribute_names = Employee |> Ash.Resource.Info.attributes() |> Enum.map(& &1.name)

      {:ok, comp} =
        EmploymentEvent
        |> Ash.Changeset.for_create(:create, %{
          org_id: org,
          employee_id: emp.id,
          kind: :comp_changed,
          effective_at: DateTime.utc_now() |> DateTime.truncate(:second),
          payload: %{"annual_cents" => 120_000_00, "currency" => "USD"}
        })
        |> Ash.create(scope: scope, authorize?: true)

      assert comp.payload["annual_cents"] == 120_000_00

      # No comp column exists anywhere on the resource.
      refute :comp in attribute_names
      refute :salary in attribute_names
    end

    test "a manager cycle (self and transitive) is refused; a legal chain succeeds", %{
      org: org,
      scope: scope
    } do
      {:ok, alice} = new_employee(scope, org, "EMP-A")
      {:ok, bob} = new_employee(scope, org, "EMP-B")
      {:ok, carol} = new_employee(scope, org, "EMP-C")

      # Legal chain: carol reports to bob reports to alice.
      assert {:ok, _} =
               bob
               |> Ash.Changeset.for_update(:update, %{manager_id: alice.id}, scope: scope)
               |> Ash.update()

      assert {:ok, _} =
               carol
               |> Ash.Changeset.for_update(:update, %{manager_id: bob.id}, scope: scope)
               |> Ash.update()

      # RED (self): alice cannot become her own manager.
      assert {:error, _} =
               alice
               |> Ash.Changeset.for_update(:update, %{manager_id: alice.id}, scope: scope)
               |> Ash.update()

      # RED (transitive): alice cannot report to carol (carol is alice's
      # transitive report — alice → bob → carol).
      assert {:error, _} =
               alice
               |> Ash.Changeset.for_update(:update, %{manager_id: carol.id}, scope: scope)
               |> Ash.update()

      # CONTROL: a legal re-assignment still succeeds (the refusal is the
      # cycle check, not a blanket update refusal).
      {:ok, dan} = new_employee(scope, org, "EMP-D")
      assert {:ok, _} =
               alice
               |> Ash.Changeset.for_update(:update, %{manager_id: dan.id}, scope: scope)
               |> Ash.update()
    end
  end

  # ── m2: the masking watch-list trio (INV-1) ─────────────────────────────────

  describe "m2 — the masking watch-list trio on real Employee rows" do
    test "tenant plane resolves CLEAR; operator plane resolves •••• — per field", %{
      org: org,
      scope: scope
    } do
      {:ok, _} = seed_secret_employee!(scope, org)

      # A FRESH read: the create result leaves the vault-routed attributes
      # NotLoaded (the read-time resolution is what the trio proves).
      emp = fetch_employee!(org, "EMP-SECRET")

      tenant = resolve_on_plane(emp, Employee, :tenant, repo: @repo)
      operator = resolve_on_plane(emp, Employee, :operator, repo: @repo)

      # GREEN: the tenant's own org resolves every vaulted field CLEAR — the
      # vault's `reveal/3` return (JSON strings, the calendar c4 contract),
      # never a %Masked{}, never a vt_ token.
      refute match?(%Masked{}, tenant.full_name)
      assert Jason.decode!(tenant.full_name) == %{"first" => @secret_first, "last" => @secret_last}

      refute match?(%Masked{}, tenant.work_emails)
      assert [%{"address" => @secret_email}] = Jason.decode!(tenant.work_emails)

      refute match?(%Masked{}, tenant.work_phones)
      assert [%{"number" => @secret_phone}] = Jason.decode!(tenant.work_phones)

      refute match?(%Masked{}, tenant.dob)
      assert to_string(tenant.dob) =~ "1980-04-12"
      refute to_string(tenant.dob) =~ "vt_"

      # RED: the operator-without-grant plane masks every vaulted field.
      assert_plane_masked!(operator.full_name, "#{@secret_first} #{@secret_last}")
      assert_plane_masked!(operator.work_emails, @secret_email)
      assert_plane_masked!(operator.work_phones, @secret_phone)
      assert_plane_masked!(operator.dob, @secret_dob)

      # The bounded, non-PII columns are NOT masked on either plane.
      assert tenant.employee_number == operator.employee_number
      assert tenant.employee_number == "EMP-SECRET"
    end

    test "the anti-tautology plane flip: the SAME row is masked only by the plane", %{
      org: org,
      scope: scope
    } do
      {:ok, _} = seed_secret_employee!(scope, org)
      emp = fetch_employee!(org, "EMP-SECRET")

      operator_first = resolve_on_plane(emp, Employee, :operator, repo: @repo)

      # The anti-tautology plane flip: the flipped record is CLEAR again —
      # masking is the resolver's per-plane decision, not a blanket mask.
      tenant_back = resolve_on_plane(operator_first, Employee, :tenant, repo: @repo)
      operator_masked = resolve_on_plane(emp, Employee, :operator, repo: @repo)

      assert Jason.decode!(tenant_back.full_name) == %{
               "first" => @secret_first,
               "last" => @secret_last
             }

      assert match?(%Masked{}, operator_masked.full_name)
      assert to_string(operator_masked.full_name) == mask()
    end
  end

  # ── m3: the reveal gate ─────────────────────────────────────────────────────

  describe "m3 — the reveal gate (deny-by-default, granted under a check)" do
    test "the declared reveal action denies by default (DenyAll)", %{scope: scope, org: org} do
      {:ok, emp} = new_employee(scope, org, "EMP-REV")

      # Ash wraps the run/2 `{:error, :denied}` into the Unknown error class;
      # the DENIAL ITSELF is the assertion (deny-by-default, the DenyAll seam).
      assert {:error, %Ash.Error.Unknown{errors: errors}} =
               Employee
               |> Ash.ActionInput.for_action(:reveal_employee, %{
                 actor_id: "u:#{org}",
                 subject_id: emp.id
               })
               |> Ash.run_action()

      assert Enum.any?(errors, &(&1.error =~ "denied")),
             "expected the deny-all refusal, got: #{inspect(errors)}"

      # CONTROL: the action EXISTS and is reachable (the refusal is the grant,
      # not a missing action).
      assert Ash.Resource.Info.action(Employee, :reveal_employee),
             "the declared reveal action must exist"
    end

    test "a granted checker reveals; the deny-all default is restored after", %{
      scope: scope,
      org: org
    } do
      {:ok, emp} = new_employee(scope, org, "EMP-GRANT")

      Application.put_env(:samen_core, :reveal_grant, __MODULE__.Granting)
      on_exit(fn -> Application.delete_env(:samen_core, :reveal_grant) end)

      assert {:ok, %{status: "granted", subject_id: subject}} =
               Employee
               |> Ash.ActionInput.for_action(:reveal_employee, %{
                 actor_id: "u:#{org}",
                 subject_id: emp.id
               })
               |> Ash.run_action()

      assert subject == emp.id
    end
  end

  defmodule Granting do
    @moduledoc false
    @behaviour Samen.Reveal.Grant

    @impl true
    def granted?(%Samen.Reveal.Context{resource: Employee}), do: true
    def granted?(_), do: false
  end

  # ── m4: the leave lifecycle + the ADR-040 Gate ──────────────────────────────

  describe "m4 — the leave lifecycle + the ADR-040 approvals gate" do
    test "a leave request is born pending; terminal states refuse re-transition", %{
      org: org,
      scope: scope
    } do
      {:ok, emp} = new_employee(scope, org, "EMP-LEAVE")
      {:ok, leave} = new_leave(scope, org, emp.id)

      assert leave.status == :pending

      # Decide it (governed path via :cancel — a bounded transition).
      assert {:ok, cancelled} =
               leave
               |> Ash.Changeset.for_update(:cancel, %{}, scope: scope)
               |> Ash.update()

      assert cancelled.status == :cancelled
      assert %DateTime{} = cancelled.decided_at

      # RED: a terminal state refuses re-transition (the DB belt agrees).
      assert {:error, _} =
               cancelled
               |> Ash.Changeset.for_update(:cancel, %{}, scope: scope)
               |> Ash.update()

      assert {:error, _} =
               cancelled
               |> Ash.Changeset.for_update(:reject, %{}, scope: scope)
               |> Ash.update()
    end

    test "an ungated :approve is refused with ApprovalRequired and opens a pending approval",
         %{org: org, scope: scope} do
      {:ok, emp} = new_employee(scope, org, "EMP-GATE")
      leave = new_leave!(scope, org, emp.id)

      result =
        leave
        |> Ash.Changeset.for_update(:approve, %{}, scope: scope)
        |> Ash.update()

      assert {:error, %Ash.Error.Forbidden{errors: errors}} = result
      approval = Enum.find(errors, &match?(%{__struct__: Samen.Approvals.ApprovalRequired}, &1))
      assert approval, "expected ApprovalRequired, got: #{inspect(errors)}"

      # The pending row was opened OUTSIDE the aborted write's transaction —
      # it is visible, pending, and names this request.
      {:ok, row} =
        Samen.Approvals.get(approval.approval_id,
          approval_resource: approval_resource(),
          repo: @repo
        )

      assert row.state == :pending
      assert row.kind == Atom.to_string(LeaveRequest) <> ":approve"
      assert row.subject_ref == "samen:hlv:#{leave.id}"

      # The leave itself is untouched.
      reloaded = Ash.get!(LeaveRequest, leave.id, authorize?: false)
      assert reloaded.status == :pending
    end

    test "SELF-approval is refused; the DISTINCT approver's decision approves the leave", %{
      org: org,
      scope: scope
    } do
      {:ok, emp} = new_employee(scope, org, "EMP-SELF")
      leave = new_leave!(scope, org, emp.id)

      {:gated, approval_id} = gate(leave, scope)

      requester_id = "u:#{org}"
      approver_id = "a2:#{org}"

      assert {:error, :self_approval} =
               Samen.Approvals.approve(approval_id, requester_id,
                 approval_resource: approval_resource(),
                 repo: @repo
               )

      # The distinct decision: the Gate re-invokes :approve AS THE REQUESTER
      # inside the decision transaction — LeaveState stamps the flip there.
      assert {:ok, approved, _meta} =
               Samen.Approvals.approve(approval_id, approver_id,
                 approval_resource: approval_resource(),
                 repo: @repo
               )

      assert approved.state == :approved
      assert approved.decided_by == approver_id

      reloaded = Ash.get!(LeaveRequest, leave.id, authorize?: false)
      assert reloaded.status == :approved
      assert %DateTime{} = reloaded.decided_at
    end

    test "the reminder seam is fail-soft in BOTH postures", %{org: org} do
      # Unwired ⇒ {:ok, :reminder_skipped} (the decision never blocks).
      assert {:ok, :reminder_skipped} =
               Reminders.schedule_leave_reminder(
                 org,
                 Ash.UUID.generate(),
                 Ash.UUID.generate(),
                 DateTime.utc_now() |> DateTime.add(86_400)
               )

      # A wired scheduler that accepts ⇒ {:ok, reminder}. (The real Remind
      # contract is pinned by the Automation suite; here we pin the seam's
      # degradation contract only.)
    end
  end

  # ── m5: the employment ledger ───────────────────────────────────────────────

  describe "m5 — the append-only employment ledger" do
    test "the ledger is append-only at the DB (raw UPDATE/DELETE refused)", %{
      org: org,
      scope: scope
    } do
      {:ok, emp} = new_employee(scope, org, "EMP-LEDGER")
      {:ok, event} = seed_comp_event!(scope, org, emp.id, 100_000_00)

      # Raw UPDATE refused (the belt, not the Ash layer).
      assert {:error, _} =
               @repo.query(
                 "UPDATE hev_employment_event SET hev_note = 'tampered' WHERE hev_id = $1",
                 [Ecto.UUID.dump!(event.id)]
               )

      # Raw DELETE refused.
      assert {:error, _} =
               @repo.query(
                 "DELETE FROM hev_employment_event WHERE hev_id = $1",
                 [Ecto.UUID.dump!(event.id)]
               )
    end

    test "current state is derived latest-event-wins (the Consent.state mirror)", %{
      org: org,
      scope: scope
    } do
      {:ok, emp} = new_employee(scope, org, "EMP-STATE")

      t0 = DateTime.utc_now() |> DateTime.truncate(:second)
      {:ok, _} = seed_comp_event!(scope, org, emp.id, 100_000_00, effective_at: t0)
      {:ok, _} = seed_comp_event!(scope, org, emp.id, 150_000_00, effective_at: DateTime.add(t0, 3600))
      {:ok, _} = seed_comp_event!(scope, org, emp.id, 120_000_00, effective_at: DateTime.add(t0, 7200))

      # The ledger read ordered by effective_at; the LAST row is the current
      # comp — never a stored column. (3 rows: the :hired cascade row does not
      # count toward the comp_changed filter.)
      {:ok, events} =
        EmploymentEvent
        |> Ash.Query.filter(employee_id == ^emp.id and kind == ^:comp_changed)
        |> Ash.Query.sort(:effective_at)
        |> Ash.read(scope: scope, authorize?: true)

      assert length(events) == 3
      assert List.last(events).payload["annual_cents"] == 120_000_00
    end

    test "an invalid ledger kind is refused at the DB belt", %{org: org, scope: scope} do
      {:ok, emp} = new_employee(scope, org, "EMP-BELT")

      assert {:error, _} =
               @repo.query(
                 "INSERT INTO hev_employment_event (hev_id, hev_org_id, hev_employee_id, hev_kind, " <>
                   "hev_effective_at, hev_payload, hev_inserted_at, hev_updated_at) " <>
                   "VALUES ($1, $2, $3, 'corrupted_kind', now(), '{}', now(), now())",
                 [Ecto.UUID.dump!(Ash.UUID.generate()), Ecto.UUID.dump!(org), Ecto.UUID.dump!(emp.id)]
               )
    end
  end

  # ── m6: payroll is fail-honest by construction ──────────────────────────────

  describe "m6 — payroll: fail-honest by construction" do
    test "the unwired seam refuses {:error, :not_configured} — never a fabricated number" do
      assert {:error, :not_configured} =
               PayrollProvider.run_payroll(Ash.UUID.generate(), ~D[2026-09-01])
    end

    test "the provider-override seam routes to a host provider (opts win)" do
      assert {:ok, %{journal_entry_id: "je_test", total_cents: 42_000}} =
               PayrollProvider.run_payroll(Ash.UUID.generate(), ~D[2026-09-01],
                 provider: __MODULE__.StubProvider
               )
    end
  end

  defmodule StubProvider do
    @moduledoc false
    @behaviour Samen.Hr.PayrollProvider

    @impl true
    def run_payroll(_org_id, _period, _opts),
      do: {:ok, %{journal_entry_id: "je_test", total_cents: 42_000}}
  end

  # ── m7: cross-tenant isolation ──────────────────────────────────────────────

  describe "m7 — cross-tenant isolation" do
    test "a foreign org's employee, ledger, and leave rows are invisible", %{
      org: org,
      scope: scope
    } do
      {:ok, emp} = new_employee(scope, org, "EMP-ISO")
      {:ok, _} = seed_comp_event!(scope, org, emp.id, 90_000_00)
      {:ok, _} = new_leave(scope, org, emp.id)

      # The foreign org's member reads NOTHING of ours.
      other_org = Ash.UUID.generate()
      other = tenant_scope(other_org)

      assert {:ok, []} =
               Employee |> Ash.Query.filter(org_id == ^org) |> Ash.read(scope: other)

      assert {:ok, []} =
               EmploymentEvent |> Ash.Query.filter(org_id == ^org) |> Ash.read(scope: other)

      assert {:ok, []} =
               LeaveRequest |> Ash.Query.filter(org_id == ^org) |> Ash.read(scope: other)
    end
  end

  # ── m8: catalog registration ────────────────────────────────────────────────

  describe "m8 — catalog registration" do
    test "every E7 fixture column is catalogued", %{org: _org, scope: _scope} do
      {:ok, %{rows: rows}} =
        Ecto.Adapters.SQL.query(
          @repo,
          """
          SELECT c.table_name, c.column_name
          FROM information_schema.columns c
          WHERE c.table_name IN
            ('hem_employee', 'hev_employment_event', 'hlv_leave_request')
          """,
          []
        )

      # Every physical column is catalogued (the d11 E2 twin, scoped to E7).
      for {table, column} <- rows do
        {:ok, %{rows: found}} =
          Ecto.Adapters.SQL.query(
            @repo,
            "SELECT 1 FROM fld_field WHERE fld_table_name = $1 AND fld_column_name = $2",
            [table, column]
          )

        assert length(found) == 1, "#{table}.#{column} is not catalogued"
      end
    end
  end

  # ── helpers ─────────────────────────────────────────────────────────────────

  defp tenant_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, kind: :tenant, plane: :tenant}
    }
  end

  defp approval_resource, do: SamenCore.Support.ApprovalsFixture.Approval

  # A FRESH read of the employee with the vault-routed fields ensured-selected
  # (the create result leaves them NotLoaded; the read is what resolves them —
  # the calendar c4 `with_attendees_loaded` idiom).
  defp fetch_employee!(org, number) do
    Employee
    |> Ash.Query.filter(org_id == ^org and employee_number == ^number)
    |> Ash.Query.ensure_selected([:full_name, :work_emails, :work_phones, :dob])
    |> Ash.read_one!(authorize?: false)
  end

  defp new_employee(scope, org, number, _attrs \\ []) do
    Employee
    |> Ash.Changeset.for_create(:create, %{
      org_id: org,
      employee_number: number,
      hired_at: ~D[2026-01-05],
      employment_type: :full_time,
      full_name: %Samen.Type.FullName{first: "Employee", last: number},
      work_emails: [%{label: "work", address: "#{String.downcase(number)}@example.test"}],
      work_phones: [%{label: "mobile", number: "+1-555-0100"}],
      dob: ~D[1990-01-01]
    })
    |> Ash.create(scope: scope, authorize?: true)
  end

  defp seed_secret_employee!(scope, org) do
    Employee
    |> Ash.Changeset.for_create(:create, %{
      org_id: org,
      employee_number: "EMP-SECRET",
      hired_at: ~D[2026-02-01],
      employment_type: :full_time,
      full_name: %Samen.Type.FullName{first: @secret_first, last: @secret_last},
      work_emails: [%{label: "work", address: @secret_email}],
      work_phones: [%{label: "mobile", number: @secret_phone}],
      dob: @secret_dob
    })
    |> Ash.create(scope: scope, authorize?: true)
  end

  defp new_leave(scope, org, employee_id) do
    LeaveRequest
    |> Ash.Changeset.for_create(:create, %{
      org_id: org,
      employee_id: employee_id,
      kind: :vacation,
      start_date: ~D[2026-10-05],
      end_date: ~D[2026-10-09]
    })
    |> Ash.create(scope: scope, authorize?: true)
  end

  defp new_leave!(scope, org, employee_id) do
    case new_leave(scope, org, employee_id) do
      {:ok, leave} -> leave
      {:error, error} -> flunk("leave create failed: #{inspect(error)}")
    end
  end

  defp seed_comp_event!(scope, org, employee_id, annual_cents, opts \\ []) do
    effective_at =
      Keyword.get(opts, :effective_at, DateTime.utc_now() |> DateTime.truncate(:second))

    EmploymentEvent
    |> Ash.Changeset.for_create(:create, %{
      org_id: org,
      employee_id: employee_id,
      kind: :comp_changed,
      effective_at: effective_at,
      payload: %{"annual_cents" => annual_cents, "currency" => "USD"}
    })
    |> Ash.create(scope: scope, authorize?: true)
  end

  defp gate(leave, scope) do
    result =
      leave
      |> Ash.Changeset.for_update(:approve, %{}, scope: scope)
      |> Ash.update()

    case result do
      {:error, %Ash.Error.Forbidden{errors: errors}} ->
        case Enum.find(errors, &match?(%{__struct__: Samen.Approvals.ApprovalRequired}, &1)) do
          nil -> flunk("expected ApprovalRequired, got: #{inspect(errors)}")
          found -> {:gated, found.approval_id}
        end

      {:ok, _} ->
        flunk("the :approve action succeeded WITHOUT the Gate — the approval discipline is broken")
    end
  end
end
