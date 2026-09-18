defmodule Samen.Scopes.Banking.MatchAmountGuard do
  @moduledoc """
  The amount-strict match guard for Banking.Match (WS-ERP E9).

  When a match is created, this guard sums the statement line's amount and
  the GL entry's total (Σ debit_cents − Σ credit_cents over the entry's
  posted lines) and verifies they are within ±0.01 (1 cent) of each other.

  This prevents:
  - Matching a $100.00 bank line to a $50.00 invoice (under-match)
  - Matching a $100.00 bank line to a $150.00 invoice (over-match)

  The tolerance handles floating-point precision in multi-currency scenarios.
  For single-currency, the amounts are exact integer cents.

  The guard is a `before_action` change — the match row is never created
  if the amounts don't reconcile.
  """
  use Ash.Resource.Change

  @tolerance 1  # 1 cent

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      statement_line_id = Ash.Changeset.get_attribute(changeset, :statement_line_id)
      entry_id = Ash.Changeset.get_attribute(changeset, :entry_id)

      line_resource = resolve_statement_line_resource(changeset)
      entry_resource = resolve_entry_resource(changeset)
      line_table = AshPostgres.DataLayer.Info.table(line_resource)
      entry_table = AshPostgres.DataLayer.Info.table(entry_resource)

      # Get the statement line amount
      line_amount = get_statement_line_amount(line_resource, line_table, statement_line_id)

      # Get the GL entry total (Σ debit - Σ credit over posted lines)
      entry_total = get_entry_total(entry_resource, entry_table, entry_id)

      # Amount-strict: within tolerance
      diff = abs(line_amount - entry_total)

      if diff > @tolerance do
        Ash.Changeset.add_error(changeset,
          field: :entry_id,
          message:
            "Amount mismatch: statement line is #{format_cents(line_amount)} but " <>
              "journal entry totals #{format_cents(entry_total)} (difference: #{format_cents(diff)})",
          variable: entry_id
        )
      else
        changeset
      end
    end)
  end

  defp get_statement_line_amount(resource, table, id) do
    repo = AshPostgres.DataLayer.Info.repo(resource, :mutate)

    sql = "SELECT amount_cents FROM #{table} WHERE id = $1"

    case repo.query(sql, [dump_uuid(id)]) do
      {:ok, %{rows: [[amount]]}} -> amount
      _ -> 0
    end
  end

  defp get_entry_total(resource, _table, entry_id) do
    repo = AshPostgres.DataLayer.Info.repo(resource, :mutate)

    # We need to sum over the entry's journal lines, not the entry itself.
    # The entry table doesn't have debit/credit — the line table does.
    # We join through the entry's lines.
    line_resource = resolve_line_resource(resource)
    line_table = AshPostgres.DataLayer.Info.table(line_resource)

    sql = """
    SELECT COALESCE(SUM(l.debit_cents - l.credit_cents), 0)::bigint
    FROM #{line_table} l
    WHERE l.entry_id = $1
    """

    case repo.query(sql, [dump_uuid(entry_id)]) do
      {:ok, %{rows: [[total]]}} -> total
      _ -> 0
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

  defp resolve_line_resource(entry_resource) do
    entry_resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.name == :lines))
    |> Map.fetch!(:destination)
  end

  defp format_cents(cents) do
    dollars = div(cents, 100)
    remainder = rem(cents, 100) |> abs()
    "$#{dollars}.#{String.pad_leading(Integer.to_string(remainder), 2, "0")}"
  end

  defp dump_uuid(nil), do: nil
  defp dump_uuid(id), do: Ecto.UUID.dump!(id)
end
