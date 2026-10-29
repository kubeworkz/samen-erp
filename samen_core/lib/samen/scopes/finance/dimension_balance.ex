defmodule Samen.Scopes.Finance.DimensionBalance do
  @moduledoc """
  The R6 core guard (WS-ACCT Phase 1; ADR-054 §3): **Σ debits == Σ credits per
  cost object**, always — the dimension twin of `UnbalancedEntry`/`PostBalance`.

  Two clauses, because per-cost-object balance is only satisfiable if the set is
  a balancing segment:

    * **R6a — the dimension set applies to the WHOLE entry.** If any line names
      a `project` (or `lot`/`fund`/`cost_pool`), every line does. A line cannot
      escape the axis its entry posts under, because such a line is exactly the
      hole through which a one-sided cost object is built.
    * **R6b — per (axis, value) balance.** For each cost object named on the
      entry, the lines tagged with it net to zero (`Σ debit == Σ credit`). An
      entry that balances org-wide (R1) but moves 100 out of project A and only
      60 back is refused even though the org total is untouched.

  Both clauses run:

    * over the `lines` ARGUMENT on create/update (`:lines` opt — the
      `UnbalancedEntry` shape), and
    * over the PERSISTED rows on `:post` (the `PostBalance` shape — the fact
      that posts is the fact that is stored).

  An entry carrying no dimensions at all — every base-system posting — passes
  vacuously: this phase adds a seam, it does not change the ordinary ledger.

  The independent READ mirror is `Samen.Scopes.Finance.DimensionReconcile`:
  the guard refuses a bad entry, the read detects one forced in below the guard
  (raw SQL), and the sabotage patch for R6 drops clause R6b so both flip.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    if Keyword.get(opts, :persisted, false) do
      Ash.Changeset.before_action(changeset, &check_persisted/1)
    else
      lines_key = Keyword.get(opts, :lines, :lines)
      Ash.Changeset.before_action(changeset, &check_argument(&1, lines_key))
    end
  end

  # ── argument mode ─────────────────────────────────────────────────────────

  defp check_argument(changeset, lines_key) do
    case Ash.Changeset.get_argument(changeset, lines_key) do
      lines when is_list(lines) and lines != [] ->
        rows =
          Enum.map(lines, fn line ->
            {refs(Map.get(line, :dimension_refs) || Map.get(line, "dimension_refs")),
             amount(line, :debit_cents), amount(line, :credit_cents)}
          end)

        check_rows(changeset, rows)

      _ ->
        changeset
    end
  end

  # ── persisted mode ────────────────────────────────────────────────────────

  defp check_persisted(changeset) do
    entry_resource = changeset.resource
    line_resource = line_resource(entry_resource)

    table = AshPostgres.DataLayer.Info.table(line_resource)
    repo =
      AshPostgres.DataLayer.Info.repo(line_resource, :read) ||
        AshPostgres.DataLayer.Info.repo(line_resource)

    entry_fk = entry_fk_source(line_resource, entry_resource)
    dim = attr_source(line_resource, :dimension_refs)
    debit = attr_source(line_resource, :debit_cents)
    credit = attr_source(line_resource, :credit_cents)

    sql = """
    SELECT #{dim}, #{debit}, #{credit} FROM #{table} WHERE #{entry_fk} = $1
    """

    case repo.query(sql, [dump_uuid(changeset.data.id)]) do
      {:ok, %{rows: rows}} ->
        check_rows(changeset, Enum.map(rows, fn [refs, d, c] -> {refs || %{}, to_i(d), to_i(c)} end))

      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :lines,
          message: "the dimension balance check could not read the stored lines: #{inspect(reason)}"
        )
    end
  end

  # ── the two clauses ───────────────────────────────────────────────────────

  defp check_rows(changeset, rows) do
    rows = Enum.map(rows, fn {refs, d, c} -> {normalize(refs), d, c} end)
    keys = rows |> Enum.flat_map(fn {refs, _d, _c} -> Map.keys(refs) end) |> Enum.uniq() |> Enum.sort()

    if keys == [] do
      changeset
    else
      case check_complete(rows, keys) do
        :ok -> check_balances(changeset, rows, keys)
        {:error, message} -> add_error(changeset, message)
      end
    end
  end

  defp normalize(refs) when is_map(refs), do: Map.new(refs, fn {k, v} -> {to_string(k), v} end)
  defp normalize(_other), do: %{}

  # R6a — the set applies to the whole entry.
  defp check_complete(rows, keys) do
    total = length(rows)

    case Enum.find(keys, fn key -> Enum.count(rows, fn {refs, _d, _c} -> Map.has_key?(refs, key) end) != total end) do
      nil ->
        :ok

      key ->
        tagged = Enum.count(rows, fn {refs, _d, _c} -> Map.has_key?(refs, key) end)

        {:error,
         "partial dimension set: #{inspect(key)} is named on #{tagged} of #{total} lines — a " <>
           "dimension applies to the WHOLE entry (R6a), so no line can escape the axis it posts under"}
    end
  end

  # R6b — per (axis, value): Σ debits == Σ credits.
  defp check_balances(changeset, rows, keys) do
    violations =
      for key <- keys,
          {value, pairs} <- tagged_pairs(rows, key),
          debits = Enum.sum(Enum.map(pairs, &elem(&1, 0))),
          credits = Enum.sum(Enum.map(pairs, &elem(&1, 1))),
          debits != credits,
          do: {key, value, debits, credits}

    case Enum.sort(violations) do
      [] ->
        changeset

      [first | _] = all ->
        {key, value, debits, credits} = first

        add_error(
          changeset,
          "per-cost-object imbalance (R6b): #{key}=#{inspect(value)} has debits #{debits} and " <>
            "credits #{credits} — Σ debits must equal Σ credits per cost object, even when the " <>
            "entry balances org-wide (R1). #{length(all)} cost object(s) out of balance."
        )
    end
  end

  # The lines carrying one axis, grouped by the cost object they name.
  defp tagged_pairs(rows, key) do
    rows
    |> Enum.filter(fn {refs, _d, _c} -> Map.has_key?(refs, key) end)
    |> Enum.group_by(fn {refs, _d, _c} -> Map.get(refs, key) end, fn {_refs, d, c} -> {d, c} end)
  end

  defp add_error(changeset, message) do
    Ash.Changeset.add_error(changeset, field: :lines, message: message)
  end

  # ── plumbing ──────────────────────────────────────────────────────────────

  defp refs(nil), do: %{}
  defp refs(refs) when is_map(refs), do: refs
  defp refs(_other), do: %{}

  defp amount(line, key) do
    line |> Map.get(key) |> to_i()
  end

  defp to_i(nil), do: 0
  defp to_i(v) when is_integer(v), do: v
  defp to_i(%Decimal{} = d), do: Decimal.to_integer(d)
  defp to_i(v) when is_binary(v) do
    case Integer.parse(v) do
      {i, ""} -> i
      _ -> 0
    end
  end
  defp to_i(_), do: 0

  defp line_resource(entry_resource) do
    entry_resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.name == :lines))
    |> Map.fetch!(:destination)
  end

  defp entry_fk_source(line_resource, entry_resource) do
    line_resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.type == :belongs_to and &1.destination == entry_resource))
    |> Map.fetch!(:source_attribute)
    |> then(&attr_source(line_resource, &1))
  end

  defp attr_source(resource, name) do
    case Ash.Resource.Info.attribute(resource, name) do
      nil -> nil
      attr -> to_string(attr.source || attr.name)
    end
  end

  defp dump_uuid(value) when is_binary(value) and byte_size(value) == 16, do: value

  defp dump_uuid(value) do
    case Ecto.UUID.dump(value) do
      {:ok, bin} -> bin
      :error -> value
    end
  end
end
