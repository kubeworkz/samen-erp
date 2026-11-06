defmodule Samen.Scopes.Finance.SupplierGovernance do
  @moduledoc """
  Derived reads over the supplier governance resources (WS-ACCT Phase 15;
  ADR-054 D18).

  A `SupplierScorecard` stores only its period and weighted dimension rows.
  This module derives the composite score and letter grade:

      composite = Σ(score × weight_pct) / 100

      A ≥ 4.5, B ≥ 3.5, C ≥ 2.5, D ≥ 1.5, otherwise F

  A `SupplierRisk` stores likelihood and impact; this module derives the
  rating and band:

      rating = likelihood × impact
      1–4 low, 5–9 medium, 10–15 high, 16–25 critical

  The escalation route is a read, not a stored decision. Neither read exposes
  supplier contact data: the resources name `vendor_id`, and the contact stays
  in `SalesOps.Vendor`.
  """

  require Ash.Query

  @dimensions [
    :quality_yield,
    :delivery_schedule,
    :cost_commercial,
    :technical_support,
    :compliance_sustainability
  ]

  @type scorecard_read :: %{
          scorecard_id: term(),
          vendor_id: term(),
          period_year: integer(),
          period_quarter: integer(),
          period_key: String.t(),
          dimensions: [map()],
          weight_total: integer(),
          composite: float() | nil,
          grade: String.t() | nil,
          valid?: boolean(),
          reason: String.t() | nil
        }

  @doc """
  Derive one scorecard's dimensions, composite and grade.

  Required opts: `:dimension` (the host's SupplierScorecardDimension module).
  """
  @spec scorecard(struct(), keyword()) :: scorecard_read()
  def scorecard(scorecard, opts) do
    dimension_mod = Keyword.fetch!(opts, :dimension)
    rows = dimensions(scorecard, dimension_mod)
    weight_total = Enum.sum(Enum.map(rows, & &1.weight_pct))
    reason = invalid_reason(rows, weight_total)
    valid? = is_nil(reason)

    composite =
      if valid? do
        rows
        |> Enum.map(&(&1.score * &1.weight_pct / 100))
        |> Enum.sum()
        |> Float.round(2)
      end

    %{
      scorecard_id: scorecard.id,
      vendor_id: scorecard.vendor_id,
      period_year: scorecard.period_year,
      period_quarter: scorecard.period_quarter,
      period_key: "#{scorecard.period_year}-Q#{scorecard.period_quarter}",
      dimensions: Enum.map(rows, &dimension_read/1),
      weight_total: weight_total,
      composite: composite,
      grade: grade(composite),
      valid?: valid?,
      reason: reason
    }
  end

  @doc """
  Read all scorecards for an org with their derived composites and grades.

  Required opts: `:scorecard` and `:dimension`.
  """
  @spec scorecards(String.t(), keyword()) :: map()
  def scorecards(org_id, opts) do
    scorecard_mod = Keyword.fetch!(opts, :scorecard)
    dimension_mod = Keyword.fetch!(opts, :dimension)

    entries =
      scorecard_mod
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.Query.sort(period_year: :desc, period_quarter: :desc)
      |> Ash.read!(authorize?: false)
      |> Enum.map(&scorecard(&1, dimension: dimension_mod))

    %{
      org_id: org_id,
      scorecards: entries,
      summary: %{
        count: length(entries),
        by_grade: Enum.frequencies_by(entries, & &1.grade)
      }
    }
  end

  @doc """
  Derive one risk row's rating, band and escalation route.
  """
  @spec risk(struct()) :: map()
  def risk(risk) do
    rating = risk.likelihood * risk.impact

    %{
      risk_id: risk.id,
      vendor_id: risk.vendor_id,
      code: risk.code,
      title: risk.title,
      category: risk.category,
      likelihood: risk.likelihood,
      impact: risk.impact,
      rating: rating,
      band: band(rating),
      escalation: escalation(band(rating)),
      mitigation: risk.mitigation,
      owner_role: risk.owner_role,
      escalation_trigger: risk.escalation_trigger,
      status: risk.status,
      reviewed_on: risk.reviewed_on
    }
  end

  @doc """
  Read an org's risk register, highest rating first.

  Required opts: `:risk` (the host's SupplierRisk module).
  """
  @spec risk_register(String.t(), keyword()) :: map()
  def risk_register(org_id, opts) do
    risk_mod = Keyword.fetch!(opts, :risk)

    entries =
      risk_mod
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.read!(authorize?: false)
      |> Enum.map(&risk/1)
      |> Enum.sort_by(&{-&1.rating, &1.code})

    %{
      org_id: org_id,
      risks: entries,
      summary: %{
        count: length(entries),
        by_band: Enum.frequencies_by(entries, & &1.band)
      }
    }
  end

  @doc "Letter grade for a composite, or nil when no valid composite exists."
  def grade(nil), do: nil
  def grade(composite) when composite >= 4.5, do: "A"
  def grade(composite) when composite >= 3.5, do: "B"
  def grade(composite) when composite >= 2.5, do: "C"
  def grade(composite) when composite >= 1.5, do: "D"
  def grade(_composite), do: "F"

  @doc "Risk band for a likelihood × impact rating."
  def band(rating) when rating in 1..4, do: :low
  def band(rating) when rating in 5..9, do: :medium
  def band(rating) when rating in 10..15, do: :high
  def band(rating) when rating in 16..25, do: :critical
  def band(_rating), do: nil

  @doc "Suggested escalation route for a risk band."
  def escalation(:low), do: :owner
  def escalation(:medium), do: :finance_lead
  def escalation(:high), do: :cfo
  def escalation(:critical), do: :board
  def escalation(_band), do: nil

  defp dimensions(scorecard, dimension_mod) do
    dimension_mod
    |> Ash.Query.filter(scorecard_id == ^scorecard.id)
    |> Ash.read!(authorize?: false)
    |> Enum.sort_by(&dimension_index/1)
  end

  defp dimension_index(row), do: Enum.find_index(@dimensions, &(&1 == row.dimension)) || 99

  defp dimension_read(row) do
    %{
      dimension: row.dimension,
      weight_pct: row.weight_pct,
      score: row.score,
      weighted_points: Float.round(row.score * row.weight_pct / 100, 2),
      note: row.note
    }
  end

  defp invalid_reason(rows, weight_total) do
    cond do
      length(rows) != 5 ->
        "expected five dimensions, found #{length(rows)}"

      weight_total != 100 ->
        "dimension weights total #{weight_total}, expected 100"

      Enum.any?(rows, &(&1.score < 1 or &1.score > 5)) ->
        "every dimension score must be between 1 and 5"

      true ->
        nil
    end
  end
end
