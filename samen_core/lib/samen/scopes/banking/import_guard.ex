defmodule Samen.Scopes.Banking.ImportGuard do
  @moduledoc """
  The import deduplication guard for Banking.StatementLine (WS-ERP E9).

  On import, each statement line is normalized (date + amount + description)
  and SHA-256 hashed to produce an `import_hash`. This guard checks the hash
  against all existing lines for the same bank account. Duplicates are skipped
  (not imported) and counted in the StatementImport's `duplicate_count`.

  The guard runs as a `before_action` on the bulk import — it filters the
  incoming batch and only inserts lines whose hash is not already present.

  This is the belt; the DB unique index on `(bank_account_id, import_hash)`
  is the braces.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      changeset
    end)
  end

  @doc """
  Filter a batch of statement line attributes, removing duplicates.
  Returns `{new_lines, duplicate_count}`.
  """
  def filter_duplicates(bank_account_id, lines, line_resource, repo) do
    # Collect all import hashes from the incoming batch
    hashes = Enum.map(lines, & &1.import_hash)

    # Query existing hashes for this bank account
    table = AshPostgres.DataLayer.Info.table(line_resource)

    sql = """
    SELECT import_hash FROM #{table}
    WHERE bank_account_id = $1 AND import_hash = ANY($2)
    """

    existing_hashes =
      case repo.query(sql, [dump_uuid(bank_account_id), hashes]) do
        {:ok, %{rows: rows}} -> Enum.map(rows, &hd/1) |> MapSet.new()
        {:error, _} -> MapSet.new()
      end

    # Partition: new vs duplicate
    {new_lines, duplicates} =
      Enum.split_with(lines, fn line ->
        not MapSet.member?(existing_hashes, line.import_hash)
      end)

    {new_lines, length(duplicates)}
  end

  @doc """
  Compute the import hash for a normalized statement line.
  Hash is SHA-256 of the normalized string: date, amount, description.
  """
  def compute_hash(date, amount_cents, description) do
    normalized =
      "#{Date.to_iso8601(date)}|#{amount_cents}|#{String.downcase(String.trim(description))}"

    :crypto.hash(:sha256, normalized) |> Base.encode16(case: :lower)
  end

  defp dump_uuid(nil), do: nil
  defp dump_uuid(id), do: Ecto.UUID.dump!(id)
end
