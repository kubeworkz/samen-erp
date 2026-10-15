defmodule Samenerp.AnalyticsActivationTest do
  @moduledoc """
  WS-B / G12 (ADR-021) — Samenerp's Analytics mount, proved END TO END through the
  user-visible surface: product events captured through the REAL
  `Samen.Analytics.track/1` boundary → the domain-sourced `:product_event_rollup` spec
  materializing `paf_product_event_rollup` from this host's `sae` ledger → the P17
  `/analytics` page rendering floored counts for the caller's org.

  ## Why this test exists (the reader-without-a-producer defect)

  Samenerp mounted the analytics READERS in Phase 3 — the tenant `/analytics` surface,
  the operator analytics plane, and the rollup tables they read (migration
  `20261006140000`) — but shipped no product-event LEDGER. Two links were therefore
  missing, and each is pinned separately below so re-breaking one fails with a named
  reason instead of silently restoring the empty state:

    1. **the emitter was INERT** — `Samen.Analytics.track/1` returns `{:ok, :dropped}`
       without `config :samen_core, Samen.Analytics, product_event_resource: …`, so the
       framework emitters that DO fire on this host (sign-in, first-run, record create,
       ⌘K search, flag assignment) persisted nothing;
    2. **the rollup had no source** — no `:product_event_rollup` spec in
       `config :samen_core, :rollups`, so `paf_product_event_rollup` was never rebuilt
       from anything.

  The old three-dot behaviour (`/analytics` rendering its honest empty state) was
  therefore not "no data yet" but "no data possible" — honest and useless. The last
  describe block asserts the OUTCOME on the page, and the second one includes the
  anti-tautology red path: with the config removed the same capture is DROPPED, which is
  the exact failure this mount fixes.
  """
  use Samenerp.DataCase, async: false

  import Phoenix.ConnTest

  alias Samenerp.Analytics.ProductEvent
  alias Samenerp.Operator, as: Op
  alias Samen.{Analytics, Kms, Rollup}

  require Ash.Query

  @endpoint SamenerpWeb.Endpoint

  # The k-anonymity floor the surface ACTUALLY applies. Read from the same module the
  # read layer calls (`Samen.Aggregate.Privacy.k/0` → `config :samen_core,
  # :k_anonymity_min_cohort`) rather than assuming the framework default of 5: every
  # shipped host configures 2, and a hardcoded floor makes these tests assert the wrong
  # boundary on a host that tunes it (this host: 2 — found the hard way).
  defp k, do: Samen.Aggregate.Privacy.k()

  setup do
    start_supervised!(SamenerpWeb.Endpoint)
    Application.put_env(:samen_core, :kms_adapter, Samen.Kms.FileBacked)
    :ok
  end

  # ---- fixtures --------------------------------------------------------------

  defp create_org!(name) do
    Op.Org
    |> Ash.Changeset.for_create(:create, %{name: name}, authorize?: false)
    |> Ash.create!(authorize?: false)
  end

  # A subject with its own KMS DEK — required for `actor_ref` to be a real pseudonym
  # (`Samen.WideEvent.for_subject/2` is keyed on the subject's own key).
  defp mk_subject do
    sid = Ash.UUID.generate()
    {:ok, _} = Kms.adapter().generate_subject_key(sid)
    sid
  end

  # Reach one activation stage with `n` DISTINCT subjects, through the REAL capture
  # boundary — never a hand-written ledger insert, so the emitter config is exercised.
  defp reach_stage!(org_id, event_name, n) do
    Enum.each(1..n, fn _ ->
      {:ok, %ProductEvent{}} =
        Analytics.track(%{
          org_id: org_id,
          event_name: event_name,
          subject_id: mk_subject()
        })
    end)

    :ok
  end

  defp ledger_rows(org_id) do
    ProductEvent
    |> Ash.Query.filter(org_id == ^org_id)
    # `ensure_selected` (the demo `events/1` shape): assert on the PHYSICAL columns, not
    # on whatever a default select happens to load.
    |> Ash.Query.ensure_selected([
      :org_id,
      :actor_ref,
      :event_name,
      :event_kind,
      :entity_ref,
      :props,
      :occurred_at
    ])
    |> Ash.read!(authorize?: false)
  end

  defp product_event_rollup_spec! do
    spec = Enum.find(Rollup.specs(), &(&1.name == :product_event_rollup))

    assert spec,
           "the :product_event_rollup spec is not registered — `paf_product_event_rollup` " <>
             "has no source, so the funnel cannot be non-empty for any org"

    spec
  end

  defp refresh_product_event_rollup! do
    spec = product_event_rollup_spec!()
    assert {:ok, _} = Rollup.refresh(Samenerp.Repo, spec)
    spec
  end

  defp funnel_rows(org_id) do
    %{rows: rows} =
      Samenerp.Repo.query!(
        """
        SELECT paf_stage, paf_actor_count, paf_suppressed
        FROM paf_product_event_rollup
        WHERE paf_org_id = $1 AND paf_kind = 'funnel'
        ORDER BY paf_stage
        """,
        [Ecto.UUID.dump!(org_id)]
      )

    rows
  end

  # A foreign org's unmistakable count, written directly into the rollup AFTER a refresh
  # (a refresh truncates the table — the rollup is a whole-table rebuild).
  defp insert_foreign_rollup!(org_id, stage, count) do
    Samenerp.Repo.query!(
      """
      INSERT INTO paf_product_event_rollup (paf_org_id, paf_kind, paf_stage, paf_actor_count)
      VALUES ($1, 'funnel', $2, $3)
      """,
      [Ecto.UUID.dump!(org_id), stage, count]
    )
  end

  # ==========================================================================
  # 1 — the mount itself
  # ==========================================================================

  describe "1 — the Analytics scope is mounted on this host" do
    test "the sae ledger resource exists, with the abbrev-derived table name" do
      assert Ash.Resource.Info.resource?(ProductEvent)

      assert AshPostgres.DataLayer.Info.table(ProductEvent) == "sae_product_event",
             "the ledger table must follow the reserved `sae` abbrev (ADR-023); a different " <>
               "name means the migration and the resource have drifted apart"
    end

    test "the framework emitter is wired to THIS host's ledger (the config link)" do
      assert Application.get_env(:samen_core, Samen.Analytics)[:product_event_resource] ==
               ProductEvent,
             "without `product_event_resource: Samenerp.Analytics.ProductEvent`, track/1 is " <>
               "INERT ({:ok, :dropped}) and every framework-emitted event is discarded"

      assert Application.get_env(:samen_core, Samen.FeatureFlags)[:emit] ==
               {Samen.Analytics, :track},
             "flag-variant assignments must flow to the same emitter (ADR-020 §3.4 seam)"
    end
  end

  # ==========================================================================
  # 2 — capture: the emitter writes, and the config is what makes it write
  # ==========================================================================

  describe "2 — product events reach the sae ledger" do
    test "track/1 writes exactly one bounded row for a valid event" do
      org = create_org!("Analytics Capture")

      assert {:ok, %ProductEvent{} = sae} =
               Analytics.track(%{
                 org_id: org.id,
                 event_name: "record.created",
                 entity_ref: "erp-42",
                 props: %{"resource" => "samenerp.erp.entry"}
               })

      assert sae.event_name == :"record.created"
      assert sae.event_kind == :record

      rows = ledger_rows(org.id)
      assert length(rows) == 1
      assert hd(rows).org_id == org.id
    end

    test "ANTI-TAUTOLOGY: with no product_event_resource the same capture is DROPPED" do
      org = create_org!("Analytics Inert")
      configured = Application.get_env(:samen_core, Samen.Analytics)

      on_exit(fn -> Application.put_env(:samen_core, Samen.Analytics, configured) end)

      Application.put_env(:samen_core, Samen.Analytics, product_event_resource: nil)

      assert {:ok, :dropped} =
               Analytics.track(%{org_id: org.id, event_name: "session.signed_in"})

      assert ledger_rows(org.id) == [],
             "an unwired emitter must persist nothing — this is exactly how the activation " <>
               "funnel was permanently empty before this mount"

      # Restored, the SAME call persists: the assertion above proves the config link,
      # not a vacuous 'track returns {:ok, _}'.
      Application.put_env(:samen_core, Samen.Analytics, configured)

      assert {:ok, %ProductEvent{}} =
               Analytics.track(%{org_id: org.id, event_name: "session.signed_in"})

      assert length(ledger_rows(org.id)) == 1
    end
  end

  # ==========================================================================
  # 3 — the domain-sourced rollup materializes the funnel from the ledger
  # ==========================================================================

  describe "3 — the product-event rollup is sourced from the sae ledger" do
    test "the spec is registered, domain-sourced, and reads this host's ledger" do
      spec = product_event_rollup_spec!()

      assert spec.source == :domain
      assert spec.table == "paf_product_event_rollup"
      assert spec.domain_table == "sae_product_event"
      assert spec.domain_subject_column == "sae_actor_ref"
    end

    test "refreshing materializes floored funnel stages from captured events" do
      org = create_org!("Analytics Rollup")

      # Independent expectation: a stage row exists iff the org reached it, and its
      # actor count is the number of DISTINCT subjects that reached it.
      expected = %{"first_run" => 7, "signup" => k()}

      reach_stage!(org.id, "session.signed_in", k())
      reach_stage!(org.id, "first_run.completed", 7)

      refresh_product_event_rollup!()

      actual =
        funnel_rows(org.id)
        |> Map.new(fn [stage, count, suppressed] -> {stage, {count, suppressed}} end)

      for {stage, count} <- expected do
        assert actual[stage] == {count, false},
               "stage #{stage}: expected the #{count} distinct actors that reached it, got " <>
                 "#{inspect(actual[stage])} — the rollup must reconcile with the ledger"
      end

      # A stage no actor reached has NO rollup row at all: the SQL groups over the
      # ledger, so absence is the honest encoding. The 0-actor cohort is materialized by
      # the READ layer (`AnalyticsReads.read/3`'s floored read defaults every stage in
      # `@funnel_stages`), which then fail-closes it — §4 proves that renders ⊘, never a
      # fabricated 0. Asserted here so the layering is explicit rather than assumed.
      assert actual["first_record"] == nil
    end
  end

  # ==========================================================================
  # 4 — the outcome: Insights → Activation renders the real funnel
  # ==========================================================================

  describe "4 — the P17 /analytics page renders the captured funnel" do
    test "an org that reached a stage sees its released count (not the empty state)" do
      org = create_org!("Analytics Page Reach")
      reach_stage!(org.id, "session.signed_in", k())
      refresh_product_event_rollup!()

      conn = get(build_conn(), "/analytics?org=#{org.id}")

      assert conn.status == 200, "the /analytics page did not render"

      body = conn.resp_body
      assert body =~ ~s(id="funnel-table"), "the funnel table did not render"

      assert body =~ ">#{k()}<",
             "the org's own captured signup cohort (= the k floor, so it RELEASES) did not render"

      refute body =~ ~s(id="analytics-empty"),
             "an org with captured events must NOT render the empty state — this is the " <>
               "defect this mount fixes (the page was permanently empty for every org)"
    end

    test "a below-floor cohort renders ⊘, never the count" do
      org = create_org!("Analytics Page Below Floor")

      # A sub-floor cohort only exists when the host's floor is >= 2 (every shipped host
      # sets 2). Asserted rather than assumed, so this test can never pass VACUOUSLY on a
      # host that neutered the floor to 1.
      assert k() >= 2, "this host's k-anonymity floor is 1 — there is no sub-floor cohort to prove"

      reach_stage!(org.id, "session.signed_in", k() - 1)
      refresh_product_event_rollup!()

      conn = get(build_conn(), "/analytics?org=#{org.id}")
      body = conn.resp_body

      # The suppression is asserted on the STAGE'S OWN CELL, not "⊘ appears somewhere" —
      # the page also renders a suppression-count note, so a bare `body =~ "⊘"` would pass
      # even if the row itself leaked. The regex pins the signup row's count cell.
      assert Regex.match?(~r/id="stage-signup".*?f-count">⊘</s, body),
             "a sub-floor stage must be suppressed with ⊘ in its own count cell"

      refute Regex.match?(~r/id="stage-signup".*?f-count">\d+</s, body),
             "a below-floor cohort must NEVER render its raw count (re-identification)"
    end

    test "another org's funnel never reaches this org's page" do
      caller = create_org!("Analytics Page Caller")
      foreign = create_org!("Analytics Page Foreign")

      reach_stage!(caller.id, "session.signed_in", k())
      refresh_product_event_rollup!()

      # A foreign sentinel, written after the rebuild (a refresh truncates the table).
      insert_foreign_rollup!(foreign.id, "signup", 987_654)

      body = get(build_conn(), "/analytics?org=#{caller.id}").resp_body

      refute body =~ "987654",
             "a foreign org's count leaked into this org's analytics (org scoping broke)"

      refute body =~ ~s(id="analytics-empty"),
             "the caller's OWN captured cohort must still render"
    end

    test "an org with no captured events keeps the honest empty state" do
      org = create_org!("Analytics Page Empty")

      body = get(build_conn(), "/analytics?org=#{org.id}").resp_body

      assert body =~ ~s(id="analytics-empty"),
             "with no ledger rows there is nothing to show — the empty state is still correct " <>
               "(what changed is that it is no longer the ONLY reachable state)"
    end
  end
end
