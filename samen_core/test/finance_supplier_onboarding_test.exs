defmodule Samen.FinanceSupplierOnboardingTest do
  @moduledoc """
  WS-ACCT Phase 15 (ADR-054 D18) — the supplier onboarding checklist is seeded
  as ordinary Work-scope tasks anchored to a supplier, not a parallel task
  engine. Re-seeding converges on the six phases and never reopens completed
  work.
  """

  use ExUnit.Case, async: false

  alias Samen.Scopes.Finance.SupplierOnboarding
  alias SamenCore.Support.SalesOpsFixture.Vendor
  alias SamenCore.Support.WorkFixture.Task

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)

    org = Ash.UUID.generate()
    scope = tenant_scope(org)
    vendor = vendor!(scope, org, "Fabrikam Foundry")

    %{org: org, scope: scope, vendor: vendor}
  end

  test "seeds one anchored Work task per onboarding phase", %{org: org, vendor: vendor} do
    seeded = SupplierOnboarding.seed!(vendor, task: Task)

    assert map_size(seeded) == 6

    assert Enum.map(SupplierOnboarding.keys(), fn key -> seeded[key].title end) == [
             "Phase 1 · Pre-Onboarding & NDA",
             "Phase 2 · Legal & Compliance",
             "Phase 3 · Technical & PDK",
             "Phase 4 · Commercial & Operational",
             "Phase 5 · Operational Integration",
             "Phase 6 · First Shuttle & Review"
           ]

    assert Enum.all?(seeded, fn {_key, task} ->
             task.kind == :task and
               task.status == :pending and
               task.priority == :normal and
               task.subject_key == SupplierOnboarding.subject_key() and
               task.subject_id == vendor.id
           end)

    assert Enum.map(
             SupplierOnboarding.tasks(vendor, task: Task),
             &SupplierOnboarding.phase_key/1
           ) == SupplierOnboarding.keys()

    assert %{tnt_field_name: "onboarding_phase"} =
             Samen.CustomFields.get_field(
               org,
               Samen.Catalog.table_name(Task),
               "onboarding_phase",
               @repo
             )
  end

  test "re-seeding is idempotent and preserves a completed task", %{vendor: vendor} do
    seeded = SupplierOnboarding.seed!(vendor, task: Task)
    phase = seeded["legal_compliance"]

    completed =
      phase
      |> Ash.Changeset.for_update(:update, %{status: :completed}, authorize?: false)
      |> Ash.update!()

    again = SupplierOnboarding.seed!(vendor, task: Task)

    assert map_size(again) == 6
    assert again["legal_compliance"].id == completed.id
    assert again["legal_compliance"].status == :completed
    assert length(SupplierOnboarding.tasks(vendor, task: Task)) == 6
  end

  test "tasks are scoped to their supplier and org", %{org: org, scope: scope, vendor: vendor} do
    other_vendor = vendor!(scope, org, "Contoso Foundry")
    SupplierOnboarding.seed!(vendor, task: Task)
    SupplierOnboarding.seed!(other_vendor, task: Task)

    assert length(SupplierOnboarding.tasks(vendor, task: Task)) == 6
    assert length(SupplierOnboarding.tasks(other_vendor, task: Task)) == 6

    assert Enum.all?(
             SupplierOnboarding.tasks(vendor, task: Task),
             &(&1.subject_id == vendor.id)
           )
  end

  defp tenant_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :member, kind: :tenant, plane: :tenant}
    }
  end

  defp vendor!(scope, org, name) do
    Vendor
    |> Ash.Changeset.for_create(:create, %{org_id: org, name: name}, scope: scope)
    |> Ash.create!()
  end
end
