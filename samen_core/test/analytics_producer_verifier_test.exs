defmodule Mix.Tasks.Samen.Verify.AnalyticsProducerTest do
  @moduledoc """
  `mix samen.verify.analytics_producer` — the silent-empty-funnel build gate.

  GREEN: an app that mounts the own-org analytics reader AND configures both producer
  links is clean. RED: either link missing is one named violation, attributed to the app
  and the link (`rule: :product_event_emitter` / `:product_event_rollup`). ANTI-VACUITY:
  the walker is asserted to have actually SEEN a mount (the macro's own definition and its
  `@doc` example must NOT read as one), and an empty tree FAILS rather than passing quietly.
  """
  use ExUnit.Case, async: true

  alias Mix.Tasks.Samen.Verify.AnalyticsProducer, as: V

  @repo_root Path.expand("../..", __DIR__)

  # ---------------------------------------------------------------------------
  # scratch trees
  # ---------------------------------------------------------------------------

  defp tree!(apps) do
    root = Path.join(System.tmp_dir!(), "apv_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)

    for {app, files} <- apps do
      for {rel, content} <- files do
        path = Path.join([root, to_string(app), rel])
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, content)
      end
    end

    root
  end

  defp mix_exs(app) do
    """
    defmodule #{Macro.camelize(app)}.MixProject do
      def project, do: [app: :#{app}, version: "0.0.0"]
    end
    """
  end

  defp mount_router, do: "samen_tenant_analytics_routes(Widgets.Primitives, repo: Widgets.Repo)"

  # `:mount?` / `:emitter?` / `:rollup?` select which pieces land in the app's files.
  defp app_files(app, opts \\ []) do
    mount? = Keyword.get(opts, :mount?, true)
    emitter? = Keyword.get(opts, :emitter?, true)
    rollup? = Keyword.get(opts, :rollup?, true)

    emitter_line =
      if emitter? do
        ["config :samen_core, Samen.Analytics, product_event_resource: " <>
           "#{Macro.camelize(app)}.Analytics.ProductEvent\n"]
      else
        []
      end

    rollup_line =
      if rollup? do
        [
          "config :samen_core, :rollups, [%{name: :product_event_rollup, " <>
            "source: :domain, table: \"paf_product_event_rollup\"}]\n"
        ]
      else
        []
      end

    config = ["import Config\n"] ++ emitter_line ++ rollup_line

    router =
      if mount? do
        """
        defmodule #{Macro.camelize(app)}Web.Router do
          import Samen.Web.Router

          def routes do
            #{mount_router()}
          end
        end
        """
      else
        """
        defmodule #{Macro.camelize(app)}Web.Router do
          import Samen.Web.Router

          def routes do
          end
        end
        """
      end

    %{
      "mix.exs" => mix_exs(app),
      "config/config.exs" => Enum.join(config),
      "lib/#{app}_web/router.ex" => router
    }
  end

  defp records(root, app \\ "widgets") do
    V.violation_records(root: root)
    |> Enum.filter(&(&1[:app] == app))
  end

  # ---------------------------------------------------------------------------
  # GREEN
  # ---------------------------------------------------------------------------

  test "GREEN: a mounted reader with BOTH producer links configured is clean" do
    root = tree!(widgets: app_files("widgets"))

    assert V.violations(root: root) == []
    assert V.violation_records(root: root) == []

    # Non-vacuity: the walker actually SAW the mount and the two settings.
    [scan] = V.scan(root: root).apps
    assert scan.reader_mount != []
    assert scan.lib_files >= 1
    assert scan.emitter
    assert scan.rollup
  end

  # ---------------------------------------------------------------------------
  # RED — each link, separately (so re-breaking one fails with a NAMED reason)
  # ---------------------------------------------------------------------------

  test "RED (emitter): reader mounted, no product_event_resource is one violation" do
    root = tree!(widgets: app_files("widgets", emitter?: false))

    assert [record] = records(root)
    assert record.kind == :missing_producer
    assert record.rule == :product_event_emitter
    assert record.app == "widgets"
    assert record.message =~ "router.ex"
    assert record.message =~ "product_event_resource"
  end

  test "RED (rollup): emitter present, no :product_event_rollup spec is one violation" do
    root = tree!(widgets: app_files("widgets", rollup?: false))

    assert [record] = records(root)
    assert record.kind == :missing_producer
    assert record.rule == :product_event_rollup
    assert record.message =~ ":product_event_rollup"
  end

  test "RED (both): each missing link is its OWN violation" do
    root = tree!(widgets: app_files("widgets", emitter?: false, rollup?: false))

    assert records(root) |> Enum.map(& &1.rule) |> Enum.sort() ==
             [:product_event_emitter, :product_event_rollup]
  end

  test "a producer with NO reader mount owes nothing — the obligation is one-directional" do
    root = tree!(widgets: app_files("widgets", mount?: false, emitter?: false, rollup?: false))

    assert V.violations(root: root) == []
  end

  # ---------------------------------------------------------------------------
  # ANTI-VACUITY — the mount signal is the CALL, not the definition or the docs
  # ---------------------------------------------------------------------------

  test "the macro's own definition + @doc example never read as a mount" do
    root = Path.join(@repo_root, "samen_web")

    [scan] = V.scan(root: root).apps

    assert scan.lib_files > 50, "expected the samen_web lib walk to be non-vacuous"
    assert scan.reader_mount == [],
           "samen_web ships the samen_tenant_analytics_routes/2 DEFINITION (and a @doc " <>
             "example) — neither is a mount, so its shipped lib/ mounts no reader"
  end

  test "the real monorepo tree satisfies its own gate (samenerp's mount is seen + fed)" do
    widgets = Path.join(@repo_root, "samenerp")
    [scan] = V.scan(root: widgets).apps

    assert scan.reader_mount != [],
           "expected samenerp's shipped router to mount the own-org analytics reader — the " <>
             "walk went vacuous (a glob that matches nothing must never read as no violation)"

    assert scan.emitter and scan.rollup

    # The whole tree is green — every host that mounts a reader feeds it.
    assert V.violations(root: @repo_root) == []
  end

  # ---------------------------------------------------------------------------
  # FAIL-CLOSED — an unwalkable or empty tree certifies nothing
  # ---------------------------------------------------------------------------

  test "an explicit --root that is not a directory is :bad_root, never a skip" do
    missing = Path.join(System.tmp_dir!(), "apv_missing_#{System.unique_integer([:positive])}")

    assert [%{kind: :bad_root}] = V.violation_records(root: missing)
  end

  test "an explicit --root that discovers no app is :empty_discovery, never a pass" do
    empty = Path.join(System.tmp_dir!(), "apv_empty_#{System.unique_integer([:positive])}")
    File.mkdir_p!(empty)
    on_exit(fn -> File.rm_rf!(empty) end)

    assert [%{kind: :empty_discovery}] = V.violation_records(root: empty)
  end

  # ---------------------------------------------------------------------------
  # CLI — fail-closed switches + the exit code
  # ---------------------------------------------------------------------------

  test "unknown switches and a bad --format are violations (a mistyped run never exits 0)" do
    assert V.cli_opts(["--root", "/tmp"])[:root] == "/tmp"
    assert V.cli_opts(["--format", "json"])[:format] == "json"
    # A value-less switch the parser could not place is reported, not ignored.
    assert V.cli_invalid(["--rrot"]) != []
  end

  test "END TO END: a red tree exits 1 and prints its JSON report" do
    root = tree!(widgets: app_files("widgets", emitter?: false, rollup?: false))

    {output, status} =
      System.cmd(
        "mix",
        ["samen.verify.analytics_producer", "--root", root, "--format", "json"],
        cd: Path.join(@repo_root, "samen_core"),
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 1, "expected a failing exit — got #{status}:\n#{output}"

    document =
      output
      |> String.split("\n", trim: true)
      |> Enum.reverse()
      |> Enum.find_value(fn line ->
        case Jason.decode(String.trim(line)) do
          {:ok, %{"task" => _} = doc} -> doc
          _ -> nil
        end
      end)

    assert document, "no JSON report on stdout:\n#{output}"
    assert document["task"] == "samen.verify.analytics_producer"
    assert document["status"] == "fail"
    assert document["violation_count"] == 2
  end
end
