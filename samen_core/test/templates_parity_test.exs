defmodule Samen.Gen.TemplatesParityTest do
  @moduledoc """
  BYTE-PARITY ORACLE for the `Samen.Gen.Templates` externalization refactor.

  The templated file set (`Samen.Gen.Templates.files/3`, piped through
  `Samen.Gen.App.render/2`) must be BYTE-FOR-BYTE identical before and after the emitter
  bodies are moved out of the god-file into `priv/templates/*.eex`. This test renders every
  emitted file for four representative configurations (headless, web, web+api,
  web+api+deploy) plus a `--modules` web variant (which exercises `home_live.ex` and the
  non-empty router mount seams), and asserts each rendered byte-string equals a frozen golden
  fixture captured from the PRE-refactor code.

  Golden fixtures live under `test/fixtures/templates_golden/<set>/<rendered_path>` and are
  committed with this test. To (re)capture them from the CURRENT code:

      SAMEN_UPDATE_GOLDEN=1 mix test test/templates_parity_test.exs

  The bindings are the REAL `Samen.Gen.App.bindings/1` of specs built via
  `Samen.Gen.App.build_spec/1` — which derives all abbrevs purely from the prefix and touches
  NEITHER the abbrev registry NOR the filesystem, so this test is hermetic and side-effect
  free. `target: Samen.Gen.App.default_target()` makes the `samen_core`/`samen_web` dep paths
  resolve to the stable `../samen_core` / `../samen_web`, so the golden is machine-independent.
  """
  use ExUnit.Case, async: true

  alias Samen.Gen.App
  alias Samen.Gen.Templates

  @golden_root Path.join([__DIR__, "fixtures", "templates_golden"])

  # The mountable `--modules` surfaces (mirrors `Samen.Gen.App`'s private @mountable_modules)
  # — used only to decide whether the `home_live.ex` menu landing rides, exactly as
  # `Samen.Gen.App.files/1` does.
  @mountable [:files, :search, :csv, :settings]

  # {set_label, build_spec opts}. Fixed module/prefix/abbrev so the golden is deterministic.
  defp specs do
    base = [module: "Acme", prefix: "ac", abbrev: "acm", target: App.default_target()]

    [
      {"headless", Keyword.merge(base, web: false, api: false)},
      {"web", Keyword.merge(base, web: true, api: false)},
      {"web_api", Keyword.merge(base, web: true, api: true)},
      {"web_api_deploy", Keyword.merge(base, web: true, api: true, deploy: true)},
      {"web_api_modules",
       Keyword.merge(base, web: true, api: true, modules: "files,search,csv,settings,chat")}
    ]
  end

  # Mirror of `Samen.Gen.App.files/1` (private): the base Templates set for the spec's
  # (web?, api?, deploy?), plus the `home_live.ex` landing IFF the web layer is on and at
  # least one mountable surface was selected.
  defp file_set(%App{web?: web?, api?: api?, deploy?: deploy?, modules: mods} = _s) do
    base = Templates.files(web?, api?, deploy?)

    if web? and Enum.any?(mods, &(&1 in @mountable)) do
      base ++ [{"lib/<%= otp_app %>_web/home_live.ex", Templates.home_live_ex()}]
    else
      base
    end
  end

  # %{set_label => %{rendered_path => rendered_content}} for the CURRENT code.
  defp render_all do
    for {label, opts} <- specs(), into: %{} do
      s = App.build_spec(opts)
      b = App.bindings(s)

      rendered =
        for {path_tmpl, content_tmpl} <- file_set(s), into: %{} do
          {App.render(path_tmpl, b), App.render(content_tmpl, b)}
        end

      {label, rendered}
    end
  end

  # Golden files carry a `.golden` suffix so ExUnit does NOT try to compile the emitted
  # `*_test.exs` fixtures (they `use Acme.DataCase`, which only exists in a generated app).
  defp golden_path(set, rel), do: Path.join([@golden_root, set, rel]) <> ".golden"

  defp write_golden(actual) do
    File.rm_rf!(@golden_root)

    for {set, files} <- actual, {rel, content} <- files do
      dest = golden_path(set, rel)
      File.mkdir_p!(Path.dirname(dest))
      File.write!(dest, content)
    end
  end

  test "every emitted file is byte-identical to the frozen golden fixture" do
    actual = render_all()

    if System.get_env("SAMEN_UPDATE_GOLDEN") == "1" do
      write_golden(actual)
      IO.puts("\n[golden captured] #{@golden_root}")
    end

    assert File.dir?(@golden_root),
           "golden fixtures missing — capture first with SAMEN_UPDATE_GOLDEN=1"

    # 1. Every rendered file matches its golden byte-for-byte.
    for {set, files} <- actual, {rel, content} <- files do
      gp = golden_path(set, rel)

      assert File.exists?(gp), "no golden fixture for #{set}/#{rel} (re-capture golden)"
      assert File.read!(gp) == content, "byte drift in #{set}/#{rel}"
    end

    # 2. Set parity: no golden file is orphaned (a removed/renamed emitter would leave one).
    actual_keys =
      for {set, files} <- actual, {rel, _} <- files, into: MapSet.new(), do: {set, rel}

    golden_keys =
      for path <- Path.wildcard(Path.join(@golden_root, "**/*.golden"), match_dot: true),
          File.regular?(path),
          into: MapSet.new() do
        rel = Path.relative_to(path, @golden_root)
        [set | rest] = Path.split(rel)
        {set, Path.join(rest) |> String.replace_suffix(".golden", "")}
      end

    assert MapSet.difference(golden_keys, actual_keys) |> MapSet.to_list() == [],
           "orphaned golden fixtures (an emitter was removed/renamed without re-capture)"
  end

  # STRICT TEMPLATE HYGIENE: no rendered artifact may leak an unreplaced `<%= … %>` token. The
  # bindings map is composed per-CONFIGURATION (`base` + `web_bindings/1`, merged only when
  # `web?`), so a token used by a template that a NON-web configuration renders leaks its raw
  # source instead of being substituted — e.g. the shared `ci_sh.eex` reachable from the headless
  # set. That is a shell syntax error at best and a silently skipped gate at worst, and it is
  # invisible to the byte-golden (which happily freezes the broken output). Checked on EVERY
  # rendered file of EVERY configuration, so adding a binding for one variant cannot quietly
  # strand the others.
  test "no rendered file leaks an unreplaced template token" do
    for {set, files} <- render_all(), {rel, content} <- files do
      refute content =~ "<%=",
             "#{set}/#{rel} contains an UNREPLACED template token — its binding is missing for " <>
               "this configuration, so the file would ship literal `<%= … %>` source"
    end
  end

  # SIDEBAR-REACHABILITY gate-parity guard: a generated host that THREADS a gated nav label must
  # also hold itself to the same dead-link gate the framework core and every reference vertical
  # run. Asserted on the RENDERED output (not the golden files), so a template edit that drops
  # the step fails HERE even after a golden re-capture. The pairing is the point: the step is
  # emitted iff the router threads a label, because `mix samen.verify.nav_links` refuses to
  # certify a label-less run vacuously (its `:empty_emit` leg) — a generated app can neither
  # claim the gate without a label, nor ship a label with no gate.
  test "every generated ci.sh that threads a gated nav label also runs samen.verify.nav_links" do
    rendered = render_all()

    for {set, files} <- rendered do
      ci = files["ci.sh"]
      router = files["lib/acme_web/router.ex"]

      assert is_binary(ci), "#{set} emitted no ci.sh"
      # Headless has no router at all (no web layer) — nothing to certify there.
      labelled = is_binary(router) and router =~ ~r/_path: "\/./

      if labelled do
        assert ci =~ "mix samen.verify.nav_links --router AcmeWeb.Router --host acme",
               "#{set}/ci.sh threads a gated nav label but does NOT run the SIDEBAR-REACHABILITY " <>
                 "gate — its sidebar could link a route its router never mounts."
      else
        refute ci =~ "mix samen.verify.nav_links",
               "#{set}/ci.sh runs the SIDEBAR-REACHABILITY gate but threads no gated nav " <>
                 "label — the verifier would report it as :empty_emit (a gate that certifies " <>
                 "nothing is a lie)."
      end
    end

    # Non-vacuous: the `--modules` set MUST be the labelled one, so this guard has a real
    # subject. (If it stopped threading labels, both branches above could pass trivially.)
    modules_set = rendered["web_api_modules"]
    assert modules_set["lib/acme_web/router.ex"] =~ ~s{files_path: "/files"}
    assert modules_set["ci.sh"] =~ "mix samen.verify.nav_links"
  end

  # A3 gate-parity guard (luminary pre-merge): EVERY generated app's ci.sh must run the B5
  # no_pan_columns sweep — the reference verticals (demo/driftwood/pawchart) all run it, and
  # before this guard the templates emitted a strictly WEAKER gate: a raw-DDL card_number
  # column that bypassed Ash was caught in driftwood and MISSED in an adopter's generated
  # app. Asserted on the RENDERED output (not the golden files) so a template edit that
  # drops the step fails HERE even after a golden re-capture — the leverage guarantee
  # ("generated apps get the reference verticals' enforcement") cannot silently regress.
  test "every generated ci.sh runs samen.verify.no_pan_columns (A3 gate parity with the reference verticals)" do
    for {set, files} <- render_all() do
      ci = files["ci.sh"]

      assert is_binary(ci), "#{set} emitted no ci.sh — the gate-parity guard has nothing to check"

      assert ci =~ "mix samen.verify.no_pan_columns",
             "#{set}/ci.sh is MISSING the B5 no_pan_columns step — a generated app would " <>
               "run a strictly weaker verifier gate than demo/driftwood/pawchart (the " <>
               "information_schema PAN sweep would never run in an adopter's CI)"
    end
  end

  # P17 / ADR-021 (mount-ledger Amendment 3) gate-parity guard: every generated WET ci.sh must
  # run the SILENT-EMPTY-FUNNEL verifier — the same gate samenerp's own ci.sh runs, the host
  # that shipped a mounted analytics reader with no producer and therefore a `/analytics` page
  # empty for every org forever. Asserted on the RENDERED output (not the golden files), so a
  # template edit that drops the step fails HERE even after a golden re-capture. The HEADLESS
  # set is the RED half: it has no web layer, so it can never mount the analytics reader.
  test "every generated web ci.sh runs samen.verify.analytics_producer (P17 gate parity)" do
    for {set, files} <- render_all() do
      ci = files["ci.sh"]
      router = files["lib/acme_web/router.ex"]

      assert is_binary(ci), "#{set} emitted no ci.sh"

      if is_binary(router) do
        assert ci =~ "mix samen.verify.analytics_producer",
               "#{set}/ci.sh emits a router but does NOT run the silent-empty-funnel gate — a " <>
                 "generated app that mounts `samen_tenant_analytics_routes` without a producer " <>
                 "would ship an empty-for-every-org /analytics page with nothing red."
      else
        refute ci =~ "samen.verify.analytics_producer",
               "#{set}/ci.sh runs the analytics-producer gate but has no web layer (no router) — " <>
                 "the headless set cannot mount the analytics reader, so the step is vacuous there."
      end
    end
  end

  # T60 framework-first guard: EVERY generated app's operator-mount migration must EMIT the
  # chat offline-escalation dedupe partial-unique index. This is stronger than the byte-golden
  # (which would silently accept a regenerated index-less golden): if a future template edit
  # drops the index and re-captures, THIS content assertion fails — so the leverage guarantee
  # (generated apps inherit the concurrent-double-escalation backstop) cannot silently regress.
  test "every generated operator-mount migration EMITS the chat-escalation dedupe partial-unique index (T60)" do
    goldens =
      Path.wildcard(Path.join(@golden_root, "*/priv/repo/migrations/*mount_operator_scopes.exs.golden"))

    assert goldens != [], "no operator-mount goldens found — regenerate with SAMEN_UPDATE_GOLDEN=1"

    for g <- goldens do
      src = File.read!(g)
      rel = Path.relative_to(g, @golden_root)

      assert src =~ ~r/create\(\s*unique_index\(:\w+_ticket, \[:\w+_org_id, :\w+_external_id\]/,
             "operator-mount golden #{rel} is MISSING the chat-escalation dedupe UNIQUE index"

      assert src =~ ~r/\w+_ticket_chat_dedupe_idx/,
             "operator-mount golden #{rel} is missing the dedupe index NAME"

      assert src =~ ~r/where: "\w+_external_id IS NOT NULL"/,
             "operator-mount golden #{rel} dedupe index is not PARTIAL (external_id IS NOT NULL)"
    end
  end

  # BORN-ARMED guard (the flood-guard analogue of the A3/T60 leverage assertions above): EVERY
  # generated WEB app must emit (a) the framework flood guard's `arm!()` line in
  # `test/test_helper.exs` and (b) the tripwire test that asserts it is armed AND biting — so a
  # generated vertical can never be BORN unarmed, and an unpinned flood written in an adopter's app
  # fails at the offending consultation instead of flaking. Asserted on the RENDERED output (not the
  # golden), so a template edit that drops either artifact fails HERE even after a golden
  # re-capture. The HEADLESS set is the RED half: it has no `samen_web` dep, so arming it could not
  # even resolve — it must emit NEITHER artifact (AC-G4-10).
  test "every generated web app is BORN ARMED (the test helper arm!() + its emitted tripwire)" do
    for {set, files} <- render_all() do
      helper = files["test/test_helper.exs"]
      tripwire = files["test/flood_guard_armed_test.exs"]

      assert is_binary(helper), "#{set} emitted no test/test_helper.exs"

      if String.starts_with?(set, "web") do
        assert helper =~ "Samen.Web.RateLimit.FloodGuard.arm!()",
               "#{set}/test_helper.exs does not ARM the framework flood guard — an unpinned " <>
                 "flood in a generated app would flake on a wall-clock window boundary instead " <>
                 "of failing at the offending consultation."

        assert is_binary(tripwire),
               "#{set} emitted no test/flood_guard_armed_test.exs — the emitted arming line " <>
                 "would have no tripwire, so losing it is silent."

        assert tripwire =~ "FloodGuard.armed?()"
        assert tripwire =~ "RateLimit.assert_flood_guard_armed!("
        assert tripwire =~ "use ExUnit.Case, async: false"
      else
        refute helper =~ "FloodGuard",
               "#{set}/test_helper.exs arms the flood guard, but the headless set has no " <>
                 "samen_web dep — the call could not even resolve (AC-G4-10 red path)."

        assert tripwire == nil,
               "#{set} emitted a flood-guard tripwire; the headless set must emit neither the " <>
                 "arming nor its tripwire."
      end
    end
  end

  # BORN-CLEAN guard (the temp-leak analogue of BORN ARMED above): EVERY generated app creates a
  # per-run KMS keystore under `System.tmp_dir!()` and points the vault at it, so every one must
  # also RELEASE it at exit. The leak this pins was measured, not hypothetical: the deploy probe
  # runs a generated app's suite, and because only the hosts carried the `at_exit` line, eight
  # `<otp_app>_keystore_test_*` directories — each holding a `master.key` — accumulated in `$TMPDIR`
  # between 2026-10-20 and 2026-10-27, one per generated-suite run, with nothing failing.
  #
  # Asserted on the RENDERED output (not the golden), so a template edit that drops the line fails
  # HERE even after a golden re-capture — which is exactly how the leak got in. The HEADLESS set is
  # held to the same standard: both templates mint the dir, so both must release it.
  test "every generated app RELEASES its per-run keystore dir at exit (no $TMPDIR accumulation)" do
    for {set, files} <- render_all() do
      helper = files["test/test_helper.exs"]

      assert is_binary(helper), "#{set} emitted no test/test_helper.exs"

      assert helper =~ "System.at_exit(fn _ -> File.rm_rf!(kms_key_dir) end)",
             "#{set}/test_helper.exs never removes its per-run KMS keystore dir at exit — every " <>
               "suite run leaves `#{set}_keystore_test_*` (containing `master.key`) in $TMPDIR " <>
               "forever, and nothing fails while it accumulates."
    end
  end
end
