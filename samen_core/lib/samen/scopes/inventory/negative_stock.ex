defmodule Samen.Scopes.Inventory.NegativeStock do
  @moduledoc """
  The fail-closed stock floor (WS-ERP E3; design §3.1): a posting that
  would take `(item, warehouse)` below zero is REFUSED — unless the
  warehouse explicitly opts out (`allow_negative: true`, the cycle-count
  reality; the default warehouse NEVER goes negative).

  Computes the would-be balance from the LIVE ledger sum
  (`Samen.Scopes.Inventory.LedgerSum.on_hand/4`) in `before_action` —
  inside the action's transaction, so it reads the transaction's own
  uncommitted events (design §9's read-your-writes note: the real-time
  check is the ledger, the rollup serves reads between posts).

  The Ash-side guard is the FIRST net; the DB trigger (the E3 migration's
  `NegativeStock` arm) re-enforces the same floor over the persisted rows,
  so even a raw-SQL event into a guard-on warehouse cannot go negative.
  A warehouse with `allow_negative` opts out at BOTH layers by construction:
  the trigger joins the warehouse row and reads the SAME column.

  ## Usage

      change({Samen.Scopes.Inventory.NegativeStock,
        warehouse: WarehouseModule,
        ledger: StockLedgerModule})

  Both resources are compile-time module params (design §8 — never runtime
  coupling between scope files). `org_id` is captured at change/2 time
  (the EntryLines discipline — CoreAttributes injects it before other
  changes run; on action RESULTS it reads back `NotLoaded`).
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    warehouse_resource = Keyword.fetch!(opts, :warehouse)
    ledger_resource = Keyword.fetch!(opts, :ledger)

    # Capture NOW (change/2 time): attributes are still pending here, and
    # CoreAttributes has already injected org_id. (Reading it later — off the
    # result or `changeset.data` — is the NotLoaded trap E1 fell into.)
    org_id = resolve_org(changeset)

    repo = AshPostgres.DataLayer.Info.repo(changeset.resource, :mutate)

    Ash.Changeset.before_action(changeset, fn changeset ->
      item_id = Ash.Changeset.get_attribute(changeset, :item_id)
      warehouse_id = Ash.Changeset.get_attribute(changeset, :warehouse_id)
      qty = Ash.Changeset.get_attribute(changeset, :qty)

      case ledger_allowance(repo, ledger_resource, warehouse_resource, org_id, item_id, warehouse_id, qty) do
        :ok ->
          changeset

        {:error, message} ->
          Ash.Changeset.add_error(changeset, field: :qty, message: message)
      end
    end)
  end

  defp resolve_org(changeset) do
    case Ash.Changeset.get_attribute(changeset, :org_id) do
      %Ash.NotLoaded{} ->
        Ash.load!(changeset.data, [:org_id], authorize?: false).org_id

      value ->
        value
    end
  end

  # The floor: live on-hand + the posting's qty >= 0, unless the warehouse
  # opts out. A `nil` (nonexistent) warehouse row fails HONEST — the FK and
  # the SameOrgFk change own existence; this guard owns the floor.
  defp ledger_allowance(repo, ledger_resource, warehouse_resource, org_id, item_id, warehouse_id, qty) do
    on_hand = Samen.Scopes.Inventory.LedgerSum.on_hand(repo, ledger_resource, org_id, item_id, warehouse_id)

    cond do
      on_hand + qty >= 0 ->
        :ok

      warehouse_allows_negative?(repo, warehouse_resource, warehouse_id) ->
        :ok

      true ->
        {:error,
         "negative stock refused: (item, warehouse) would go to #{on_hand + qty} — the floor is 0 " <>
           "(set the warehouse's `allow_negative: true` to opt out for cycle-count realities; " <>
           "fail-closed is the default)"}
    end
  end

  defp warehouse_allows_negative?(repo, warehouse_resource, warehouse_id) do
    table = AshPostgres.DataLayer.Info.table(warehouse_resource)
    pk = pk_source(warehouse_resource)
    allow_col = attr_source(warehouse_resource, :allow_negative)

    case repo.query(
           "SELECT #{allow_col} FROM #{table} WHERE #{pk} = $1",
           [dump_uuid(warehouse_id)]
         ) do
      {:ok, %{rows: [[allowed]]}} -> allowed == true
      {:ok, %{rows: []}} -> false
      {:error, _} -> false
    end
  end

  defp pk_source(resource) do
    resource
    |> Ash.Resource.Info.attributes()
    |> Enum.find(& &1.primary_key?)
    |> case do
      nil -> raise ArgumentError, "no primary key on #{inspect(resource)}"
      attr -> to_string(attr.source || attr.name)
    end
  end

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
