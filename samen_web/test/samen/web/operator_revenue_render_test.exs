defmodule Samen.Web.OperatorRevenueRenderTest do
  @moduledoc """
  Framework OPERATOR / Revenue render tests (WS-B / B3; design §1.4 + §1.6).

  The own-book half (waterfall / NRR + churn tiles / cohort grid) reads REAL rows:
  `mov` ledger rows via the OrgScope'd bounded Ash read and `mrr_revenue_rollup` RAW
  rows via the bounded SQL read — both wrapped through the `Samen.Revenue.Metrics`
  kernel fold by `Samen.Web.Operator.RevenueReads` (the surface never recomputes;
  the numbers asserted here are the kernel's, rendered).

  The cross-tenant half (MRR by plan) proves the RENDER contract of the token-blind
  path (AC-G7-9): a `%Samen.Aggregate.Suppressed{}` cohort — what the k-anon floor
  at the `Samen.Aggregate.read_all/2` chokepoint hands the loader for a below-floor
  plan — renders `⊘` and its underlying value NEVER reaches the HTML; a released
  cohort renders its value (positive control). The floor MECHANISM red-path (seed
  below-floor → suppressed; sabotage the floor → released) runs against the real
  aggregate plane in the demo suite (`Demo.OperatorRevenuePlanFloorTest`).
  """
  use Samen.WebTest.DataCase, async: false

  alias Samen.Web.Operator.RevenueLive
  alias Samen.Web.Operator.RevenueReads
  alias Samen.WebTest.Operator, as: Op

  # -- fixtures -----------------------------------------------------------------

  # Seed the mov ledger lifecycle + the matching rollup rows for ONE operator org:
  #   2026-01: C1 :new +$100.00, C2 :new +$50.00   → closing $150.00
  #   2026-02: C1 :expansion +$50.00               → closing $200.00
  #   2026-03: C2 :churn −$50.00                   → closing $150.00
  defp seed_revenue! do
    org_id = Ash.UUID.generate()
    c1 = Ash.UUID.generate()
    c2 = Ash.UUID.generate()

    movements = [
      {c1, :new, 10_000, 0, 10_000, ~U[2026-01-10 12:00:00Z]},
      {c2, :new, 5_000, 0, 5_000, ~U[2026-01-20 12:00:00Z]},
      {c1, :expansion, 5_000, 10_000, 15_000, ~U[2026-02-08 12:00:00Z]},
      {c2, :churn, -5_000, 5_000, 0, ~U[2026-03-15 12:00:00Z]}
    ]

    for {customer_id, kind, delta, before_c, after_c, at} <- movements do
      Op.SubscriptionEvent
      |> Ash.Changeset.for_create(
        :append,
        %{
          org_id: org_id,
          subscription_id: Ash.UUID.generate(),
          customer_id: customer_id,
          kind: kind,
          mrr_delta_cents: delta,
          mrr_before_cents: before_c,
          mrr_after_cents: after_c,
          occurred_at: at
        },
        authorize?: false
      )
      |> Ash.create!()
    end

    rollup = [
      {~D[2026-01-01], "new", 15_000, 2},
      {~D[2026-02-01], "expansion", 5_000, 1},
      {~D[2026-03-01], "churn", -5_000, 1}
    ]

    for {month, kind, delta, count} <- rollup do
      Ecto.Adapters.SQL.query!(
        Samen.WebTest.Repo,
        """
        INSERT INTO mrr_revenue_rollup
          (mrr_org_id, mrr_period_month, mrr_kind, mrr_delta_cents, mrr_count)
        VALUES ($1, $2, $3, $4, $5)
        """,
        [Ecto.UUID.dump!(org_id), month, kind, delta, count]
      )
    end

    org_id
  end

  # A host revenue_plan_loader as the token-blind aggregate path would hand it over:
  # the floors ran at the read_all/2 chokepoint; the below-floor "bespoke" cohort
  # arrives ALREADY %Suppressed{} — the loader (and the framework) never see its value.
  def sample_plan_cohorts do
    [
      %{plan: "growth", tenant_count: 6, mrr_cents: 300_000},
      %{
        plan: "bespoke",
        tenant_count: 4,
        # observed is a DISTINCTIVE sentinel (still < k, so genuinely below-floor):
        # the render test refutes it ever reaching the HTML — a money_cell that
        # renders any part of a %Suppressed{} turns the test red (B3 gate P2 fix).
        mrr_cents: %Samen.Aggregate.Suppressed{reason: :k_anonymity, k: 99_991, observed: 41_927}
      }
    ]
  end

  defp revenue_mount(org_id, labels \\ %{}), do: build_operator_mount(org_id, labels: labels)

  # -- own book: waterfall / tiles / cohort grid ---------------------------------

  test "the waterfall renders per-period rows from the rollup, chained opening→closing (kernel fold, R1 shape)" do
    org_id = seed_revenue!()
    html = render_live(Samen.Web.Operator.RevenueLive, revenue_mount(org_id), [])

    assert html =~ ~s(class="app")
    assert html =~ "MRR movement waterfall"
    assert html =~ "waterfall-row"

    # 2026-01: opening $0 → new $150 → closing $150; 2026-02 opens at the prior
    # closing (the chain) → closing $200; 2026-03 churns $50 → closing $150.
    assert html =~ "2026-01"
    assert html =~ "2026-02"
    assert html =~ "2026-03"
    assert html =~ "$150.00"
    assert html =~ "$200.00"
  end

  test "the NRR / churn tiles render the kernel metrics for the latest period" do
    org_id = seed_revenue!()
    html = render_live(Samen.Web.Operator.RevenueLive, revenue_mount(org_id), [])

    # Latest period (2026-03): opening $200, churn $50 →
    # NRR (200−50)/200 = 75.0%; gross churn 50/200 = 25.0%;
    # logo churn: opening_logos 2 (two :new, zero prior churn), churn_logos 1 → 50.0%.
    assert html =~ "NRR"
    assert html =~ "75.0%"
    assert html =~ "Gross churn"
    assert html =~ "25.0%"
    assert html =~ "Logo churn"
    assert html =~ "50.0%"
    # The MRR tile is the latest closing.
    assert html =~ "MRR"
  end

  test "the cohort retention grid renders from the mov timeline (customer-keyed kernel fold)" do
    org_id = seed_revenue!()
    html = render_live(Samen.Web.Operator.RevenueLive, revenue_mount(org_id), [])

    # One cohort (2026-01, both customers), retained 100% M0/M1, 50% at M2 (C2 churned).
    assert html =~ "Cohort retention"
    assert html =~ "cohort-row"
    assert html =~ "100.0%"
    assert html =~ "50.0%"

    # GREEN half of the per-half silence contract: BOTH reads answered, so neither half
    # reports a silence (`unread` = the rollup's, `cohorts_unread` = the mov timeline's).
    assigns = loaded_assigns(revenue_mount(org_id))
    assert assigns.revenue.unread == nil
    assert assigns.revenue.cohorts_unread == nil
    refute html =~ ~s(data-read-state="unread")
  end

  test "the revenue surface is not a PII surface: no vault token, no mask sentinel, all bounded numbers" do
    org_id = seed_revenue!()
    html = render_live(Samen.Web.Operator.RevenueLive, revenue_mount(org_id), [])

    refute html =~ "vt_"
    refute html =~ "••••"
  end

  test "zero data renders the kit empty states, never a crash or a raw table" do
    html = render_live(Samen.Web.Operator.RevenueLive, revenue_mount(Ash.UUID.generate()), [])

    assert html =~ "revenue-empty"
    assert html =~ "cohorts-empty"
    assert html =~ "No revenue movements yet."
    # A READ that answered and found nothing is the only case that may say "none" — the
    # zero-data render carries no unread marker at all.
    refute html =~ ~s(data-read-state="unread")
  end

  # -- cross-tenant: the k-anon suppression render contract (AC-G7-9) -------------

  test "a below-floor plan cohort renders ⊘ and its value NEVER reaches the HTML; a released cohort renders (positive control)" do
    org_id = seed_revenue!()

    html =
      render_live(
        Samen.Web.Operator.RevenueLive,
        revenue_mount(org_id, %{revenue_plan_loader: {__MODULE__, :sample_plan_cohorts, []}}),
        []
      )

    # Token-blind chrome.
    assert html =~ "MRR by plan"
    assert html =~ ~s(class="tb-bar")
    assert html =~ "k-anon suppressed"

    # Positive control: the released cohort renders its value.
    assert html =~ "growth"
    assert html =~ "$3000.00"

    # The below-floor cohort renders ⊘ IN ITS OWN ROW (never a number) + the
    # suppression note. The VALUE-level proof (the exact below-floor MRR exists in
    # the DB, is withheld by the floor, and a sabotaged floor releases it) is the
    # demo red-path against the real aggregate plane: `Demo.OperatorRevenuePlanFloorTest`.
    assert html =~ "bespoke"
    assert html =~ ~r/bespoke.*⊘/s, "the bespoke row itself must render the ⊘ glyph"
    assert html =~ "below the k-anonymity floor"

    # NEGATIVE contract (B3 gate P2 fix — makes this test non-tautological): no
    # fragment of the %Suppressed{} struct may reach the HTML. The observed/k
    # sentinels are distinctive, so any cell that renders them (e.g. a sabotaged
    # money_cell interpolating `observed`) turns this red.
    refute html =~ "41927"
    refute html =~ "41,927"
    refute html =~ "99991"
    refute html =~ "99,991"
  end

  test "without a revenue_plan_loader the cross-tenant section renders the wiring empty state" do
    org_id = seed_revenue!()
    html = render_live(Samen.Web.Operator.RevenueLive, revenue_mount(org_id), [])

    assert html =~ "plan-mrr-empty"
    assert html =~ "No cross-tenant plan projection wired."
  end

  # ---------------------------------------------------------------------------
  # The per-half / per-read silences (fail-honest, ADR-014/024/026).
  #
  # The own-book surface reads TWO sources (the `mrr_revenue_rollup` RAW table for the
  # waterfall, the mount's `SubscriptionEvent` mov timeline for the cohort grid), and the
  # cross-tenant section reads a THIRD (the host's `revenue_plan_loader:` label). Each is
  # proven green / read-failed / sabotage-twin, so none of them can print "none" for a
  # read that never answered.

  test "RED — an unreadable mov timeline leaves the WATERFALL readable and the grid honest" do
    org_id = seed_revenue!()
    mount = revenue_mount(org_id)

    # The mov-timeline read cannot run (an unscopable read of that ONE resource) while the
    # rollup's own read — a different source entirely — still answers: exactly the per-half
    # case a single page-wide flag cannot express. Asserted against the REAL read, not a stub.
    revenue = RevenueReads.revenue(mount, nil)

    assert revenue.unread == nil, "the rollup answered — the waterfall is readable"
    assert revenue.cohorts_unread == :read_failed
    assert revenue.periods != []
    assert revenue.cohorts.cohorts == []

    html = render_html(RevenueLive, %{loaded_assigns(mount) | revenue: revenue})

    assert html =~ "Cohort retention could not be read."
    assert html =~ ~s(data-unread-reason="read_failed")
    assert html =~ ~s(class="card unread-state cohorts-unread")
    refute html =~ "No cohorts yet.",
           "an unreadable timeline claimed the tenant has no signup cohorts"

    # …and the waterfall beside it still renders its real rows — the two halves hold their
    # OWN silences (blanking this table would be the mirror-image lie).
    assert html =~ "waterfall-row"
    refute html =~ "Revenue movements could not be read."
  end

  test "SABOTAGE TWIN — the same grid renders BOTH states, so the probe discriminates" do
    # An org with no rows at all: the grid is genuinely empty, and the ONLY difference
    # between the two renders below is the marker.
    base = loaded_assigns(revenue_mount(Ash.UUID.generate()))
    assert base.revenue.cohorts.cohorts == []

    readable = render_html(RevenueLive, base)
    assert readable =~ "No cohorts yet."
    refute readable =~ ~s(data-read-state="unread")

    unread = render_html(RevenueLive, %{base | revenue: %{base.revenue | cohorts_unread: :read_failed}})
    assert unread =~ "Cohort retention could not be read."
    refute unread =~ "No cohorts yet."

    # Non-vacuous: the assertion that separates them FAILS on the readable render.
    assert_raise ExUnit.AssertionError, fn ->
      assert readable =~ "Cohort retention could not be read."
    end
  end

  test "RED — a WIRED plan loader that RAISES is never rendered as 'no projection wired'" do
    org_id = seed_revenue!()

    mount =
      revenue_mount(org_id, %{revenue_plan_loader: {__MODULE__, :raising_plan_cohorts, []}})

    assigns = loaded_assigns(mount)
    assert assigns.plan_cohorts_unread == :read_failed

    html = render_html(RevenueLive, assigns)

    assert html =~ "The cross-tenant plan projection could not be read."
    assert html =~ ~s(data-unread-reason="read_failed")
    assert html =~ ~s(class="card unread-state plan-mrr-unread")
    # The old collapse: a false statement about the HOST ("not wired") over a loader that is
    # wired and raised, and a false one about the platform ("none").
    refute html =~ "No cross-tenant plan projection wired."
    refute html =~ "No plan cohorts to show."
  end

  test "GREEN/twin — a loader that ANSWERED and a host with NO loader are told apart, and neither is read-failed" do
    org_id = seed_revenue!()

    answered =
      loaded_assigns(revenue_mount(org_id, %{revenue_plan_loader: {__MODULE__, :empty_plan_cohorts, []}}))

    assert answered.plan_cohorts_unread == nil
    answered_html = render_html(RevenueLive, answered)
    assert answered_html =~ "No plan cohorts to show."
    refute answered_html =~ "No cross-tenant plan projection wired."
    refute answered_html =~ ~s(data-read-state="unread")

    unwired = loaded_assigns(revenue_mount(org_id))
    assert unwired.plan_cohorts_unread == :not_configured
    wiring_html = render_html(RevenueLive, unwired)
    assert wiring_html =~ "No cross-tenant plan projection wired."
    refute wiring_html =~ "could not be read"
    refute wiring_html =~ "No plan cohorts to show."

    # SABOTAGE TWIN — the predicate that separates the twos is refutable on BOTH sides.
    assert_raise ExUnit.AssertionError, fn -> assert wiring_html =~ "No plan cohorts to show." end
  end

  # -- harness ------------------------------------------------------------------

  # The loader a host wires when its floored aggregate read answers with nothing (every plan
  # below the floor or empty) — an ANSWERED read, so the section may say "none".
  def empty_plan_cohorts, do: []

  # …and a wired loader that RAISES: the loader exists, so "no projection wired" is false.
  def raising_plan_cohorts, do: raise("plan loader exploded")

  # The socket's assigns after the REAL `load/1` (the same path `render_live/3` drives), for
  # assertions on the read-layer markers themselves rather than on rendered copy.
  defp loaded_assigns(mount) do
    %Phoenix.LiveView.Socket{}
    |> Phoenix.Component.assign(:samen_mount, mount)
    |> Phoenix.Component.assign(:samen_acting_as, false)
    |> RevenueLive.load()
    |> Map.fetch!(:assigns)
  end
end
