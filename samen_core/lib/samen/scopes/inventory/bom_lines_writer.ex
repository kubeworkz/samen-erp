defmodule Samen.Scopes.Inventory.BomLinesWriter do
  @moduledoc """
  Materializes the `lines` argument of a `Bom` create/update into real
  `BomLine` rows (WS-ERP E6) — the ONLY sanctioned writer of line rows,
  the `Samen.Scopes.Inventory.PoLinesWriter` shape.

  * LINE SHAPE: a BOM carries at least one line; every `qty_per` is a
    POSITIVE integer; every `scrap_pct` is 0–100. The embedded-argument
    constraints type the fields; this guard owns the business conditions
    the type system cannot express.
  * FROZEN EDGES: a lines-replace on a BOM that any IN-FLIGHT work order
    (released or completed) references is REFUSED — R4's reconciliation
    reads the bill that produced the facts (the belt's raw-SQL twin
    refuses the same edit). A BOM with no in-flight WO may re-materialize
    freely (work orders carry their own snapshot, so nothing re-prices).

  Runs in `after_action` (inside the action's transaction): if any line
  insert fails, the whole BOM write rolls back. Each line still runs its
  own governed create (its `SameOrgFk` asserts same-org BOM + item), so a
  line can never point at a foreign org's referent. Org pins happen at
  the QUERY layer — fixture structs never select `org_id` (the E4
  lesson).
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    action = changeset.action && changeset.action.name

    # Capture the tenant NOW (attributes still pending — the EntryLines
    # posture); resolve off the record when NotLoaded (the E4 lesson).
    org_id = resolve_org(changeset)

    changeset
    |> refuse_frozen_lines(action)
    |> Ash.Changeset.after_action(fn changeset, bom ->
      materialize(changeset, bom, org_id)
    end)
  end

  defp resolve_org(changeset) do
    require Ash.Query

    case Ash.Changeset.get_attribute(changeset, :org_id) do
      value when is_binary(value) ->
        value

      _ ->
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

  # ── the frozen-edges refusal (only when lines are being replaced) ───────────

  defp refuse_frozen_lines(changeset, :create), do: changeset

  defp refuse_frozen_lines(changeset, :update) do
    case Ash.Changeset.get_argument(changeset, :lines) do
      nil ->
        changeset

      _lines ->
        bom_id = changeset.data.id

        in_flight? =
          bom_resource_wo_relationship(changeset.resource)
          |> then(fn wo_resource ->
            require Ash.Query

            wo_resource
            # authz-scope: internal guard — bom_id is org-bounded via BOM FK
            |> Ash.Query.filter(bom_id == ^bom_id and status in [:released, :completed])
            |> Ash.read_one(authorize?: false)
            |> case do
              {:ok, row} -> not is_nil(row)
              {:error, reason} -> raise "the WO in-flight read failed: #{inspect(reason)}"
            end
          end)

        if in_flight? do
          Ash.Changeset.add_error(changeset,
            field: :lines,
            message:
              "the BOM's lines are frozen while a released/completed work order references it — " <>
                "R4 reconciles the bill that produced the facts (new versions, not rewrites)"
          )
        else
          changeset
        end
    end
  end

  defp refuse_frozen_lines(changeset, _other), do: changeset

  defp bom_resource_wo_relationship(bom_resource) do
    bom_resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.name == :work_orders))
    |> Map.fetch!(:destination)
  end

  # ── shape guards ────────────────────────────────────────────────────────────

  defp validate_shape(changeset, lines) do
    cond do
      lines == [] ->
        Ash.Changeset.add_error(changeset,
          field: :lines,
          message: "a BOM carries at least one line"
        )

      lines ->
        Enum.reduce(lines, changeset, fn line, acc ->
          qty = Map.get(line, :qty_per) || Map.get(line, "qty_per")
          scrap = Map.get(line, :scrap_pct) || Map.get(line, "scrap_pct")

          acc =
            if is_integer(qty) and qty > 0 do
              acc
            else
              Ash.Changeset.add_error(acc,
                field: :qty_per,
                message: "every BOM line qty_per must be a positive integer — got: #{inspect(qty)}"
              )
            end

          if is_integer(scrap) and scrap >= 0 and scrap <= 100 do
            acc
          else
            Ash.Changeset.add_error(acc,
              field: :scrap_pct,
              message: "every BOM line scrap_pct must be 0–100 — got: #{inspect(scrap)}"
            )
          end
        end)
    end
  end

  # ── materialization (after_action: commit-or-roll-back with the BOM) ───────

  defp materialize(changeset, bom, org_id) do
    case Ash.Changeset.get_argument(changeset, :lines) do
      nil ->
        {:ok, bom}

      lines ->
        changeset = validate_shape(changeset, lines)

        if changeset.errors == [] do
          line_resource =
            changeset.resource
            |> Ash.Resource.Info.relationships()
            |> Enum.find(&(&1.name == :lines))
            |> Map.fetch!(:destination)

          with :ok <- delete_existing(line_resource, org_id, bom),
               {:ok, rows} <- insert_lines(line_resource, org_id, bom, lines) do
            {:ok, %{bom | lines: rows}}
          end
        else
          {:error, changeset}
        end
    end
  end

  defp delete_existing(line_resource, org_id, bom) do
    repo = AshPostgres.DataLayer.Info.repo(line_resource, :mutate)
    table = AshPostgres.DataLayer.Info.table(line_resource)
    bom_fk = attr_source(line_resource, :bom_id)
    org_col = attr_source(line_resource, :org_id)

    case repo.query("DELETE FROM #{table} WHERE #{bom_fk} = $1 AND #{org_col} = $2", [
           dump_uuid(bom.id),
           dump_uuid(org_id)
         ]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_lines(line_resource, org_id, bom, lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      attrs = %{
        org_id: org_id,
        bom_id: bom.id,
        item_id: Map.get(line, :component_item_id) || Map.get(line, "component_item_id"),
        qty_per: Map.get(line, :qty_per) || Map.get(line, "qty_per"),
        scrap_pct: Map.get(line, :scrap_pct) || Map.get(line, "scrap_pct") || 0
      }

      case line_resource
           |> Ash.Changeset.for_create(:create, attrs, authorize?: false)
           |> Ash.create(authorize?: false) do
        {:ok, row} -> {:cont, {:ok, [row | acc]}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, rows} -> {:ok, Enum.reverse(rows)}
      other -> other
    end
  end

  # ── plumbing ────────────────────────────────────────────────────────────────

  defp attr_source(resource, name) do
    case Ash.Resource.Info.attribute(resource, name) do
      nil -> raise ArgumentError, "no attribute #{inspect(name)} on #{inspect(resource)}"
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
