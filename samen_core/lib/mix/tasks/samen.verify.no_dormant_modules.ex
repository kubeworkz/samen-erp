defmodule Mix.Tasks.Samen.Verify.NoDormantModules do
  @shortdoc "Verify no scopes/ module is unmounted, unmigrated, and unreferenced (ADR-055)."

  @moduledoc """
  `mix samen.verify.no_dormant_modules` — ADR-055 decision 9.

  A module under `samen_core/lib/samen/scopes/` is **dormant** when all three hold:

    1. it is unreachable from a mounted scope — no host does
       `use Samen.Scopes.<Scope>`, and no live blueprint/scope module or
       external `lib` file reaches it;
    2. no migration in any app creates its declared table;
    3. no live code outside the module's own file references it.

  The walk is static (no DB, no `app.start`). It seeds live modules from:

    * a table created by any app migration;
    * an external `lib` reference outside the module's scope;
    * a reference from a mounted scope's module or a `*blueprint*.ex`.

  It then closes over references between live modules. Anything left inside a
  scope is dormant and fails the gate. This is deliberately module-level, not
  directory-level: the deleted `Finance.TrialBalance` (E11) and
  `Work.TimesheetEntry` (E15) lived inside mounted scopes, while the live
  `Inventory.TransferOrder`/`LandedCost` and `Finance` expense helpers remain.

  `--root` points the walk at another tree (used by the fixture tests):

      mix samen.verify.no_dormant_modules --root /tmp/fixture
  """

  use Mix.Task

  @task_name "samen.verify.no_dormant_modules"

  # ADR-055 §7 explicitly preserves E13/E14, and E10 (FX) is live; its
  # conversion helpers are part of that surface. These are reachable only
  # through tests or macro expansion, which the static walk cannot see.
  #
  # The execution reconciliation also preserved Finance/Inventory read and
  # test-oracle modules. They are exercised by focused tests but are not
  # reachable from a mounted scope and their tables are not migrated by any
  # host, so the static walk would otherwise flag them.
  @ratified_live [
    "Samen.Scopes.Inventory.TransferGuard",
    "Samen.Scopes.Inventory.LandedCostAllocator",
    "Samen.Scopes.Finance.FxConvert",
    "Samen.Scopes.Finance.FxConversionGuard",
    "Samen.Scopes.Finance.ApAchArtifact",
    "Samen.Scopes.Finance.ApAchArtifactRecord",
    "Samen.Scopes.Finance.ApInvoiceCapture",
    "Samen.Scopes.Finance.AssetRegister",
    "Samen.Scopes.Finance.PrepaidRegister",
    "Samen.Scopes.Finance.BudgetVsActual",
    "Samen.Scopes.Finance.GrantReconcile",
    "Samen.Scopes.Finance.ReconcileRecognition",
    "Samen.Scopes.Finance.TaxCalculator",
    "Samen.Scopes.Inventory.ReconcileFulfillment",
    "Samen.Scopes.Inventory.ReconcileProcurement",
    "Samen.Scopes.Inventory.ReconcileProduction"
  ]

  @impl Mix.Task
  def run(args) do
    {opts, _rest, invalid} = OptionParser.parse(args, strict: [root: :string])
    root = Keyword.get(opts, :root) || repo_root()

    violations =
      Samen.Verifier.cli_argument_violations(invalid, [:root], "--root PATH") ++
        check(root)

    Samen.Verifier.halt_if_violations(@task_name, violations)
  end

  @doc """
  Return the dormant-module violations under `root` as human-readable strings.
  """
  def check(root) do
    root = norm(root)
    scopes_root = norm(Path.join([root, "samen_core", "lib", "samen", "scopes"]))

    if not File.dir?(scopes_root) do
      ["no scopes directory at #{scopes_root} (check --root)"]
    else
      modules = modules(scopes_root)
      lib = lib_contents(root)
      mounted = mounted_scopes(lib, scopes_root)
      migrated = migrated_tables(root)
      refs = references(modules, lib)

      live =
        modules
        |> seed_live(mounted, migrated, refs, scopes_root)
        |> close_live(modules, refs)

      modules
      |> Enum.reject(&MapSet.member?(live, &1.module))
      |> Enum.sort_by(& &1.module)
      |> Enum.map(&violation(&1, root))
    end
  end

  # ---------------------------------------------------------------------------
  # Module discovery
  # ---------------------------------------------------------------------------

  defp modules(scopes_root) do
    [scopes_root, "**", "*.ex"]
    |> Path.join()
    |> norm()
    |> Path.wildcard()
    |> Enum.flat_map(fn file ->
      content = File.read!(file)

      for module <- extract_modules(content) do
        %{
          module: module,
          file: file,
          scope: scope_for(file, scopes_root),
          table: table_for(content)
        }
      end
    end)
    |> Enum.uniq_by(& &1.module)
  end

  defp extract_modules(content) do
    ~r/^\s*defmodule\s+([A-Z][A-Za-z0-9_.]*)\s+do/m
    |> Regex.scan(content)
    |> Enum.map(fn [_, module] -> module end)
    |> Enum.filter(&String.starts_with?(&1, "Samen.Scopes."))
  end

  defp scope_for(file, scopes_root) do
    scope =
      file
      |> Path.relative_to(scopes_root)
      |> Path.split()
      |> List.first()
      |> Path.rootname()
      |> Macro.camelize()

    "Samen.Scopes." <> scope
  end

  defp table_for(content) do
    case Regex.run(~r/table\(\s*[:"']?([a-z0-9_]+)/, content) do
      [_, table] -> table
      _ -> nil
    end
  end

  # ---------------------------------------------------------------------------
  # Source facts
  # ---------------------------------------------------------------------------

  defp lib_contents(root) do
    [root, "*", "lib", "**", "*.ex"]
    |> Path.join()
    |> norm()
    |> Path.wildcard()
    |> Map.new(fn file -> {file, File.read!(file)} end)
  end

  defp mounted_scopes(lib, scopes_root) do
    lib
    |> Enum.reject(fn {file, _} -> String.starts_with?(file, scopes_root) end)
    |> Enum.flat_map(fn {_file, content} ->
      ~r/\buse\s+Samen\.Scopes\.([A-Z][A-Za-z0-9_.]*)/
      |> Regex.scan(content)
      |> Enum.map(fn [_, scope] -> "Samen.Scopes." <> scope end)
    end)
    |> MapSet.new()
  end

  defp migrated_tables(root) do
    [root, "*", "priv", "**", "migrations", "*.exs"]
    |> Path.join()
    |> norm()
    |> Path.wildcard()
    |> Enum.map_join("\n", &File.read!/1)
    |> then(fn text ->
      ~r/create\s+(?:if_not_exists\s+)?table\(\s*[:"']?([a-z0-9_]+)/
      |> Regex.scan(text)
      |> Enum.map(fn [_, table] -> table end)
      |> MapSet.new()
    end)
  end

  defp references(modules, lib) do
    Map.new(modules, fn module ->
      refs =
        lib
        |> Enum.reject(fn {file, _} -> file == module.file end)
        |> Enum.filter(fn {_file, content} ->
          Regex.match?(
            ~r/(?<![\w.])#{Regex.escape(module.module)}(?:\.(?=[a-z_])|(?![\w.]))/,
            content
          )
        end)
        |> Enum.map(fn {file, _} -> file end)
        |> MapSet.new()

      {module.module, refs}
    end)
  end

  # ---------------------------------------------------------------------------
  # Reachability
  # ---------------------------------------------------------------------------

  defp seed_live(modules, mounted, migrated, refs, scopes_root) do
    Enum.reduce(modules, MapSet.new(), fn module, live ->
      cond do
        module.module in @ratified_live ->
          MapSet.put(live, module.module)

        module.table != nil and MapSet.member?(migrated, module.table) ->
          MapSet.put(live, module.module)

        external_reference?(refs[module.module], module, scopes_root) ->
          MapSet.put(live, module.module)

        MapSet.member?(mounted, module.scope) and
            blueprint_or_scope_reference?(refs[module.module], module, scopes_root) ->
          MapSet.put(live, module.module)

        true ->
          live
      end
    end)
  end

  defp close_live(live, modules, refs) do
    next =
      Enum.reduce(modules, live, fn module, acc ->
        if MapSet.member?(acc, module.module) do
          acc =
            modules
            |> Enum.filter(&same_path?(&1.file, module.file))
            |> Enum.reduce(acc, fn other, acc2 -> MapSet.put(acc2, other.module) end)

          modules
          |> Enum.filter(fn other ->
            not same_path?(other.file, module.file) and
              MapSet.member?(refs[other.module], module.file)
          end)
          |> Enum.reduce(acc, fn other, acc2 -> MapSet.put(acc2, other.module) end)
        else
          acc
        end
      end)

    if MapSet.size(next) == MapSet.size(live), do: live, else: close_live(next, modules, refs)
  end

  defp external_reference?(ref_files, module, scopes_root) do
    scope_module = scope_module_file(module, scopes_root)
    scope_dir = scope_dir(module, scopes_root)

    Enum.any?(ref_files, fn file ->
      not same_path?(file, scope_module) and not in_dir?(file, scope_dir)
    end)
  end

  defp blueprint_or_scope_reference?(ref_files, module, scopes_root) do
    scope_module = scope_module_file(module, scopes_root)
    scope_dir = scope_dir(module, scopes_root)

    Enum.any?(ref_files, fn file ->
      same_path?(file, scope_module) or
        (in_dir?(file, scope_dir) and String.contains?(Path.basename(file), "blueprint"))
    end)
  end

  defp same_path?(left, right) do
    if windows?(), do: String.downcase(left) == String.downcase(right), else: left == right
  end

  defp in_dir?(file, dir) do
    if windows?() do
      String.starts_with?(String.downcase(file), String.downcase(dir) <> "/")
    else
      String.starts_with?(file, dir <> "/")
    end
  end

  defp windows?, do: match?({:win32, _}, :os.type())

  defp scope_module_file(module, scopes_root) do
    case relative_segments(module.file, scopes_root) do
      [_file] -> module.file
      [dir | _] -> norm(Path.join(scopes_root, dir <> ".ex"))
    end
  end

  defp scope_dir(module, scopes_root) do
    case relative_segments(module.file, scopes_root) do
      [_file] -> module.file
      [dir | _] -> norm(Path.join(scopes_root, dir))
    end
  end

  defp relative_segments(file, scopes_root) do
    relative = file |> Path.relative_to(scopes_root) |> norm()

    if String.starts_with?(relative, "../") or Path.type(relative) == :absolute do
      [file]
    else
      String.split(relative, "/")
    end
  end

  defp violation(module, root) do
    path = Path.relative_to(module.file, root)

    table_clause =
      if module.table,
        do: "table #{module.table} has no migration",
        else: "no table is declared"

    "dormant module: #{module.module} (#{path}) — unreachable from #{module.scope}'s mounted " <>
      "surface, #{table_clause}, and no live code references it (ADR-055)"
  end

  defp norm(path), do: String.replace(path, "\\", "/")

  defp repo_root do
    cwd = File.cwd!()

    cond do
      File.dir?(Path.join(cwd, "samen_core")) and File.dir?(Path.join(cwd, "samen_web")) ->
        cwd

      File.dir?(Path.join(Path.expand("..", cwd), "samen_core")) ->
        Path.expand("..", cwd)

      true ->
        cwd
    end
  end
end
