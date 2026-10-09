defmodule Samen.Verifier.Fleet do
  @moduledoc """
  Run every **tree-scoped** verifier against one tree and fold their reports into ONE
  aggregate document — the machine-readable roll-up a CI job or a dashboard consumes instead
  of re-deriving per-verifier exit codes.

  The set is `Samen.Verifier.Registry.tree_scoped/0`; read that module for the inclusion rule
  and the named exclusions. This module owns three things and nothing else: how each member is
  pointed at a tree (its `:tree_args`), how it is invoked, and how the results are aggregated.

  ## Each verifier runs as its OWN OS process

  An entry is invoked as `mix <task> --format json <tree args>` in a child process rather than
  in-process, for three reasons:

    1. **`:erlang.halt/1`.** Every verifier fails closed by halting the VM. In-process, the
       first failing verifier would take the aggregate down with it and the other verdicts
       would never be recorded.
    2. **Runtime isolation.** A verifier that boots the app or opens a DB takes its own runtime
       with it, so one verifier's setup failure cannot be mistaken for another's verdict.
    3. **No second contract.** The aggregate is *literally* a consumer of the per-verifier JSON
       — the same contract a dashboard reads — so the two paths cannot drift apart.

  ## Fail-closed: an unevaluable verifier FAILS

  A child that exits non-zero without a JSON report, crashes, or prints nothing parseable is
  recorded as a per-verifier document with `"status":"fail"` and a `runner_error` violation,
  and it fails the aggregate. A tree the fleet could not fully evaluate is never reported
  `"ok"` — and neither is an EMPTY roster (an aggregate over zero verifiers certifies nothing).

  ## Purity

  `aggregate/2` is pure (documents in, document out) so the roll-up — the part a dashboard
  keys on — is testable without spawning anything. `run/2` accepts a `:runner` to make the
  invocation layer injectable, with the real subprocess runner as the default.
  """

  @task_name "samen.verify.fleet"

  @doc "The aggregate task name, for a consumer that keys on `\"task\"`."
  def task_name, do: @task_name

  @doc """
  Fold per-verifier documents into the fleet document.

  `documents` are the documents each member printed (`Samen.Verifier.document/2` shape:
  `task`/`status`/`violation_count`/`violations`). The fleet is `"ok"` only when the roster is
  non-empty AND every member is `"ok"`; any `"fail"` (including a `runner_error`) makes it
  `"fail"`. `violation_count` is the total across members, so a consumer can see the blast
  radius without walking `verifiers`.
  """
  @spec aggregate(Path.t(), [map()]) :: map()
  def aggregate(root, documents) when is_list(documents) do
    ok? = documents != [] and Enum.all?(documents, &(&1["status"] == "ok"))

    %{
      "task" => @task_name,
      "root" => root,
      "status" => if(ok?, do: "ok", else: "fail"),
      "verifier_count" => length(documents),
      "failed_count" => Enum.count(documents, &(&1["status"] != "ok")),
      "violation_count" => Enum.sum(Enum.map(documents, &(&1["violation_count"] || 0))),
      "verifiers" => documents
    }
  end

  @doc """
  Run the tree-scoped roster against `root` and return the aggregate document.

  `opts`:
    * `:runner` — `(entry, root, opts) :: {:ok, document} | {:error, reason}`; defaults to the
      real subprocess runner (`subprocess_runner/3`). Injectable so the roll-up logic can be
      tested without booting a real `mix` per member.
    * `:cd` — the project directory the children run in (default: the cwd). The tree being
      *analyzed* is `root`; the *runtime* (the app whose `app.start`/config the verifiers use)
      is `cd`, which is why they are separate — a scratch copy of a tree is gated by pointing
      `root` at it while still running from the real project.
    * `:env` — extra environment for the children.
  """
  @spec run(Path.t(), keyword()) :: map()
  def run(root, opts \\ []) do
    root = Path.expand(root)

    documents =
      Samen.Verifier.Registry.tree_scoped()
      |> Enum.map(&run_entry(&1, root, opts))

    aggregate(root, documents)
  end

  defp run_entry(entry, root, opts) do
    runner = Keyword.get(opts, :runner, &subprocess_runner/3)

    case runner.(entry, root, opts) do
      {:ok, document} when is_map(document) -> document
      {:error, reason} -> error_document(entry, reason)
    end
  end

  @doc """
  The per-verifier document standing in for one that could not be evaluated.

  It is a normal `Samen.Verifier.document/2` — same four keys per violation — carrying a
  single `:runner_error`, so a consumer parses a failed child with the SAME code path as a
  reported violation and needs no special case.
  """
  @spec error_document(map(), String.t()) :: map()
  def error_document(entry, reason) do
    Samen.Verifier.document(entry.task, [
      %{
        kind: :runner_error,
        message: "`mix #{entry.task}` could not be evaluated: #{reason}"
      }
    ])
  end

  @doc """
  The default runner: `mix <task> --format json <tree args>` in a child OS process, then read
  the JSON report off its stdout.

  A non-`ok` exit is NOT an error by itself — a verifier with violations exits 1 *and* prints
  its report, which is a verdict, not a failure to evaluate. Only a child that produced no
  parseable document is a `runner_error`. stdout is scanned for the LAST line that decodes to
  a document carrying a `"task"` key, because several verifiers print advisory lines (hints,
  exemption lists) around the report.
  """
  @spec subprocess_runner(map(), Path.t(), keyword()) :: {:ok, map()} | {:error, String.t()}
  def subprocess_runner(entry, root, opts) do
    args = [entry.task, "--format", "json" | Samen.Verifier.Registry.tree_args(entry, root)]

    {output, status} =
      System.cmd("mix", args,
        cd: Keyword.get(opts, :cd, File.cwd!()),
        env: Keyword.get(opts, :env, [{"MIX_ENV", to_string(Mix.env())}]),
        stderr_to_stdout: false
      )

    case last_document(output) do
      {:ok, document} ->
        {:ok, document}

      :error ->
        {:error, "exit #{status}, no JSON report on stdout — #{tail(output)}"}
    end
  end

  @doc """
  The last line of `output` that decodes to a JSON object with a `"task"` key, or `:error`.
  """
  @spec last_document(String.t()) :: {:ok, map()} | :error
  def last_document(output) when is_binary(output) do
    output
    |> String.split("\n", trim: true)
    |> Enum.reverse()
    |> Enum.find_value(:error, fn line ->
      case Jason.decode(String.trim(line)) do
        {:ok, %{"task" => _} = document} -> {:ok, document}
        _ -> nil
      end
    end)
  end

  # A bounded tail for the runner_error message: enough to see WHY (a compile error, a missing
  # task), not so much that a dashboard's message field is a wall of text.
  defp tail(output) do
    output
    |> String.trim()
    |> String.slice(-400, 400)
  end
end
