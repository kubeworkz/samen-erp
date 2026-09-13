defmodule Samen.Scopes.Finance.PostBalance do
  @moduledoc """
  The `:post`-time R1 re-check (WS-ERP E1; ADR-049 §2): sums the entry's
  PERSISTED `JournalLine` rows (bare SQL — the Reconcile idiom) and refuses
  unless `Σ debits == Σ credits` AND the entry carries at least one line.

  Posting validates against the STORED lines, never a caller argument — a
  caller cannot post lines that differ from what the draft actually holds
  (fail-closed: the fact that posts is the fact that is stored). The
  argument-based sum check is `Samen.Scopes.Finance.UnbalancedEntry`'s, on the
  create/update actions; this is its persisted-rows twin at the instant of
  posting. Between them, an entry can never drift out of balance on its way
  to becoming an immutable fact.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, &check/1)
  end

  defp check(changeset) do
    resource = changeset.resource
    line_resource = line_resource(resource)
    repo = AshPostgres.DataLayer.Info.repo(resource, :read) || AshPostgres.DataLayer.Info.repo(resource)

    entry_id = changeset.data.id
    entry_fk = entry_fk_source(line_resource, resource)
    table = AshPostgres.DataLayer.Info.table(line_resource)
    debit = attr_source(line_resource, :debit_cents)
    credit = attr_source(line_resource, :credit_cents)

    sql = """
    SELECT COALESCE(SUM(#{debit}), 0)::bigint, COALESCE(SUM(#{credit}), 0)::bigint, COUNT(*)::bigint
    FROM #{table} WHERE #{entry_fk} = $1
    """

    case repo.query(sql, [dump_uuid(entry_id)]) do
      {:ok, %{rows: [[debits, credits, count]]}} ->
        cond do
          count == 0 ->
            Ash.Changeset.add_error(changeset,
              field: :lines,
              message: "a posting requires at least one line — refusing to post a line-less entry"
            )

          debits != credits ->
            Ash.Changeset.add_error(changeset,
              field: :lines,
              message:
                "unbalanced entry: stored debits sum to #{debits} but credits sum to #{credits} — " <>
                  "Σ debits must equal Σ credits (R1, double entry)"
            )

          true ->
            changeset
        end

      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :lines,
          message: "post balance check could not verify the stored lines: #{inspect(reason)}"
        )
    end
  end

  defp line_resource(resource) do
    resource
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
