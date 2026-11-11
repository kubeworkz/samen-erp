defmodule Samen.Abbrev.Retirement do
  @moduledoc """
  The sanctioned retirement path for abbrev rows whose owner module has been
  deleted (ADR-055 §4).

  Permanence exists to protect data: a prefix that was projected into a table
  can never be recycled, even after its resource is gone. A prefix that never
  reached a table is different — it is a dangling reservation, not history.
  This module makes that distinction mechanical and fail-closed.

  A row is eligible only when **all** of these hold:

    * the owner module has no `defmodule` declaration anywhere under an app's
      `lib/` or `test/` tree (so no stale source still owns it);
    * the table recorded for the owner is not created by any
      `priv/**/migrations/*.exs` in any app;
    * no migration references the owner module (the catalog path would have
      named it);
    * neither the owner nor its table appears in any `schema.dict.json`.

  The last two checks are deliberately redundant with the table check: a
  migration that names the owner but creates a differently-spelled table must
  still block retirement. The engine is pure planning; `apply!/2` is the only
  writer and preserves the registry's existing line ordering and `$comment`.
  """

  alias Samen.AbbrevRegistry

  @type entry :: %{owner: String.t(), table: String.t() | nil}
  @type action :: %{
          namespace: :global | {:host, String.t()},
          abbrev: String.t(),
          owner: String.t()
        }

  @doc """
  Plans retirement of `entries` against `registry_path` under `root`.

  Returns `{:ok, %{retire: actions, missing: entries_without_rows}}` when every
  targeted owner passes the evidence checks, or `{:error, violations}`. A
  missing registry row is reported, not an error: the caller supplied a deleted
  module that never had a reservation.
  """
  @spec plan(String.t(), String.t(), [entry()]) ::
          {:ok, %{retire: [action()], missing: [entry()]}} | {:error, [String.t()]}
  def plan(root, registry_path, entries) do
    namespaced = AbbrevRegistry.load_namespaced(registry_path)
    rows = rows(namespaced)
    by_owner = Enum.group_by(rows, & &1.owner)

    entries = Enum.uniq_by(entries, & &1.owner)
    {targets, missing} = Enum.split_with(entries, &Map.has_key?(by_owner, &1.owner))

    source_modules = source_modules(root)
    migrations = migration_text(root)
    migrated_tables = migrated_tables(migrations)
    schema_values = schema_values(root)

    violations =
      Enum.flat_map(targets, fn entry ->
        checks(entry, source_modules, migrations, migrated_tables, schema_values)
      end)

    if violations == [] do
      retire = Enum.flat_map(targets, fn entry -> Map.fetch!(by_owner, entry.owner) end)
      {:ok, %{retire: retire, missing: missing}}
    else
      {:error, violations}
    end
  end

  @doc """
  Removes every planned row from `registry_path`.

  Preserves all unrelated lines, the `$comment`, and the file's ordering; the
  result is re-decoded before it is written. Returns the number of rows removed.
  """
  @spec apply!(String.t(), %{retire: [action()], missing: [entry()]}) :: non_neg_integer()
  def apply!(registry_path, %{retire: retire}) do
    owners = retire |> Enum.map(& &1.owner) |> MapSet.new()
    raw = File.read!(registry_path)
    lines = String.split(raw, "\n", trim: false)

    {kept_reversed, removed} =
      Enum.reduce(lines, {[], 0}, fn line, {kept, count} ->
        if target_line?(line, owners) do
          {kept, count + 1}
        else
          {[line | kept], count}
        end
      end)

    updated =
      kept_reversed
      |> Enum.reverse()
      |> Enum.join("\n")
      |> remove_dangling_commas()

    decoded = Jason.decode!(updated)

    if owners_remaining?(decoded, owners) do
      raise "refusing to write #{registry_path}: retired owners are still present"
    end

    if removed != length(retire) do
      raise "refusing to write #{registry_path}: planned #{length(retire)} rows but removed #{removed}"
    end

    File.write!(registry_path, updated)
    removed
  end

  # ---------------------------------------------------------------------------
  # evidence
  # ---------------------------------------------------------------------------

  defp checks(entry, source_modules, migrations, migrated_tables, schema_values) do
    owner = entry.owner
    table = entry.table

    [
      if(MapSet.member?(source_modules, owner),
        do: "#{owner} still has a defmodule in the source tree"
      ),
      if(migration_references_owner?(migrations, owner),
        do: "a migration references #{owner}"
      ),
      if(is_nil(table) or table == "",
        do: "#{owner} has no table evidence in the retirement manifest"
      ),
      if(table && MapSet.member?(migrated_tables, table),
        do: "table #{table} is created by a migration"
      ),
      if(table && MapSet.member?(schema_values, table),
        do: "table #{table} appears in schema.dict.json"
      ),
      if(MapSet.member?(schema_values, owner),
        do: "#{owner} appears in schema.dict.json"
      )
    ]
    |> Enum.reject(&is_nil/1)
  end

  defp rows(%{global: global, hosts: hosts}) do
    global_rows =
      Enum.map(global, fn {abbrev, owner} ->
        %{namespace: :global, abbrev: abbrev, owner: owner}
      end)

    host_rows =
      for {host, ns} <- hosts, {abbrev, owner} <- ns do
        %{namespace: {:host, host}, abbrev: abbrev, owner: owner}
      end

    global_rows ++ host_rows
  end

  defp source_modules(root) do
    root
    |> app_dirs()
    |> Enum.flat_map(fn app ->
      files_under(Path.join(app, "lib")) ++ files_under(Path.join(app, "test"))
    end)
    |> Enum.filter(&(Path.extname(&1) in [".ex", ".exs"]))
    |> Enum.flat_map(fn path ->
      path
      |> File.read!()
      |> then(&Regex.scan(~r/^\s*defmodule\s+([A-Z][A-Za-z0-9_.]*)/m, &1))
      |> Enum.map(&List.last/1)
    end)
    |> MapSet.new()
  end

  defp migration_text(root) do
    root
    |> app_dirs()
    |> Enum.flat_map(&files_under(Path.join(&1, "priv")))
    |> Enum.filter(fn path ->
      Path.extname(path) == ".exs" and Enum.member?(Path.split(path), "migrations")
    end)
    |> Enum.map_join("\n", &File.read!/1)
  end

  defp migrated_tables(text) do
    ~r/create\s+(?:if_not_exists\s+)?table\(\s*[:"']?([a-z0-9_]+)/
    |> Regex.scan(text)
    |> Enum.map(&List.last/1)
    |> MapSet.new()
  end

  defp schema_values(root) do
    paths =
      root
      |> app_dirs()
      |> Enum.map(&Path.join(&1, "schema.dict.json"))
      |> Kernel.++([Path.join(root, "schema.dict.json")])

    paths
    |> Enum.uniq()
    |> Enum.filter(&File.regular?/1)
    |> Enum.flat_map(fn path ->
      path
      |> File.read!()
      |> Jason.decode!()
      |> json_strings()
    end)
    |> MapSet.new()
  end

  defp json_strings(value) when is_binary(value), do: [value]
  defp json_strings(value) when is_list(value), do: Enum.flat_map(value, &json_strings/1)

  defp json_strings(value) when is_map(value) do
    Enum.flat_map(value, fn {key, val} -> [to_string(key) | json_strings(val)] end)
  end

  defp json_strings(_), do: []

  defp migration_references_owner?(text, owner) do
    Regex.match?(~r/(?<![\w.])#{Regex.escape(owner)}(?![\w.])/, text)
  end

  # ---------------------------------------------------------------------------
  # write path
  # ---------------------------------------------------------------------------

  defp target_line?(line, owners) do
    case Regex.run(~r/^\s*"[a-z]{3}"\s*:\s*"([^"]+)"\s*,?\s*$/, line) do
      [_, owner] -> MapSet.member?(owners, owner)
      _ -> false
    end
  end

  defp remove_dangling_commas(text) do
    Regex.replace(~r/,[ \t]*\n([ \t]*[}\]])/, text, "\\n\\1")
  end

  defp owners_remaining?(value, owners) when is_map(value) do
    Enum.any?(value, fn {_key, val} -> owners_remaining?(val, owners) end)
  end

  defp owners_remaining?(value, owners) when is_list(value) do
    Enum.any?(value, &owners_remaining?(&1, owners))
  end

  defp owners_remaining?(value, owners) when is_binary(value), do: MapSet.member?(owners, value)
  defp owners_remaining?(_value, _owners), do: false

  defp app_dirs(root) do
    case File.ls(root) do
      {:ok, entries} ->
        entries
        |> Enum.map(&Path.join(root, &1))
        |> Enum.filter(&File.dir?/1)

      {:error, _} ->
        []
    end
  end

  defp files_under(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        Enum.flat_map(entries, fn entry ->
          path = Path.join(dir, entry)

          cond do
            File.dir?(path) -> files_under(path)
            File.regular?(path) -> [path]
            true -> []
          end
        end)

      {:error, _} ->
        []
    end
  end
end
