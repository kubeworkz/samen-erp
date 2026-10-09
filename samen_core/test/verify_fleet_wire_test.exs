defmodule Samen.VerifyFleetWireTest do
  @moduledoc """
  T84b — `mix samen.verify.fleet_wire` (ADR-044 §5.2 point 4 / phase6-punchlist P8).

  Three independent checks, each green + red + anti-tautology:

    * RP-J-4 — schema class discipline (delegates to the already-shipped
      `Schema.class_discipline_violations/0`; asserted here at the TASK level so
      a future regression is caught by THIS gate, not just the schema's own test).
    * P8 — closed-catalog MEMBERSHIP: a host that declares a non-empty catalog
      gets REAL membership enforcement (the live smoke-check); a host that
      declares an EMPTY catalog fails (a catalog that claims closure but admits
      nothing is worse than not declaring one); a host with NO declaration at
      all is clean (opt-in, not a regression for the many hosts that haven't
      adopted cohorts yet).
    * RP-J-4b — the route-surface cross-check (needs `--router`; skipped, not a
      violation, when omitted).
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.Samen.Verify.FleetWire

  @test_host :samen_core_fleet_wire_test_host

  # The child-process acceptance tests below run the REAL command from here (`mix …`),
  # the only way to observe `:erlang.halt(1)` without taking the test VM with it.
  @project_dir Path.expand("../", __DIR__)

  setup do
    on_exit(fn -> Application.delete_env(@test_host, :fleet_wire_catalogs) end)
    :ok
  end

  describe "RP-J-4 — class discipline (delegated, asserted at the gate level)" do
    test "GREEN: the real schema has zero class-discipline violations" do
      Application.delete_env(@test_host, :fleet_wire_catalogs)
      assert FleetWire.violations(host: @test_host) == []
    end
  end

  describe "P8 — closed-catalog membership" do
    test "GREEN: no catalogs declared at all — not a violation (opt-in, unadopted host untouched)" do
      Application.delete_env(@test_host, :fleet_wire_catalogs)
      assert FleetWire.violations(host: @test_host) == []
    end

    test "GREEN: a declared non-empty catalog passes the live smoke-check" do
      Application.put_env(@test_host, :fleet_wire_catalogs,
        closed_check_catalog: ~w(db_reachable redis_reachable)
      )

      assert FleetWire.violations(host: @test_host) == []
    end

    test "RED: a declared EMPTY catalog is a violation (claims closure, admits nothing/anything)" do
      Application.put_env(@test_host, :fleet_wire_catalogs, closed_check_catalog: [])

      assert [violation] = FleetWire.violations(host: @test_host)
      assert violation =~ "empty or malformed"
      assert violation =~ "closed_check_catalog"
    end

    test "RED sabotage twin — Schema.validate/2 accepting an out-of-catalog label flips the smoke-check" do
      # Simulate the regression the smoke-check exists to catch: a catalog is
      # declared, but membership enforcement is NOT wired (Schema.validate/2
      # would accept anything shape-valid). We can't literally break the shipped
      # Schema module inside a test without a real sabotage patch, so this test
      # instead pins the CONTRACT the smoke-check depends on: validate/2 MUST
      # reject a label outside a supplied non-empty catalog. If this assertion
      # ever fails, the FleetWire smoke-check silently stops being able to catch
      # a real regression (the anti-tautology guarantee).
      catalogs = %{closed_check_catalog: ~w(db_reachable)}

      payload =
        Samen.Fleet.Report.build(app_id: "11111111-1111-4111-8111-111111111111")
        |> Samen.Fleet.Report.to_wire()
        |> Map.put("checks", [%{"name" => "zz_not_in_catalog", "status" => "ok"}])

      assert {:error, errors} = Samen.Fleet.Report.Schema.validate(payload, catalogs)
      assert Enum.any?(errors, &String.contains?(&1, "closed_check_catalog"))
    end

    test "all four sentinels get a real smoke-check when declared" do
      Application.put_env(@test_host, :fleet_wire_catalogs,
        closed_check_catalog: ~w(a),
        closed_plan_tier_catalog: ~w(free),
        closed_app_queue_catalog: ~w(mailers),
        closed_audit_taxonomy_catalog: ~w(login)
      )

      assert FleetWire.violations(host: @test_host) == []
    end
  end

  describe "H1 (phase6 SEC, INV-2) — the closed-member premise reaches the NESTED level" do
    test "GREEN: the real schema rejects undeclared nested keys, so the gate is clean" do
      Application.delete_env(@test_host, :fleet_wire_catalogs)
      # `violations/1` runs the nested-member check unconditionally, over EVERY declared
      # list section + every suppressible cell. A clean schema contributes zero.
      assert FleetWire.violations(host: @test_host) == []
    end

    test "anti-tautology: the CONTRACT the nested check depends on (item + suppressed reject undeclared keys)" do
      # If either nested validator regressed, the FleetWire check would silently stop
      # catching the INV-2 hole. Pin the contract directly, for EVERY declared section.
      base =
        Samen.Fleet.Report.build(app_id: "11111111-1111-4111-8111-111111111111")
        |> Samen.Fleet.Report.to_wire()

      for {section, opts} <- Samen.Fleet.Report.Schema.list_fields() do
        fields = Keyword.fetch!(opts, :fields)

        item =
          Map.new(fields, fn {name, type, field_opts} ->
            {Atom.to_string(name), probe_value(type, field_opts)}
          end)
          |> Map.put("zz_undeclared_leak", "smuggled@example.test")

        payload = Map.put(base, Atom.to_string(section), [item])

        assert {:error, errors} = Samen.Fleet.Report.Schema.validate(payload),
               "expected #{section} to reject an undeclared item key"

        assert Enum.any?(errors, &String.contains?(&1, "zz_undeclared_leak"))
      end

      suppressed_payload =
        Map.put(base, "deliverability", [
          %{
            "handle" => String.duplicate("a", 32),
            "sent" => %{
              "suppressed" => true,
              "reason" => "k_anonymity",
              "k" => 5,
              "zz_undeclared_leak" => "smuggled@example.test"
            },
            "bounced" => 0,
            "complained" => 0,
            "health_index" => 90
          }
        ])

      assert {:error, sup_errors} = Samen.Fleet.Report.Schema.validate(suppressed_payload)
      assert Enum.any?(sup_errors, &String.contains?(&1, "zz_undeclared_leak"))
    end
  end

  describe "RP-J-4b — route surface (needs --router)" do
    test "no --router: skipped, not a violation" do
      Application.delete_env(@test_host, :fleet_wire_catalogs)
      assert FleetWire.violations(host: @test_host, router: nil) == []
    end

    test "RED: --router pointing at a non-router module is a violation" do
      Application.delete_env(@test_host, :fleet_wire_catalogs)

      assert [violation] = FleetWire.violations(host: @test_host, router: Samen.Fleet.RouteTable)
      assert violation =~ "not a compiled Phoenix router"
    end
  end

  # The co-adoption rules (`FleetWire.co_adoption_rules/0`): a mount side is sound only
  # alongside its counterpart in the same app. Two rules ship — the ADR-044 §3.1/§9.2 fleet
  # cockpit pair (`samen_fleet_ingest_routes/1` ⇒ a cockpit) and the ADR-038 §5.1 raw-bytes
  # seam (`samen_webhook_routes`/`samen_fleet_routes` ⇒ `Samen.Web.Webhook.RawBodyReader` in
  # `Plug.Parsers`). Both are one-directional. Per the house gate discipline each rule gets a
  # green real-tree proof, a red divergence, a positive control and an anti-tautology twin,
  # plus the two fail-closed paths for the walker itself.
  describe "co-adoption rules — a mount side is sound only alongside its counterpart" do
    test "GREEN: the real tree mounts the ingest nowhere, and the macro's own definition is not a mount" do
      Application.delete_env(@test_host, :fleet_wire_catalogs)

      scan = FleetWire.adoption_scan([])
      refute scan.skipped, "the real checkout must be recognized as the monorepo"

      apps = Enum.map(scan.apps, & &1.app)
      assert length(scan.apps) >= 5, "the walker found too few apps: #{inspect(apps)}"

      # Non-vacuity: we DID walk the app that defines the macro — so "no mount found"
      # below is a fact about the walker, not a glob that matched nothing.
      web = Enum.find(scan.apps, &(&1.app == "samen_web"))
      assert web, "expected samen_web among the scanned apps: #{inspect(apps)}"
      assert web.files > 0

      # The anti-false-positive assertion: `defmacro samen_fleet_ingest_routes(opts)` and
      # the `@doc` example in samen_web/lib/samen/web/router.ex are NOT adoptions. (Also
      # excludes `defmacro samen_webhook_routes(opts \\ [])` — a default-arg head parses as a
      # single NON-list argument, which is why rule 2's predicate insists on [] or a keyword
      # list.)
      mounted = Enum.filter(scan.apps, &(&1.ingest != []))
      assert mounted == [], "a definition/doc line was read as a MOUNT: #{inspect(mounted)}"

      # Rule 2's real-tree non-vacuity: exactly three hosts mount a signature-verifying wire,
      # so the rule is genuinely engaged — and each wires the seam. Naming them keeps a rule
      # that stopped firing visible here instead of silently green.
      wired = Enum.filter(scan.apps, &(&1.wire != []))
      assert Enum.map(wired, & &1.app) == ["driftwood", "pawchart", "samenerp"],
             "expected exactly the wire-mounting hosts, got: #{inspect(Enum.map(wired, & &1.app))}"

      for app_scan <- wired, do: assert(app_scan.seam, "#{app_scan.app} should wire the seam")

      # ...and the seam signal is not simply true everywhere (a signal that cannot say "no"
      # would make rule 2 unfalsifiable).
      refute Enum.all?(scan.apps, & &1.seam), "every app reports the seam — signal cannot discriminate"

      assert FleetWire.violations(host: @test_host) == []

      # Rules 3 and 4 are engaged by the same three hosts (and ONLY them — samen_web is a
      # library, demo is API-only, and the adapter packages mount no web surface at all).
      org_session = Enum.filter(scan.apps, &(&1.org_session != []))
      assert Enum.map(org_session, & &1.app) == ["driftwood", "pawchart", "samenerp"]

      for app_scan <- org_session do
        assert app_scan.session_plug != [],
               "#{app_scan.app} must supply the session plug its byte/export routes read"
      end

      realtime = Enum.filter(scan.apps, &(&1.realtime != []))
      assert Enum.map(realtime, & &1.app) == ["driftwood", "pawchart", "samenerp"]

      for app_scan <- realtime do
        assert app_scan.pubsub_ready != [],
               "#{app_scan.app} must run the PubSub its realtime mount broadcasts on"
      end

      # Neither signal is true everywhere — a counterpart that cannot say "no" would make
      # rules 3 and 4 unfalsifiable.
      refute Enum.all?(scan.apps, &(&1.session_plug != [])),
             "every app reports a session plug — signal cannot discriminate"

      refute Enum.all?(scan.apps, &(&1.pubsub_ready != [])),
             "every app reports a ready PubSub — signal cannot discriminate"
    end

    test "RED: a host that mounts the cockpit-side ingest without a cockpit is a violation" do
      Application.delete_env(@test_host, :fleet_wire_catalogs)

      root =
        shadow_root(
          %{
            "ghost" => ingest_only_router(),
            "plain" => reporting_only_router()
          },
          seams: ["plain"]
        )

      # Two positive controls inside the red run. `plain` mounts the reporting side
      # (`samen_fleet_routes/1`, what driftwood/pawchart/samenerp mount) and gets the seam, so
      # it is clean under BOTH rules — which is what makes the ghost violations attributable.
      #
      # `ghost` violates BOTH rules on the same mount, and that is the point: the cockpit-side
      # ingest is a cockpit's own side of the wire (rule 1) AND a signature-verifying receiver
      # whose heartbeat pipe signs `Crypto.body_digest(raw_body)` (rule 2 — see the ingest
      # leg test below). One mount, two independent obligations, each reported separately.
      assert [cockpit_violation, seam_violation] = FleetWire.adoption_violations(adoption_root: root)

      assert cockpit_violation =~ "ghost: mounts the cockpit-side fleet ingest"
      assert cockpit_violation =~ "samen_fleet_ingest_routes/1"
      assert cockpit_violation =~ "ghost/lib/ghost_web/router.ex:5"
      assert cockpit_violation =~ "mounts NO cockpit"
      refute cockpit_violation =~ "raw-bytes seam"
      refute cockpit_violation =~ "plain"

      assert seam_violation =~ "ghost: mounts a signature-verifying receiver"
      assert seam_violation =~ "mounts NO raw-bytes seam"
      refute seam_violation =~ "cockpit"
      refute seam_violation =~ "plain"
    end

    test "CONTROL: the same router with the cockpit mounted alongside is clean" do
      Application.delete_env(@test_host, :fleet_wire_catalogs)

      # Both apps get the seam: with the cockpit mounted alongside, rule 1 is satisfied and rule
      # 2 is the only remaining obligation — so a clean run here proves the cockpit pair is
      # discharged by the mount itself, not by the absence of the other rule's trigger.
      root =
        shadow_root(
          %{
            "ghost" => ingest_plus_cockpit_router(),
            "plain" => reporting_only_router()
          },
          seams: ["ghost", "plain"]
        )

      scan = FleetWire.adoption_scan(adoption_root: root)
      assert Enum.find(scan.apps, &(&1.app == "ghost")).cockpit

      assert FleetWire.adoption_violations(adoption_root: root) == []
    end

    test "anti-tautology: prose, a comment, or a labels map in ANOTHER call never satisfies the cockpit leg" do
      Application.delete_env(@test_host, :fleet_wire_catalogs)

      root = shadow_root(%{"ghost" => ingest_with_fake_cockpit_router()})

      # The source mentions `fleet_cockpit: true` twice — once in a comment, once as a
      # keyword in a DIFFERENT call. Only a real `samen_operator_routes(..., fleet_cockpit:
      # true)` counts, so the cockpit leg must STILL be a violation: if this test ever goes
      # green, the detector has degraded to a string match and the invariant is gone. (Rule 2
      # also engages this mount — it is a receiver with no seam — so there are exactly two.)
      assert [cockpit_violation, seam_violation] = FleetWire.adoption_violations(adoption_root: root)
      assert cockpit_violation =~ "ghost: mounts the cockpit-side fleet ingest"
      assert cockpit_violation =~ "mounts NO cockpit"
      assert seam_violation =~ "mounts NO raw-bytes seam"
    end

    test "fail-closed: an unparsable file that MENTIONS the macro is reported, never assumed clean" do
      Application.delete_env(@test_host, :fleet_wire_catalogs)

      root = shadow_root(%{"ghost" => unparsable_router()})

      # The fixture names the ingest macro, so it is attributed to BOTH rules the file could
      # plausibly be adopting — the cockpit pair and the seam — never silently assumed clean.
      assert [cockpit_violation, seam_violation] = FleetWire.adoption_violations(adoption_root: root)

      assert cockpit_violation =~ "unparsable — cannot certify"
      assert cockpit_violation =~ "mounts NO cockpit"
      assert seam_violation =~ "unparsable — cannot certify"
      assert seam_violation =~ "mounts NO raw-bytes seam"
    end

    test "fail-closed: a monorepo whose app discovery comes back EMPTY is a violation, not a pass" do
      Application.delete_env(@test_host, :fleet_wire_catalogs)

      root = shadow_root(%{})

      assert [violation] = FleetWire.adoption_violations(adoption_root: root)
      assert violation =~ "found NO app dirs"
    end

    # --- rule 2: the raw-bytes seam (ADR-038 §5.1 / ADR-044 §4.4a) ----------------------

    test "RED (rule 2): a wire-mounting app with no raw-bytes seam is a violation" do
      Application.delete_env(@test_host, :fleet_wire_catalogs)

      root = shadow_root(%{"vet" => webhook_only_router()})

      assert [violation] = FleetWire.adoption_violations(adoption_root: root)
      assert violation =~ "vet: mounts a signature-verifying receiver"
      assert violation =~ "samen_webhook_routes/1"
      assert violation =~ "vet/lib/vet_web/router.ex:5"
      assert violation =~ "mounts NO raw-bytes seam"
      refute violation =~ "cockpit"
    end

    test "CONTROL (rule 2): the same router with the seam wired in the ENDPOINT is clean" do
      Application.delete_env(@test_host, :fleet_wire_catalogs)

      # The counterpart lives in the endpoint, so the rule must be app-scoped, not
      # file-scoped: a seam in a DIFFERENT file of the same app discharges the obligation.
      root = shadow_root(%{"vet" => webhook_only_router()}, seams: ["vet"])

      scan = FleetWire.adoption_scan(adoption_root: root)
      assert Enum.find(scan.apps, &(&1.app == "vet")).seam

      assert FleetWire.adoption_violations(adoption_root: root) == []
    end

    test "anti-tautology (rule 2): a comment or a DIFFERENT body reader never satisfies the seam" do
      Application.delete_env(@test_host, :fleet_wire_catalogs)

      # The endpoint here names `Samen.Web.Webhook.RawBodyReader` in a comment and wires a
      # right-shaped but WRONG reader. Only the real seam counts — if this ever goes green,
      # rule 2 has degraded to a keyword match and no longer enforces anything.
      root =
        shadow_root(%{"vet" => wrong_reader_router()},
          endpoint: %{"vet" => wrong_reader_endpoint()}
        )

      assert [violation] = FleetWire.adoption_violations(adoption_root: root)
      assert violation =~ "vet: mounts a signature-verifying receiver"
      assert violation =~ "mounts NO raw-bytes seam"
    end

    # --- rule 2, ingest leg: all THREE signature-verifying receivers, not just two ---------

    test "RED (rule 2, ingest leg): the cockpit-side ingest is a wire side too, so it needs the seam" do
      Application.delete_env(@test_host, :fleet_wire_catalogs)

      # The cockpit IS mounted alongside it, so rule 1 is satisfied — exactly one violation,
      # and it is rule 2 naming the THIRD receiver. Its own @doc states the obligation
      # ("Needs the SAME raw-body reader samen_fleet_routes/1 documents") and the code earns it:
      # `Registry.verify_and_ingest_heartbeat/2` signs `Crypto.body_digest(raw_body)`, which
      # `Samen.Web.Fleet.CockpitIngress.heartbeat/2` reads through `RawBodyReader.raw_body/1`.
      root = shadow_root(%{"ghost" => ingest_plus_cockpit_router()})

      assert [violation] = FleetWire.adoption_violations(adoption_root: root)
      assert violation =~ "ghost: mounts a signature-verifying receiver"
      assert violation =~ "samen_fleet_ingest_routes/1"
      assert violation =~ "mounts NO raw-bytes seam"
      refute violation =~ "mounts NO cockpit"
    end

    # --- rule 3: an org-session surface needs the session plug (ADR-026 / ADR-028 / F2) ----

    test "RED (rule 3): a files mount with no session plug anywhere in the app is a violation" do
      Application.delete_env(@test_host, :fleet_wire_catalogs)

      root = shadow_root(%{"vet" => files_only_router()})

      assert [violation] = FleetWire.adoption_violations(adoption_root: root)
      assert violation =~ "vet: mounts an org-session-reading surface"
      assert violation =~ "samen_files_routes/3"
      assert violation =~ "vet/lib/vet_web/router.ex:10"
      assert violation =~ "mounts NO session plug"
      refute violation =~ "raw-bytes seam"
    end

    test "CONTROL (rule 3): the plug in a DIFFERENT file of the same app discharges it" do
      Application.delete_env(@test_host, :fleet_wire_catalogs)

      # The counterpart is app-scoped like rule 2's seam (a host may wire the session in a
      # pipeline module rather than beside the mount).
      root =
        shadow_root(%{"vet" => files_only_router()},
          extra: %{"vet" => %{"lib/vet_web/session_pipeline.ex" => session_plug_pipeline()}}
        )

      scan = FleetWire.adoption_scan(adoption_root: root)
      assert Enum.find(scan.apps, &(&1.app == "vet")).session_plug != []

      assert FleetWire.adoption_violations(adoption_root: root) == []
    end

    test "anti-tautology (rule 3): a comment or a differently-named plug never satisfies the session plug" do
      Application.delete_env(@test_host, :fleet_wire_catalogs)

      # The source NAMES `fetch_session` twice — in a comment and as the PREFIX of a different
      # plug. If this ever goes green, rule 3 has degraded to a keyword match.
      root = shadow_root(%{"vet" => comment_only_session_router()})

      assert [violation] = FleetWire.adoption_violations(adoption_root: root)
      assert violation =~ "vet: mounts an org-session-reading surface"
      assert violation =~ "mounts NO session plug"
    end

    # --- rule 4: a realtime mount needs a PubSub this app actually runs (ADR-012 / ADR-016) -

    test "RED (rule 4): a chat mount with no supervision tree in the app is a violation" do
      Application.delete_env(@test_host, :fleet_wire_catalogs)

      root = shadow_root(%{"vet" => chat_only_router()})

      assert [violation] = FleetWire.adoption_violations(adoption_root: root)
      assert violation =~ "vet: mounts a realtime surface"
      assert violation =~ "vet/lib/vet_web/router.ex:5"
      assert violation =~ "mounts NO supervised Phoenix.PubSub"
      refute violation =~ "session plug"
    end

    test "CONTROL (rule 4): the tree the macros' @docs ask for (bus + roster, same name) discharges it" do
      Application.delete_env(@test_host, :fleet_wire_catalogs)

      root =
        shadow_root(%{"vet" => chat_only_router()},
          extra: %{"vet" => %{"lib/vet/application.ex" => pubsub_application(Vet.PubSub)}}
        )

      scan = FleetWire.adoption_scan(adoption_root: root)
      assert Enum.find(scan.apps, &(&1.app == "vet")).pubsub_ready != []

      assert FleetWire.adoption_violations(adoption_root: root) == []
    end

    test "anti-tautology (rule 4): the bus must be the mount's OWN name, and CHAT also needs the roster" do
      Application.delete_env(@test_host, :fleet_wire_catalogs)

      # A right-shaped `Phoenix.PubSub` under a DIFFERENT name does not discharge the rule — a
      # "has a Phoenix.PubSub at all" signal would pass this, and that is exactly the
      # wrong-bus failure the framework's vertical-named default produces.
      misnamed =
        shadow_root(%{"vet" => chat_only_router()},
          extra: %{"vet" => %{"lib/vet/application.ex" => pubsub_application(Other.PubSub)}}
        )

      misnamed_scan = FleetWire.adoption_scan(adoption_root: misnamed)
      assert misnamed_scan.apps != [], "the fixture root must still be a walkable monorepo"

      assert [violation] = FleetWire.adoption_violations(adoption_root: misnamed)
      assert violation =~ "vet: mounts a realtime surface"
      assert violation =~ "mounts NO supervised Phoenix.PubSub"

      # ...and the bus alone is not enough for CHAT: its connected mount also tracks presence.
      no_roster =
        shadow_root(%{"vet" => chat_only_router()},
          extra: %{"vet" => %{"lib/vet/application.ex" => pubsub_only_application(Vet.PubSub)}}
        )

      assert [violation] = FleetWire.adoption_violations(adoption_root: no_roster)
      assert violation =~ "mounts NO supervised Phoenix.PubSub"

      # The notifications sibling has NO roster requirement, so the same tree is clean for it.
      notif =
        shadow_root(%{"vet" => notifications_only_router()},
          extra: %{"vet" => %{"lib/vet/application.ex" => pubsub_only_application(Vet.PubSub)}}
        )

      assert FleetWire.adoption_violations(adoption_root: notif) == []
    end

    test "the rule table is DATA: unique ids, every field present, a cited reason per rule" do
      rules = FleetWire.co_adoption_rules()

      assert length(rules) >= 4, "expected the fleet pair, the seam, the session plug and the PubSub"
      assert Enum.uniq(Enum.map(rules, & &1.id)) == Enum.map(rules, & &1.id)

      for rule <- rules do
        for key <- [:id, :side, :side_desc, :requires, :requires_desc, :why, :fix] do
          assert Map.has_key?(rule, key), "#{inspect(rule[:id])} is missing #{key}"
        end

        assert rule.why =~ "ADR-", "#{inspect(rule.id)} cites no governing text"
      end
    end
  end

  # `--root` — the CLI's EXPLICIT tree. The green proof above walks the checkout the test
  # runs INSIDE; this pins the other half: an explicit tree is walked AS GIVEN, in the two
  # shapes a caller actually has (a scratch monorepo copy, which may carry no
  # `samen_core/lib` probe at all, and ONE standalone host whose own root is the app),
  # plus the fail-honest edges — a mistyped path is a violation, never the silent skip the
  # cwd default uses outside a checkout.
  describe "--root: an explicit tree is walked as given, fail-honest on a bad path" do
    test "the CLI still RECOGNIZES --root (a dropped switch would revert to discovery)" do
      assert FleetWire.cli_opts(["--root", "C:/somewhere/mono"])[:root] == "C:/somewhere/mono"

      assert FleetWire.cli_opts(["--host", "driftwood", "--root", "C:/somewhere/mono"])[:root] ==
               "C:/somewhere/mono"

      # The contrast that makes the assertion above non-vacuous: an option that is NOT a
      # declared switch lands in `rest` and never appears in `opts`.
      refute Keyword.has_key?(FleetWire.cli_opts(["--not-a-switch", "x"]), :"not-a-switch")

      # ...and its ABSENCE is the discovery default, not a walk of some empty path.
      assert FleetWire.cli_opts([])[:root] == nil
    end

    test "a scratch copy is walked WITHOUT the samen_core/lib monorepo probe" do
      # The probe the default discovery requires is deliberately ABSENT: this is the
      # scratch-copy shape. Same tree, same violation with and without it, so the walk —
      # not the probe — decides.
      without = shadow_root(%{"vet" => webhook_only_router()}, monorepo_probe: false)
      with_probe = shadow_root(%{"vet" => webhook_only_router()})

      refute FleetWire.adoption_scan(adoption_root: without).skipped

      assert [v1] = FleetWire.adoption_violations(adoption_root: without)
      assert [v2] = FleetWire.adoption_violations(adoption_root: with_probe)
      assert v1 == v2
      assert v1 =~ "vet: mounts a signature-verifying receiver"
    end

    test "ONE standalone host: the root itself is the app (no checkout, no sub-app dirs)" do
      root = standalone_host_root(webhook_only_router())

      scan = FleetWire.adoption_scan(adoption_root: root)
      refute scan.skipped
      assert Enum.map(scan.apps, & &1.app) == ["vet"]

      assert [violation] = FleetWire.adoption_violations(adoption_root: root)
      assert violation =~ "vet: mounts a signature-verifying receiver"
      assert violation =~ "mounts NO raw-bytes seam"
    end

    test "fail-honest: a --root that is not a directory is a VIOLATION, never a skip" do
      missing = Path.join(System.tmp_dir!(), "no_such_tree_#{System.unique_integer([:positive])}")

      scan = FleetWire.adoption_scan(adoption_root: missing)
      refute scan.skipped, "a mistyped path must never read as 'outside a monorepo: skip'"
      assert scan.bad_root
      assert scan.apps == []

      assert [violation] = FleetWire.adoption_violations(adoption_root: missing)
      assert violation =~ "is not a directory"
      assert violation =~ scan.root
    end

    test "anti-tautology: an existing but EMPTY tree fails closed with its OWN message" do
      root = Path.join(System.tmp_dir!(), "empty_tree_#{System.unique_integer([:positive])}")
      File.mkdir_p!(root)
      on_exit(fn -> File.rm_rf!(root) end)

      # Distinguishable from the bad-path case above: a directory that EXISTS but holds no
      # app dirs is discovered-empty, not unwalkable.
      refute FleetWire.adoption_scan(adoption_root: root).bad_root

      assert [violation] = FleetWire.adoption_violations(adoption_root: root)
      assert violation =~ "found NO app dirs"
      refute violation =~ "is not a directory"
    end
  end

  # `--format json` — the machine-readable report. Prose and data come from ONE construction
  # (`violation_record/3`), so these tests assert the PAIRING: every JSON field says what the
  # text report says, and no consumer has to re-parse the message to attribute a failure.
  # The three child-process cases are the acceptance layer — they observe the real exit code
  # and the real stdout, which the pure tests cannot.
  describe "--format json: machine-readable violations" do
    test "format_from/1 maps text/json, and an unknown value is an ERROR (never a fallback)" do
      assert FleetWire.format_from([]) == {:ok, :text}
      assert FleetWire.format_from(format: "text") == {:ok, :text}
      assert FleetWire.format_from(format: "json") == {:ok, :json}

      # Anti-tautology: a JSON-asking caller must never be handed the text report, so an
      # unsupported value is `:error`. If this ever returns {:ok, :text}, the CLI has gone
      # back to serving prose to a machine consumer with a green exit code.
      assert FleetWire.format_from(format: "xml") == :error
      assert FleetWire.format_from(format: "JSON") == :error
    end

    test "cli_invalid/1 surfaces what OptionParser could not place (the anti-silent-typo guard)" do
      assert FleetWire.cli_invalid(["--host", "driftwood"]) == []
      assert FleetWire.cli_invalid(["--root", "C:/x", "--format", "json"]) == []

      # Both halves of the guard: a mistyped switch, and a switch that lost its value —
      # without this each would be silently IGNORED and the run would exit 0 over the
      # default tree in the default format.
      assert FleetWire.cli_invalid(["--formatt", "json"]) == [{"--formatt", nil}]
      assert FleetWire.cli_invalid(["--rrot", "C:/x"]) == [{"--rrot", nil}]
      assert FleetWire.cli_invalid(["--format"]) == [{"--format", nil}]

      # ...and the recognized-switch half, so the guard cannot fire on a correct invocation.
      opts = FleetWire.cli_opts(["--host", "h", "--root", "C:/x", "--format", "json"])
      assert opts[:format] == "json"
      assert opts[:root] == "C:/x"
    end

    test "a co-adoption violation carries app + rule, from the SAME construction as the prose" do
      root = shadow_root(%{"vet" => webhook_only_router()})

      assert [record] = FleetWire.violation_records(adoption_root: root)

      # Equality, not "both non-empty": the two reports can never disagree about WHICH app
      # and WHICH rule fired, because the message is built once.
      assert record.message == hd(FleetWire.adoption_violations(adoption_root: root))
      assert record.kind == :co_adoption
      assert record.app == "vet"
      assert record.rule == :raw_body_seam

      doc = Samen.Verifier.document("samen.verify.fleet_wire", [record])
      assert doc["task"] == "samen.verify.fleet_wire"
      assert doc["status"] == "fail"
      assert doc["violation_count"] == 1

      assert [
               %{
                 "message" => message,
                 "kind" => "co_adoption",
                 "app" => "vet",
                 "rule" => "raw_body_seam"
               }
             ] = doc["violations"]

      assert message =~ "vet: mounts a signature-verifying receiver"

      # ...and it is genuinely JSON, not merely a map.
      assert %{"task" => "samen.verify.fleet_wire"} = doc |> Jason.encode!() |> Jason.decode!()
    end

    test "the OTHER checks are tagged too, so a dashboard can name the failing check" do
      Application.put_env(@test_host, :fleet_wire_catalogs, closed_check_catalog: [])

      assert [%{kind: :catalog, message: message}] =
               FleetWire.violation_records(host: @test_host)

      assert message =~ "empty or malformed"
    end

    test "a bare-string violation still renders the SAME four keys (stable schema)" do
      doc = Samen.Verifier.document("some.verify.task", ["a legacy string violation"])

      assert doc["status"] == "fail"
      assert doc["violation_count"] == 1

      assert [violation] = doc["violations"]
      assert violation["message"] == "a legacy string violation"
      assert violation["kind"] == nil
      assert violation["app"] == nil
      assert violation["rule"] == nil
      assert Enum.sort(Map.keys(violation)) == ["app", "kind", "message", "rule"]
    end

    test "the degenerate co-adoption shapes carry their own kind and no app" do
      missing = Path.join(System.tmp_dir!(), "no_tree_#{System.unique_integer([:positive])}")
      assert [bad] = FleetWire.adoption_violation_records(adoption_root: missing)
      assert bad.kind == :bad_root
      refute Map.has_key?(bad, :app)

      empty = Path.join(System.tmp_dir!(), "empty_tree_#{System.unique_integer([:positive])}")
      File.mkdir_p!(empty)
      on_exit(fn -> File.rm_rf!(empty) end)

      assert [discovery] = FleetWire.adoption_violation_records(adoption_root: empty)
      assert discovery.kind == :empty_discovery

      # ...and the json form of one, rendered through the same document builder.
      assert [%{"kind" => "bad_root", "app" => nil, "rule" => nil}] =
               Samen.Verifier.document("t", [bad])["violations"]
    end

    test "a clean run's document is ok with an empty list (the success shape a CI keys on)" do
      assert Samen.Verifier.document("t", []) ==
               %{"task" => "t", "status" => "ok", "violation_count" => 0, "violations" => []}
    end

    test "the harness REFUSES a format it does not print (never a silent downgrade)" do
      assert_raise ArgumentError, ~r/unsupported report format/, fn ->
        Samen.Verifier.halt_if_violations("t", [], format: :xml)
      end
    end

    test "ACCEPTANCE (child process): a failing run prints ONE JSON line and exits 1" do
      root = shadow_root(%{"vet" => webhook_only_router()})

      {output, exit_code} = run_task(["--format", "json", "--root", root])

      assert exit_code == 1, "expected exit 1, got #{exit_code}. Output: #{output}"

      doc = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
      assert doc["task"] == "samen.verify.fleet_wire"
      assert doc["status"] == "fail"
      assert doc["violation_count"] == 1

      assert [%{"kind" => "co_adoption", "app" => "vet", "rule" => "raw_body_seam"}] =
               doc["violations"]
    end

    test "ACCEPTANCE (child process): a clean run prints the ok document and exits 0" do
      root = shadow_root(%{"vet" => webhook_only_router()}, seams: ["vet"])

      {output, exit_code} = run_task(["--format", "json", "--root", root])

      assert exit_code == 0, "expected exit 0, got #{exit_code}. Output: #{output}"

      assert output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!() ==
               %{
                 "task" => "samen.verify.fleet_wire",
                 "status" => "ok",
                 "violation_count" => 0,
                 "violations" => []
               }
    end

    test "ACCEPTANCE (child process): an unrecognized switch is a violation, not a shrug" do
      # A CLEAN tree plus one mistyped switch: without the guard this invocation would ignore
      # `--rrot`, gate the default tree and exit 0 — the caller believing it gated one tree
      # while it gated another. Exactly one violation, and it is the argument one.
      root = shadow_root(%{"vet" => webhook_only_router()}, seams: ["vet"])

      {output, exit_code} = run_task(["--root", root, "--format", "json", "--rrot"])

      assert exit_code == 1, "expected exit 1, got #{exit_code}. Output: #{output}"

      doc = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
      assert doc["status"] == "fail"
      assert doc["violation_count"] == 1

      assert [%{"kind" => "cli_argument", "message" => message}] = doc["violations"]
      assert message =~ "unrecognized argument --rrot"
    end

    test "ACCEPTANCE (child process): --format xml exits 1 instead of quietly printing text" do
      root = shadow_root(%{"vet" => webhook_only_router()}, seams: ["vet"])

      {output, exit_code} = run_task(["--format", "xml", "--root", root])

      assert exit_code == 1, "expected exit 1, got #{exit_code}. Output: #{output}"
      assert output =~ "--format \"xml\" is not supported — use text or json."

      # The anti-tautology half: the tree is CLEAN, so a silent fallback to text would have
      # printed the pass banner and exited 0. It printed neither.
      refute output =~ "OK — no violations found"
    end
  end

  # --- §3.1 fixture sources -------------------------------------------------------------
  #
  # Functions rather than module attributes: the describe block above reads them, and an
  # attribute must be defined before the function that reads it is compiled.

  defp ingest_only_router do
    """
    defmodule GhostWeb.Router do
      import Samen.Web.Router

      scope "/" do
        samen_fleet_ingest_routes(namespace: Ghost.Fleet)
      end
    end
    """
  end

  defp ingest_plus_cockpit_router do
    """
    defmodule GhostWeb.Router do
      import Samen.Web.Router

      scope "/" do
        samen_operator_routes(GhostWeb, repo: Ghost.Repo, fleet_cockpit: true)
        samen_fleet_ingest_routes(namespace: Ghost.Fleet)
      end
    end
    """
  end

  defp reporting_only_router do
    """
    defmodule PlainWeb.Router do
      import Samen.Web.Router

      scope "/" do
        samen_fleet_routes(otp_app: :plain)
      end
    end
    """
  end

  # The cockpit leg is mentioned TWICE and neither is a mount: a comment (invisible to the
  # AST) and a `fleet_cockpit: true` keyword inside a DIFFERENT call's map.
  defp ingest_with_fake_cockpit_router do
    """
    defmodule GhostWeb.Router do
      # ADR-044: we would mount samen_operator_routes(..., fleet_cockpit: true) here if we
      # hosted a cockpit. This comment is not a mount.
      import Samen.Web.Router

      plug(:accepts, ["json"], private: %{labels: %{fleet_cockpit: true}})

      scope "/" do
        samen_fleet_ingest_routes(namespace: Ghost.Fleet)
      end
    end
    """
  end

  defp unparsable_router do
    """
    defmodule BrokenWeb.Router do
      samen_fleet_ingest_routes(namespace: Broken.Fleet)
    """
  end

  # Rule 2's side: the webhook ingress alone (the fleet report macro is also a wire side —
  # `reporting_only_router/0` above covers that shape).
  defp webhook_only_router do
    """
    defmodule VetWeb.Router do
      import Samen.Web.Router

      scope "/" do
        samen_webhook_routes()
      end
    end
    """
  end

  # Rule 2's side with a right-shaped but WRONG reader wired in the endpoint.
  defp wrong_reader_router do
    """
    defmodule VetWeb.Router do
      import Samen.Web.Router

      scope "/" do
        samen_fleet_routes(otp_app: :vet)
      end
    end
    """
  end

  # The seam as the macros' own docs write it (this file is parsed, never compiled).
  defp seam_endpoint do
    """
    defmodule ShadowWeb.Endpoint do
      plug Plug.Parsers,
        parsers: [:urlencoded, :json],
        body_reader: {Samen.Web.Webhook.RawBodyReader, :read_body, []},
        json_decoder: Jason
    end
    """
  end

  defp wrong_reader_endpoint do
    """
    defmodule VetWeb.Endpoint do
      # The docs say to wire Samen.Web.Webhook.RawBodyReader here.
      plug Plug.Parsers,
        parsers: [:urlencoded, :json],
        body_reader: {VetWeb.CachingReader, :read_body, []},
        json_decoder: Jason
    end
    """
  end

  # A synthetic monorepo: `samen_core/lib` is the scan's monorepo probe, and each entry
  # writes `<app>/mix.exs` + `<app>/lib/<app>_web/router.ex`. `:seams` names apps that also
  # get an `endpoint.ex` carrying the raw-bytes seam; `:endpoint` supplies a custom endpoint
  # source per app; `:extra` writes arbitrary additional app-relative files (a supervision
  # tree, a pipeline module) so the app-scoped counterparts of rules 3/4 can be placed
  # anywhere in the app under test. An empty map therefore produces a root with NO app dirs —
  # the fail-closed discovery case.
  # `monorepo_probe: false` omits the `samen_core/lib` marker — an explicit `--root` tree
  # (a scratch copy) that the walk must accept without it.
  defp shadow_root(router_sources, opts \\ []) do
    seams = Keyword.get(opts, :seams, [])
    endpoints = Keyword.get(opts, :endpoint, %{})
    extra = Keyword.get(opts, :extra, %{})

    root = Path.join(System.tmp_dir!(), "fleet_adoption_#{System.unique_integer([:positive])}")
    if Keyword.get(opts, :monorepo_probe, true), do: File.mkdir_p!(Path.join(root, "samen_core/lib"))

    for {app, source} <- router_sources do
      dir = Path.join([root, app, "lib", "#{app}_web"])
      File.mkdir_p!(dir)
      File.write!(Path.join(dir, "router.ex"), source)
      File.write!(Path.join([root, app, "mix.exs"]), "")

      endpoint = Map.get(endpoints, app) || if(app in seams, do: seam_endpoint(), else: nil)
      if endpoint, do: File.write!(Path.join(dir, "endpoint.ex"), endpoint)

      for {rel, extra_source} <- Map.get(extra, app, %{}) do
        path = Path.join([root, app, rel])
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, extra_source)
      end
    end

    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  # The child-process runner: the task's own documented invocation, from the project dir, in
  # the test env, with stderr folded in so a crash is visible in the assertion message.
  defp run_task(args) do
    System.cmd("mix", ["samen.verify.fleet_wire" | args],
      cd: @project_dir,
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )
  end

  # ONE standalone host: the root IS the app — its own `mix.exs` + `lib/`, named `vet` so
  # the discovered app name is `vet` — the shape `--root` unlocks and the monorepo
  # discovery (which globs `*/mix.exs` under a checkout root) can never produce.
  defp standalone_host_root(router_source) do
    parent = Path.join(System.tmp_dir!(), "refute_host_#{System.unique_integer([:positive])}")
    root = Path.join(parent, "vet")
    dir = Path.join(root, "lib/vet_web")
    File.mkdir_p!(dir)
    File.write!(Path.join(root, "mix.exs"), "")
    File.write!(Path.join(dir, "router.ex"), router_source)
    on_exit(fn -> File.rm_rf!(parent) end)
    root
  end

  # --- rule 3 fixtures: an org-session surface without/with the session plug -------------

  defp files_only_router do
    """
    defmodule VetWeb.Router do
      import Samen.Web.Router

      pipeline :browser do
        plug(:accepts, ["html"])
      end

      scope "/" do
        pipe_through(:browser)
        samen_files_routes(:files, Vet.Primitives, repo: Vet.Repo)
      end
    end
    """
  end

  # The counterpart in a DIFFERENT file of the same app (app-scoped, like rule 2's seam).
  defp session_plug_pipeline do
    """
    defmodule VetWeb.SessionPipeline do
      import Phoenix.Router

      pipeline :browser do
        plug(:fetch_session)
      end
    end
    """
  end

  # Anti-tautology: the source NAMES `fetch_session` — in a comment and as the PREFIX of a
  # different plug — and never wires it.
  defp comment_only_session_router do
    """
    defmodule VetWeb.Router do
      import Samen.Web.Router

      # The docs say to `plug :fetch_session` here. This comment is not a plug.
      pipeline :browser do
        plug(:fetch_session_lax)
      end

      scope "/" do
        pipe_through(:browser)
        samen_files_routes(:files, Vet.Primitives, repo: Vet.Repo)
      end
    end
    """
  end

  # --- rule 4 fixtures: a realtime mount and the supervision trees around it --------------

  defp chat_only_router do
    """
    defmodule VetWeb.Router do
      import Samen.Web.Router

      scope "/" do
        samen_chat_routes(:chat, Vet.Chat, repo: Vet.Repo, labels: %{pubsub: Vet.PubSub})
      end
    end
    """
  end

  defp notifications_only_router do
    """
    defmodule VetWeb.Router do
      import Samen.Web.Router

      scope "/" do
        samen_notifications_routes(:notifications, Vet.Primitives,
          repo: Vet.Repo,
          labels: %{pubsub: Vet.PubSub}
        )
      end
    end
    """
  end

  # The supervision tree the realtime macros' @docs ask for, parameterised by bus name: the
  # `:pubsub` label on the mount (`labels: %{pubsub: Vet.PubSub}` above) must MATCH it.
  defp pubsub_application(bus) do
    """
    defmodule Vet.Application do
      use Application

      def start(_type, _args) do
        children = [
          {Phoenix.PubSub, name: #{inspect(bus)}},
          {Samen.Web.Chat.Presence, pubsub_server: #{inspect(bus)}},
          VetWeb.Endpoint
        ]

        Supervisor.start_link(children, strategy: :one_for_one)
      end
    end
    """
  end

  # The bus, without chat's roster server.
  defp pubsub_only_application(bus) do
    """
    defmodule Vet.Application do
      use Application

      def start(_type, _args) do
        children = [{Phoenix.PubSub, name: #{inspect(bus)}}, VetWeb.Endpoint]
        Supervisor.start_link(children, strategy: :one_for_one)
      end
    end
    """
  end

  # A minimal VALID value for a declared field spec (mirrors the gate's own synthesiser,
  # independently written so the two cannot agree on a shared bug).
  defp probe_value(:number, opts) do
    case Keyword.get(opts, :range) do
      {lo, _hi} -> lo
      nil -> 0
    end
  end

  defp probe_value(:enum, opts) do
    case Keyword.get(opts, :allowed) do
      [first | _] -> Atom.to_string(first)
      _sentinel -> "zz_probe_label"
    end
  end

  defp probe_value(type, opts) when type in [:opaque_id, :token] do
    case Keyword.get(opts, :form) do
      {:hex, len} -> String.duplicate("a", len)
      {:uuid_v4} -> "11111111-1111-4111-8111-111111111111"
      nil -> ""
    end
  end
end
