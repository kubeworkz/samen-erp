defmodule Samen.Scopes.Banking.ReconcileGuard do
  @moduledoc """
  The reconciliation guard for Banking.Match (WS-ERP E9).

  Enforces two invariants on every match create:

  1. **No double-match.** A statement line that is already `:matched` or
     `:reconciled` cannot receive another match. The DB unique index on
     `(statement_line_id)` is the belt; this is the braces.

  2. **No match to voided entry.** A JournalEntry with `status: :void` is
     a reversing event — matching a bank line to it would double-count the
     original transaction. The guard queries the entry's status and refuses
     the match before any row lands.

  Both are `before_action` changes — the match row is never created if
  either invariant is violated.
  """
  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      statement_line_id = Ash.Changeset.get_attribute(changeset, :statement_line_id)
      entry_id = Ash.Changeset.get_attribute(changeset, :entry_id)

      with :ok <- prevent_double_match(changeset, statement_line_id),
           :ok <- prevent_voided_match(changeset, entry_id) do
        changeset
      end
    end)
  end

  # A statement line that is already :matched or :reconciled cannot receive
  # another match — AND neither can a line that already HAS a Match row. The
  # status column is not transitioned by the match create itself (the line
  # stays :unmatched until period close), so without this second check the
  # guard would pass and only the DB unique index would refuse (an opaque
  # constraint error instead of the honest message). Belt AND braces.
  defp prevent_double_match(changeset, statement_line_id) do
    line_resource = resolve_statement_line_resource(changeset)

    status_check =
      case Ash.get(line_resource, statement_line_id, authorize?: false) do
        {:ok, %{status: status}} when status in [:matched, :reconciled] ->
          Ash.Changeset.add_error(changeset,
            field: :statement_line_id,
            message: "Statement line is already #{status}",
            variable: statement_line_id
          )

        _ ->
          :ok
      end

    if status_check == :ok do
      match_exists_check(changeset, statement_line_id)
    else
      status_check
    end
  end

  defp match_exists_check(changeset, statement_line_id) do
    match_resource = changeset.resource

    # Existence probe as a SCALAR AGGREGATE (T132 read-scope lint): `exists?`
    # transfers a boolean, never a cross-tenant row set, so it needs no org pin
    # — the sanctioned aggregate form for an `authorize?: false` check. The
    # SameOrgFk change has already proven `statement_line_id` belongs to this
    # changeset's org before this guard runs. `Ash.exists?/2` is the RAISING
    # form (bare boolean); a query error must REFUSE the match, never fall
    # through to `:ok`.
    existing? =
      match_resource
      |> Ash.Query.filter(statement_line_id == ^statement_line_id)
      |> Ash.exists?(authorize?: false)

    case existing? do
      true ->
        Ash.Changeset.add_error(changeset,
          field: :statement_line_id,
          message: "Statement line already has a match",
          variable: statement_line_id
        )

      false ->
        :ok
    end
  end

  # A JournalEntry with status: :void is a reversing event.
  # Matching a bank line to it would double-count.
  defp prevent_voided_match(changeset, entry_id) do
    entry_resource = resolve_entry_resource(changeset)

    case Ash.get(entry_resource, entry_id, authorize?: false) do
      {:ok, %{status: :void}} ->
        Ash.Changeset.add_error(changeset,
          field: :entry_id,
          message: "Cannot match to a voided journal entry",
          variable: entry_id
        )
        |> tap_error()

      _ ->
        :ok
    end
  end

  defp resolve_statement_line_resource(changeset) do
    changeset.resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.name == :statement_line))
    |> Map.fetch!(:destination)
  end

  defp resolve_entry_resource(changeset) do
    changeset.resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.name == :entry))
    |> Map.fetch!(:destination)
  end

  defp tap_error(changeset), do: changeset
end
