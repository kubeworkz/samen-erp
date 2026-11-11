defmodule Mix.Tasks.Samen.Abbrev.Retire do
  @shortdoc "Retire abbrev rows for deleted, never-migrated modules (ADR-055)."

  @moduledoc """
  `mix samen.abbrev.retire` — the sanctioned ADR-055 §4 retirement path.

  This task is the only sanctioned way to remove abbrev rows. It does **not**
  edit the registry on a hunch: it proves the owner module is gone, the table
  was never migrated, no migration names the owner, and no schema dictionary
  still references either. The default is a dry run; `--apply` performs the
  write only after every entry passes.

  ## Usage

      # inspect what would be retired
      mix samen.abbrev.retire --manifest retire.tsv

      # perform the retirement
      mix samen.abbrev.retire --manifest retire.tsv --apply

  The manifest is tab-separated, one entry per line:

      Samen.Scopes.Old.Resource	old_resource

  Blank table fields are accepted for deleted modules that never had a
  reservation; such entries are reported as `missing` and are not errors.

  Options:

    * `--manifest` (required) — path to the tab-separated owner/table list.
    * `--registry` — registry path; defaults to `Samen.AbbrevRegistry.path()`.
    * `--root` — tree to scan for source/migrations/schema dictionaries;
      defaults to the repository root.
    * `--apply` — write the retirement. Without it the task is read-only.
  """

  use Mix.Task

  alias Samen.Abbrev.Retirement
  alias Samen.AbbrevRegistry

  @switches [manifest: :string, registry: :string, root: :string, apply: :boolean]

  @impl Mix.Task
  def run(argv) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: @switches)

    if invalid != [] or rest != [] do
      Mix.raise(
        "mix samen.abbrev.retire: unexpected arguments #{inspect(invalid ++ rest)}; " <>
          "pass --manifest PATH [--registry PATH] [--root PATH] [--apply]"
      )
    end

    manifest = require_opt!(opts, :manifest)
    registry = Keyword.get(opts, :registry, AbbrevRegistry.path())
    root = Keyword.get(opts, :root, repo_root())
    entries = read_manifest!(manifest)

    case Retirement.plan(root, registry, entries) do
      {:error, violations} ->
        Mix.raise(
          "samen.abbrev.retire: refusing to retire #{length(entries)} entries:\n" <>
            Enum.map_join(violations, "\n", &"  - #{&1}")
        )

      {:ok, plan} ->
        Mix.shell().info(
          "samen.abbrev.retire: eligible rows=#{length(plan.retire)} " <>
            "owners=#{plan.retire |> Enum.map(& &1.owner) |> Enum.uniq() |> length()} " <>
            "missing_rows=#{length(plan.missing)}"
        )

        if plan.missing != [] do
          Mix.shell().info(
            "samen.abbrev.retire: no registry row for " <>
              Enum.map_join(plan.missing, ", ", & &1.owner)
          )
        end

        if Keyword.get(opts, :apply, false) do
          removed = Retirement.apply!(registry, plan)
          Mix.shell().info("samen.abbrev.retire: removed #{removed} row(s) from #{registry}")
        else
          Mix.shell().info("samen.abbrev.retire: dry run; pass --apply to write #{registry}")
        end
    end
  end

  defp require_opt!(opts, key) do
    case Keyword.get(opts, key) do
      nil -> Mix.raise("mix samen.abbrev.retire: missing required --#{key}")
      "" -> Mix.raise("mix samen.abbrev.retire: --#{key} may not be empty")
      value -> value
    end
  end

  defp read_manifest!(path) do
    path
    |> File.read!()
    |> String.split("\n")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
    |> Enum.map(fn line ->
      case String.split(line, "\t", parts: 2) do
        [owner] ->
          %{owner: String.trim(owner), table: nil}

        [owner, table] ->
          %{owner: String.trim(owner), table: String.trim(table)}

        _ ->
          Mix.raise("mix samen.abbrev.retire: malformed manifest line #{inspect(line)}")
      end
    end)
    |> Enum.reject(fn entry ->
      if entry.owner == "" do
        Mix.raise("mix samen.abbrev.retire: manifest entry has an empty owner")
      end

      false
    end)
  end

  defp repo_root do
    cwd = File.cwd!()

    cond do
      File.dir?(Path.join(cwd, "samen_core")) -> cwd
      Path.basename(cwd) == "samen_core" -> Path.expand("..", cwd)
      true -> cwd
    end
  end
end
