defmodule Samen.Scopes.Hr.ManagerCycle do
  @moduledoc """
  Refuses a `manager_id` write on the self-referential `Employee` reporting
  tree (WS-ERP E7; design §5 — a manager can never be made the employee's own
  transitive report), and bounds the walk depth so a pathological/corrupted
  chain cannot hang a write.

  Same-CycleGuard-lineage as `Samen.Scopes.Finance.CycleGuard` (ADR-041 §3.4)
  — a node cannot become its own ancestor; the walk is depth-bounded. Mirrors
  `Samen.Policy.SameOrgFk`'s bare-repo-query idiom (never `Ash.read`): this is
  a structural-integrity guard over opaque ids, not a data-leak surface, so
  bypassing `OrgScope` here is safe (and load-bearing: a hidden foreign row
  must not silently vanish from the ancestor walk).

  ## Usage

      changes do
        change(Samen.Scopes.Hr.ManagerCycle)
      end

  Runs only when `manager_id` is being changed. `nil` (detaching from a
  manager) is always a no-op. A legal N-level reporting chain is accepted; a
  cycle (including the self-manager degenerate case) is refused with a positive
  control retained by the caller's test (a legal re-assignment still succeeds).
  """

  use Ash.Resource.Change

  @max_depth 100

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &refuse_cycle/1)
  end

  defp refuse_cycle(changeset) do
    if Ash.Changeset.changing_attribute?(changeset, :manager_id) do
      manager_id = Ash.Changeset.get_attribute(changeset, :manager_id)
      self_id = self_id(changeset)

      cond do
        is_nil(manager_id) ->
          changeset

        not is_nil(self_id) and same_uuid?(manager_id, self_id) ->
          cycle_error(changeset)

        true ->
          case ancestor_ids(changeset.resource, manager_id) do
            {:ok, ancestors} ->
              if not is_nil(self_id) and Enum.any?(ancestors, &same_uuid?(&1, self_id)) do
                cycle_error(changeset)
              else
                changeset
              end

            {:error, :depth_exceeded} ->
              Ash.Changeset.add_error(changeset,
                field: :manager_id,
                message:
                  "manager chain exceeds max depth (#{@max_depth}) — refusing (possible cycle)"
              )
          end
      end
    else
      changeset
    end
  end

  defp self_id(%{data: %{id: id}}) when not is_nil(id), do: id
  defp self_id(_), do: nil

  defp cycle_error(changeset) do
    Ash.Changeset.add_error(changeset,
      field: :manager_id,
      message: "an employee cannot be their own manager (cycle refused)"
    )
  end

  # Walk manager_id upward from `start_id`, collecting every ancestor id
  # encountered (including start_id itself), bounded by @max_depth.
  defp ancestor_ids(resource, start_id) do
    repo =
      AshPostgres.DataLayer.Info.repo(resource, :read) || AshPostgres.DataLayer.Info.repo(resource)

    table = AshPostgres.DataLayer.Info.table(resource)
    id_source = attribute_source(resource, :id)
    manager_source = attribute_source(resource, :manager_id)

    walk(repo, table, id_source, manager_source, start_id, [], 0)
  end

  defp walk(_repo, _table, _id_src, _manager_src, nil, acc, _depth), do: {:ok, acc}

  defp walk(_repo, _table, _id_src, _manager_src, _id, _acc, depth) when depth > @max_depth do
    {:error, :depth_exceeded}
  end

  defp walk(repo, table, id_src, manager_src, id, acc, depth) do
    sql = "SELECT #{manager_src} FROM #{table} WHERE #{id_src} = $1 LIMIT 1"

    case repo.query(sql, [dump_uuid(id)]) do
      {:ok, %{rows: [[nil]]}} ->
        {:ok, [id | acc]}

      {:ok, %{rows: [[manager_bin]]}} ->
        walk(repo, table, id_src, manager_src, load_uuid(manager_bin), [id | acc], depth + 1)

      {:ok, %{rows: []}} ->
        {:ok, [id | acc]}

      {:error, reason} ->
        # Fail-closed: a broken ancestor read must never admit a write.
        {:error, reason}
    end
  end

  defp attribute_source(resource, name) do
    case Ash.Resource.Info.attribute(resource, name) do
      nil -> raise ArgumentError, "no attribute #{inspect(name)} on #{inspect(resource)}"
      attr -> to_string(attr.source || attr.name)
    end
  end

  defp same_uuid?(a, b), do: normalize_uuid(a) == normalize_uuid(b)

  defp normalize_uuid(v) when is_binary(v) and byte_size(v) == 16, do: Ecto.UUID.load!(v)
  defp normalize_uuid(v) when is_binary(v), do: v
  defp normalize_uuid(v), do: v

  defp dump_uuid(v) when is_binary(v) and byte_size(v) == 16, do: v

  defp dump_uuid(v) do
    case Ecto.UUID.dump(v) do
      {:ok, bin} -> bin
      :error -> v
    end
  end

  defp load_uuid(bin) when is_binary(bin) and byte_size(bin) == 16, do: Ecto.UUID.load!(bin)
  defp load_uuid(v), do: v
end
