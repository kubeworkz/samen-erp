defmodule Samen.Scopes.Finance.PayrollTieOut do
  @moduledoc """
  Read-only tie-out from a payroll register to the bank.

  The report follows the money in one direction:

      register journal lines
        -> payroll payable / tax liability credits
        -> settlement drafts (debit the liability, credit cash)
        -> posted settlement entries
        -> Banking.Match rows and their statement lines

  It never writes. A settlement is prepared and posted through
  `PayrollSettlement`'s actions, and the bank link is the existing
  `Banking.Match` row, so this report cannot invent a reconciliation or bypass
  the match guards.

  Statuses:

    * `:unsettled` — the register is posted but no settlement batch exists.
    * `:unposted` — a settlement exists in draft, or one of its entries is
      still draft.
    * `:unreconciled` — the settlement is posted and balanced, but no bank match
      proves the cash movement (or this host has not mounted Banking).
    * `:mismatch` — the register liability, settlement debit, cash credit or
      matched bank amount does not agree.
    * `:voided` — the register or a settlement entry was voided.
    * `:register_unposted` — the register itself is not posted, so there is
      nothing to settle yet.
    * `:reconciled` — every liability is settled for its register credit, the
      cash legs agree, and each cash movement has a bank match.

  The report is org-pinned: every read filters or checks the caller's
  `org_id`, and a foreign import is treated as not found.
  """

  require Ash.Query

  @type status ::
          :unsettled
          | :unposted
          | :unreconciled
          | :mismatch
          | :voided
          | :register_unposted
          | :reconciled

  @doc """
  Builds the tie-out for one payroll import.

  Options:

    * `:import_module` (required) — the host's `PayrollImport`.
    * `:settlement_module` (required) — the host's `PayrollSettlement`.
    * `:entry_module` (required) — the host's `JournalEntry`.
    * `:match_module` — the host's `Banking.Match`; omit when Banking is not
      mounted. Without it the report can still prove register -> settlement ->
      cash, but it fails closed at `:unreconciled`.
  """
  def report(org_id, payroll_import_id, opts)
      when is_binary(org_id) and is_binary(payroll_import_id) do
    import_mod = Keyword.fetch!(opts, :import_module)
    settlement_mod = Keyword.fetch!(opts, :settlement_module)
    entry_mod = Keyword.fetch!(opts, :entry_module)
    match_mod = Keyword.get(opts, :match_module)

    with {:ok, import} <- load_import(import_mod, org_id, payroll_import_id),
         {:ok, settlement} <- load_settlement(settlement_mod, org_id, payroll_import_id),
         {:ok, settlement_entries} <- load_settlement_entries(entry_mod, org_id, settlement),
         {:ok, matches} <- load_matches(match_mod, org_id, settlement_entries) do
      {:ok, build(import, settlement, settlement_entries, matches, not is_nil(match_mod), org_id)}
    end
  end

  defp load_import(import_mod, org_id, import_id) do
    import_mod
    |> Ash.Query.filter(id == ^import_id and org_id == ^org_id)
    |> Ash.Query.load(entry: [lines: :account])
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %{} = import} -> {:ok, import}
      {:ok, nil} -> {:error, :not_found}
      {:error, reason} -> {:error, {:payroll_import_unreadable, reason}}
    end
  end

  defp load_settlement(settlement_mod, org_id, import_id) do
    settlement_mod
    |> Ash.Query.filter(org_id == ^org_id and payroll_import_id == ^import_id)
    |> Ash.read_one(authorize?: false)
  end

  defp load_settlement_entries(_entry_mod, _org_id, nil), do: {:ok, []}

  defp load_settlement_entries(entry_mod, org_id, settlement) do
    ids = settlement.entry_ids || []

    if ids == [] do
      {:ok, []}
    else
      entry_mod
      |> Ash.Query.filter(id in ^ids and org_id == ^org_id)
      |> Ash.Query.load(lines: :account)
      |> Ash.read(authorize?: false)
    end
  end

  defp load_matches(nil, _org_id, _entries), do: {:ok, []}

  defp load_matches(_match_mod, _org_id, []), do: {:ok, []}

  defp load_matches(match_mod, org_id, entries) do
    ids = Enum.map(entries, & &1.id)

    match_mod
    |> Ash.Query.filter(org_id == ^org_id and entry_id in ^ids)
    |> Ash.Query.load(:statement_line)
    |> Ash.read(authorize?: false)
  end

  defp build(import, settlement, settlement_entries, matches, bank_wired?, org_id) do
    register_entry = import.entry
    register_lines = Enum.map(register_entry.lines || [], &register_line/1)
    register_liabilities = aggregate_register_liabilities(register_lines)
    settlement_by_account = aggregate_settlements(settlement_entries, settlement)
    matches_by_entry = Enum.group_by(matches, & &1.entry_id)

    liabilities =
      Enum.map(register_liabilities, fn register ->
        settlement_row =
          Map.get(settlement_by_account, register.account_id, empty_settlement_row())

        entry_matches =
          Enum.flat_map(settlement_row.entries, &Map.get(matches_by_entry, &1.id, []))

        bank_matches = Enum.map(entry_matches, &bank_match/1)
        matched_cents = Enum.reduce(bank_matches, 0, &(abs(&1.amount_cents || 0) + &2))

        %{
          account_id: register.account_id,
          code: register.code,
          name: register.name,
          register_cents: register.cents,
          settlement_cents: settlement_row.liability_cents,
          cash_cents: settlement_row.cash_cents,
          matched_cents: matched_cents,
          variance_cents: register.cents - settlement_row.liability_cents,
          cash_variance_cents: settlement_row.cash_cents - matched_cents,
          entry_ids: Enum.map(settlement_row.entries, & &1.id),
          entry_statuses: Enum.map(settlement_row.entries, & &1.status),
          bank_matches: bank_matches,
          accepted?: accepted?(register.cents, settlement_row, bank_matches, matched_cents)
        }
      end)

    totals = totals(liabilities)
    missing_entry_ids = missing_entry_ids(settlement, settlement_entries)

    status =
      status(
        import,
        settlement,
        settlement_entries,
        liabilities,
        totals,
        bank_wired?,
        missing_entry_ids
      )

    %{
      status: status,
      reconciled?: status == :reconciled,
      org_id: org_id,
      payroll_import: %{
        id: import.id,
        provider: import.provider,
        external_id: import.external_id,
        entry_id: import.entry_id,
        entry_status: register_entry.status,
        entry_date: import.entry_date,
        total_cents: import.total_cents,
        status: import.status
      },
      register_lines: register_lines,
      liabilities: liabilities,
      settlement: settlement_view(settlement),
      totals: totals,
      missing_entry_ids: missing_entry_ids,
      bank_wired?: bank_wired?,
      exceptions: exceptions(status, liabilities, totals, missing_entry_ids)
    }
  end

  defp aggregate_register_liabilities(register_lines) do
    register_lines
    |> Enum.filter(&(&1.kind == :liability))
    |> Enum.reduce(%{}, fn line, acc ->
      cents = line.credit_cents - line.debit_cents

      Map.update(
        acc,
        line.account_id,
        %{account_id: line.account_id, code: line.code, name: line.name, cents: cents},
        fn row -> %{row | cents: row.cents + cents} end
      )
    end)
    |> Map.values()
    |> Enum.filter(&(&1.cents > 0))
    |> Enum.sort_by(& &1.code)
  end

  defp aggregate_settlements(settlement_entries, settlement) do
    cash_id = settlement && settlement.cash_account_id

    Enum.reduce(settlement_entries, %{}, fn entry, acc ->
      per_account = liability_amounts(entry)
      cash_cents = cash_amount(entry, cash_id)

      Enum.reduce(per_account, acc, fn {account_id, cents}, acc ->
        Map.update(
          acc,
          account_id,
          %{entries: [entry], liability_cents: cents, cash_cents: cash_cents},
          fn row ->
            %{
              row
              | entries: [entry | row.entries],
                liability_cents: row.liability_cents + cents,
                cash_cents: row.cash_cents + cash_cents
            }
          end
        )
      end)
    end)
  end

  defp liability_amounts(entry) do
    entry.lines
    |> Enum.filter(&(&1.account && &1.account.kind == :liability))
    |> Enum.reduce(%{}, fn line, acc ->
      Map.update(
        acc,
        line.account_id,
        line.debit_cents - line.credit_cents,
        &(&1 + line.debit_cents - line.credit_cents)
      )
    end)
  end

  defp cash_amount(entry, cash_id) do
    entry.lines
    |> Enum.filter(&(&1.account_id == cash_id))
    |> Enum.reduce(0, &(&1.credit_cents - &1.debit_cents + &2))
  end

  defp empty_settlement_row, do: %{entries: [], liability_cents: 0, cash_cents: 0}

  defp accepted?(register_cents, settlement_row, bank_matches, matched_cents) do
    settlement_row.entries != [] and
      Enum.all?(settlement_row.entries, &(&1.status == :posted)) and
      register_cents == settlement_row.liability_cents and
      settlement_row.liability_cents == settlement_row.cash_cents and
      bank_matches != [] and
      matched_cents == settlement_row.cash_cents
  end

  defp totals(liabilities) do
    register = Enum.reduce(liabilities, 0, &(&1.register_cents + &2))
    settlement = Enum.reduce(liabilities, 0, &(&1.settlement_cents + &2))
    cash = Enum.reduce(liabilities, 0, &(&1.cash_cents + &2))
    matched = Enum.reduce(liabilities, 0, &(&1.matched_cents + &2))

    %{
      register_liability_cents: register,
      settlement_cents: settlement,
      cash_cents: cash,
      matched_cents: matched,
      variance_cents: register - settlement,
      cash_variance_cents: settlement - cash,
      bank_variance_cents: cash - matched
    }
  end

  defp missing_entry_ids(nil, _entries), do: []

  defp missing_entry_ids(settlement, entries) do
    found = MapSet.new(entries, & &1.id)
    Enum.reject(settlement.entry_ids || [], &MapSet.member?(found, &1))
  end

  defp status(
         import,
         settlement,
         settlement_entries,
         liabilities,
         totals,
         bank_wired?,
         missing_entry_ids
       ) do
    cond do
      import.entry.status == :void ->
        :voided

      import.entry.status != :posted ->
        :register_unposted

      is_nil(settlement) ->
        :unsettled

      settlement.status == :draft ->
        :unposted

      Enum.any?(settlement_entries, &(&1.status == :void)) ->
        :voided

      Enum.any?(settlement_entries, &(&1.status != :posted)) ->
        :unposted

      missing_entry_ids != [] ->
        :mismatch

      totals.variance_cents != 0 or totals.cash_variance_cents != 0 ->
        :mismatch

      Enum.any?(liabilities, &(&1.variance_cents != 0)) ->
        :mismatch

      Enum.any?(liabilities, &(&1.settlement_cents != &1.cash_cents)) ->
        :mismatch

      Enum.any?(liabilities, &(&1.bank_matches != [] and &1.cash_variance_cents != 0)) ->
        :mismatch

      not bank_wired? ->
        :unreconciled

      Enum.any?(liabilities, &(not &1.accepted?)) ->
        :unreconciled

      true ->
        :reconciled
    end
  end

  defp exceptions(status, liabilities, totals, missing_entry_ids) do
    base =
      case status do
        :unsettled -> [:settlement_not_prepared]
        :unposted -> [:settlement_not_posted]
        :register_unposted -> [:register_not_posted]
        :voided -> [:voided_payroll_entry]
        :unreconciled -> [:bank_match_missing]
        _ -> []
      end

    variance =
      if status in [:mismatch, :unreconciled] and
           (totals.variance_cents != 0 or totals.cash_variance_cents != 0) do
        base ++ [:settlement_amount_mismatch]
      else
        base
      end

    missing =
      if missing_entry_ids == [], do: variance, else: variance ++ [:settlement_entry_missing]

    Enum.reduce(liabilities, missing, fn liability, acc ->
      cond do
        status not in [:mismatch, :unreconciled] ->
          acc

        liability.variance_cents != 0 ->
          acc ++ [{:liability_variance, liability.code, liability.variance_cents}]

        liability.settlement_cents != liability.cash_cents ->
          acc ++ [{:cash_variance, liability.code, liability.cash_variance_cents}]

        liability.bank_matches != [] and liability.cash_variance_cents != 0 ->
          acc ++
            [{:bank_match_amount_mismatch, liability.code, liability.cash_variance_cents}]

        not liability.accepted? and status == :unreconciled ->
          acc ++ [{:bank_match_missing, liability.code}]

        true ->
          acc
      end
    end)
    |> Enum.uniq()
  end

  defp settlement_view(nil), do: nil

  defp settlement_view(settlement) do
    %{
      id: settlement.id,
      status: settlement.status,
      payroll_import_id: settlement.payroll_import_id,
      cash_account_id: settlement.cash_account_id,
      settlement_date: settlement.settlement_date,
      reference: settlement.reference,
      total_cents: settlement.total_cents,
      payment_count: settlement.payment_count,
      entry_ids: settlement.entry_ids || [],
      prepared_by: settlement.prepared_by,
      prepared_at: settlement.prepared_at,
      posted_by: settlement.posted_by,
      posted_at: settlement.posted_at
    }
  end

  defp register_line(line) do
    account = line.account

    %{
      id: line.id,
      account_id: line.account_id,
      code: account && account.code,
      name: account && account.name,
      kind: account && account.kind,
      debit_cents: line.debit_cents,
      credit_cents: line.credit_cents,
      memo: line.memo
    }
  end

  defp bank_match(match) do
    line = match.statement_line

    %{
      id: match.id,
      statement_line_id: match.statement_line_id,
      entry_id: match.entry_id,
      amount_cents: line && line.amount_cents,
      posted_at: line && line.posted_at,
      description: line && line.description,
      reference: line && line.reference,
      bank_account_id: line && line.bank_account_id
    }
  end
end
