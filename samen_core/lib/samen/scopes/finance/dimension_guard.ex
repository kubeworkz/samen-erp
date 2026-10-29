defmodule Samen.Scopes.Finance.DimensionGuard do
  @moduledoc """
  The cost-object seam's WRITE guard (WS-ACCT Phase 1; ADR-054 D1): a
  `JournalLine.dimension_refs` map may only carry the **frozen four-key
  vocabulary** and, under each key, a **same-org `CostObject` id** — nothing
  else, ever.

  Three refusals, all fail-closed:

    1. **Unknown key** — the analysis axes are a KERNEL decision, not caller
       input (#{inspect(["project", "lot", "fund", "cost_pool"])}). A fifth axis
       ships as a deliberate change here, never as a caller's convenience.
    2. **Not an id** — a value that is not a UUID is refused. This is what keeps
       the dimension from becoming a de-anonymisation channel (design §4): a
       `"project" => "RISC-V64 SoC — Jane Doe"` string can never land next to a
       vaulted field and be joined back to a person. Ids only, never names.
    3. **Not a same-org CostObject** — a value naming another org's cost object
       (or nothing at all) is refused, so a cross-org join can never be
       constructed through the ledger.

  Runs on the line's create path (`Ash.Resource.Change`, `before_action` — inside
  the action's transaction) and therefore inside the entry's write transaction,
  since `Samen.Scopes.Finance.EntryLines` materializes line rows through the
  line's own governed `:create`. The entry-level twin — that the dimensions
  BALANCE — is `Samen.Scopes.Finance.DimensionBalance` (R6).

  An empty (or absent) map is a no-op: an undimensioned line is the base
  system's ordinary posting and stays untouched by this phase.
  """

  @vocabulary ["project", "lot", "fund", "cost_pool"]

  @doc "The frozen dimension vocabulary. Adding an axis is a deliberate, tested change."
  def vocabulary, do: @vocabulary

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, &check(&1, opts))
  end

  defp check(changeset, opts) do
    raw = Ash.Changeset.get_attribute(changeset, :dimension_refs) || %{}

    cond do
      not is_map(raw) ->
        error(changeset, "dimension_refs is a map of axis => CostObject id, got: #{inspect(raw)}")

      map_size(raw) == 0 ->
        changeset

      true ->
        with {:ok, refs} <- normalize_keys(raw),
             :ok <- check_vocabulary(refs),
             {:ok, pairs} <- collect_ids(refs),
             :ok <- check_org_scope(changeset, pairs, opts) do
          changeset
        else
          {:error, message} -> error(changeset, message)
        end
    end
  end

  defp normalize_keys(refs) do
    {:ok, Map.new(refs, fn {key, value} -> {to_string(key), value} end)}
  end

  defp check_vocabulary(refs) do
    unknown = refs |> Map.keys() |> Enum.reject(&(&1 in @vocabulary)) |> Enum.sort()

    if unknown == [] do
      :ok
    else
      {:error,
       "unknown dimension key(s) #{inspect(unknown)} — the vocabulary is frozen to " <>
         "#{inspect(@vocabulary)} (an axis is a kernel decision, never caller input)"}
    end
  end

  # ids only: every value must be a UUID. A name, a label, a number or nil is
  # refused here — the de-anonymisation channel this guard exists to close.
  defp collect_ids(refs) do
    Enum.reduce_while(refs, {:ok, []}, fn {key, value}, {:ok, acc} ->
      case Ecto.UUID.cast(value) do
        {:ok, uuid} ->
          {:cont, {:ok, [{key, uuid} | acc]}}

        :error ->
          {:halt,
           {:error,
            "dimension #{inspect(key)} must be a CostObject ID (a UUID) — got: #{inspect(value)}. " <>
              "Dimensions carry ids, never names or free text."}}
      end
    end)
    |> case do
      {:ok, pairs} -> {:ok, Enum.reverse(pairs)}
      other -> other
    end
  end

  defp check_org_scope(changeset, pairs, opts) do
    check_same_org(pairs, Keyword.fetch!(opts, :cost_object), org_id(changeset))
  end

  defp check_same_org([], _cost_object, _org_id), do: :ok

  defp check_same_org(pairs, cost_object, org_id) do
    ids = pairs |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()

    table = AshPostgres.DataLayer.Info.table(cost_object)
    id_col = attr_source(cost_object, :id)
    org_col = attr_source(cost_object, :org_id)
    placeholders = ids |> Enum.with_index(2) |> Enum.map(fn {_id, i} -> "$#{i}::uuid" end)

    sql = """
    SELECT #{id_col}::text FROM #{table}
    WHERE #{org_col} = $1::uuid AND #{id_col} IN (#{Enum.join(placeholders, ", ")})
    """

    repo =
      AshPostgres.DataLayer.Info.repo(cost_object, :read) ||
        AshPostgres.DataLayer.Info.repo(cost_object)

    # `$n` is inferred as uuid from the cast, so params are dumped binaries —
    # a UUID string here is an EncodeError, not a refusal.
    case repo.query(sql, [dump_uuid(org_id) | Enum.map(ids, &dump_uuid/1)]) do
      {:ok, %{rows: rows}} ->
        found = rows |> List.flatten() |> MapSet.new(&String.downcase/1)

        case Enum.reject(ids, &MapSet.member?(found, String.downcase(&1))) do
          [] ->
            :ok

          missing ->
            keys =
              pairs
              |> Enum.filter(fn {_key, id} -> String.downcase(id) in Enum.map(missing, &String.downcase/1) end)
              |> Enum.map(&elem(&1, 0))
              |> Enum.uniq()
              |> Enum.sort()

            {:error,
             "dimension #{inspect(keys)} names a CostObject that is not in this org: " <>
               "#{inspect(missing)} — a cross-org dimension is refused (the ledger never joins " <>
               "across tenants)"}
        end

      {:error, reason} ->
        {:error, "the cost-object check could not run: #{inspect(reason)}"}
    end
  end

  # The line's org. EntryLines hands it explicitly on the cascade path; a
  # caller-created line carries it as a cast attribute. A NotLoaded placeholder
  # (a record passed straight from a create result) is re-fetched.
  defp org_id(changeset) do
    case Ash.Changeset.get_attribute(changeset, :org_id) do
      %Ash.NotLoaded{} -> Ash.load!(changeset.data, [:org_id], authorize?: false).org_id
      nil -> Ash.load!(changeset.data, [:org_id], authorize?: false).org_id
      value -> value
    end
  end

  defp error(changeset, message) do
    Ash.Changeset.add_error(changeset, field: :dimension_refs, message: message)
  end

  # Postgrex's uuid codec takes the 16-byte form (the `Reconcile`/`PostBalance`
  # discipline); a 36-char string would be refused at encode time.
  defp dump_uuid(value) when is_binary(value) and byte_size(value) == 16, do: value

  defp dump_uuid(value) do
    case Ecto.UUID.dump(value) do
      {:ok, bin} -> bin
      :error -> value
    end
  end

  defp attr_source(resource, name) do
    case Ash.Resource.Info.attribute(resource, name) do
      nil -> nil
      attr -> to_string(attr.source || attr.name)
    end
  end
end
