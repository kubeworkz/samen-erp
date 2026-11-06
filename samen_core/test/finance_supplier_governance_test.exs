defmodule Samen.FinanceSupplierGovernanceTest do
  @moduledoc """
  WS-ACCT Phase 15 (ADR-054 D18) — supplier governance.

  The scorecard composite and grade, and the risk rating and band, are derived
  by `SupplierGovernance`; the resources store only their inputs. Each refusal
  is paired with a positive control, and the no-PII check asserts the
  scorecard/risk contract names `vendor_id` rather than copying a supplier
  contact.
  """

  use ExUnit.Case, async: false

  require Ash.Query

  alias Samen.Scopes.Finance.SupplierGovernance

  alias SamenCore.Support.FinanceFixture.{
    SupplierRisk,
    SupplierScorecard,
    SupplierScorecardDimension
  }

  @repo SamenCore.TestRepo

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(@repo)

    org = Ash.UUID.generate()
    other = Ash.UUID.generate()
    vendor_id = Ash.UUID.generate()
    other_vendor_id = Ash.UUID.generate()

    %{
      org: org,
      other: other,
      vendor_id: vendor_id,
      other_vendor_id: other_vendor_id,
      admin: admin_scope(org),
      other_admin: admin_scope(other)
    }
  end

  test "the composite is the weighted sum and the letter grade is derived", %{
    org: org,
    vendor_id: vendor_id,
    admin: admin
  } do
    scorecard = scorecard!(admin, org, vendor_id, weighted_dimensions())

    read = SupplierGovernance.scorecard(scorecard, dimension: SupplierScorecardDimension)

    assert read.period_key == "2026-Q4"
    assert read.weight_total == 100
    assert read.valid?
    assert read.reason == nil

    assert Enum.map(read.dimensions, & &1.dimension) == [
             :quality_yield,
             :delivery_schedule,
             :cost_commercial,
             :technical_support,
             :compliance_sustainability
           ]

    assert read.composite == 3.99
    assert read.grade == "B"

    assert SupplierGovernance.grade(4.5) == "A"
    assert SupplierGovernance.grade(3.5) == "B"
    assert SupplierGovernance.grade(2.5) == "C"
    assert SupplierGovernance.grade(1.5) == "D"
    assert SupplierGovernance.grade(1.49) == "F"

    list =
      SupplierGovernance.scorecards(org,
        scorecard: SupplierScorecard,
        dimension: SupplierScorecardDimension
      )

    assert [entry] = list.scorecards
    assert entry.composite == 3.99
    assert list.summary.by_grade == %{"B" => 1}
  end

  test "weights that do not sum to 100 are refused and leave no half-written scorecard", %{
    org: org,
    vendor_id: vendor_id,
    admin: admin
  } do
    bad_dimensions =
      Enum.map(weighted_dimensions(), fn dimension ->
        if dimension.dimension == :compliance_sustainability,
          do: %{dimension | weight_pct: 7},
          else: dimension
      end)

    attrs = scorecard_attrs(org, vendor_id, bad_dimensions)
    before = scorecards(org)

    assert {:error, error} =
             SupplierScorecard
             |> Ash.Changeset.for_create(:create, attrs, scope: admin)
             |> Ash.create()

    assert Exception.message(error) =~ "sum to exactly 100"
    assert scorecards(org) == before

    # CONTROL: the same shape with weights summing to 100 lands.
    scorecard = scorecard!(admin, org, vendor_id, weighted_dimensions())
    assert SupplierGovernance.scorecard(scorecard, dimension: SupplierScorecardDimension).valid?
  end

  test "risk rating is likelihood × impact and the band drives escalation", %{
    org: org,
    vendor_id: vendor_id,
    admin: admin
  } do
    risk = risk!(admin, org, vendor_id, %{likelihood: 4, impact: 4})

    read = SupplierGovernance.risk(risk)
    assert read.rating == 16
    assert read.band == :critical
    assert read.escalation == :board

    updated =
      risk
      |> Ash.Changeset.for_update(:update, %{likelihood: 2, impact: 2}, scope: admin)
      |> Ash.update!()

    assert SupplierGovernance.risk(updated).band == :low
    assert SupplierGovernance.risk(updated).escalation == :owner

    assert SupplierGovernance.band(1) == :low
    assert SupplierGovernance.band(5) == :medium
    assert SupplierGovernance.band(10) == :high
    assert SupplierGovernance.band(16) == :critical

    # Red path: a 6 is outside the 5×5 scale and is refused.
    invalid = risk_attrs(org, vendor_id, %{code: "R-002", likelihood: 6})

    assert {:error, error} =
             SupplierRisk
             |> Ash.Changeset.for_create(:create, invalid, scope: admin)
             |> Ash.create()

    assert Exception.message(error) =~ "likelihood"
  end

  test "the risk register is org-scoped and ordered by rating", %{
    org: org,
    other: other,
    vendor_id: vendor_id,
    other_vendor_id: other_vendor_id,
    admin: admin,
    other_admin: other_admin
  } do
    _critical = risk!(admin, org, vendor_id, %{code: "R-001", likelihood: 4, impact: 4})
    _low = risk!(admin, org, vendor_id, %{code: "R-002", likelihood: 1, impact: 2})
    _foreign = risk!(other_admin, other, other_vendor_id, %{code: "R-003"})

    register = SupplierGovernance.risk_register(org, risk: SupplierRisk)

    assert Enum.map(register.risks, & &1.code) == ["R-001", "R-002"]
    assert register.summary.by_band == %{critical: 1, low: 1}
  end

  test "supplier governance carries vendor ids, not supplier PII columns" do
    forbidden = [:contact_name, :contact_email, :email, :phone, :owner_name, :supplier_name]

    for module <- [SupplierScorecard, SupplierScorecardDimension, SupplierRisk] do
      names = Ash.Resource.Info.attributes(module) |> Enum.map(& &1.name)
      assert Enum.all?(names, &(&1 not in forbidden)), "#{inspect(module)} carries a PII column"
    end

    scorecard_names = Ash.Resource.Info.attributes(SupplierScorecard) |> Enum.map(& &1.name)
    risk_names = Ash.Resource.Info.attributes(SupplierRisk) |> Enum.map(& &1.name)

    assert :vendor_id in scorecard_names
    assert :vendor_id in risk_names
    refute :contact_name in scorecard_names
    refute :contact_name in risk_names
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp admin_scope(org_id) do
    %Samen.Scope{
      actor: %{id: "u:#{org_id}", org_id: org_id, role: :admin, kind: :tenant, plane: :tenant}
    }
  end

  defp scorecards(org) do
    SupplierScorecard
    |> Ash.Query.filter(org_id == ^org)
    |> Ash.read!(authorize?: false)
  end

  defp scorecard!(admin, org, vendor_id, dimensions, period_quarter \\ 4) do
    %{
      org_id: org,
      vendor_id: vendor_id,
      period_year: 2026,
      period_quarter: period_quarter,
      dimensions: dimensions
    }
    |> then(&Ash.Changeset.for_create(SupplierScorecard, :create, &1, scope: admin))
    |> Ash.create!()
  end

  defp scorecard_attrs(org, vendor_id, dimensions) do
    %{
      org_id: org,
      vendor_id: vendor_id,
      period_year: 2026,
      period_quarter: 4,
      dimensions: dimensions
    }
  end

  defp weighted_dimensions do
    [
      %{dimension: :quality_yield, weight_pct: 35, score: 5, note: "Yield above target"},
      %{dimension: :delivery_schedule, weight_pct: 25, score: 4},
      %{dimension: :cost_commercial, weight_pct: 20, score: 3},
      %{dimension: :technical_support, weight_pct: 12, score: 2},
      %{dimension: :compliance_sustainability, weight_pct: 8, score: 5}
    ]
  end

  defp risk!(admin, org, vendor_id, overrides) do
    attrs = risk_attrs(org, vendor_id, overrides)

    SupplierRisk
    |> Ash.Changeset.for_create(:create, attrs, scope: admin)
    |> Ash.create!()
  end

  defp risk_attrs(org, vendor_id, overrides) do
    Map.merge(
      %{
        org_id: org,
        vendor_id: vendor_id,
        code: "R-001",
        title: "Single-source die supply",
        category: :delivery,
        likelihood: 4,
        impact: 4,
        mitigation: "Qualify a second assembly partner",
        owner_role: :procurement_lead,
        escalation_trigger: "Open allocations exceed four weeks",
        status: :open,
        reviewed_on: ~D[2026-11-06]
      },
      overrides
    )
  end
end
