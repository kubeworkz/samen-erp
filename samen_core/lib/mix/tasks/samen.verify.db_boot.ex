defmodule Mix.Tasks.Samen.Verify.DbBoot do
  @shortdoc "Fail the build when an emitted harness or priv probe boots its database by hand instead of through Samen.TestDb; --format json prints one machine-readable line."

  @moduledoc """
  `mix samen.verify.db_boot` — the **tolerant-boot** gate.

  ## The defect this closes

  Every database-owning harness in this tree (the emitted `test/test_helper.exs`, the emitted
  `priv/ci_bootstrap.exs`, the emitted `priv/anti_tautology_probe.exs`, the verticals' own
  copies of those, and the hosts' test helpers) runs moments after SOME other BEAM has just
  exited — the `mix test` VM whose pool is still closing, or a sibling `ci.sh` gate on the same
  Postgres. In that window `storage_down/1` legitimately answers `{:error, :being_accessed}`
  (or a pool timeout), and the `storage_up/1` that follows answers `{:error, :already_up}`
  because the database was never dropped. A harness that hard-matches

      :ok = Ecto.Adapters.Postgres.storage_up(Repo.config())

  **MatchError-kills at its own boot line, before a single assertion**. Observed 2026-10-20: the
  PawChart and SamenERP anti-tautology probes died exactly there under the root gate, reporting
  a boot crash instead of a verdict about the vault path they exist to prove.

  The fix is one shared tolerance (`Samen.TestDb`), never a per-harness copy: a best-effort
  drop, a create retried until the database verifiably reports `:up`, and a raise on anything
  genuinely wrong. This gate is what keeps a future harness from re-growing the hand-rolled
  version — the failure is invisible in a green run, so nothing else in CI would notice.

  ## What it checks

  Over the harness surface of the walked tree (below), two rules:

    1. **No raw adapter boot.** Any `Ecto.Adapters.<Adapter>.storage_up(...)` /
       `storage_down(...)` call — the hand-rolled boot — is a violation. Only
       `Samen.TestDb` may talk to the adapter's storage API. This applies to every scanned
       file, whatever its name.
    2. **Every harness that boots a database goes through the helper.** A file whose basename
       is one of the emitted boot harnesses (`ci_bootstrap.exs|eex`,
       `anti_tautology_probe.exs|eex`, `test_helper.eex`, `test_helper_web.eex` — a trailing
       `.golden` ignored) exists ONLY to create/migrate the database, so it always owes the
       call. A host `test_helper.exs` owes it as soon as its code shows a boot signal
       (`storage_up`/`storage_down`, `Ecto.Migrator.run`, or the helper itself) — which is why
       `samen_web`'s and the adapter packages' DB-LESS helpers (a KMS dir + `ExUnit.start()`)
       are correctly exempt rather than falsely accused. The obligation is a real
       `Samen.TestDb.boot!(…)` / `Samen.TestDb.ensure_up!(…)` CALL: a comment that merely
       mentions the helper does not satisfy it, so deleting the call is red even when the
       explanation stays.

  ## Which files are scanned

  Per app discovered under the walked tree (the root itself when it carries a `mix.exs`, else
  every `*/mix.exs`):

    * `priv/**/*.exs` — the probes and `ci_bootstrap.exs`;
    * `priv/templates/**/*.eex` — the EMITTED templates (`samen_core` only);
    * `test/test_helper.exs`, `test/support/**/*.{ex,exs}` — the host/support harnesses;
    * `test/fixtures/**/*.golden` — the emitted output the goldens pin.

  Comments are ignored line-wise (a line whose first non-space character is `#`), because the
  templates and probes legitimately DOCUMENT the old pattern in prose. A trailing comment on a
  code line is not stripped: that could only ever cause a false FAILURE (loud), never a silent
  pass, which is the direction this gate must err in.

  ## Named exclusions (and why)

    * **`lib/`** — shipped code is not a boot harness. `Samen.TestDb` itself is the one module
      allowed to call the adapter's storage API, and `Samen.Web.TestSetup` (the `mix test`
      alias's create step) owns its own retry loop because it must verify the database exists
      mid-flight. Scanning `lib/` would mean allow-listing both, i.e. trading a precise rule
      for an exception list.
    * **Frozen `spikes/`** — mechanism spikes are deliberately not maintained; the root
      `spikes/*/lib` walk belongs to `agent_coverage`, not here.

  ## Which tree it walks

  Default: the current app (the cwd), so a host's own gate gates itself. `--root PATH` says
  WHICH tree to walk — the umbrella checkout (every app scanned, which is how the ROOT gate
  certifies the framework AND the verticals at once) or one app's directory. The path must
  EXIST as a directory, and empty discovery is a VIOLATION, never a quiet pass: a tree with no
  app, or an app with no harness file, certifies nothing.

  The scan is STATIC (source files only): it needs no DB, boots nothing, and points at an
  arbitrary checkout with one argument — which is why this task is also a member of
  `Samen.Verifier.Registry.tree_scoped/0` (`samen.verify.fleet`).

  ## Usage

      mix samen.verify.db_boot                        # this app
      mix samen.verify.db_boot --root /path/to/a/checkout
      mix samen.verify.db_boot --format json          # one line, for CI

  ## Output

  `--format json` prints ONE line (`Samen.Verifier.document/2` shape), before halting, so a
  failing run's report is always readable:

      {"task":"samen.verify.db_boot","status":"fail","violation_count":1,"violations":
       [{"message":"…","kind":"raw_storage_boot","app":"pawchart","rule":"shared_helper"}]}

  `kind` names the check (`raw_storage_boot`, `missing_helper`, `bad_root`,
  `empty_discovery`, `cli_argument`); `app` and `rule` attribute a harness failure to an app
  and the rule it broke, so a consumer never parses the prose.

  ## Exit code

  Exits 0 on success, 1 on any violation (fail-closed via `Samen.Verifier`) — and 1 for a
  `--format` value this task does not print or an argument it does not recognize, because a
  mistyped invocation must never be quietly served a different report than it asked for.
  """

  use Mix.Task

  @task_name "samen.verify.db_boot"

  # Harnesses that exist ONLY to create/migrate a database: they always owe the helper call.
  # Compared against a candidate's basename with a trailing `.golden` removed, so the emitted
  # GOLDEN output is held to the same rule as the template that renders it.
  @always_boot_harnesses ~w(
    ci_bootstrap.exs
    ci_bootstrap.eex
    anti_tautology_probe.exs
    anti_tautology_probe.eex
    test_helper.eex
    test_helper_web.eex
  )

  # A host `test_helper.exs` is NOT inherently a database harness — `samen_web`'s and the
  # adapter packages' helpers only set up a KMS dir and start ExUnit. It owes the helper once
  # its code shows a boot signal.
  @conditional_harnesses ~w(test_helper.exs)

  # The signals that a harness really does bootstrap a schema.
  @boot_signals ~r/(?:storage_up|storage_down|Ecto\.Migrator\.run|Samen\.TestDb)/

  # A raw adapter storage call — the hand-rolled boot this gate exists to retire.
  @raw_storage ~r/Ecto\.Adapters\.[A-Z]\w*\.(?:storage_up|storage_down)\b/

  # A real CALL to the shared helper (never a comment-only mention: comments are stripped).
  @helper_call ~r/Samen\.TestDb\.(?:boot!|ensure_up!)\s*\(/

  # The harness surface of one app. Every one of these is a file that can own a database boot.
  @in_scope ~w(
    priv/**/*.exs
    priv/templates/**/*.eex
    test/test_helper.exs
    test/support/**/*.ex
    test/support/**/*.exs
    test/fixtures/**/*.golden
  )

  # `--format` comes from the shared harness spec, so a new adopter cannot spell it differently
  # and silently drop it (`OptionParser` with `strict:` parks an unknown switch in `invalid`).
  @cli_switches [root: :string] ++ [Samen.Verifier.format_switch()]
  @cli_switch_names ~w(--root --format)
  @cli_switches_text "--root <path> and --format <text|json>"

  @impl Mix.Task
  def run(args) do
    opts = cli_opts(args)

    {format, format_violations} =
      case format_from(opts) do
        {:ok, format} -> {format, []}
        :error -> {:text, [Samen.Verifier.format_violation(Keyword.get(opts, :format))]}
      end

    Samen.Verifier.halt_if_violations(
      @task_name,
      format_violations ++ unknown_switch_violations(args) ++ violation_records(opts),
      format: format
    )
  end

  @doc false
  # Separated from `run/1` so a test can prove a switch is still RECOGNIZED: `OptionParser`
  # with `strict:` parks an option it does not know in `invalid` (never in `opts`), so a
  # switch missing from the list would silently revert to a default with nothing red.
  def cli_opts(args), do: args |> parse_cli() |> elem(0)

  @doc false
  def cli_invalid(args), do: args |> parse_cli() |> elem(2)

  defp parse_cli(args), do: OptionParser.parse(args, strict: @cli_switches)

  @doc false
  def format_from(opts), do: Samen.Verifier.parse_format(opts)

  defp unknown_switch_violations(args) do
    Samen.Verifier.cli_argument_violations(
      cli_invalid(args),
      @cli_switch_names,
      @cli_switches_text
    )
  end

  @doc """
  The violation list as message STRINGS (the text report's form), separated from `run/1` so
  tests can call it without halting.
  """
  def violations(opts \\ []), do: Enum.map(violation_records(opts), & &1.message)

  @doc """
  The same violations as RECORDS: `%{message:, kind:}` with `:app`/`:rule` added for the
  harness family. A machine consumer attributes a failure from these fields rather than from
  the prose.
  """
  def violation_records(opts \\ []) do
    scan = scan(opts)

    cond do
      scan.bad_root ->
        [%{kind: :bad_root, message: bad_root_message(scan.root)}]

      scan.apps == [] ->
        [%{kind: :empty_discovery, message: empty_apps_message(scan.root)}]

      scan.files == [] ->
        [%{kind: :empty_discovery, message: empty_files_message(scan.root)}]

      true ->
        Enum.flat_map(scan.files, &file_violations/1)
    end
  end

  @doc """
  The scan, exposed so the GREEN proof can assert what the walker actually SAW (anti-vacuity:
  a glob that silently matches nothing must never read as "no violation").

  Returns `%{root:, apps:, files:, harness_count:, bad_root:}`. Each app is `%{app:, dir:}`;
  each file is `%{app:, path:, basename:, text:}`, `path` root-relative (forward-slashed);
  `harness_count` counts the files rule 2 applies to, which is the witness a test asserts on.
  `bad_root` is true when an EXPLICIT `:root` names something that is not a directory (`root`
  then holds the expanded path), which `violation_records/1` reports as a failure, never a skip.
  """
  def scan(opts \\ []) do
    case root(opts) do
      {:bad_root, path} ->
        %{root: path, apps: [], files: [], harness_count: 0, bad_root: true}

      root ->
        apps = app_dirs(root) |> Enum.map(&app_entry(root, &1))
        files = apps |> Enum.flat_map(&app_files(root, &1))

        %{
          root: root,
          apps: apps,
          files: files,
          harness_count: Enum.count(files, &harness_file?(&1.basename)),
          bad_root: false
        }
    end
  end

  # ---------------------------------------------------------------------------
  # Per-file verdicts
  # ---------------------------------------------------------------------------

  # One violation per file: a hand-rolled boot that ALSO fails to call the helper is ONE defect,
  # and reporting it twice would overstate the blast radius a dashboard reads.
  defp file_violations(%{app: app, path: path, basename: basename, text: text}) do
    case raw_boot_sites(text) do
      [{line, call} | _] ->
        [
          %{
            app: app,
            rule: :shared_helper,
            kind: :raw_storage_boot,
            message: raw_boot_message(app, path, line, call)
          }
        ]

      [] ->
        if boots_database?(basename, text) and not helper_call?(text) do
          [
            %{
              app: app,
              rule: :shared_helper,
              kind: :missing_helper,
              message: missing_helper_message(app, path)
            }
          ]
        else
          []
        end
    end
  end

  defp raw_boot_message(app, path, line, call) do
    "#{app}: #{path}:#{line} boots the database BY HAND (`#{call}`) — route it through the " <>
      "shared tolerant boot `Samen.TestDb.boot!/2` (or `Samen.TestDb.ensure_up!/2` when " <>
      "something must happen between create and migrate, as samen_core's test helper does for " <>
      "its pgvector pre-check). The helper makes the drop best-effort, retries the create until " <>
      "the database verifiably reports :up, and raises on anything genuinely wrong; a " <>
      "hand-rolled `:ok = storage_up(...)` instead MatchErrors on the benign " <>
      "`{:error, :already_up}` race that follows another BEAM's exit — killing the harness " <>
      "before it can assert anything (observed 2026-10-20: the PawChart and SamenERP " <>
      "anti-tautology probes died at their own boot line under the root gate)."
  end

  defp missing_helper_message(app, path) do
    "#{app}: #{path} is an emitted/host harness that never routes its database boot through " <>
      "`Samen.TestDb` — every harness that owns a database must CALL " <>
      "`Samen.TestDb.boot!/2` (or `ensure_up!/2` between create and migrate), the ONE tolerant " <>
      "create: best-effort drop, retried create verified against `storage_status/1`, raise on " <>
      "anything genuinely wrong. A comment that merely mentions the helper does not count — " <>
      "the call is what makes the boot crash-resilient against the database another gate's BEAM " <>
      "left held."
  end

  # ---------------------------------------------------------------------------
  # Source matching (comment-aware)
  # ---------------------------------------------------------------------------

  # Code lines only, WITH their 1-based numbers: a line whose first non-space character is `#`
  # is documentation, and the probes legitimately quote the old `:ok = storage_up(...)` pattern
  # in prose. Dropping the numbers with the lines would move every reported location, so the
  # number travels with the line instead.
  defp code_lines(text) do
    text
    |> String.split("\n")
    |> Enum.with_index(1)
    |> Enum.reject(fn {line, _number} ->
      line |> String.trim_leading() |> String.starts_with?("#")
    end)
  end

  defp raw_boot_sites(text) do
    for {line, number} <- code_lines(text),
        match = Regex.run(@raw_storage, line),
        match != nil,
        do: {number, hd(match)}
  end

  defp helper_call?(text) do
    Enum.any?(code_lines(text), fn {line, _number} -> Regex.match?(@helper_call, line) end)
  end

  # A golden's basename carries the emitted file's name plus `.golden`.
  defp stem(basename), do: String.replace_suffix(basename, ".golden", "")

  # The naming witness the walk reports (the anti-vacuity count).
  defp harness_file?(basename) do
    stem(basename) in @always_boot_harnesses or stem(basename) in @conditional_harnesses
  end

  # Does this file actually own a database boot?
  defp boots_database?(basename, text) do
    cond do
      stem(basename) in @always_boot_harnesses ->
        true

      stem(basename) in @conditional_harnesses ->
        Enum.any?(code_lines(text), fn {line, _number} -> Regex.match?(@boot_signals, line) end)

      true ->
        false
    end
  end

  # ---------------------------------------------------------------------------
  # Discovery
  # ---------------------------------------------------------------------------

  defp root(opts) do
    case Keyword.get(opts, :root) do
      nil ->
        Path.expand(File.cwd!())

      given ->
        expanded = given |> Samen.SourceGlob.normalize() |> Path.expand()

        if File.dir?(expanded), do: expanded, else: {:bad_root, expanded}
    end
  end

  # Every dir under the walked root carrying a mix.exs, by app name. A root that IS an app
  # counts too (its own `mix.exs`), so the DEFAULT root (a host running its own gate) is one
  # app and `--root <umbrella>` is every `*/mix.exs` app.
  defp app_dirs(root) do
    nested =
      root
      |> Samen.SourceGlob.expand!("*/mix.exs")
      |> Enum.map(&Path.dirname/1)
      |> Enum.filter(&File.dir?/1)
      |> Enum.map(fn dir -> {Path.basename(dir), dir} end)

    self =
      if File.regular?(Path.join(root, "mix.exs")), do: [{Path.basename(root), root}], else: []

    (self ++ nested)
    |> Enum.uniq_by(fn {_app, dir} -> Samen.SourceGlob.normalize(dir) end)
    |> Enum.sort()
  end

  defp app_entry(root, {app, dir}), do: %{app: app, dir: rel(dir, root)}

  # Every in-scope harness file under one app, read ONCE. Windows: backslash-carrying paths make
  # `Path.wildcard` match nothing, so every dir glob goes through the normalized expansion
  # helper (`Samen.SourceGlob`) — a silent zero-match would read as "no violation". A file that
  # vanished between the glob and the read is skipped rather than crashing the gate.
  defp app_files(root, %{app: app, dir: dir}) do
    files =
      for pattern <- @in_scope,
          path <- Samen.SourceGlob.expand!(Path.join(root, dir), pattern),
          File.regular?(path),
          {:ok, text} <- [File.read(path)] do
        %{
          app: app,
          path: rel(path, root),
          basename: Path.basename(path),
          text: text
        }
      end

    files
    |> Enum.uniq_by(& &1.path)
    |> Enum.sort_by(& &1.path)
  end

  defp rel(path, root) do
    path
    |> Samen.SourceGlob.normalize()
    |> Path.relative_to(Samen.SourceGlob.normalize(root))
  end

  defp bad_root_message(path) do
    "--root #{path} is not a directory — a tree that cannot be walked certifies nothing. Pass " <>
      "the checkout (or one app's directory) to gate."
  end

  defp empty_apps_message(root) do
    "#{root}: discovered NO app — no mix.exs at the root and none one level down, so no " <>
      "harness surface was walked. That is a FAILURE, not a pass: an empty walk certifies " <>
      "nothing."
  end

  defp empty_files_message(root) do
    "#{root}: discovered no harness file — looked for priv/**/*.exs, priv/templates/**/*.eex, " <>
      "test/test_helper.exs, test/support/**, and test/fixtures/**/*.golden under every app. A " <>
      "walk that finds nothing certifies nothing."
  end
end
