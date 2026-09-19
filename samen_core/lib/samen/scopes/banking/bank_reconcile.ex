defmodule Samen.Scopes.Banking.BankReconcile do
  @moduledoc """
  Period-based bank reconciliation for Banking (WS-ERP E9).

  Reconciliation closes a date range (typically a month) when all statement
  lines in that range are resolved (matched or categorized). The reconciler:

  1. **Asserts balance.** The sum of all matched/categorized GL entries in
     the period must equal the bank statement balance for that period.
     This is the R1 analogue for banking: the books must agree with the bank.

  2. **Locks the period.** Once reconciled, all statement lines in the range
     are marked `:reconciled` and frozen — no new matches or categorizations
     can target them. The DB trigger belt enforces this.

  3. **Creates a reconciliation record.** The `BankReconcile` row captures
     the period, the statement balance, the book balance, and the matched
     total. This is the audit trail.

  The reconciliation is refuse-closed:
  - Unbalanced (statement ≠ book) → refused
  - Unresolved lines in the period → refused
  - Already reconciled → refused
  """

  @doc """
  Reconcile a period for a bank account.

  Returns `{:ok, reconcile_record}` or `{:error, reason}`.
  """
  def reconcile(bank_account_id, from_date, to_date, statement_balance_cents, opts) do
    line_resource = Keyword.fetch!(opts, :line_resource)
    match_resource = Keyword.fetch!(opts, :match_resource)
    entry_resource = Keyword.fetch!(opts, :entry_resource)
    repo = Keyword.fetch!(opts, :repo)
    reconcile_resource = Keyword.fetch!(opts, :reconcile_resource)
    org_id = Keyword.get(opts, :org_id)

    with :ok <- validate_not_already_reconciled(reconcile_resource, bank_account_id, from_date, to_date, repo),
         {:ok, lines} <- get_lines_in_period(line_resource, bank_account_id, from_date, to_date, repo),
         :ok <- validate_all_resolved(lines),
         {:ok, book_balance} <- compute_book_balance(match_resource, entry_resource, lines, repo),
         :ok <- validate_balanced(statement_balance_cents, book_balance) do
      # Mark all lines as reconciled
      mark_lines_reconciled(line_resource, lines, repo)

      # Create the reconciliation record
      book_int = book_balance + 0
      attrs = %{bank_account_id: bank_account_id, from_date: from_date, to_date: to_date, statement_balance_cents: statement_balance_cents, book_balance_cents: book_int, line_count: length(lines), reconciled_at: DateTime.utc_now(), org_id: org_id}
      create_reconcile_record(reconcile_resource, attrs, repo)
    end
  end

  defp validate_not_already_reconciled(resource, bank_account_id, from_date, to_date, repo) do
    table = AshPostgres.DataLayer.Info.table(resource)

    sql = """
    SELECT COUNT(*) FROM #{table}
    WHERE bank_account_id = $1 AND from_date = $2 AND to_date = $3
    """

    case repo.query(sql, [dump_uuid(bank_account_id), from_date, to_date]) do
      {:ok, %{rows: [[0]]}} -> :ok
      {:ok, %{rows: [[_]]}} -> {:error, :already_reconciled}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_lines_in_period(resource, bank_account_id, from_date, to_date, repo) do
    table = AshPostgres.DataLayer.Info.table(resource)

    sql = """
    SELECT id, amount_cents, status FROM #{table}
    WHERE bank_account_id = $1
      AND posted_at >= $2
      AND posted_at <= $3
    """

    case repo.query(sql, [dump_uuid(bank_account_id), from_date, to_date]) do
      {:ok, %{rows: rows}} ->
        lines =
          Enum.map(rows, fn [id, amount, status] ->
            %{id: id, amount_cents: amount, status: status}
          end)

        {:ok, lines}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp validate_all_resolved(lines) do
    unresolved = Enum.filter(lines, &(&1.status in [:unmatched]))

    if length(unresolved) > 0 do
      {:error, {:unresolved_lines, length(unresolved)}}
    else
      :ok
    end
  end

  defp compute_book_balance(match_resource, entry_resource, lines, repo) do
    match_table = AshPostgres.DataLayer.Info.table(match_resource)

    line_ids = Enum.map(lines, & &1.id)

    if length(line_ids) == 0 do
      {:ok, 0}
    else
      # Sum the GL entries linked to these statement lines
      sql = """
      SELECT COALESCE(SUM(
        (SELECT SUM(l.debit_cents - l.credit_cents)
         FROM #{AshPostgres.DataLayer.Info.table(entry_resource)}_line l
         WHERE l.entry_id = m.entry_id)
      ), 0)::bigint
      FROM #{match_table} m
      WHERE m.statement_line_id = ANY($1)
      """

      case repo.query(sql, [line_ids]) do
        {:ok, %{rows: [[balance]]}} -> {:ok, balance}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp validate_balanced(statement_balance, book_balance) do
    if statement_balance == book_balance do
      :ok
    else
      {:error, {:unbalanced, statement: statement_balance, book: book_balance}}
    end
  end

  defp mark_lines_reconciled(resource, lines, repo) do
    table = AshPostgres.DataLayer.Info.table(resource)
    line_ids = Enum.map(lines, & &1.id)

    sql = """
    UPDATE #{table}
    SET status = 'reconciled', reconciled_at = NOW()
    WHERE id = ANY($1)
    """

    repo.query(sql, [line_ids])
  end

  defp create_reconcile_record(resource, attrs, repo) do
    table = AshPostgres.DataLayer.Info.table(resource)

    sql = """
    INSERT INTO #{table} (id, bank_account_id, from_date, to_date,
      statement_balance_cents, book_balance_cents, line_count, reconciled_at, org_id, inserted_at, updated_at)
    VALUES (gen_random_uuid(), $1, $2, $3, $4, $5, $6, $7, $8, NOW(), NOW())
    RETURNING id
    """

    case repo.query(sql, [
           dump_uuid(attrs.bank_account_id),
           attrs.from_date,
           attrs.to_date,
           attrs.statement_balance_cents,
           attrs.book_balance_cents,
           attrs.line_count,
           attrs.reconciled_at,
           attrs.org_id
         ]) do
      {:ok, %{rows: [[id]]}} -> {:ok, %{id: id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp dump_uuid(nil), do: nil
  defp dump_uuid(id), do: Ecto.UUID.dump!(id)
end
