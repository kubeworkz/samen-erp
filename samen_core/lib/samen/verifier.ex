defmodule Samen.Verifier do
  @moduledoc """
  Harness for Samen verifier mix tasks.

  Verifiers follow a consistent three-step pattern:
    1. Introspect — gather facts from code and/or the running DB.
    2. Check — compute violations.
    3. Report — print human-readable diagnostics, then exit(1) if any violations.

  This module provides shared helpers for the pattern. Each concrete verifier
  (e.g. `Mix.Tasks.Samen.Verify.CatalogParity`) calls `halt_if_violations/3` with
  a task name and list of violations; the harness prints them and exits non-zero if
  the list is non-empty.

  ## Report formats (`:format`)

  `:text` (the default, and every verifier's historical behaviour) prints the
  banner plus one bullet per violation. `:json` prints ONE line of JSON for CI and
  dashboards:

      {"task":"…","status":"ok|fail","violation_count":N,"violations":[…]}

  A violation is either the historical bare string or a RECORD — a map with a
  required `:message` plus the optional identity fields `:kind` (which check
  failed), `:app` and `:rule`. `:json` carries those fields as data, so a consumer
  never has to parse the prose to attribute a failure: a string renders as
  `{"message": …, "kind": null, "app": null, "rule": null}` and a record fills in
  whatever it declares. `document/2` is the pure form of that document, so a test
  can assert its shape without spawning a task process.

  ## Exit behaviour (fail-closed guarantee)

  `halt_if_violations/3` calls `:erlang.halt(1)` directly (not `System.stop/1`)
  so the process exits immediately after printing diagnostics — no cleanup hook
  can swallow the non-zero code. This holds in `:json` too: the document is
  printed FIRST, then the process halts, so a machine consumer always sees the
  structured report on a failing run. In the test harness the tests capture this by
  calling the task via `System.cmd/3` in a child OS process rather than calling
  the task function directly, which gives a true end-to-end exit-code assertion.
  """

  @formats [:text, :json]

  @doc """
  The `OptionParser` `strict:` entry that declares `--format` — one name and one type for
  every verifier that offers the machine-readable report, so a new adopter cannot spell it
  differently and silently drop it (`OptionParser` with `strict:` parks an unknown switch in
  the invalid list, never in `opts`).
  """
  def format_switch, do: {:format, :string}

  @doc """
  Resolve the `--format` option to `{:ok, :text | :json}`, or `:error` for any value this
  harness does not print.

  FAIL-HONEST: an unrecognized value is an ERROR, never a quiet fall back to `:text`. A
  caller that asked for JSON and silently received prose would hand its CI agent a document
  it cannot parse while the run still exited 0 — exactly the lie the format exists to remove.
  """
  @spec parse_format(keyword()) :: {:ok, :text | :json} | :error
  def parse_format(opts) do
    case Keyword.get(opts, :format) do
      nil -> {:ok, :text}
      "text" -> {:ok, :text}
      "json" -> {:ok, :json}
      _other -> :error
    end
  end

  @doc """
  The violation record for an unsupported `--format` value. The message is built HERE, once,
  so every verifier's refusal names the same switch and the same accepted values.
  """
  def format_violation(value) do
    %{
      kind: :cli_argument,
      message: "--format #{inspect(value)} is not supported — use text or json."
    }
  end

  @doc """
  Violation records for arguments `OptionParser` could not place, given the task's switch
  names and the human-readable switch list it prints.

  FAIL-CLOSED: an ignored argument is never a shrug. A mistyped `--rrot <tree>` or a value-less
  `--format` would otherwise let a run exit 0 over the DEFAULT tree in the DEFAULT format while
  the caller believes it asked for something else — so every stray argument becomes a
  `:cli_argument` violation. A KNOWN switch that arrived with no value is told apart from an
  unknown one ("requires a value" vs "unrecognized argument"), because telling a caller their
  real switch is unrecognized is its own small lie.
  """
  @spec cli_argument_violations([{String.t(), String.t() | nil}], [String.t()], String.t()) :: [
          map()
        ]
  def cli_argument_violations(invalid, switch_names, switches_text) do
    known = Enum.map(switch_names, &to_string/1)

    Enum.map(invalid, fn
      {switch, nil} ->
        if to_string(switch) in known do
          %{
            kind: :cli_argument,
            message:
              "#{switch} requires a value — this task takes #{switches_text}; refusing to " <>
                "run with an ignored argument (fail-closed)."
          }
        else
          unrecognized_argument(switch, switches_text)
        end

      {switch, _value} ->
        unrecognized_argument(switch, switches_text)
    end)
  end

  defp unrecognized_argument(switch, switches_text) do
    %{
      kind: :cli_argument,
      message:
        "unrecognized argument #{switch} — this task takes #{switches_text}; refusing to " <>
          "run with an ignored argument (fail-closed)."
    }
  end

  @doc """
  The whole `--format` prologue: `{format, violations}`. A bad value is reported IN TEXT
  (it cannot be reported in the format it asked for) as one `:cli_argument` violation, so the
  run still exits 1 and still prints a readable report rather than a document in a format the
  caller did not request.
  """
  @spec resolve_format(keyword()) :: {:text | :json, [map()]}
  def resolve_format(opts) do
    case parse_format(opts) do
      {:ok, format} -> {format, []}
      :error -> {:text, [format_violation(Keyword.get(opts, :format))]}
    end
  end

  @doc """
  Print violations and exit(1) if there are any; otherwise print a pass banner.

  `task_name` is used only in the banner (e.g. `"samen.verify.catalog_parity"`).
  `violations` is a list of violation STRINGS (the historical shape) or of records
  (maps with a required `:message` and optional `:kind`/`:app`/`:rule`).

  `opts`:
    * `:format` — `:text` (default) or `:json`; see the moduledoc. Any other value
      raises, so a caller that asked for a format we do not print is never quietly
      served a different one.
  """
  def halt_if_violations(task_name, violations, opts \\ []) do
    case format!(Keyword.get(opts, :format, :text)) do
      :text -> halt_text(task_name, violations)
      :json -> halt_json(task_name, violations)
    end
  end

  @doc """
  The JSON document a `format: :json` run prints, as a map — pure, so a test can
  assert the shape without spawning a task. `"status"` is `"ok"`/`"fail"`, and
  every violation carries the SAME four keys whether it arrived as a record or as
  a bare string, so the schema a dashboard keys on never changes shape.
  """
  def document(task_name, violations) do
    %{
      "task" => task_name,
      "status" => if(violations == [], do: "ok", else: "fail"),
      "violation_count" => length(violations),
      "violations" => Enum.map(violations, &violation_document/1)
    }
  end

  # The human-readable report, byte-for-byte what this harness has always printed.
  defp halt_text(task_name, violations) do
    if violations == [] do
      IO.puts("#{task_name}: OK — no violations found.")
    else
      IO.puts("")
      IO.puts("FAIL: #{task_name} found #{length(violations)} violation(s):")

      Enum.each(violations, fn v ->
        IO.puts("  • #{message_of(v)}")
      end)

      IO.puts("")
      :erlang.halt(1)
    end
  end

  # Document FIRST, halt second: a failing run's stdout still holds the report.
  defp halt_json(task_name, violations) do
    IO.puts(Jason.encode!(document(task_name, violations)))

    if violations != [], do: :erlang.halt(1)
  end

  defp violation_document(v) when is_binary(v), do: shape(v)

  defp violation_document(%{} = v) do
    %{
      "message" => Map.fetch!(v, :message),
      "kind" => textifiable(Map.get(v, :kind)),
      "app" => textifiable(Map.get(v, :app)),
      "rule" => textifiable(Map.get(v, :rule))
    }
  end

  defp shape(message), do: %{"message" => message, "kind" => nil, "app" => nil, "rule" => nil}

  defp textifiable(nil), do: nil
  defp textifiable(atom) when is_atom(atom), do: Atom.to_string(atom)
  defp textifiable(other), do: to_string(other)

  defp message_of(v) when is_binary(v), do: v
  defp message_of(%{} = v), do: Map.fetch!(v, :message)

  defp format!(format) when format in @formats, do: format

  defp format!(other) do
    raise ArgumentError,
          "unsupported report format: #{inspect(other)} — expected :text or :json"
  end
end
