defmodule Mix.Tasks.Samen.Verify.DbBootTest do
  @moduledoc """
  `mix samen.verify.db_boot` — the tolerant-boot gate.

  GREEN: the real monorepo (every emitted template + golden, every vertical probe/`ci_bootstrap`,
  every host `test_helper.exs` and `test/support/` harness) routes its boot through
  `Samen.TestDb`, and the walk is asserted NON-VACUOUS (it actually saw those harnesses). RED:
  a hand-rolled `Ecto.Adapters.Postgres.storage_up/1` is caught even when the filename is not a
  known harness, and a known harness that never CALLS the helper is caught even when a comment
  explains the rule. ANTI-VACUITY: a tree with no harness file FAILS rather than passing
  quietly, and the exit code is observed through the real command.
  """

  use ExUnit.Case, async: true

  alias Mix.Tasks.Samen.Verify.DbBoot, as: V

  @repo_root Path.expand("../..", __DIR__)
  @project_dir Path.expand("../", __DIR__)

  # ---------------------------------------------------------------------------
  # scratch trees
  # ---------------------------------------------------------------------------

  defp tree!(apps) do
    root = Path.join(System.tmp_dir!(), "dbt_#{System.unique_integer([:positive])}")
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

  # The hand-rolled boot this gate retires, on its own line so `path:line` is assertable.
  defp raw_storage_boot do
    """
    defmodule Boot do
      def go(repo) do
        :ok = Ecto.Adapters.Postgres.storage_up(repo.config())
      end
    end
    """
  end

  defp compliant_helper do
    """
    defmodule Boot do
      def go(repo) do
        Samen.TestDb.boot!(repo)
      end
    end
    """
  end

  defp records(root) do
    V.violation_records(root: root)
  end

  # ---------------------------------------------------------------------------
  # GREEN — the real tree, non-vacuously
  # ---------------------------------------------------------------------------

  # The two real-tree proofs below walk the WHOLE checkout (5 apps' `priv/` probes and
  # templates, every `test/support/` harness, every golden) — pure filesystem I/O with a warm
  # cost of ~6 s, but >10x that on a memory-starved host, which killed this at the 60 s default
  # under the root gate's concurrent tiers (2026-10-24: stuck in `File.regular?`, 872 MB free
  # of 7.9 GB, inside the same window as `DROP DATABASE … command timed out`). The work is
  # correct and the walk is bounded; only the clock was wrong, so these carry an explicit budget
  # instead of inheriting the default. A genuine hang still fails — later, and once.
  @monorepo_walk_timeout 180_000

  @tag timeout: @monorepo_walk_timeout
  test "GREEN: the real monorepo satisfies its own gate, and the walk is NOT vacuous" do
    scan = V.scan(root: @repo_root)

    apps = Enum.map(scan.apps, & &1.app)
    assert "samen_core" in apps
    assert "pawchart" in apps
    assert "samenerp" in apps
    assert "driftwood" in apps

    # The witness: the templates, their goldens, the vertical probes/bootstraps and the host
    # test helpers were all actually SEEN. A glob that matched nothing would read as green.
    assert scan.harness_count >= 15,
           "expected the walk to find the emitted templates + goldens + probes + host helpers, " <>
             "found #{scan.harness_count}"

    assert V.violation_records(root: @repo_root) == []
  end

  # Spawns a whole second `mix` VM over the same tree, so it is strictly heavier than the walk
  # above and shares its budget for the same reason.
  @tag timeout: @monorepo_walk_timeout
  test "END TO END (green): the real tree exits 0 through the task" do
    {output, status} =
      System.cmd(
        "mix",
        ["samen.verify.db_boot", "--root", @repo_root, "--format", "json"],
        cd: @project_dir,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 0, "expected exit 0 over the real tree — got #{status}:\n#{output}"

    document = last_document!(output)
    assert document["task"] == "samen.verify.db_boot"
    assert document["status"] == "ok"
    assert document["violation_count"] == 0
  end

  # ---------------------------------------------------------------------------
  # RED — rule 1: the raw adapter boot, whatever the file is called
  # ---------------------------------------------------------------------------

  test "RED (test/support): a hand-rolled storage_up is caught even when the name is not a harness" do
    root =
      tree!(
        widgets: %{
          "mix.exs" => mix_exs("widgets"),
          "test/support/boot.ex" => raw_storage_boot()
        }
      )

    assert [record] = records(root)
    assert record.kind == :raw_storage_boot
    assert record.rule == :shared_helper
    assert record.app == "widgets"
    assert record.message =~ "test/support/boot.ex:3"
    assert record.message =~ "Samen.TestDb.boot!/2"
  end

  test "RED (priv probe): the raw boot is caught in a probe too, and reported once per file" do
    root =
      tree!(
        widgets: %{
          "mix.exs" => mix_exs("widgets"),
          "priv/ci_bootstrap.exs" => raw_storage_boot()
        }
      )

    assert [record] = records(root)
    assert record.kind == :raw_storage_boot
  end

  # ---------------------------------------------------------------------------
  # RED — rule 2: a known harness that never CALLS the helper
  # ---------------------------------------------------------------------------

  test "RED (emitted harness): a ci_bootstrap that never calls the helper is caught" do
    hand_rolled = """
    alias Widgets.Repo

    # A hard `:ok = storage_up(...)` used to crash here.
    {:ok, _} = Repo.start_link()
    Ecto.Migrator.run(Repo, :up, all: true)
    """

    root =
      tree!(
        widgets: %{
          "mix.exs" => mix_exs("widgets"),
          "priv/ci_bootstrap.exs" => hand_rolled
        }
      )

    assert [record] = records(root)
    assert record.kind == :missing_helper
    assert record.rule == :shared_helper
    assert record.message =~ "priv/ci_bootstrap.exs"
    assert record.message =~ "never routes its database boot through `Samen.TestDb`"
  end

  test "GREEN (comment-only mention): a harness that satisfies the rule by CALLING the helper" do
    # The emitted templates QUOTE the old pattern in prose (the reason comments are stripped) —
    # and the call, not the mention, is what the gate requires.
    with_prose = """
    # Tolerant boot: a hard `:ok = storage_up(...)` would MatchError here. See `Samen.TestDb`.
    #{compliant_helper()}
    """

    root =
      tree!(
        widgets: %{
          "mix.exs" => mix_exs("widgets"),
          "priv/ci_bootstrap.exs" => with_prose
        }
      )

    assert records(root) == []
    # ...and the walked harness was seen (so the green is not from an empty walk).
    assert V.scan(root: root).harness_count == 1
  end

  # ---------------------------------------------------------------------------
  # FAIL-CLOSED — an unwalkable or empty tree certifies nothing
  # ---------------------------------------------------------------------------

  test "an explicit --root that is not a directory is :bad_root, never a skip" do
    missing = Path.join(System.tmp_dir!(), "dbt_missing_#{System.unique_integer([:positive])}")

    assert [%{kind: :bad_root}] = V.violation_records(root: missing)
  end

  test "a root that discovers no app is :empty_discovery, never a pass" do
    empty = Path.join(System.tmp_dir!(), "dbt_empty_#{System.unique_integer([:positive])}")
    File.mkdir_p!(empty)
    on_exit(fn -> File.rm_rf!(empty) end)

    assert [%{kind: :empty_discovery}] = V.violation_records(root: empty)
  end

  test "an app with NO harness file is :empty_discovery, never a vacuous pass" do
    root = tree!(widgets: %{"mix.exs" => mix_exs("widgets")})

    assert [record] = records(root)
    assert record.kind == :empty_discovery
    assert record.message =~ "certifies nothing"
  end

  # ---------------------------------------------------------------------------
  # CLI + the exit code
  # ---------------------------------------------------------------------------

  test "the recognized switches are actually parsed (a renamed switch cannot silently default)" do
    assert V.cli_opts(["--root", "/tmp"])[:root] == "/tmp"
    assert V.cli_opts(["--format", "json"])[:format] == "json"
    assert V.cli_invalid(["--rrot"]) != []
  end

  test "END TO END: a red tree exits 1 and prints its JSON report" do
    root =
      tree!(
        widgets: %{
          "mix.exs" => mix_exs("widgets"),
          "test/support/boot.ex" => raw_storage_boot()
        }
      )

    {output, status} =
      System.cmd(
        "mix",
        ["samen.verify.db_boot", "--root", root, "--format", "json"],
        cd: @project_dir,
        env: [{"MIX_ENV", "test"}],
        stderr_to_stdout: true
      )

    assert status == 1, "expected a failing exit — got #{status}:\n#{output}"

    document = last_document!(output)
    assert document["task"] == "samen.verify.db_boot"
    assert document["status"] == "fail"
    assert document["violation_count"] == 1

    assert [violation] = document["violations"]
    assert violation["kind"] == "raw_storage_boot"
    assert violation["app"] == "widgets"
    assert violation["message"] =~ "Samen.TestDb"
  end

  defp last_document!(output) do
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
    document
  end
end
