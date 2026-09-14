defmodule Samen.Scopes.Inventory.SoLinesWriter do
  @moduledoc """
  Materializes the `lines` argument of a `SalesOrder` create/update into
  real `SoLine` rows (WS-ERP E5) — the ONLY sanctioned writer of line rows,
  the `Samen.Scopes.Inventory.PoLinesWriter` shape.

  * LINE SHAPE: a SO carries at least one line; every `qty` is a POSITIVE
    integer; every `unit_price_cents` is a NON-NEGATIVE integer (a sale
    price). The embedded-argument constraints type the fields; this guard
    owns the business conditions the type system cannot express.
  * STATE: line materialization happens on `:create` (born a draft) and on
    `:update` — a draft-only REPLACE (delete-all + re-insert) is safe
    exactly because a draft SO has no external referents. A SO that has
    left draft can never edit its lines (fulfillment consumes the order AS
    ORDERED — the belt's raw-SQL twin refuses the same edit).

  Runs in `after_action` (inside the action's transaction): if any line
  insert fails, the whole SO write rolls back. Each line still runs its own
  governed create (its `SameOrgFk` asserts same-org item + SO), so a line
  can never point at a foreign org's referent even though the rows are
  written by a cascade. Org pins happen at the QUERY layer — fixture
  structs never select `org_id` (the E4 lesson).
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    action = changeset.action && changeset.action.name

    # Capture the tenant NOW (attributes still pending — the EntryLines
    # posture); resolve off the record when NotLoaded (the E4 lesson).
    org_id = resolve_org(changeset)

    changeset
    |> validate_state(action)
    |> Ash.Changeset.after_action(fn changeset, so ->
      materialize(changeset, so, org_id)
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
          other -> raise "the SO's org could not be resolved: #{inspect(other)}"
        end
    end
  end

  # ── state + shape guards ────────────────────────────────────────────────────

  defp validate_state(changeset, :create) do
    lines = Ash.Changeset.get_argument(changeset, :lines) || []
    validate_shape(changeset, lines)
  end

  defp validate_state(changeset, :update) do
    require_state(changeset, :draft,
      message: "only a :draft SO can be edited (one-way state machine)"
    )
    |> then(fn changeset ->
      case Ash.Changeset.get_argument(changeset, :lines) do
        nil -> changeset
        lines -> validate_shape(changeset, lines)
      end
    end)
  end

  defp validate_state(changeset, _other), do: changeset

  defp require_state(changeset, state, message: message) do
    pre =
      case changeset.data.status do
        %Ash.NotLoaded{} -> Ash.load!(changeset.data, [:status], authorize?: false).status
        value -> value
      end

    if pre == state do
      changeset
    else
      Ash.Changeset.add_error(changeset, field: :status, message: message)
    end
  end

  defp validate_shape(changeset, lines) do
    cond do
      lines == [] ->
        Ash.Changeset.add_error(changeset,
          field: :lines,
          message: "a sales order carries at least one line"
        )

      lines ->
        Enum.reduce(lines, changeset, fn line, acc ->
          qty = Map.get(line, :qty) || Map.get(line, "qty")
          price = Map.get(line, :unit_price_cents) || Map.get(line, "unit_price_cents")

          acc =
            if is_integer(qty) and qty > 0 do
              acc
            else
              Ash.Changeset.add_error(acc,
                field: :qty,
                message: "every SO line qty must be a positive integer — got: #{inspect(qty)}"
              )
            end

          if is_integer(price) and price >= 0 do
            acc
          else
            Ash.Changeset.add_error(acc,
              field: :unit_price_cents,
              message:
                "every SO line unit_price_cents must be a non-negative integer — got: #{inspect(price)}"
            )
          end
        end)
    end
  end

  # ── materialization (after_action: commit-or-roll-back with the SO) ─────────

  defp materialize(changeset, so, org_id) do
    case Ash.Changeset.get_argument(changeset, :lines) do
      nil ->
        {:ok, so}

      lines ->
        line_resource =
          changeset.resource
          |> Ash.Resource.Info.relationships()
          |> Enum.find(&(&1.name == :lines))
          |> Map.fetch!(:destination)

        with :ok <- delete_existing(line_resource, org_id, so),
             {:ok, rows} <- insert_lines(line_resource, org_id, so, lines) do
          {:ok, %{so | lines: rows}}
        end
    end
  end

  defp delete_existing(line_resource, org_id, so) do
    repo = AshPostgres.DataLayer.Info.repo(line_resource, :mutate)
    table = AshPostgres.DataLayer.Info.table(line_resource)
    so_fk = attr_source(line_resource, :sales_order_id)
    org_col = attr_source(line_resource, :org_id)

    case repo.query("DELETE FROM #{table} WHERE #{so_fk} = $1 AND #{org_col} = $2", [
           dump_uuid(so.id),
           dump_uuid(org_id)
         ]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_lines(line_resource, org_id, so, lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      attrs = %{
        org_id: org_id,
        sales_order_id: so.id,
        item_id: Map.get(line, :item_id) || Map.get(line, "item_id"),
        qty: Map.get(line, :qty) || Map.get(line, "qty"),
        unit_price_cents:
          Map.get(line, :unit_price_cents) || Map.get(line, "unit_price_cents")
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
