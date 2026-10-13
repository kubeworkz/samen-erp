defmodule Mix.Tasks.Samen.Verify.AnalyticsProducer do
  @shortdoc "Fail the build when a host mounts the own-org analytics reader without a configured product-event producer; --format json prints one machine-readable line."

  @moduledoc """
  `mix samen.verify.analytics_producer` — the **silent-empty-funnel** build gate
  (ADR-021; the mount-ledger Amendment 3).

  ## The defect this closes

  A host can mount the P17 own-org analytics reader — the
  `samen_tenant_analytics_routes/2` macro, whose single route renders
  `Samen.Web.Tenant.AnalyticsLive` over the `paf_product_event_rollup` table — and
  ship a page that is empty for **every org, forever**, under copy that reads as
  *"no data yet"*. That is what happened to samenerp: the reader was mounted in
  Phase 3 and the producer was never wired, so `GET /analytics` rendered its
  honest-looking empty state while the truth was *"no data possible"*. Nothing in
  the build said a word, because a mounted reader and a fed reader look identical
  on disk, in config, and at boot.

  Filling that page needs BOTH halves of the producer, and each is a config the
  router mount does not imply:

    * **the emitter** — `Samen.Analytics.track/1` persists NOTHING without
      `config :samen_core, Samen.Analytics, product_event_resource: <Module>`; it
      returns `{:ok, :dropped}` (the documented quiet-until-mounted posture), so
      every framework-emitted event (sign-in, first-run, record create, ⌘K search,
      flag assignment) is discarded; and
    * **the rollup source** — `paf_product_event_rollup` is rebuilt from the host's
      event ledger ONLY by a `:product_event_rollup` spec in
      `config :samen_core, :rollups`. With no spec the table the reader queries
      stays empty even if the ledger fills.

  A reader mount without both is the failure class: an analytics surface that is
  structurally incapable of ever showing a number. This task refuses to let that
  ship on any host.

  ## What it checks

  A host **mounts the analytics reader** when its SHIPPED `lib/` contains a real
  `samen_tenant_analytics_routes(…)` mount (AST-matched on the CALL, so the macro's
  own `defmacro` head and its `@doc` example snippets never count). For every such
  host it requires:

    1. a non-nil `product_event_resource` under `config :samen_core, Samen.Analytics`
       (the emitter), and
    2. a `:product_event_rollup` entry in `config :samen_core, :rollups` (the source).

  Each missing half is ONE violation, named, with the mount location and the fix —
  so re-breaking either link fails with a reason rather than restoring the silent
  empty state.

  ## Which tree it walks

  Default: the CURRENT app — the cwd is treated as the host's checkout, so a host's
  own `ci.sh` gates itself with the bare command. `--root PATH` says WHICH tree to
  walk instead: the root may be the umbrella checkout (every `*/mix.exs` app is
  scanned, which is how the ROOT gate certifies every host at once) or a single
  standalone host's directory. It must EXIST as a directory, and an explicitly
  requested tree that discovers no app is a VIOLATION — a tree that cannot be walked
  certifies nothing.

  The scan is STATIC (source + config files only): it needs no DB, boots no app, and
  points at an arbitrary checkout with one argument, which is why this task is also a
  member of `Samen.Verifier.Registry.tree_scoped/0` (`samen.verify.fleet`).

  ### The operator-seed carve-out, stated plainly

  `samen_operator_routes/2` ALWAYS mounts `/operator/analytics`
  (`Samen.Web.Operator.AnalyticsLive`), which reads the same `paf` rollup — so an
  operator-only host can render the same silent empty funnel. It is deliberately NOT
  in scope here: that surface is bundled into the operator workspace every generated
  app mounts, so requiring a producer for it would make product analytics mandatory
  rather than opt-in — a much larger policy change (the generator would have to mount
  the Analytics scope + its ledger migration by default). This gate covers the
  surface a host OPTS INTO by mounting `samen_tenant_analytics_routes/2`; widening it
  to the operator seed is a separate, deliberate decision.

  ## Usage

      mix samen.verify.analytics_producer                    # this app
      mix samen.verify.analytics_producer --root /path/to/a/checkout
      mix samen.verify.analytics_producer --format json      # one line, for CI

  ## Output

  `--format text` (default) prints the human-readable report every verifier prints.
  `--format json` prints ONE line of JSON to stdout — before halting, so a failing
  run's report is always readable:

      {"task":"samen.verify.analytics_producer","status":"fail","violation_count":1,"violations":
       [{"message":"…","kind":"missing_producer","app":"samenerp","rule":"product_event_emitter"}]}

  Every violation carries the same four keys: `kind` names the check that failed
  (`missing_producer`, `bad_root`, `empty_discovery`, `cli_argument`), and `app`/`rule`
  — present on the `missing_producer` family, `null` elsewhere — attribute the failure
  to an app and a producer link WITHOUT any consumer parsing the prose.
  `violation_records/1` returns that same list as data for in-process callers.

  ## Exit code

  Exits 0 on success, 1 on any violation (fail-closed via `Samen.Verifier`) — and 1
  for a `--format` value this task does not print, or an argument it does not
  recognize, because a mistyped invocation must never be quietly served a different
  report than it asked for.
  """

  use Mix.Task

  @task_name "samen.verify.analytics_producer"

  # The P17 own-org reader mount. `Samen.Web.Tenant.AnalyticsLive` is the single route
  # it mounts and `Samen.Web.Tenant.AnalyticsReads` the read layer it renders — neither
  # is referenced directly here (the macro is the mount-side signal).
  @reader_macro :samen_tenant_analytics_routes

  # The emitter config: `config :samen_core, Samen.Analytics, product_event_resource: Mod`.
  @analytics_module [:Samen, :Analytics]
  @emitter_key :product_event_resource

  # The rollup-source config: a `:product_event_rollup` entry in `config :samen_core, :rollups`.
  @rollups_key :rollups
  @rollup_name :product_event_rollup

  # The CLI's switch list, in ONE place: `cli_opts/1` reads what it could place and
  # `cli_invalid/1` reports what it could not. `--format` comes from the shared harness
  # spec, so a new adopter cannot spell it differently and silently drop it.
  @cli_switches [root: :string] ++ [Samen.Verifier.format_switch()]

  @impl Mix.Task
  def run(args) do
    opts = cli_opts(args)

    # A bad `--format` cannot be reported in the format it asked for — report it in text.
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

  @cli_switch_names ~w(--root --format)
  @cli_switches_text "--root <path> and --format <text|json>"

  # An argument OptionParser could not place is a VIOLATION, not a shrug: ignored, a
  # mistyped `--rrot <tree>` would let the run exit 0 over the default tree while the
  # caller believes it asked for something else.
  defp unknown_switch_violations(args) do
    Samen.Verifier.cli_argument_violations(cli_invalid(args), @cli_switch_names, @cli_switches_text)
  end

  @doc """
  The full violation list, separated from `run/1` so tests can call it without halting.
  `opts`: `:root` (an EXPLICIT tree for the scan — the CLI's `--root`: it must be a
  directory and is walked as given; empty discovery in it is a violation; default: the
  current app, the cwd).

  Returns message STRINGS (the text report's form). `violation_records/1` is the same
  list with each check's identity attached, for `--format json`.
  """
  def violations(opts \\ []), do: Enum.map(violation_records(opts), & &1.message)

  @doc """
  The same violations as RECORDS: `%{message:, kind:}` with `:app`/`:rule` added for the
  `missing_producer` family. A machine consumer attributes a failure from these fields
  rather than from the prose.
  """
  def violation_records(opts \\ []) do
    scan = scan(opts)

    cond do
      scan.bad_root -> [%{message: bad_root_message(scan.root), kind: :bad_root}]
      scan.apps == [] -> [%{message: empty_discovery_message(scan.root), kind: :empty_discovery}]
      true -> Enum.flat_map(scan.apps, &app_violations/1)
    end
  end

  @doc """
  The scan, exposed so the GREEN proof can assert what the walker actually SAW
  (anti-vacuity: a glob that silently matches nothing must never read as "no
  violation"). Returns `%{root:, apps:, bad_root:}`; each app is
  `%{app:, dir:, lib_files:, reader_mount:, emitter:, rollup:}` — `reader_mount` holds
  `{rel_path, line | :unparsable}` locations, `lib_files` is the count of shipped `lib/`
  files walked (the anti-vacuity witness), and `emitter`/`rollup` are booleans.
  `bad_root` is true when an EXPLICIT `:root` names something that is not a directory
  (`root` then holds the expanded path), which `violation_records/1` reports as a
  failure, never a skip.
  """
  def scan(opts \\ []) do
    case root(opts) do
      {:bad_root, path} ->
        %{root: path, apps: [], bad_root: true}

      root ->
        apps = root |> app_dirs() |> Enum.map(&scan_app(root, &1))
        %{root: root, apps: apps, bad_root: false}
    end
  end

  # ---------------------------------------------------------------------------
  # The per-app verdict — reader mounted ⟹ both producer links configured
  # ---------------------------------------------------------------------------

  # A host that mounts no reader owes nothing: the obligation is one-directional
  # (reader ⇒ producer), so a fed producer on a host with no reader is not a violation.
  defp app_violations(%{reader_mount: []}), do: []

  defp app_violations(%{app: app, reader_mount: mounts, emitter: emitter, rollup: rollup}) do
    where = where(mounts)
    e = emitter_violation(app, where, emitter)
    r = rollup_violation(app, where, rollup)

    Enum.reject([e, r], &is_nil/1)
  end

  defp emitter_violation(_app, _where, true), do: nil

  defp emitter_violation(app, where, false) do
    %{
      kind: :missing_producer,
      app: app,
      rule: :product_event_emitter,
      message:
        "#{app}: mounts the own-org analytics reader (samen_tenant_analytics_routes/2) at " <>
          "#{where} but configures NO product-event emitter — `Samen.Analytics.track/1` " <>
          "persists nothing without `config :samen_core, Samen.Analytics, " <>
          "product_event_resource: <Module>` (it returns {:ok, :dropped}), so the ledger " <>
          "behind every funnel stage stays empty and the page renders \"no data yet\" when " <>
          "the truth is \"no data possible\". Mount the Analytics scope and wire the emitter, " <>
          "or remove the reader mount."
    }
  end

  defp rollup_violation(_app, _where, true), do: nil

  defp rollup_violation(app, where, false) do
    %{
      kind: :missing_producer,
      app: app,
      rule: :product_event_rollup,
      message:
        "#{app}: mounts the own-org analytics reader (samen_tenant_analytics_routes/2) at " <>
          "#{where} but configures NO :product_event_rollup spec in `config :samen_core, " <>
          ":rollups` — the `paf_product_event_rollup` table the reader queries is rebuilt " <>
          "from the event ledger ONLY by that spec, so it stays empty even once the emitter " <>
          "fills the ledger. Register the domain-sourced :product_event_rollup spec, or " <>
          "remove the reader mount."
    }
  end

  defp where(locations) do
    Enum.map_join(locations, ", ", fn
      {path, :unparsable} -> "#{path} (unparsable — cannot certify)"
      {path, line} -> "#{path}:#{line}"
    end)
  end

  # ---------------------------------------------------------------------------
  # App discovery + the shipped-lib AST scan
  # ---------------------------------------------------------------------------

  # Every dir under the walked root carrying a mix.exs, by app name. A root that IS an
  # app counts too (its own `mix.exs` + `lib/`), so the DEFAULT root (the cwd of a host
  # running its own gate) is one app, and `--root <umbrella>` is every `*/mix.exs` app.
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

  defp scan_app(root, {app, dir}) do
    lib = source_files(root, Path.join(dir, "lib"))
    configs = config_files(Path.join(dir, "config"))

    %{
      app: app,
      dir: rel(dir, root),
      lib_files: length(lib),
      reader_mount: mount_locations(lib),
      emitter: Enum.any?(configs, &emitter_config?/1),
      rollup: Enum.any?(configs, &rollup_config?/1)
    }
  end

  # Every shipped `.ex` under an app's `lib/`, read and parsed EXACTLY ONCE:
  # `%{path: <root-relative>, text:, ast: <AST | nil>}`. Windows: backslash-carrying paths
  # make `Path.wildcard` match nothing, so every dir glob goes through the normalized
  # expansion helper (`Samen.SourceGlob`). A file that vanished between the glob and the
  # read is skipped rather than crashing the gate.
  defp source_files(root, dir) do
    for path <- Samen.SourceGlob.expand!(dir, "**/*.ex"),
        File.regular?(path),
        {:ok, text} <- [File.read(path)] do
      %{path: rel(path, root), text: text, ast: parse(text)}
    end
  end

  # Every `.exs` under an app's `config/` (config.exs, test.exs, runtime.exs, prod.exs…),
  # parsed for the two producer settings. Not root-relative: the message names the fix,
  # not the setting's location.
  defp config_files(dir) do
    for path <- Samen.SourceGlob.expand!(dir, "**/*.exs"),
        File.regular?(path),
        {:ok, text} <- [File.read(path)],
        ast = parse(text),
        ast != nil,
        do: ast
  end

  # `emit_warnings: false` — whether a host's source warns is not this gate's business.
  defp parse(text) do
    case Code.string_to_quoted(text, emit_warnings: false) do
      {:ok, ast} -> ast
      {:error, _} -> nil
    end
  end

  # The reader MOUNT CALLS in one pre-parsed shipped file, as {root-relative path, line}.
  # The AST match (over the `defmacro` head and `@doc` heredocs, which are not call nodes)
  # is what keeps the macro's own definition — and its documented example — from reading
  # as a mount.
  defp mount_locations(sources) do
    Enum.flat_map(sources, fn
      %{path: path, ast: nil, text: text} ->
        if String.contains?(text, "#{@reader_macro}("), do: [{path, :unparsable}], else: []

      %{path: path, ast: ast} ->
        for line <- call_lines(ast, &reader_call?/1), do: {path, line}
    end)
  end

  # A genuine `samen_tenant_analytics_routes(Namespace, opts \\ [])` CALL. The `defmacro`
  # head parses as `{:samen_tenant_analytics_routes, meta, [{:namespace, _, nil},
  # {:\\, _, [{:opts, _, nil}, []]}]}` — a FIRST argument variable and a SECOND argument
  # that is a `:\\` node, never a keyword list — so requiring a keyword-list second
  # argument (or the one-arg form) excludes the definition while matching every real mount.
  defp reader_call?({@reader_macro, _meta, [_namespace]}), do: true
  defp reader_call?({@reader_macro, _meta, [_namespace, opts]}), do: is_list(opts)
  defp reader_call?(_), do: false

  # ---------------------------------------------------------------------------
  # Config detection (AST, over every config/*.exs)
  # ---------------------------------------------------------------------------

  # `config :samen_core, Samen.Analytics, product_event_resource: <non-nil>`.
  defp emitter_config?(ast) do
    ast_any?(ast, fn
      {:config, _meta, [:samen_core, analytics, opts]} ->
        analytics_alias?(analytics) and truthy?(keyword_get(opts, @emitter_key))

      _ ->
        false
    end)
  end

  # A `:product_event_rollup` entry inside `config :samen_core, :rollups, [...]`.
  defp rollup_config?(ast) do
    ast_any?(ast, fn
      {:config, _meta, [:samen_core, @rollups_key, specs]} ->
        ast_any?(specs, fn
          {:%{}, _m, pairs} -> keyword_get(pairs, :name) == @rollup_name
          other -> other == {:name, @rollup_name}
        end)

      _ ->
        false
    end)
  end

  # `Samen.Analytics` as written literally in a config (`{:__aliases__, _, [:Samen, :Analytics]}`)
  # — or, after a partial aliasing the parser still resolves, any alias whose LAST TWO
  # segments are `Samen.Analytics`. A host that aliases the module differently is out of
  # scope by design (the shipped convention is the literal module).
  defp analytics_alias?({:__aliases__, _meta, parts}) when is_list(parts) do
    case Enum.take(parts, -2) do
      @analytics_module -> true
      _ -> false
    end
  end

  defp analytics_alias?(_), do: false

  # A keyword list's value for `key` (nil when absent or when `opts` is not a list).
  defp keyword_get(term, key) when is_list(term) do
    Enum.find_value(term, fn
      {^key, value} -> value
      _ -> nil
    end)
  end

  defp keyword_get(_term, _key), do: nil

  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(_), do: true

  # Any node satisfying `pred` anywhere in the AST (used for the option-shaped signals,
  # which are key/value tuples rather than calls).
  defp ast_any?(ast, pred) do
    {_ast, found} = Macro.prewalk(ast, false, fn node, acc -> {node, acc or pred.(node)} end)
    found
  end

  # Line numbers of every call node satisfying `pred` (accumulate + reverse: the walker
  # visits depth-first, so prepending would report a file's mounts in reverse order).
  defp call_lines(ast, pred) do
    {_ast, lines} =
      Macro.prewalk(ast, [], fn
        {name, meta, args} = node, acc when is_atom(name) and is_list(args) ->
          if pred.(node),
            do: {node, [Keyword.get(meta, :line, 0) | acc]},
            else: {node, acc}

        node, acc ->
          {node, acc}
      end)

    Enum.reverse(lines)
  end

  # ---------------------------------------------------------------------------
  # The root + its degenerate shapes
  # ---------------------------------------------------------------------------

  # An EXPLICIT `:root` (the CLI's `--root`) is taken at its word: it is walked as given —
  # it need not be a samen monorepo checkout, and the root itself may BE a host app — so a
  # scratch copy or one standalone host can be gated. It must exist as a directory, though:
  # a mistyped path is a hard `{:bad_root, _}` violation. The DEFAULT is the cwd, which —
  # inside a Mix project — is the host app itself.
  defp root(opts) do
    case Keyword.get(opts, :root) do
      path when is_binary(path) ->
        expanded = Path.expand(path)
        if File.dir?(expanded), do: expanded, else: {:bad_root, expanded}

      _ ->
        Path.expand(File.cwd!())
    end
  end

  defp bad_root_message(path) do
    "--root #{path} is not a directory — a tree that cannot be walked certifies nothing " <>
      "(fail-closed: point --root at the checkout root that holds the app dirs, or at the " <>
      "host app itself)."
  end

  defp empty_discovery_message(root) do
    "the analytics-producer scan found NO app dirs under #{root} — a scan that discovers " <>
      "nothing certifies nothing (fail-closed: an empty walk must never read as " <>
      "\"no violation\")."
  end

  # Both sides normalized: the walker's paths come back forward-slashed (Samen.SourceGlob)
  # while `root` is a `Path.expand/1` result, so a raw `Path.relative_to/2` would not strip
  # the prefix on Windows.
  defp rel(path, root) do
    Path.relative_to(Samen.SourceGlob.normalize(path), Samen.SourceGlob.normalize(root))
  end
end
