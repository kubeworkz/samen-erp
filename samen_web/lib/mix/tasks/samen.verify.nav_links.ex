defmodule Mix.Tasks.Samen.Verify.NavLinks do
  @shortdoc "Fail a host's build when a sidebar nav label points at a route its router does not mount (tree-scoped: the host's own router source + compiled route table); --format json prints one machine-readable line."

  @moduledoc """
  `mix samen.verify.nav_links` — the SIDEBAR-REACHABILITY build gate: the framework's inherited
  navigation must never link a route the host did not mount.

  ## Why this exists

  `Samen.UI.Nav.module_nav/1` renders its gated module groups off the HOST's mount labels — the
  X1 posture: a label's presence IS the dead-link guard, because a host that never mounted
  `/chat` never sets `:chat_path`. That guard is a convention, and nothing enforced it: a label
  that drifts from the route macro it belongs to (a mount moved to `path: "/conversations"` while
  `chat_path` still says `/chat`), or a group that was defaulted instead of gated, ships a
  sidebar link that raises `Phoenix.Router.NoRouteError` on the user's first click — the exact
  PP-8/PP-9 class this navigation has already been repaired for twice. `pawchart` carried a live
  instance when this task was written: it mounts no automation surface, yet a defaulted
  `/automation` item put that `NoRouteError` one click away on every tenant page. That item is
  label-gated now, and this task is what keeps it that way.

  ## What it certifies (two legs, both fail-closed)

  The host's navigation is certified from its OWN source plus its COMPILED route table:

    1. **dead links** — the links those mounts would emit for the gated module groups (ERP ·
       Banking · Work · Documents · Chat · Discover · Insights · Calendar · AI · Feature flags ·
       Automation) are RENDERED with the real `Samen.UI.Nav.module_nav/1` from the label maps the
       mounts actually carry, and every emitted `href` must match a `GET` route the compiled
       router declares. The link set is rendered, never re-declared here, so a new nav item is
       covered the moment it exists — there is no second copy of the href shapes to drift from.

    2. **unlabelled mounts** — a TENANT-plane mount of a module that OWNS a nav group
       (`samen_files_routes(:files, …)` → `:files_path`, `samen_module_routes(:work, …)` →
       `:work_path`, …) with no path label is reported too: no label means no group, so the
       surface would be mounted and unreachable from the app's own sidebar — a nav island. A host
       that reaches such a route from its own pages can say so explicitly with
       `--allow-unlabelled <kinds>`; a silent absence is never accepted.

  The four inherited module groups (CRM · Billing · Support · Marketing), the Inbox group and the
  Workspace Settings item render from framework DEFAULTS gated by the `surfaces` filter, not from
  a host label, so they are out of scope by construction — this task checks what a HOST labels
  (`:kb`/`:csat` public portals and `:csv` — an action on a per-resource route, not a destination
  — own no group at all).

  ## Which sources it reads

  `--source-dir` (repeatable, default `lib`) is scanned for `samen_*_routes` mount CALLS and for
  the label maps they are handed: an inline map, a module-attribute literal, or a
  `Map.put`/`Map.merge` chain over one. An unresolvable `:labels`/`:plane`, an unparseable source
  file, a missing source dir, and a scan that finds no tenant mount at all are all VIOLATIONS
  rather than skips — a mount the verifier cannot reason about certifies nothing. A call whose
  first two arguments are not literals — the framework's own
  `defmacro samen_files_routes(kind, namespace, …)` heads — is not a host mount and is skipped,
  because a host names its module kind and namespace literally. Doc examples are invisible to it,
  because the scan is AST-based, so a `@moduledoc` snippet is not a call. Point it at the HOST's
  router tree: the framework's macro module defines the macros rather than mounting them.

  ## Usage

      mix samen.verify.nav_links --router SamenerpWeb.Router
      mix samen.verify.nav_links --router DriftwoodWeb.Router --source-dir lib
      mix samen.verify.nav_links --router MyAppWeb.Router --source-dir test/support/my_host
      mix samen.verify.nav_links --router MyAppWeb.Router --allow-unlabelled chat,csv
      mix samen.verify.nav_links --router MyAppWeb.Router --host driftwood --format json

  Wired into every host gate that serves a framework sidebar (`samenerp`, `driftwood`,
  `pawchart`, and `samen_web` against its own test host fixture). `demo` mounts no framework UI
  (`CLAUDE.md`: API-only), so it has no sidebar to certify and no such step.

  A `mix samen.gen.app --web` scaffold is deliberately NOT wired: its `--modules` surfaces
  (`/files`, `/search`) ride the generated `:extra` Product group rather than a gated
  `module_nav/1` group, so such a host carries NO gated label and the `:empty_emit` leg would
  (correctly) refuse to certify it. A generated host that later threads a gated label runs this
  same command against its own router.

  ## Exit code (fail-closed)

  Exits 0 on success, 1 on any violation (via `Samen.Verifier`, i.e. `:erlang.halt/1`, so no
  cleanup hook can swallow the code) — including for a `--format` value this task does not print
  or an argument it does not recognize, because a mistyped invocation must never be quietly served
  a different report than it asked for.
  """

  use Mix.Task

  alias Samen.SourceGlob

  @task_name "samen.verify.nav_links"

  # Which nav group each gated module owns — the label that makes it render. Data, so the coverage
  # leg, the emitted-link filter and `--allow-unlabelled` are all driven by one table rather than a
  # branch per module.
  @gated_kinds %{
    erp: :erp_path,
    banking: :banking_path,
    work: :work_path,
    files: :files_path,
    chat: :chat_path,
    search: :search_path,
    analytics: :analytics_path,
    ics: :ics_path,
    ai: :ai_path,
    flags: :flags_path,
    automation: :automation_path
  }

  # Every mount macro the framework exports that carries mount labels. `:kind` is the module kind
  # (`:__first_arg__` for the generic `samen_module_routes/3`, whose first argument is the kind);
  # `:plane` says whether the macro reads a `plane:` option or is an operator mount by
  # construction. A macro absent here is not a labelled module mount (`samen_fleet_routes/1`,
  # `samen_webhook_routes/1`, `samen_metrics_route/1`) and contributes no nav links.
  @mount_macros %{
    "samen_erp_routes" => %{kind: :erp, plane: :opt},
    "samen_files_routes" => %{kind: :files, plane: :opt},
    "samen_chat_routes" => %{kind: :chat, plane: :opt},
    "samen_search_routes" => %{kind: :search, plane: :opt},
    "samen_ics_routes" => %{kind: :ics, plane: :opt},
    "samen_ai_routes" => %{kind: :ai, plane: :opt},
    "samen_flags_routes" => %{kind: :flags, plane: :opt},
    "samen_automation_routes" => %{kind: :automation, plane: :opt},
    "samen_tenant_analytics_routes" => %{kind: :analytics, plane: :opt},
    "samen_csv_routes" => %{kind: :csv, plane: :opt},
    "samen_module_routes" => %{kind: :__first_arg__, plane: :opt},
    "samen_settings_routes" => %{kind: :settings, plane: :opt},
    "samen_notifications_routes" => %{kind: :notifications, plane: :opt},
    "samen_auth_routes" => %{kind: :auth, plane: :opt},
    "samen_onboarding_routes" => %{kind: :auth, plane: :opt},
    "samen_operator_routes" => %{kind: :operator, plane: :operator}
  }

  # The label key each gated group renders on (derived, so the two tuples can never drift).
  @gated_label_keys Map.values(@gated_kinds)

  @cli_switches [router: :string, host: :string, source_dir: [:string, :keep], allow_unlabelled: :string] ++
                  [Samen.Verifier.format_switch()]

  @switches_text "--router MODULE [--host NAME] [--source-dir DIR] [--allow-unlabelled KINDS] [--format text|json]"

  @impl Mix.Task
  def run(args) do
    # app.start compiles + starts the app so the host's router module is loadable.
    Mix.Task.run("app.start")

    # `{parsed, rest, invalid}` — an argument OptionParser could not place lands in the THIRD
    # slot, and is turned into a violation below rather than ignored.
    {opts, _rest, invalid} = OptionParser.parse(args, strict: @cli_switches)
    {format, format_violations} = Samen.Verifier.resolve_format(opts)

    violations =
      format_violations ++
        Samen.Verifier.cli_argument_violations(invalid, Keyword.keys(@cli_switches), @switches_text) ++
        run_checks(opts)

    Samen.Verifier.halt_if_violations(@task_name, violations, format: format)
  end

  defp run_checks(opts) do
    {allow, allow_violations} = resolve_allow(Keyword.get(opts, :allow_unlabelled))

    case Keyword.get(opts, :router) do
      nil ->
        allow_violations ++
          [
            %{
              kind: :cli_argument,
              message:
                "--router MODULE is required: this task certifies one host against the " <>
                  "router it actually serves (switches: #{@switches_text})."
            }
          ]

      router_str ->
        allow_violations ++
          check(Module.concat([router_str]),
            app: Keyword.get(opts, :host, to_string(Mix.Project.config()[:app])),
            source_dirs: Keyword.get_values(opts, :source_dir),
            allow_unlabelled: allow
          )
    end
  end

  # `--allow-unlabelled` names the gated module kinds a host links from its own pages; an unknown
  # name is refused (never silently ignored), and the recognized ones are matched against the
  # @gated_kinds table so no atom is minted from user input.
  defp resolve_allow(nil), do: {[], []}
  defp resolve_allow(""), do: {[], []}

  defp resolve_allow(list) do
    names =
      list |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    known = Map.new(@gated_kinds, fn {kind, _label} -> {Atom.to_string(kind), kind} end)

    allowed = for name <- names, kind = Map.get(known, name), do: kind

    unknown = Enum.reject(names, &Map.has_key?(known, &1))

    violations =
      Enum.map(unknown, fn name ->
        %{
          kind: :cli_argument,
          message:
            "--allow-unlabelled #{name} is not a gated module kind — expected a comma-separated " <>
              "subset of: #{Enum.map_join(Map.keys(@gated_kinds), ", ", &to_string/1)}."
        }
      end)

    {allowed, violations}
  end

  @doc """
  Certify `router` against the mount labels declared in the source tree.

  `opts`:
    * `:source_dirs` — dirs to scan (default `["lib"]`, resolved against the cwd);
    * `:allow_unlabelled` — gated module kinds a host mounts without a nav label on purpose;
    * `:app` — the host name used in violation records.

  Returns the list of violation records; `[]` means the sidebar is sound. Public so the framework
  suite can drive the whole check against a fixture tree plus a real compiled router without
  spawning a task process (which would `:erlang.halt/1`).
  """
  @spec check(module(), keyword()) :: [map()]
  def check(router, opts \\ []) do
    source_dirs = case Keyword.get(opts, :source_dirs, []) do
      [] -> ["lib"]
      dirs -> dirs
    end

    allow = Keyword.get(opts, :allow_unlabelled, [])
    app = Keyword.get(opts, :app)

    with {:ok, routes} <- load_routes(router),
         {:ok, files} <- source_files(source_dirs),
         {:ok, mounts} <- mount_calls(files) do
      check_dead_links(router, routes, mounts, app) ++ check_unlabelled(mounts, allow, app)
    else
      {:error, violation} -> [violation]
    end
  end

  # ---- leg 1: every emitted nav link resolves --------------------------------------------------

  defp check_dead_links(router, routes, mounts, app) do
    tenant_mounts = Enum.filter(mounts, &(&1.plane == :tenant))
    labelled = Enum.filter(tenant_mounts, &(gated_paths(&1.labels) != []))

    cond do
      tenant_mounts == [] ->
        [
          violation(:scan, app, "no TENANT-plane mount calls found — the scan found nothing to " <>
            "certify (wrong --source-dir?)")
        ]

      labelled == [] ->
        [
          violation(:empty_emit, app, "no gated nav label is declared on any tenant mount " <>
            "(checked: #{Enum.map_join(Map.keys(@gated_kinds), ", ", &to_string/1)}) — the " <>
            "sidebar would render no module group, so this run certifies nothing")
        ]

      true ->
        links = labelled |> Enum.flat_map(&emitted_links/1) |> Enum.uniq_by(& &1.href)
        dead_links(router, routes, links, labelled, app)
    end
  end

  defp dead_links(_router, _routes, [], labelled, app) do
    [
      violation(:empty_emit, app, "gated labels are declared but the nav emitted no link for " <>
        "them — a nav regression (mounts: #{Enum.map_join(labelled, "; ", &describe/1)})")
    ]
  end

  defp dead_links(router, routes, links, _labelled, app) do
    Enum.flat_map(links, fn link ->
      if route_match?(routes, path_of(link.href)) do
        []
      else
        [
          violation(:dead_link, app, "the sidebar links #{link.href} (label #{link.label} from " <>
            "#{link.source.file}:#{link.source.line}) but #{inspect(router)} declares no matching " <>
            "GET route — Phoenix.Router.NoRouteError on the user's first click")
        ]
      end
    end)
  end

  # ---- leg 2: a mounted gated module must own a label -----------------------------------------

  defp check_unlabelled(mounts, allow, app) do
    mounts
    |> Enum.filter(&(&1.plane == :tenant))
    |> Enum.filter(&Map.has_key?(@gated_kinds, &1.kind))
    |> Enum.reject(&(&1.kind in allow))
    |> Enum.flat_map(fn mount ->
      key = Map.fetch!(@gated_kinds, mount.kind)
      where = "#{mount.file}:#{mount.line}"

      case Map.get(mount.labels, key) do
        path when is_binary(path) ->
          []

        nil ->
          [
            violation(:unlabelled_mount, app, "#{where} mounts :#{mount.kind} on the tenant " <>
              "plane without threading #{inspect(key)} — the surface would be reachable only by " <>
              "hand-typing its URL (no nav group renders). Add `#{key}: \"…\"` to that mount's " <>
              "labels, or pass --allow-unlabelled #{mount.kind} if the host links it from its own " <>
              "pages.")
          ]

        other ->
          [
            violation(:labels, app, "#{where} threads #{inspect(key)} = #{inspect(other)}, " <>
              "which is not a path string — module_nav/1 interpolates that label into an href, so " <>
              "a page rendering this nav would raise.")
          ]
      end
    end)
  end

  # ---- the emitted link set -------------------------------------------------------------------

  # Render the REAL nav for the labels this mount carries (the artifact, never a re-declared href
  # table) and keep the links that belong to a gated group — exactly the ones whose label put them
  # in the sidebar.
  defp emitted_links(mount) do
    paths = gated_paths(mount.labels)

    attr_map =
      paths
      |> Enum.into(%{org_id: "nav-links-verify", active: nil, extra: [], surfaces: :all})
      |> Map.put(:__changed__, %{})

    # __render_component__/4 (not the render_component/2 macro): the macro binds the endpoint from
    # the COMPILING project's config, while this task runs inside a HOST's compile — a pure
    # function component renders identically with no endpoint (verified: the diff renderer never
    # consults it for a stateless component).
    html = Phoenix.LiveViewTest.__render_component__(nil, &Samen.UI.module_nav/1, attr_map, [])

    ~r/href="([^"]+)"/
    |> Regex.scan(html)
    |> Enum.map(fn [_, href] -> href end)
    |> Enum.filter(fn href -> Enum.any?(paths, fn {_key, path} -> under?(href, path) end) end)
    |> Enum.map(fn href ->
      {key, _path} = Enum.find(paths, fn {_key, path} -> under?(href, path) end)
      %{href: href, label: to_string(key), source: mount}
    end)
  end

  # {label_key, path} for every gated label this mount carries as a path string.
  defp gated_paths(labels) do
    for {_kind, key} <- @gated_kinds, path = Map.get(labels, key), is_binary(path), do: {key, path}
  end

  defp under?(href, path) do
    plain = path_of(href)
    plain == path or String.starts_with?(plain, String.trim_trailing(path, "/") <> "/")
  end

  defp path_of(href), do: href |> String.split("?") |> hd()

  defp describe(mount) do
    paths = Enum.map_join(gated_paths(mount.labels), ", ", fn {key, path} -> "#{key}=#{path}" end)
    "#{mount.file}:#{mount.line} (#{paths})"
  end

  # ---- the route table ------------------------------------------------------------------------

  defp load_routes(router) do
    case Code.ensure_compiled(router) do
      {:module, ^router} ->
        {:ok, router.__routes__() |> Enum.filter(&(&1.verb in [:get, :*])) |> Enum.map(& &1.path)}

      _other ->
        {:error,
         violation(:router, nil, "could not load #{inspect(router)} — check the --router value " <>
           "(a host's router must be compiled in this env before it can be certified)")}
    end
  end

  # The nav is a GET navigation, so only a GET route can satisfy a link; dynamic segments match any
  # one segment (`/crm/:id`).
  defp route_match?(routes, path) do
    path_segments = segments(path)

    Enum.any?(routes, fn declared ->
      declared_segments = segments(declared)

      length(declared_segments) == length(path_segments) and
        Enum.all?(Enum.zip(declared_segments, path_segments), fn {d, actual} ->
          dynamic?(d) or d == actual
        end)
    end)
  end

  defp dynamic?(segment), do: String.starts_with?(segment, ":") or String.starts_with?(segment, "*")

  defp segments(path), do: path |> String.split("/") |> Enum.reject(&(&1 == ""))

  # ---- the source scan ------------------------------------------------------------------------

  defp source_files(source_dirs) do
    case Enum.reject(source_dirs, &File.dir?/1) do
      [] ->
        {:ok, Enum.flat_map(source_dirs, &SourceGlob.expand!/1)}

      missing ->
        {:error,
         violation(:source, nil, "source dir(s) not found: #{Enum.join(missing, ", ")} — refusing " <>
           "to certify a tree it could not read (fail-closed)")}
    end
  end

  @doc """
  Every `samen_*_routes` mount call in `files`, as records:

      %{kind: :files, plane: :tenant, labels: %{files_path: "/files"},
        macro: :samen_files_routes, file: "lib/my_app_web/router.ex", line: 42}

  AST-based, so a `@moduledoc`/comment example is never counted. Returns `{:error, violation}` when
  a call's `:plane`/`:labels` cannot be resolved statically, or when a source file does not parse:
  a mount the verifier cannot reason about is a failure, not a silent skip. Public so the suite can
  assert the scan directly.
  """
  @spec mount_calls([Path.t()]) :: {:ok, [map()]} | {:error, map()}
  def mount_calls(files) do
    Enum.reduce_while(files, {:ok, []}, fn file, {:ok, acc} ->
      with {:ok, source} <- read(file),
           {:ok, ast} <- parse(source, file),
           {:ok, calls} <- calls_in(ast, file) do
        {:cont, {:ok, acc ++ calls}}
      else
        {:error, violation} -> {:halt, {:error, violation}}
      end
    end)
  end

  defp read(file) do
    case File.read(file) do
      {:ok, source} -> {:ok, source}
      {:error, reason} -> {:error, violation(:source, nil, "could not read #{file}: #{inspect(reason)}")}
    end
  end

  defp parse(source, file) do
    case Code.string_to_quoted(source, columns: true, token_metadata: true) do
      {:ok, ast} ->
        {:ok, ast}

      {:error, {location, error, token}} ->
        # `location` is a line number in some versions and a metadata keyword list
        # (`[line: 2, column: 13, …]`) in others — never interpolate it directly.
        {:error,
         violation(:source, nil, "could not parse #{file} #{location_text(location)}: " <>
           "#{inspect(error)} #{inspect(token)}")}
    end
  end

  defp location_text(location) when is_list(location) do
    case Keyword.get(location, :line) do
      nil -> inspect(location)
      line -> "at line #{line}"
    end
  end

  defp location_text(location), do: "at line #{location}"

  defp calls_in(ast, file) do
    attrs = module_attrs(ast)

    ast
    |> find_nodes(fn
      {name, meta, args} when is_atom(name) and is_list(args) ->
        if Map.has_key?(@mount_macros, Atom.to_string(name)), do: {name, meta, args}

      _ ->
        nil
    end)
    |> Enum.reduce_while({:ok, []}, fn node, {:ok, acc} ->
      case mount_call(node, attrs, file) do
        {:ok, call} -> {:cont, {:ok, acc ++ [call]}}
        :skip -> {:cont, {:ok, acc}}
        {:error, violation} -> {:halt, {:error, violation}}
      end
    end)
  end

  defp mount_call({macro, meta, args}, attrs, file) do
    spec = Map.fetch!(@mount_macros, Atom.to_string(macro))

    if host_mount?(args) do
      case kind_of(spec.kind, args) do
        {:ok, kind} -> do_mount_call(macro, spec, meta, args, kind, attrs, file)
        {:error, violation} -> {:error, violation}
      end
    else
      :skip
    end
  end

  # A host mount names its module kind + namespace literally (`samen_files_routes(:files, Acme,
  # …)`) and passes its options as a keyword list, while a macro DEFINITION in the framework's
  # router module threads variables (`defmacro samen_files_routes(kind, namespace, opts \\ [])`)
  # — the latter is not a host mount and is skipped rather than reported as an unlabelled one.
  # Only the POSITIONAL arguments decide: a dynamic `labels:` expression must still be reached and
  # REPORTED, not skipped.
  defp host_mount?([first | rest]) do
    literal_arg?(first) and Enum.all?(rest, &(literal_arg?(&1) or mount_opts?(&1)))
  end

  defp host_mount?(_args), do: false

  defp literal_arg?(value) when is_atom(value) or is_binary(value) or is_number(value), do: true
  defp literal_arg?({:@, _, [{name, _, _}]}) when is_atom(name), do: true
  defp literal_arg?({:__aliases__, _, _}), do: true
  defp literal_arg?({:__block__, _, [value]}), do: literal_arg?(value)
  defp literal_arg?(_other), do: false

  defp kind_of(:__first_arg__, [kind | _]) when is_atom(kind), do: {:ok, kind}

  defp kind_of(:__first_arg__, _args),
    do: {:error, violation(:unresolved, nil, "samen_module_routes/3 was called without a literal " <>
      "module kind as its first argument — an uncertifiable mount is reported rather than skipped")}

  defp kind_of(kind, _args), do: {:ok, kind}

  defp do_mount_call(macro, spec, meta, args, kind, attrs, file) do
    opts = Enum.find(args, [], &mount_opts?/1)
    line = meta[:line] || 0

    with {:ok, plane} <- resolve_plane(spec.plane, Keyword.get(opts, :plane)),
         {:ok, labels} <- resolve_labels(Keyword.get(opts, :labels), attrs) do
      {:ok, %{kind: kind, plane: plane, labels: labels, macro: macro, file: file, line: line}}
    else
      {:unresolved, what} ->
        {:error,
         violation(:unresolved, nil, "#{file}:#{line} calls #{macro} with a #{what} this verifier " <>
           "cannot resolve statically — an uncertifiable mount is reported rather than skipped " <>
           "(pass a literal, a module-attribute literal, or a Map.put/Map.merge chain over one)")}
    end
  end

  # The mount macros take their options as a keyword list (an empty list included).
  defp mount_opts?(arg) do
    is_list(arg) and Enum.all?(arg, &match?({key, _} when is_atom(key), &1))
  end

  # `samen_operator_routes/2` is an operator mount by construction; every other macro defaults to
  # the tenant plane and honours an explicit `plane:` option.
  defp resolve_plane(:operator, _opt), do: {:ok, :operator}
  defp resolve_plane(:opt, nil), do: {:ok, :tenant}
  defp resolve_plane(:opt, :tenant), do: {:ok, :tenant}
  defp resolve_plane(:opt, :operator), do: {:ok, :operator}
  defp resolve_plane(:opt, _other), do: {:unresolved, ":plane"}

  # `labels:` may be an inline map, a module-attribute literal, or a Map.put/Map.merge chain over
  # one. A value that is not a literal is dropped — EXCEPT under a gated path key, where an
  # unresolvable value is the whole point of the check and is reported.
  defp resolve_labels(nil, _attrs), do: {:ok, %{}}

  defp resolve_labels(ast, attrs) do
    case resolve_map_ast(ast, attrs) do
      {:ok, map} ->
        if Enum.any?(@gated_label_keys, &(Map.get(map, &1) == :__unresolved__)) do
          {:unresolved, "gated path label whose value"}
        else
          {:ok, Map.reject(map, fn {_key, value} -> value == :__unresolved__ end)}
        end

      :unresolved ->
        {:unresolved, ":labels expression"}
    end
  end

  # Module attributes, as `name => value AST`: both `@x %{…}` (the `@current_org_labels` seam) and
  # `@x = %{…}`. The value AST is kept UNRESOLVED and resolved on demand, so a chain
  # (`@a = @b = %{…}`) and a literal (`@tenant_landing "/clinic"`) both resolve at the label site.
  defp module_attrs(ast) do
    ast
    |> find_nodes(&attr_node/1)
    |> Map.new()
  end

  defp attr_node({:@, _, [{name, _, [value]}]}) when is_atom(name), do: {name, value}
  defp attr_node({:=, _, [{:@, _, [{name, _, nil}]}, value]}) when is_atom(name), do: {name, value}
  defp attr_node(_other), do: nil

  defp find_nodes(ast, fun) do
    ast
    |> Macro.prewalk([], fn node, acc ->
      case fun.(node) do
        nil -> {node, acc}
        found -> {node, [found | acc]}
      end
    end)
    |> elem(1)
    |> Enum.reverse()
  end

  defp resolve_map_ast({:%{}, _, pairs}, attrs), do: resolve_map(pairs, attrs)

  defp resolve_map_ast({:@, _, [{name, _, _}]}, attrs) do
    case Map.get(attrs, name) do
      nil -> :unresolved
      value_ast -> resolve_map_ast(value_ast, attrs)
    end
  end

  defp resolve_map_ast({{:., _, [{:__aliases__, _, [:Map]}, fun]}, _, [base | rest]}, attrs)
       when fun in [:put, :merge] do
    case resolve_map_ast(base, attrs) do
      {:ok, base_map} -> apply_map_fun(fun, base_map, rest, attrs)
      :unresolved -> :unresolved
    end
  end

  defp resolve_map_ast(_other, _attrs), do: :unresolved

  defp apply_map_fun(:put, map, [key, value], attrs) do
    if is_atom(key) and not is_nil(key) do
      {:ok, Map.put(map, key, resolve_value(value, attrs))}
    else
      :unresolved
    end
  end

  defp apply_map_fun(:merge, map, [other], attrs) do
    case resolve_map_ast(other, attrs) do
      {:ok, other_map} -> {:ok, Map.merge(map, other_map)}
      :unresolved -> :unresolved
    end
  end

  defp apply_map_fun(_fun, _map, _args, _attrs), do: :unresolved

  defp resolve_map(pairs, attrs) do
    Enum.reduce_while(pairs, {:ok, %{}}, fn
      {key, value}, {:ok, acc} when is_atom(key) ->
        {:cont, {:ok, Map.put(acc, key, resolve_value(value, attrs))}}

      {_key, _value}, {:ok, acc} ->
        {:cont, {:ok, acc}}

      _pair, :unresolved ->
        {:halt, :unresolved}
    end)
  end

  # A literal resolves to itself; an `@attr` to its value; anything else (an MFA, a function call)
  # is kept as :__unresolved__ so a gated path key with a dynamic value is still reported.
  defp resolve_value({:__block__, _, [inner]}, attrs), do: resolve_value(inner, attrs)

  defp resolve_value(value, _attrs)
       when is_binary(value) or is_number(value) or is_boolean(value) or is_nil(value),
       do: value

  defp resolve_value({:@, _, [{name, _, _}]}, attrs) do
    case Map.get(attrs, name) do
      nil -> :__unresolved__
      value_ast -> resolve_value(value_ast, attrs)
    end
  end

  defp resolve_value(_other, _attrs), do: :__unresolved__

  # ---- violation records ----------------------------------------------------------------------

  defp violation(kind, app, message), do: %{kind: kind, message: message, app: app}
end
