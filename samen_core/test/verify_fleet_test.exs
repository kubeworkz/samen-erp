defmodule Samen.VerifyFleetTest do
  @moduledoc """
  `mix samen.verify.fleet` — the tree-scoped aggregate.

  Three layers, the house shape:

    * **pure** — `aggregate/2`, `last_document/1` and `error_document/2` are asserted
      directly, so the roll-up a dashboard keys on is testable without spawning anything;
    * **seam** — `run/2` with an injected `:runner` proves every registry member is pointed at
      the tree and that verdicts (including an unevaluable member) fold into the document;
    * **acceptance** — the REAL command in a child OS process, so the exit code and the stdout
      are observed through the interface a CI job uses, not through the task function.
  """

  use ExUnit.Case, async: false

  alias Samen.Verifier.{Fleet, Registry}

  # The acceptance tests run the real command from here (`mix …`), the only way to observe
  # `:erlang.halt(1)` without taking the test VM with it.
  @project_dir Path.expand("../", __DIR__)

  # --------------------------------------------------------------- the roster

  describe "Samen.Verifier.Registry: the tree-scoped roster" do
    test "names exactly the source-tree-walking verifiers, each with a scope and a tree argv" do
      assert Registry.tasks() == [
               "samen.verify.agent_coverage",
               "samen.verify.fleet_wire",
               "samen.verify.pii_reads",
               "samen.verify.never_read_current"
             ]

      for entry <- Registry.tree_scoped() do
        assert is_binary(entry.scope) and entry.scope != ""
        assert entry.tree_args in [:root, :source_dirs]
        assert Mix.Task.get(entry.task), "#{entry.task} is registered but is not a real task"
      end
    end

    test "argv: `:root` members get `--root`; `:source_dirs` members get the discovered lib dirs" do
      root = scratch_root()
      File.mkdir_p!(Path.join(root, "app/lib"))
      File.mkdir_p!(Path.join(root, "other/lib"))

      ac = Registry.entry("samen.verify.agent_coverage")
      fw = Registry.entry("samen.verify.fleet_wire")
      assert Registry.tree_args(ac, root) == ["--root", root]
      assert Registry.tree_args(fw, root) == ["--root", root]

      pr = Registry.entry("samen.verify.pii_reads")
      assert ["--source-dirs" | dirs] = Registry.tree_args(pr, root)

      assert Enum.sort(dirs) ==
               Enum.sort([Path.join(root, "app/lib"), Path.join(root, "other/lib")])
    end

    test "source_lib_dirs: a root that IS an app yields its own lib/ (no glob)" do
      root = scratch_root()
      File.mkdir_p!(Path.join(root, "lib"))
      assert Registry.source_lib_dirs(root) == [Path.join(root, "lib")]
    end
  end

  # --------------------------------------------------------------- the roll-up

  describe "Samen.Verifier.Fleet.aggregate/2 (pure)" do
    test "all members OK ⇒ ok, with the totals a consumer reads" do
      docs = [doc("a", []), doc("b", [])]

      assert Fleet.aggregate("/tree", docs) == %{
               "task" => "samen.verify.fleet",
               "root" => "/tree",
               "status" => "ok",
               "verifier_count" => 2,
               "failed_count" => 0,
               "violation_count" => 0,
               "verifiers" => docs
             }
    end

    test "ONE failing member makes the whole fleet fail, and the totals count the blast radius" do
      docs = [doc("a", []), doc("b", ["x", "y"])]

      aggregate = Fleet.aggregate("/tree", docs)

      assert aggregate["status"] == "fail"
      assert aggregate["failed_count"] == 1
      assert aggregate["violation_count"] == 2
      assert aggregate["verifier_count"] == 2
    end

    test "anti-vacuity: an EMPTY roster is fail — an aggregate over nothing certifies nothing" do
      aggregate = Fleet.aggregate("/tree", [])

      assert aggregate["status"] == "fail"
      assert aggregate["verifier_count"] == 0
      assert aggregate["verifiers"] == []
    end
  end

  describe "Samen.Verifier.Fleet.run/2 (injected runner)" do
    test "points every member at the tree and folds the verdicts" do
      parent = self()
      root = scratch_root()
      File.mkdir_p!(Path.join(root, "app/lib"))

      runner = fn entry, expanded_root, _opts ->
        send(parent, {:ran, entry.task, expanded_root, Registry.tree_args(entry, expanded_root)})
        {:ok, doc(entry.task, [])}
      end

      aggregate = Fleet.run(root, runner: runner)

      assert aggregate["status"] == "ok"
      assert aggregate["verifier_count"] == length(Registry.tasks())

      for task <- Registry.tasks() do
        assert_received {:ran, ^task, ^root, args}
        # every member is actually pointed at the tree it was given
        assert Enum.member?(args, root) or Enum.any?(args, &String.starts_with?(&1, root))
      end
    end

    test "an UNEVALUABLE member is a runner_error and fails the fleet (fail-closed)" do
      root = scratch_root()

      runner = fn entry, _root, _opts ->
        if entry.task == "samen.verify.pii_reads" do
          {:error, "exit 1, no JSON report on stdout"}
        else
          {:ok, doc(entry.task, [])}
        end
      end

      aggregate = Fleet.run(root, runner: runner)

      assert aggregate["status"] == "fail"
      assert aggregate["failed_count"] == 1

      [failed] = Enum.filter(aggregate["verifiers"], &(&1["status"] == "fail"))
      assert failed["task"] == "samen.verify.pii_reads"

      assert [%{"kind" => "runner_error", "message" => message}] = failed["violations"]
      assert message =~ "samen.verify.pii_reads"
      assert message =~ "no JSON report"
    end
  end

  describe "Samen.Verifier.Fleet.last_document/1" do
    test "reads the LAST document, past the advisory prose several verifiers print" do
      output =
        "samen.verify.pii_reads: 2 laundered-flow advisories (NOT failures)\n" <>
          "not json at all\n" <>
          "{\"task\":\"a\",\"status\":\"ok\",\"violation_count\":0,\"violations\":[]}\n" <>
          "{\"task\":\"b\",\"status\":\"fail\",\"violation_count\":1,\"violations\":[]}\n"

      assert {:ok, %{"task" => "b"}} = Fleet.last_document(output)
    end

    test "a JSON value without a `task` key is not a report" do
      assert :error = Fleet.last_document("[1,2,3]\n\"just a string\"\n")
      assert :error = Fleet.last_document("")
    end

    test "error_document/2 carries the SAME four-key schema as a reported violation" do
      document =
        Fleet.error_document(%{task: "samen.verify.pii_reads"}, "exit 1, no JSON report")

      assert document["task"] == "samen.verify.pii_reads"
      assert document["status"] == "fail"
      assert document["violation_count"] == 1

      assert [violation] = document["violations"]
      assert Enum.sort(Map.keys(violation)) == ["app", "kind", "message", "rule"]
      assert violation["kind"] == "runner_error"
    end
  end

  # --------------------------------------------------------------- acceptance

  describe "mix samen.verify.fleet ACCEPTANCE (child process)" do
    test "a malformed invocation exits 1 WITHOUT running the roster" do
      {bad_format, code} = run_fleet(["--format", "xml"])

      assert code != 0
      assert bad_format =~ ~s(--format "xml" is not supported)

      {bad_switch, code} = run_fleet(["--rrot", "/tmp"])

      assert code != 0
      assert bad_switch =~ "unrecognized argument --rrot"
    end

    test "a root that is not a directory is refused (a tree that cannot be walked certifies nothing)" do
      missing =
        Path.join(System.tmp_dir!(), "fleet_missing_#{System.unique_integer([:positive])}")

      {output, code} = run_fleet(["--format", "json", "--root", missing])

      assert code != 0

      document = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
      assert document["status"] == "fail"
      assert [%{"kind" => "bad_root", "message" => message}] = document["violations"]
      assert message =~ "not a directory"
    end

    test "the whole roster over THIS project: ONE JSON document, status ok, exits 0" do
      {output, code} = run_fleet(["--format", "json", "--root", @project_dir])

      assert code == 0

      document = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()

      assert document["task"] == "samen.verify.fleet"

      assert document["status"] == "ok",
             "the real fleet must be green over its own project: #{output}"

      assert document["verifier_count"] == length(Registry.tasks())
      assert document["failed_count"] == 0
      assert Enum.map(document["verifiers"], & &1["task"]) == Registry.tasks()
      assert Enum.all?(document["verifiers"], &(&1["status"] == "ok"))
    end

    test "a tree with a violation flips the aggregate to fail and exits 1" do
      # A single-app scratch tree whose lib/ carries NO `use Samen.AI.Agent` module: the
      # non-vacuity floor MUST fire, so the run is a real red through the real command.
      root = scratch_root()
      File.mkdir_p!(Path.join(root, "app/lib"))
      File.write!(Path.join(root, "app/lib/thing.ex"), "defmodule Thing do\nend\n")

      {output, code} = run_fleet(["--format", "json", "--root", root])

      assert code != 0

      document = output |> String.split("\n", trim: true) |> List.last() |> Jason.decode!()
      assert document["status"] == "fail"
      assert document["failed_count"] >= 1

      failed = Enum.filter(document["verifiers"], &(&1["status"] == "fail"))
      assert Enum.any?(failed, &(&1["task"] == "samen.verify.agent_coverage"))
      assert Enum.all?(failed, &(&1["violation_count"] > 0))
    end
  end

  # --------------------------------------------------------------- helpers

  defp doc(task, violations) do
    Samen.Verifier.document(task, violations)
  end

  defp scratch_root do
    # EXPANDED, so it is byte-identical to what `Fleet.run/2` hands the runner (`Path.expand/1`
    # normalizes `System.tmp_dir!()`'s backslashes to forward slashes on Windows).
    root =
      System.tmp_dir!()
      |> Path.join("fleet_#{System.unique_integer([:positive])}")
      |> Path.expand()

    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    root
  end

  defp run_fleet(args) do
    System.cmd("mix", ["samen.verify.fleet" | args],
      cd: @project_dir,
      env: [{"MIX_ENV", "test"}],
      stderr_to_stdout: true
    )
  end
end
