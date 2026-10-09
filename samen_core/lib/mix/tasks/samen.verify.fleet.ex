defmodule Mix.Tasks.Samen.Verify.Fleet do
  @shortdoc "Run every tree-scoped verifier against one tree; one aggregate report (`--format json`)."

  @moduledoc """
  `mix samen.verify.fleet` — run every **tree-scoped** verifier against ONE tree and emit a
  single aggregate report, so a CI job or a dashboard reads one document instead of
  re-deriving per-verifier exit codes.

  The roster is `Samen.Verifier.Registry.tree_scoped/0` — read that module for the inclusion
  rule (a verifier whose findings come from reading source files under a tree) and the named
  exclusions (the DB- and module-introspecting tiers, which have no tree to point at).
  Today: `agent_coverage`, `fleet_wire`, `pii_reads`, `never_read_current`.

  Each member runs as its OWN OS process (`mix <task> --format json <tree args>`) and the
  aggregate is a consumer of the per-verifier JSON — so a member that halts the VM, needs
  `app.start`, or exits 1 with a report is recorded as a verdict, not a crash. A member that
  produced no parseable report is a `runner_error` and FAILS the aggregate (see
  `Samen.Verifier.Fleet`).

  ## Usage

      mix samen.verify.fleet                          # the cwd, every tree-scoped verifier
      mix samen.verify.fleet --root /path/to/a/tree   # gate THAT tree (a scratch copy, a host)
      mix samen.verify.fleet --format json            # one line, for CI/dashboards

  `--root` defaults to the cwd. The **tree being analyzed** (`--root`) and the **runtime the
  children run in** (the cwd's project, which supplies `app.start`/config) are separate on
  purpose: a scratch copy of a tree is gated by pointing `--root` at it while still running
  from the real project. A root that is not a directory — or a root that yields no source to
  scan — is reported per-member rather than silently skipped.

  ## Output

  `--format text` (default) prints one line per verifier plus its violations and a summary.
  `--format json` prints ONE line of JSON — the aggregate document:

      {"task":"samen.verify.fleet","root":"…","status":"ok|fail","verifier_count":4,
       "failed_count":0,"violation_count":0,
       "verifiers":[{"task":"samen.verify.agent_coverage","status":"ok",
                     "violation_count":0,"violations":[]}, …]}

  Each entry under `"verifiers"` is the SAME document that verifier prints alone, so a consumer
  has one schema to learn and one parser to write. `status` is `"ok"` only when the roster is
  non-empty and every member is `"ok"`; a `runner_error` member makes it `"fail"`.

  ## Exit code (fail-closed)

  Exits 0 only when every member is `"ok"`, 1 otherwise (via `:erlang.halt/1`, and the document
  is printed FIRST so a failing run is still readable). A MALFORMED INVOCATION — an unsupported
  `--format` value, or an argument OptionParser could not place (`--rrot <tree>`) — is reported
  in the standard violation schema and exits 1 WITHOUT running the roster: an ignored `--root`
  would otherwise gate the default tree while the caller believes it gated another.
  """

  use Mix.Task

  @task_name "samen.verify.fleet"

  @cli_switches [root: :string] ++ [Samen.Verifier.format_switch()]
  @cli_switch_names ~w(--root --format)
  @cli_switches_text "--root <path> and --format <text|json>"

  @impl Mix.Task
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: @cli_switches)

    {format, format_violations} = Samen.Verifier.resolve_format(opts)

    root = Path.expand(Keyword.get(opts, :root, File.cwd!()))

    cli_violations =
      format_violations ++
        Samen.Verifier.cli_argument_violations(
          invalid,
          @cli_switch_names,
          @cli_switches_text
        ) ++ root_violations(root)

    # A malformed invocation is not a fleet verdict: report the CLI problem in the standard
    # violation schema and halt, rather than spawning children over a request we could not
    # fully understand. `format` is `:text` when the format itself was the problem (a bad
    # value cannot be reported in the format it asked for).
    if cli_violations != [] do
      Samen.Verifier.halt_if_violations(@task_name, cli_violations, format: format)
    end

    document = Samen.Verifier.Fleet.run(root, cd: File.cwd!())

    print(document, format)

    if document["status"] != "ok", do: :erlang.halt(1)
  end

  # A root that is not a directory is refused BEFORE any member runs: the `--source-dirs`
  # members drop missing dirs and would scan nothing and report `ok`, so an unrunnable tree
  # would otherwise read as a partial pass. A tree that cannot be walked certifies nothing
  # (the same fail-closed rule `fleet_wire`'s `--root` applies to its own walk).
  defp root_violations(root) do
    if File.dir?(root) do
      []
    else
      [
        %{
          kind: :bad_root,
          message:
            "--root #{root} is not a directory — a tree that cannot be walked certifies " <>
              "nothing (fail-closed: point --root at the checkout root)."
        }
      ]
    end
  end

  defp print(document, :json), do: IO.puts(Jason.encode!(document))

  defp print(document, :text) do
    IO.puts("")

    IO.puts(
      "#{@task_name}: #{document["verifier_count"]} tree-scoped verifier(s) over " <>
        "#{document["root"]}"
    )

    Enum.each(document["verifiers"], fn verifier ->
      marker = if verifier["status"] == "ok", do: "ok  ", else: "FAIL"
      IO.puts("  [#{marker}] #{verifier["task"]} — #{verifier["violation_count"]} violation(s)")

      Enum.each(verifier["violations"], fn violation ->
        IO.puts("        • #{violation["message"]}")
      end)
    end)

    IO.puts("")

    if document["status"] == "ok" do
      IO.puts("#{@task_name}: OK — every tree-scoped verifier passed.")
    else
      IO.puts(
        "FAIL: #{@task_name} — #{document["failed_count"]} of #{document["verifier_count"]} " <>
          "verifier(s) failed (#{document["violation_count"]} violation(s) total)."
      )
    end
  end
end
