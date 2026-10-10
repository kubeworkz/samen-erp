defmodule Samen.Web.NavLinksVerifierTest do
  @moduledoc """
  `mix samen.verify.nav_links` — the SIDEBAR-REACHABILITY build gate.

  Green + red + anti-tautology at the GATE level (not only the component level):

    * GREEN — the framework's reference host fixture (`Samen.WebTest.NavLinksHost.Router`, the
      router `samen_web/ci.sh` certifies) passes, and it really mounts every gated group, so the
      framework's own leg cannot pass by certifying nothing.
    * RED — a label that drifts from its route macro (the PP-8/PP-9 rot this task exists for)
      fails, an unlabelled mount fails, an unresolvable `labels:` expression fails, a tree with no
      mount at all fails, an unparseable source file fails, and a missing `--source-dir` fails.
      Each red case is paired with the POSITIVE CONTROL that must stay clean, so no assertion here
      can pass vacuously.
    * EXIT CODE — one child process runs the real command, because `:erlang.halt(1)` cannot be
      observed from inside the test VM.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.Samen.Verify.NavLinks

  @router Samen.WebTest.NavLinksHost.Router
  @fixture_dir "test/support/nav_links_host"

  # The project dir the child process runs `mix` from — the task's documented invocation.
  @project_dir Path.expand("../../../", __DIR__)

  describe "GREEN — the framework's reference host" do
    test "the full-mount fixture certifies clean" do
      assert NavLinks.check(@router, source_dirs: [@fixture_dir], app: "samen_web") == []
    end

    test "anti-vacuity: the fixture really mounts every gated group, so its clean run proves the leg ran" do
      {:ok, calls} =
        NavLinks.mount_calls(Samen.SourceGlob.expand!(@fixture_dir))

      tenant_kinds =
        calls |> Enum.filter(&(&1.plane == :tenant)) |> Enum.map(& &1.kind) |> MapSet.new()

      for kind <- ~w(erp banking work files chat search analytics ics ai flags automation)a do
        assert MapSet.member?(tenant_kinds, kind),
               "the reference host does not mount :#{kind}, so the framework's own nav-links leg " <>
                 "would not exercise it"
      end

      labelled =
        calls
        |> Enum.filter(&(&1.plane == :tenant))
        |> Enum.flat_map(&Map.keys(&1.labels))

      # 11 gated path labels (the `authn` MFA is a label too, but it resolves to :__unresolved__
      # and is dropped, exactly as a host's non-path labels are).
      assert length(Enum.uniq(labelled)) >= 11,
             "the fixture carries too few labels to certify the gated groups"
    end

    test "the fixture's compiled route table serves the links its labels emit (the resolver is refutable)" do
      assert_route("/chat")
      assert_route("/calendar.ics")
      refute_route("/conversations")
    end
  end

  describe "RED — a label drifting from its route macro" do
    test "fails, and the failure names the href, the label and its source line" do
      dir = tree!(mounts(labels: %{chat_path: "/conversations"}))

      assert [violation] = NavLinks.check(@router, source_dirs: [dir], app: "test")
      assert violation.kind == :dead_link
      assert violation.message =~ "/conversations"
      assert violation.message =~ "chat_path"
      assert violation.message =~ "router.ex:"
      assert violation.message =~ "no matching GET route"
    end

    test "positive control: the same tree with the matching label certifies clean" do
      dir = tree!(mounts(labels: %{chat_path: "/chat"}))

      assert NavLinks.check(@router, source_dirs: [dir], app: "test") == []
    end
  end

  describe "RED — a mounted gated module with no nav label (a nav island)" do
    test "fails, and tells the host exactly which label to add" do
      dir = tree!(mounts(labels: %{chat_path: "/chat"}) <> files_mount_unlabelled())

      assert [violation] = NavLinks.check(@router, source_dirs: [dir], app: "test")
      assert violation.kind == :unlabelled_mount
      assert violation.message =~ ":files"
      assert violation.message =~ "files_path"
      assert violation.message =~ "hand-typing"
    end

    test "GREEN — the host can declare the island deliberate with allow_unlabelled" do
      dir = tree!(mounts(labels: %{chat_path: "/chat"}) <> files_mount_unlabelled())

      assert NavLinks.check(@router,
               source_dirs: [dir],
               app: "test",
               allow_unlabelled: [:files]
             ) == []
    end

    test "RED — a gated label that is not a path string is reported (module_nav would raise interpolating it)" do
      dir = tree!(mounts(labels: %{chat_path: "/chat"}) <> files_mount_bad_label())

      assert [violation] = NavLinks.check(@router, source_dirs: [dir], app: "test")
      assert violation.kind == :labels
      assert violation.message =~ "files_path = 42"
    end
  end

  describe "RED — mounts the verifier cannot reason about are failures, never skips" do
    test "an unresolvable labels expression" do
      dir = tree!(mounts(labels: "@labels_expr", extra_attr: "@labels_expr = compute()"))

      assert [violation] = NavLinks.check(@router, source_dirs: [dir], app: "test")
      assert violation.kind == :unresolved
      assert violation.message =~ ":labels expression"
    end

    test "a gated path label whose value is not a literal" do
      dir =
        tree!(
          mounts(labels: "@labels_expr",
            extra_attr: "@labels_expr = %{chat_path: System.tmp_dir!()}"
          )
        )

      assert [violation] = NavLinks.check(@router, source_dirs: [dir], app: "test")
      assert violation.kind == :unresolved
      assert violation.message =~ "gated path label"
    end

    test "a source tree with no mount call at all (the vacuous run)" do
      dir = tree!("  def nothing, do: :ok\n")

      assert [violation] = NavLinks.check(@router, source_dirs: [dir], app: "test")
      assert violation.kind == :scan
    end

    test "an unparseable source file" do
      dir = tree!("  def broken(, do: :ok\n")

      assert [violation] = NavLinks.check(@router, source_dirs: [dir], app: "test")
      assert violation.kind == :source
      assert violation.message =~ "could not parse"
    end

    test "a missing source dir (refusing to certify a tree it cannot read)" do
      assert [violation] =
               NavLinks.check(@router, source_dirs: ["test/support/no_such_dir"], app: "test")

      assert violation.kind == :source
      assert violation.message =~ "not found"
    end

    test "an unloadable router" do
      assert [violation] = NavLinks.check(No.Such.Router, app: "test")
      assert violation.kind == :router
      assert violation.message =~ "could not load"
    end
  end

  describe "the CLI is fail-closed" do
    test "the real command exits 0 on the fixture and prints the pass banner" do
      {out, status} =
        run_task(["--router", "Samen.WebTest.NavLinksHost.Router", "--host", "samen_web", "--source-dir", @fixture_dir])

      assert status == 0, "expected a clean exit, got #{status}:\n#{out}"
      assert out =~ "samen.verify.nav_links: OK"
    end

    test "the real command exits 1 with a machine-readable document on a drifted label" do
      dir = tree!(mounts(labels: %{chat_path: "/gone"}))

      {out, status} =
        run_task(["--router", "Samen.WebTest.NavLinksHost.Router", "--format", "json", "--source-dir", dir])

      assert status == 1, "expected exit 1, got #{status}:\n#{out}"

      document =
        out
        |> String.split("\n")
        |> Enum.reject(&(&1 == ""))
        |> List.last()
        |> Jason.decode!()
      assert document["status"] == "fail"
      assert document["task"] == "samen.verify.nav_links"
      assert [violation] = document["violations"]
      assert violation["kind"] == "dead_link"
    end

    test "an unrecognized argument is refused rather than ignored" do
      dir = tree!(mounts(labels: %{chat_path: "/chat"}))

      {out, status} =
        run_task(["--router", "Samen.WebTest.NavLinksHost.Router", "--source-dir", dir, "--rrot", "x"])

      assert status == 1, "expected exit 1, got #{status}:\n#{out}"
      assert out =~ "unrecognized argument"
    end

    test "an unsupported --format is refused rather than silently served prose" do
      {out, status} = run_task(["--router", "Samen.WebTest.NavLinksHost.Router", "--format", "yaml"])

      assert status == 1, "expected exit 1, got #{status}:\n#{out}"
      assert out =~ "--format"
      assert out =~ "not supported"
    end

    test "a missing --router is refused rather than certifying some default tree" do
      {out, status} = run_task([])

      assert status == 1, "expected exit 1, got #{status}:\n#{out}"
      assert out =~ "--router MODULE is required"
    end
  end

  # ---- helpers ------------------------------------------------------------------------------

  # A tmp source tree holding one module. `SourceGlob` normalizes Windows separators, so the
  # natively-joined `System.tmp_dir!()` path scans correctly on every platform.
  defp tree!(body) do
    dir = Path.join(System.tmp_dir!(), "nav_links_#{System.unique_integer([:positive])}")
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "router.ex"), "defmodule NavLinksTmp.Router do\n" <> body <> "end\n")
    on_exit(fn -> File.rm_rf!(dir) end)
    dir
  end

  # A minimal tenant mount tree: one gated module with an `@labels` attribute (or an inline map),
  # so each test can state exactly one defect.
  defp mounts(opts) do
    labels = opts |> Keyword.fetch!(:labels) |> source_literal()
    extra_attr = Keyword.get(opts, :extra_attr, "")

    """
      #{extra_attr}
      @labels #{labels}

      def r do
        samen_chat_routes(:chat, Samen.WebTest.Chat, repo: Samen.WebTest.Repo, labels: @labels)
      end
    """
  end

  # A source literal: a string is already Elixir source (`"@labels_expr"`), anything else is
  # rendered with `inspect/1` (a map or a bare number).
  defp source_literal(value) when is_binary(value), do: value
  defp source_literal(value), do: inspect(value)

  # A tenant :files mount with NO path label — the nav island leg 2 exists for.
  defp files_mount_unlabelled do
    """
      def files do
        samen_files_routes(:files, Samen.WebTest.Primitives,
          repo: Samen.WebTest.Repo,
          labels: %{title: "No path label here"}
        )
      end
    """
  end

  # A tenant :files mount whose gated label is a literal that is not a path string.
  defp files_mount_bad_label do
    """
      def files do
        samen_files_routes(:files, Samen.WebTest.Primitives,
          repo: Samen.WebTest.Repo,
          labels: %{files_path: 42}
        )
      end
    """
  end

  defp assert_route(path) do
    assert Enum.any?(@router.__routes__(), &(&1.path == path)),
           "the reference host does not declare #{path}, so the fixture cannot certify it"
  end

  defp refute_route(path) do
    refute Enum.any?(@router.__routes__(), &(&1.path == path)),
           "#{path} IS declared — the dead-link cases in this suite would not be refutable"
  end

  defp run_task(args) do
    System.cmd("mix", ["samen.verify.nav_links" | args],
      cd: @project_dir,
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )
  end
end
