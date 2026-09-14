defmodule Samen.Scopes.Inventory.PoLinesWriter do
  @moduledoc """
  Materializes the `lines` argument of a `PurchaseOrder` create/update into
  real `PoLine` rows (WS-ERP E4) — the ONLY sanctioned writer of line rows,
  the `Samen.Scopes.Finance.EntryLines` shape.

  * LINE SHAPE: a PO carries at least one line; every `qty` is a POSITIVE
    integer; every `unit_cost_cents` is a NON-NEGATIVE integer (a purchase
    order commits spend). The embedded-argument constraints type the fields;
    this guard owns the business conditions the type system cannot express.
  * STATE: line materialization happens on `:create` (born a draft) and on
    `:update` — and a draft-only `:update` REPLACE (delete-all + re-insert)
    is safe exactly because a draft PO has no external referents. A PO that
    has left draft can never edit its lines (the receiving quantities must
    reconcile against the order AS ORDERED — the belt's raw-SQL twin refuses
    the same edit).

  Runs in `after_action` (inside the action's transaction): if any line
  insert fails, the whole PO write rolls back — a PO can never end up
  line-less or half-replaced. Each line still runs its own governed create
  (its `SameOrgFk` asserts same-org item + PO), so a line can never point at
  a foreign org's referent even though the rows are written by a cascade.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    action = changeset.action && changeset.action.name

    # Capture the tenant NOW (attributes still pending — the EntryLines
    # posture); inside after_action the record's org_id may read NotLoaded.
    org_id =
      case Ash.Changeset.get_attribute(changeset, :org_id) do
        %Ash.NotLoaded{} -> Ash.load!(changeset.data, [:org_id], authorize?: false).org_id
        value -> value
      end

    changeset
    |> validate_state(action, org_id)
    |> Ash.Changeset.after_action(fn changeset, po ->
      materialize(changeset, po, org_id)
    end)
  end

  # ── state + shape guards (before_action semantics via validation) ───────────

  defp validate_state(changeset, :create, _org_id) do
    lines = Ash.Changeset.get_argument(changeset, :lines) || []
    validate_shape(changeset, lines)
  end

  defp validate_state(changeset, :update, org_id) do
    case Ash.Changeset.get_argument(changeset, :lines) do
      nil ->
        # A no-lines update (memo/date/warehouse edits) still must not fire on
        # a non-draft PO — the belt's twin refuses the state flip too.
        require_state(changeset, org_id, :draft,
          message: "only a :draft PO can be edited (one-way state machine)"
        )

      lines ->
        require_state(changeset, org_id, :draft,
          message: "only a :draft PO can be edited (one-way state machine)"
        )
        |> validate_shape(lines)
    end
  end

  defp validate_state(changeset, _other, _org_id), do: changeset

  defp require_state(changeset, _org_id, state, message: message) do
    pre =
      case Ash.Changeset.get_attribute(changeset, :status) || changeset.data.status do
        %Ash.NotLoaded{} ->
          Ash.load!(changeset.data, [:status], authorize?: false).status

        value ->
          value
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
          message: "a purchase order carries at least one line"
        )

      lines ->
        Enum.reduce(lines, changeset, fn line, acc ->
          qty = Map.get(line, :qty) || Map.get(line, "qty")
          cost = Map.get(line, :unit_cost_cents) || Map.get(line, "unit_cost_cents")

          acc =
            if is_integer(qty) and qty > 0 do
              acc
            else
              Ash.Changeset.add_error(acc,
                field: :qty,
                message: "every PO line qty must be a positive integer — got: #{inspect(qty)}"
              )
            end

          if is_integer(cost) and cost >= 0 do
            acc
          else
            Ash.Changeset.add_error(acc,
              field: :unit_cost_cents,
              message:
                "every PO line unit_cost_cents must be a non-negative integer — got: #{inspect(cost)}"
            )
          end
        end)
    end
  end

  # ── materialization (after_action: commit-or-roll-back with the PO) ─────────

  defp materialize(changeset, po, org_id) do
    case Ash.Changeset.get_argument(changeset, :lines) do
      nil ->
        {:ok, po}

      lines ->
        line_resource =
          changeset.resource
          |> Ash.Resource.Info.relationships()
          |> Enum.find(&(&1.name == :lines))
          |> Map.fetch!(:destination)

        with :ok <- delete_existing(line_resource, org_id, po),
             {:ok, rows} <- insert_lines(line_resource, org_id, po, lines) do
          {:ok, %{po | lines: rows}}
        end
    end
  end

  # Draft replacement: a draft's staged lines are not facts yet (nothing
  # outside the PO references them; receipts reference the line only after
  # the PO leaves draft). The migration's trigger permits line DELETEs and
  # UPDATEs only while the parent PO is still a draft — the belt over this
  # brace.
  defp delete_existing(line_resource, org_id, po) do
    repo = AshPostgres.DataLayer.Info.repo(line_resource, :mutate)
    table = AshPostgres.DataLayer.Info.table(line_resource)
    po_fk = attr_source(line_resource, :purchase_order_id)
    org_col = attr_source(line_resource, :org_id)

    case repo.query("DELETE FROM #{table} WHERE #{po_fk} = $1 AND #{org_col} = $2", [
           dump_uuid(po.id),
           dump_uuid(org_id)
         ]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_lines(line_resource, org_id, po, lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      attrs = %{
        org_id: org_id,
        purchase_order_id: po.id,
        item_id: Map.get(line, :item_id) || Map.get(line, "item_id"),
        qty: Map.get(line, :qty) || Map.get(line, "qty"),
        unit_cost_cents: Map.get(line, :unit_cost_cents) || Map.get(line, "unit_cost_cents")
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
