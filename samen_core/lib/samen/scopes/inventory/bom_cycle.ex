defmodule Samen.Scopes.Inventory.BomCycle do
  @moduledoc """
  Refuses a `Bom` whose transitive component expansion contains its own
  item (WS-ERP E6; design §4 — the `Samen.Scopes.Finance.CycleGuard`
  lineage): a bill that manufactures itself is not a plan, it is a
  contradiction. The walk is DEPTH-BOUNDED so a corrupted chain cannot
  hang a write.

  The edges are `Bom → BomLine.component_item → Item → (Bom for that item)`.
  Walking parent→components from this BOM's item: if the finished item
  reappears among its transitive components, the expansion is cyclic.
  Like the Finance CycleGuard, this is a structural-integrity guard over
  opaque ids via the bare repo (never `Ash.read`) — bypassing OrgScope is
  safe and load-bearing: a hidden foreign row must not silently vanish
  from the walk.

  Runs on `:create` and on any `:update` that rewrites `lines` (a new
  expansion must also be acyclic). A self-cycle (the BOM's own item as a
  direct component) is refused by the same walk (depth 1).
  """

  use Ash.Resource.Change

  @max_depth 50

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &refuse_cycle/1)
  end

  defp refuse_cycle(changeset) do
    org_id = resolve_org(changeset)
    self_item_id = Ash.Changeset.get_attribute(changeset, :item_id)
    bom_id = changeset.data && Map.get(changeset.data, :id)

    cond do
      is_nil(self_item_id) ->
        changeset

      # On :update with a lines replace, exclude THIS bom's own current
      # edges from the walk (they are about to be replaced).
      true ->
        exclude_bom_id =
          if is_map_key(changeset.arguments || %{}, :lines), do: bom_id, else: nil

        # The walk STARTS at depth 0 — the bound (50) is the CEILING of
        # expansion levels, not the starting depth (starting at the bound
        # makes any bill-of-bills a false depth refusal).
        case cyclic?(changeset.resource, org_id, self_item_id, exclude_bom_id, 0) do
          {:ok, false} -> changeset
          {:ok, true} -> cycle_error(changeset, self_item_id, :cycle)
          {:error, :depth} -> cycle_error(changeset, self_item_id, :depth)
        end
    end
  end

  # BFS over the expansion: start at the finished item, expand through the
  # ACTIVE boms of each item reached. If the finished item reappears, the
  # bill is cyclic. Depth-bounded.
  defp cyclic?(bom_resource, org_id, item_id, exclude_bom_id, depth)

  defp cyclic?(_bom_resource, _org_id, _item_id, _exclude_bom_id, depth) when depth > @max_depth,
    do: {:error, :depth}

  defp cyclic?(bom_resource, org_id, item_id, exclude_bom_id, depth) do
    repo = AshPostgres.DataLayer.Info.repo(bom_resource, :mutate)
    bom_table = AshPostgres.DataLayer.Info.table(bom_resource)
    line_resource = line_resource(bom_resource)
    line_table = AshPostgres.DataLayer.Info.table(line_resource)

    item = col(bom_resource, :item_id)
    org = col(bom_resource, :org_id)
    id = col(bom_resource, :id)
    active = col(bom_resource, :is_active)
    line_item = col(line_resource, :item_id)
    line_bom = col(line_resource, :bom_id)

    # The excluded bom is a BOUND parameter — a raw 16-byte uuid binary
    # interpolated into SQL is a syntax error, not a filter.
    exclude_clause =
      if exclude_bom_id do
        "AND b.#{id} <> $3"
      else
        ""
      end

    params =
      if exclude_bom_id do
        [dump_uuid(org_id), dump_uuid(item_id), dump_uuid(exclude_bom_id)]
      else
        [dump_uuid(org_id), dump_uuid(item_id)]
      end

    # The component items of the ACTIVE boms for this item (excluding the
    # bom being edited). Every column is derived from the RESOURCES — a
    # host abbrev remaps both tables (the fixture's `sbm_`/`sbl_`), and a
    # hardcoded column is a fail-closed trap.
    case repo.query(
           """
           SELECT DISTINCT bl.#{line_item} AS component
           FROM #{bom_table} b
           JOIN #{line_table} bl ON bl.#{line_bom} = b.#{id}
           WHERE b.#{org} = $1 AND b.#{item} = $2 AND b.#{active} = true #{exclude_clause}
           """,
           params
         ) do
      {:ok, %{rows: rows}} ->
        # Postgrex rows are LISTS of values, not tuples.
        components = Enum.map(rows, &normalize_uuid(List.first(&1)))

        cond do
          Enum.any?(components, &(&1 == normalize_uuid(item_id))) ->
            {:ok, true}

          components == [] ->
            {:ok, false}

          true ->
            # Recurse one level per component (BFS by expansion level).
            Enum.reduce_while(components, {:ok, false}, fn component, {:ok, _} ->
              case cyclic?(bom_resource, org_id, component, exclude_bom_id, depth + 1) do
                {:ok, true} = hit -> {:halt, hit}
                other -> {:cont, other}
              end
            end)
        end

      {:error, _reason} ->
        # Fail-closed: a read failure refuses the write (a cycle check that
        # cannot run cannot prove the bill acyclic).
        cycle_error_struct(item_id, :unverifiable)
    end
  end

  defp cycle_error(changeset, _item_id, kind) do
    message =
      case kind do
        :cycle ->
          "BOM cycle: the transitive component expansion of this bill contains its own item — " <>
            "a bill that manufactures itself is a contradiction, not a plan"

        :depth ->
          "BOM expansion exceeded the depth bound (#{@max_depth} levels) — a pathological " <>
            "component graph is refused rather than walked"
      end

    Ash.Changeset.add_error(changeset, field: :item_id, message: message)
  end

  defp cycle_error_struct(_item_id, :unverifiable) do
    raise "BomCycle: the expansion read failed — refusing the write (fail-closed: a cycle " <>
            "check that cannot run cannot prove the bill acyclic)"
  end

  # ── plumbing ────────────────────────────────────────────────────────────────

  defp resolve_org(changeset) do
    case Ash.Changeset.get_attribute(changeset, :org_id) do
      value when is_binary(value) ->
        value

      _ ->
        # Fixture structs never select org_id (the E4 lesson): resolve off
        # the QUERY layer, never a struct-pattern match.
        require Ash.Query

        changeset.resource
        |> Ash.Query.filter(id == ^changeset.data.id)
        |> Ash.Query.select(:org_id)
        |> Ash.read_one(authorize?: false)
        |> case do
          {:ok, %{org_id: org_id}} -> org_id
          other -> raise "the BOM's org could not be resolved: #{inspect(other)}"
        end
    end
  end

  # The BomLine table/cols are read through the BOM's relationship — derive
  # them from the BomLine resource (passed via the defining module's
  # convention: the table is "<abbrev>_bom_line").
  defp col(resource, name) do
    case Ash.Resource.Info.attribute(resource, name) do
      nil -> raise ArgumentError, "no attribute #{inspect(name)} on #{inspect(resource)}"
      attr -> to_string(attr.source || attr.name)
    end
  end

  defp line_resource(bom_resource) do
    bom_resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.name == :lines))
    |> Map.fetch!(:destination)
  end

  defp dump_uuid(value) when is_binary(value) and byte_size(value) == 16, do: value

  defp dump_uuid(value) do
    case Ecto.UUID.dump(value) do
      {:ok, bin} -> bin
      :error -> value
    end
  end

  defp normalize_uuid(<<_::128>> = bin), do: Ecto.UUID.load!(bin)
  defp normalize_uuid(bin) when is_binary(bin), do: bin
  defp normalize_uuid(nil), do: nil
end
