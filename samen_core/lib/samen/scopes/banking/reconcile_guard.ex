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
  # another match.
  defp prevent_double_match(changeset, statement_line_id) do
    line_resource = resolve_statement_line_resource(changeset)

    case Ash.get(line_resource, statement_line_id, authorize?: false) do
      {:ok, %{status: status}} when status in [:matched, :reconciled] ->
        Ash.Changeset.add_error(changeset,
          field: :statement_line_id,
          message: "Statement line is already #{status}",
          variable: statement_line_id
        )
        |> tap_error()

      _ ->
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
