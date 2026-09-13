defmodule Samen.Scopes.Finance.EntryLines do
  @moduledoc """
  Materializes the `lines` argument of a `JournalEntry` create/update into real
  `JournalLine` rows (WS-ERP E1; ADR-049 §2) — the ONLY writer of line rows in
  the base system.

  Runs in the entry's `after_action` (inside the action's transaction —
  `Samen.Scopes.SalesOps.ConvertLead`'s cross-row-cascade discipline): if any
  line insert fails, the whole entry write rolls back (an entry can never end
  up line-less, or half-replaced).  * On `:create` (and `:create_reversal`): inserts one row per line.
  * On `:update` (DRAFT edits only — the DB trigger refuses the update of a
    non-draft row): REPLACES the persisted lines (delete-all + re-insert) when
    the optional `lines` argument is present; a draft has no external
    referents, so full replacement is safe.

  `Samen.Scopes.Finance.UnbalancedEntry` has ALREADY validated the sum over the
  same argument in `before_action`, so by the time rows are materialized the
  entry is known-balanced; each line still runs its own governed create
  (`LineAmounts` re-refuses exactly-one-non-zero per row) and each line's
  `account_id` is asserted same-org via the line's own
  `Samen.Policy.SameOrgFk` change (`belongs_to :account`), so a line can never
  point at a foreign org's account even though the rows are created by a
  system cascade.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    # Capture the tenant NOW (attributes still pending — get_attribute sees the
    # cast org_id); inside after_action the created record's org_id may be an
    # Ash.NotLoaded placeholder and changeset.attributes are already cleared.
    # On an :update the record ITSELF may carry a NotLoaded org_id (the caller
    # holds a create result) — Ash.load! re-fetches it (the ConvertLead
    # discipline: `Ash.load!(lead, [:org_id, ...])`).
    org_id =
      case Ash.Changeset.get_attribute(changeset, :org_id) do
        %Ash.NotLoaded{} -> Ash.load!(changeset.data, [:org_id], authorize?: false).org_id
        value -> value
      end

    Ash.Changeset.after_action(changeset, fn changeset, entry ->
      materialize(changeset, entry, org_id)
    end)
  end

  defp materialize(changeset, entry, org_id) do
    case Ash.Changeset.get_argument(changeset, :lines) do
      nil -> {:ok, entry}
      lines -> write_lines(changeset, entry, org_id, lines)
    end
  end

  defp write_lines(changeset, entry, org_id, lines) do
    line_resource =
      changeset.resource
      |> Ash.Resource.Info.relationships()
      |> Enum.find(&(&1.name == :lines))
      |> Map.fetch!(:destination)

    with :ok <- delete_existing(changeset.resource, line_resource, entry),
         {:ok, rows} <- insert_lines(line_resource, org_id, entry, lines) do
      {:ok, %{entry | lines: rows}}
    end
  end

  # Draft replacement: a draft's staged lines are not facts yet (nothing
  # outside the entry references them), so an update carrying a `lines`
  # argument deletes the staged rows and re-materializes. The migration's
  # trigger permits line DELETEs only while every row's ENTRY is still a
  # draft — the belt over this braces.
  defp delete_existing(entry_resource, line_resource, entry) do
    repo = AshPostgres.DataLayer.Info.repo(line_resource, :mutate)
    table = AshPostgres.DataLayer.Info.table(line_resource)
    entry_fk = entry_fk_source(line_resource, entry_resource)

    case repo.query("DELETE FROM #{table} WHERE #{entry_fk} = $1", [dump_uuid(entry.id)]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp insert_lines(line_resource, org_id, entry, lines) do
    Enum.reduce_while(lines, {:ok, []}, fn line, {:ok, acc} ->
      attrs = %{
        org_id: org_id,
        entry_id: entry.id,
        account_id: Map.fetch!(line, :account_id),
        debit_cents: Map.get(line, :debit_cents) || Map.get(line, "debit_cents") || 0,
        credit_cents: Map.get(line, :credit_cents) || Map.get(line, "credit_cents") || 0,
        memo: Map.get(line, :memo) || Map.get(line, "memo")
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
