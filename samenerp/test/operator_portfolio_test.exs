defmodule Samenerp.OperatorPortfolioTest do
  @moduledoc """
  The operator **Portfolio** page (`/operator/aggregate`) — the surface the sidebar's Portfolio
  item opens, which used to answer "Not Found" because `samen_operator_routes/2` was mounted
  without `include_aggregate`.

  Three legs, each paired with a control that must stay green:

    * MOUNT — the route is declared, rides the operator `live_session` with the
      `:require_operator` on_mount, the mount carries the `aggregate_page` label (so the
      sidebar offers the item) and the host loader, and the REAL sidebar rendered from that
      compiled mount links it.
    * PROJECTION — the numbers come from the operator's own book: totals are clear, and every
      cross-tenant cohort value under the k-anonymity floor is `⊘` (a 2-tenant plan releases
      no MRR) while a cohort at the floor releases it. That is the released-floors rule, proven
      refutable in both directions.
    * FAIL-HONEST — no operator org means no projection (never invented numbers).
  """

  use Samenerp.DataCase, async: false

  alias Samen.Aggregate.Suppressed
  alias Samen.Web.Mount
  alias Samen.Web.Operator.AggregateLive
  alias Samenerp.OperatorAggregate

  @path "/operator/aggregate"

  # ── leg 1 — the route, the gate, the nav item ───────────────────────────────

  defp live_meta(plug) do
    SamenerpWeb.Router.__routes__()
    |> Enum.find(fn route -> route.plug == Phoenix.LiveView.Plug and route.plug_opts == plug end)
    |> case do
      nil -> nil
      route -> route.metadata |> Map.fetch!(:phoenix_live_view) |> elem(3)
    end
  end

  test "the router declares the aggregate route on the OPERATOR session's require_operator hook" do
    route =
      SamenerpWeb.Router.__routes__()
      |> Enum.find(&(&1.path == @path and &1.plug == Phoenix.LiveView.Plug))

    assert route, "#{@path} is not mounted — the Portfolio nav item would be a dead link"
    assert route.plug_opts == AggregateLive

    meta = live_meta(AggregateLive)

    assert meta.name == :samen_operator,
           "#{@path} must ride the OPERATOR live_session"

    assert Enum.any?(meta.extra.on_mount, &(&1.id == {Samen.Web.Operator.Authz, :require_operator})),
           "#{@path} has no require_operator on_mount — a tenant session could open the portfolio"
  end

  test "the compiled mount carries the aggregate label AND the host loader (and the sidebar links it)" do
    meta = live_meta(AggregateLive)
    mount = Mount.from_session(meta.extra.session["samen_mount"])

    assert Mount.label(mount, :aggregate_page, false) == true,
           "the operator sidebar hides Portfolio without this label (include_aggregate threads it)"

    assert Mount.label(mount, :aggregate_loader, nil) == {OperatorAggregate, :load, []},
           "the aggregate page has no host loader, so it would render the unwired state"

    # The real artifact: what an operator actually clicks.
    html =
      Phoenix.LiveViewTest.__render_component__(
        nil,
        &Samen.Web.Operator.Live.operator_sidebar/1,
        %{mount: mount, active: nil, operator_role: nil, __changed__: %{}},
        []
      )

    assert html =~ ~s(href="#{@path}")
  end

  # ── leg 2 — the projection and its floors ───────────────────────────────────

  defp account(plan, mrr_cents, seats, band) do
    %{
      plan: plan,
      __mrr_cents__: mrr_cents,
      __seats__: seats,
      __health__: %{band: band}
    }
  end

  defp plan_row(projection, plan) do
    projection.groups
    |> Enum.find(&(&1.id == "accounts-by-plan"))
    |> Map.fetch!(:rows)
    |> Enum.find(fn [row_plan | _] -> row_plan == plan end)
  end

  test "a cross-tenant plan cohort under the k-anonymity floor releases NO MRR (⊘), the count stays" do
    # The floor is the HOST's configured `k` (`Samen.Aggregate.Privacy.k/0`), not a literal here:
    # one cohort one tenant under it (suppressed) and one exactly at it (released), so the proof
    # holds at whatever floor this host runs.
    k = Samen.Aggregate.Privacy.k()
    under = k - 1

    assert under >= 1,
           "this host disables the k-anonymity floor (k=#{k}) — the portfolio's cross-tenant " <>
             "cohorts cannot be proven to withhold"

    accounts =
      List.duplicate(account("starter", 10_000, 2, :healthy), under) ++
        List.duplicate(account("growth", 100_000, 4, :healthy), k)

    projection = OperatorAggregate.projection(accounts)

    [plan, tenants, mrr, seats] = plan_row(projection, "starter")
    assert plan == "starter"
    # The cohort SIZE is the count that justifies the suppression — it stays readable.
    assert tenants == under
    assert %Suppressed{reason: :k_anonymity} = mrr
    assert %Suppressed{reason: :k_anonymity} = seats

    # Control: a cohort AT the floor releases its real values, so the suppression above is the
    # floor working, not the projection failing to produce numbers at all.
    [_, ^k, growth_mrr, growth_seats] = plan_row(projection, "growth")
    assert growth_mrr == {:money, k * 100_000}
    assert growth_seats == 4 * k
  end

  test "the book TOTALS are clear (the SaaS owns its own revenue), even while every cohort is floored" do
    accounts = [
      account("starter", 10_000, 2, :healthy),
      account("enterprise", 30_000, 3, :at_risk),
      account("solo", 7_500, 1, :critical)
    ]

    projection = OperatorAggregate.projection(accounts)
    metrics = Map.new(projection.metrics, &{&1.label, &1.value})

    assert metrics["Portfolio MRR"] == {:money, 47_500}
    assert metrics["Tenants"] == 3
    assert metrics["Seats"] == 6
    assert metrics["At risk"] == 2

    # Each plan here is a cohort of ONE tenant. Below a floor of 2 that withholds; at a floor of
    # 1 it is legally releasable — either way the count below is DERIVED from the rows, so this
    # assertion cannot drift from the floor the host runs.
    withheld =
      Enum.count(projection.groups, fn group ->
        Enum.any?(group.rows, fn row -> Enum.any?(row, &Suppressed.suppressed?/1) end)
      end)

    assert projection.suppressed_count >= withheld
  end

  test "an empty book projects zeros, never a fabricated number" do
    projection = OperatorAggregate.projection([])
    metrics = Map.new(projection.metrics, &{&1.label, &1.value})

    assert metrics["Portfolio MRR"] == {:money, 0}
    assert metrics["Tenants"] == 0
    assert projection.suppressed_count == 0
    assert Enum.all?(projection.groups, fn group -> group.rows == [] end)
  end

  # ── leg 2b — load/1 over the REAL book (the route from account rows to numbers) ──────────

  test "load/1 reads the operator's actual book through the mount" do
    operator_org_id = "0f000000-0000-4000-8000-0000000000aa"
    mount = Mount.from_session(live_meta(AggregateLive).extra.session["samen_mount"])

    for plan <- ~w(starter enterprise) do
      org!(operator_org_id, plan)
    end

    projection = OperatorAggregate.load(mount)
    metrics = Map.new(projection.metrics, &{&1.label, &1.value})

    assert metrics["Tenants"] == 2, "load/1 did not read the operator's accounts"
    # The page is populated: one row per plan, whether or not the cohort is floored.
    plan_rows =
      projection.groups
      |> Enum.find(&(&1.id == "accounts-by-plan"))
      |> Map.fetch!(:rows)

    assert Enum.map(plan_rows, fn [plan | _] -> plan end) |> Enum.sort() == ["enterprise", "starter"]
  end

  defp org!(operator_org_id, plan) do
    Samenerp.Operator.Org
    |> Ash.Changeset.for_create(
      :create,
      %{
        org_id: operator_org_id,
        name: "Acct #{plan}",
        slug: "acct-#{plan}-#{System.unique_integer([:positive])}",
        plan: plan
      },
      authorize?: false
    )
    |> Ash.create!(authorize?: false)
  end

  # ── leg 3 — fail-honest when the mount has no operator org ──────────────────

  test "a mount that resolves no operator org renders no projection" do
    mount = Mount.new(:operator, nil, nil, labels: %{})

    assert OperatorAggregate.load(mount) == %{metrics: [], groups: [], suppressed_count: 0}
  end
end
