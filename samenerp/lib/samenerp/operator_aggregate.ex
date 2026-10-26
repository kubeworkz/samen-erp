defmodule Samenerp.OperatorAggregate do
  @moduledoc """
  The host adapter that feeds Samenerp's operator **Portfolio** page
  (`Samen.Web.Operator.AggregateLive`, mounted at `/operator/aggregate` by
  `samen_operator_routes(Samenerp.Operator, ..., include_aggregate: true)`).

  ## Why this adapter exists at all

  The framework owns the token-blind CHROME (the banner, the metric cards, the `⊘`
  suppression rendering) but cannot derive a host's projection SHAPE by name. SamenERP's
  portfolio is its OWN book of business — tenants, their plans, seats and MRR — which
  lives in the Billing scope, not in a `Samen.Aggregate` summary table. So this module is
  the MFA the operator mount wires as `aggregate_loader: {Samenerp.OperatorAggregate,
  :load, []}`; the framework calls it and renders the generic
  `%{metrics: [...], groups: [...]}` it returns.

  It takes the MOUNT as a leading argument (the framework's optional arity), because the
  book can only be read through THIS mount's plane + operator org.

  ## The two data classes, and which one is floored (ADR-010 / WS-B)

    * **The operator's own book totals** (metric cards: portfolio MRR, tenants, seats,
      at-risk accounts) are the SaaS's own revenue and its own customer count. Per WS-B
      §"revenue", per-tenant revenue on the operator's OWN book is CLEAR — the SaaS owns
      that population — so these are read on the operator org's TENANT plane through
      `Samen.Web.Operator.Reads.accounts/3`, exactly as the Accounts page does. No new
      read path, no SQL, no impersonation.

    * **Cross-tenant COHORT cuts** (MRR-by-plan, MRR-by-health-band) are a different
      thing: a plan tier holding two tenants is a re-identifiable slice, so every
      releasable value in a cohort under the k-anonymity floor is replaced with a
      `%Samen.Aggregate.Suppressed{}` by `Samen.Aggregate.Privacy.apply/3` — the ONE
      floor chokepoint — and the chrome renders `⊘`. The cohort SIZE itself stays visible
      (it is the count that justifies the suppression, and it is what an operator needs to
      read the row). This is the released-floors discipline, applied in memory instead of
      over an Ash projection, because the source rows are the operator's own clear book.

  Fail-honest: an unreadable book yields an EMPTY projection (`[]` metrics, no rows), never
  invented numbers — `Reads.accounts/3` already rescues to `[]`.
  """

  alias Samen.Aggregate.{CohortSpec, Privacy, Suppressed}
  alias Samen.Web.Mount
  alias Samen.Web.Operator
  alias Samen.Web.Operator.Reads

  # MRR-by-plan: the cohort is the PLAN TIER (tenants on that tier), so a tier under the
  # k-anonymity floor releases neither its MRR nor its seat count — those two columns
  # together ARE the per-tenant slice. The tenant count stays (cohort size).
  @plan_spec %CohortSpec{
    cohort_key_columns: [:plan],
    cohort_count_column: :tenants,
    distinct_sensitive_column: nil,
    value_columns: [:mrr_cents, :seats],
    sensitive_attribute: nil
  }

  # MRR-by-health-band: same rule, cohort = accounts in the band.
  @band_spec %CohortSpec{
    cohort_key_columns: [:band],
    cohort_count_column: :accounts,
    distinct_sensitive_column: nil,
    value_columns: [:mrr_cents],
    sensitive_attribute: nil
  }

  @doc """
  The Portfolio projection for one operator mount. Returns
  `%{metrics: [...], groups: [...], suppressed_count: n}` — the generic shape
  `Samen.Web.Operator.AggregateLive` renders.
  """
  @spec load(Mount.t() | term()) :: %{
          metrics: list(),
          groups: list(),
          suppressed_count: non_neg_integer()
        }
  def load(%Mount{} = mount) do
    case Operator.org_id(mount) do
      nil ->
        empty()

      operator_org_id ->
        mount
        |> Reads.accounts(Operator.scope(mount), operator_org_id)
        |> projection()
    end
  end

  def load(_mount), do: empty()

  @doc """
  The projection over a list of operator account rows
  (`Samen.Web.Operator.Reads.accounts/3`'s shape). The pure seam: `load/1` is this function
  applied to the mount's book, so the metrics, the cohort assembly and the FLOORS can be
  proven without a database or a socket.
  """
  @spec projection([map()]) :: %{
          metrics: list(),
          groups: list(),
          suppressed_count: non_neg_integer()
        }
  def projection(accounts) when is_list(accounts) do
    plan_rows = accounts |> Enum.group_by(&plan_of/1) |> plan_rows()
    band_rows = accounts |> Enum.group_by(&band_of/1) |> band_rows()

    %{
      metrics: metrics(accounts),
      groups: [plan_group(plan_rows), band_group(band_rows)],
      suppressed_count: suppressed_count(plan_rows) + suppressed_count(band_rows)
    }
  end

  defp empty, do: %{metrics: [], groups: [], suppressed_count: 0}

  # -- metric cards (the operator's own book — CLEAR) ---------------------------

  defp metrics(accounts) do
    at_risk = Enum.count(accounts, &(&1.__health__.band in [:at_risk, :critical]))

    [
      %{
        label: "Portfolio MRR",
        value: {:money, Enum.reduce(accounts, 0, &(&1.__mrr_cents__ + &2))},
        sub: "across subscribing tenants"
      },
      %{label: "Tenants", value: length(accounts), sub: "accounts on the book"},
      %{label: "Seats", value: Enum.reduce(accounts, 0, &(&1.__seats__ + &2)), sub: "tenant admins"},
      %{label: "At risk", value: at_risk, sub: "at-risk + critical accounts"}
    ]
  end

  # -- cohort assembly (floored by Privacy.apply/3) -----------------------------

  defp plan_rows(by_plan) do
    by_plan
    |> Enum.map(fn {plan, rows} ->
      %{
        plan: plan,
        tenants: length(rows),
        mrr_cents: sum(rows, & &1.__mrr_cents__),
        seats: sum(rows, & &1.__seats__)
      }
    end)
    |> Enum.sort_by(& &1.plan)
    |> floored(@plan_spec)
  end

  defp band_rows(by_band) do
    by_band
    |> Enum.map(fn {band, rows} ->
      %{band: band, accounts: length(rows), mrr_cents: sum(rows, & &1.__mrr_cents__)}
    end)
    |> Enum.sort_by(& &1.band)
    |> floored(@band_spec)
  end

  # The floor chokepoint. The specs are literal `%CohortSpec{}`s, so `Privacy.apply/3` cannot
  # answer `{:error, :no_cohort_spec}` here — the match asserts that, so an unapplied floor can
  # never fall through as CLEAR data (an unfloored cohort is the leak this call exists to stop).
  defp floored(rows, %CohortSpec{} = spec) do
    {:ok, floored} = Privacy.apply(rows, spec)
    floored
  end

  # -- the generic groups the framework chrome renders --------------------------

  defp plan_group(rows) do
    %{
      id: "accounts-by-plan",
      title: "Accounts by plan",
      columns: ["Plan", "Tenants", "MRR", "Seats"],
      rows: Enum.map(rows, fn r -> [r.plan, r.tenants, money(r.mrr_cents), r.seats] end)
    }
  end

  defp band_group(rows) do
    %{
      id: "accounts-by-health-band",
      title: "Accounts by health band",
      columns: ["Health band", "Accounts", "MRR"],
      rows: Enum.map(rows, fn r -> [band_label(r.band), r.accounts, money(r.mrr_cents)] end)
    }
  end

  # -- helpers -----------------------------------------------------------------

  # A `%Suppressed{}` cell flows through untouched (the chrome renders `⊘`); a real integer
  # is tagged `{:money, cents}` so the chrome formats dollars.
  defp money(%Suppressed{} = s), do: s
  defp money(cents) when is_integer(cents), do: {:money, cents}
  defp money(_), do: {:money, 0}

  defp plan_of(%{plan: plan}) when is_binary(plan) and plan != "", do: plan
  defp plan_of(_), do: "No plan"

  defp band_of(%{__health__: %{band: band}}) when is_atom(band), do: band
  defp band_of(_), do: :unknown

  defp band_label(:healthy), do: "Healthy"
  defp band_label(:watch), do: "Watch"
  defp band_label(:at_risk), do: "At risk"
  defp band_label(:critical), do: "Critical"
  defp band_label(other), do: to_string(other)

  defp sum(rows, fun), do: Enum.reduce(rows, 0, fn row, acc -> acc + fun.(row) end)

  defp suppressed_count(rows) do
    Enum.count(rows, fn row ->
      Enum.any?(row, fn {_k, v} -> Suppressed.suppressed?(v) end)
    end)
  end
end
