defmodule Samen.Scopes.Finance.CashFlow do
  @moduledoc """
  The indirect-method cash-flow statement (WS-ACCT Phase 13; ADR-054 D12).

  The read is a pure read over the posted ledger, never a stored balance. The
  cash accounts are the ones the host's posting map binds to the `:cash`
  meaning (`PostingAccount.key`), so the statement follows the host's chart
  rather than a hard-coded account code.

  ## Two views, one reconciliation

  The top-level movement totals are unchanged:

    * `opening_cents` — the cash accounts' balance before the period;
    * `inflows_cents` / `outflows_cents` — debits / credits inside the period;
    * `net_cents` — inflows minus outflows;
    * `closing_cents` — the cash accounts' balance through the period end.

  The classified statement adds:

    * `operating` — net income, non-cash/reclassification adjustments, changes
      in operating assets and liabilities, and the derived operating cash;
    * `investing` / `financing` — cash movements whose entries carry an
      investing or financing counterpart, grouped by the primary counterpart;
    * `sections_reconciled?` — whether the indirect operating derivation equals
      the directly classified operating cash and the three sections sum to the
      ledger's net movement.

  ## Classification

  `Samen.Scopes.Finance.BalanceSheet` accounts are classified by default as:

    * equity → financing;
    * asset-cost, accumulated-contra and disposal accounts named by the host's
      posting map → investing;
    * every other asset, liability, income and expense account → operating.

  A host can override any account by id, code, or posting-map key with
  `classifications: %{account_id_or_code_or_key => :operating | :investing |
  :financing}`. An entry carrying more than one class is classified by its
  capital/financing counterpart (investing before financing); the split is not
  invented.

  ## Indirect operating section

  Net income is the period's income less expense. For an operating entry, a
  credit-normal asset movement (accumulated depreciation/amortization) is a
  non-cash addback and every other balance-sheet movement is a working-capital
  change with the sign that turns the accrual into cash. For an investing,
  financing or explicitly non-cash entry, its P&L lines are reclassified out of
  operating (a disposal gain/loss, for example), and its balance-sheet legs do
  not enter working capital. That is what keeps a disposal's gain out of
  operating while its proceeds land in investing.

  ## Honest absence

  `mapped?: false` is the honest empty state for a host that never bound
  `:cash`: every amount is zero and no statement is invented. A host with a
  cash mapping gets `reconciled?: true` only when closing equals opening plus
  the period's net movement, and `sections_reconciled?` only when the indirect
  operating derivation agrees with the classified cash entries.

  Physical table/column names come from `ReportColumns`, exactly like the
  trial balance, balance sheet and P&L reads, so a host's abbrev-prefixed
  columns are not guessed.
  """

  require Ash.Query

  alias Samen.Scopes.Finance.ReportColumns

  @classes [:operating, :investing, :financing]

  @investing_keys [
    :asset_cost_intangible,
    :asset_cost_equipment,
    :construction_in_progress,
    :accumulated_amortization,
    :accumulated_depreciation,
    :disposal_gain_loss
  ]

  @non_cash_keys [:unrealized_fx_gain_loss, :disposal_gain_loss]
  @contra_keys [:accumulated_amortization, :accumulated_depreciation]

  @type statement :: %{
          opening_cents: integer(),
          inflows_cents: integer(),
          outflows_cents: integer(),
          net_cents: integer(),
          closing_cents: integer(),
          cash_account_ids: [String.t()],
          mapped?: boolean(),
          reconciled?: boolean(),
          method: :indirect,
          operating: map(),
          investing: map(),
          financing: map(),
          sections_reconciled?: boolean()
        }

  @doc """
  Build the cash-flow statement for `org_id` over `[from_date, to_date]`.

  Required opts: `:repo`, `:posting_account`, `:line`, `:entry`.
  Optional: `:classifications` — account id/code/posting-key overrides for the
  operating/investing/financing classification.
  """
  @spec statement(String.t(), DateTime.t(), DateTime.t(), keyword()) ::
          {:ok, statement()} | {:error, term()}
  def statement(org_id, from_date, to_date, opts) do
    repo = Keyword.fetch!(opts, :repo)
    posting_account = Keyword.fetch!(opts, :posting_account)
    line = Keyword.fetch!(opts, :line)
    entry = Keyword.fetch!(opts, :entry)

    cash_account_ids = cash_account_ids(posting_account, org_id)

    if cash_account_ids == [] do
      {:ok, empty_statement()}
    else
      with {:ok, overrides} <- normalize_overrides(Keyword.get(opts, :classifications, %{})),
           {:ok, %{rows: [[opening, inflows, outflows, closing]]}} <-
             repo.query(statement_sql(line, entry), [
               dump_uuid(org_id),
               from_date,
               to_date,
               Enum.map(cash_account_ids, &dump_uuid/1)
             ]),
           {:ok, %{rows: line_rows}} <-
             repo.query(lines_sql(line, entry), [
               dump_uuid(org_id),
               from_date,
               to_date,
               Enum.map(cash_account_ids, &dump_uuid/1)
             ]) do
        posting_keys = posting_keys(posting_account, org_id)
        entries = entries(line_rows, posting_keys, overrides)
        sections = sections(entries)
        net = inflows - outflows

        {:ok,
         %{
           opening_cents: opening,
           inflows_cents: inflows,
           outflows_cents: outflows,
           net_cents: net,
           closing_cents: closing,
           cash_account_ids: cash_account_ids,
           mapped?: true,
           reconciled?: closing == opening + net,
           method: :indirect,
           operating: sections.operating,
           investing: sections.investing,
           financing: sections.financing,
           sections_reconciled?:
             sections.operating.cash_cents == sections.operating.net_cents and
               sections.operating.cash_cents + sections.investing.net_cents +
                 sections.financing.net_cents == net
         }}
      else
        {:error, reason} -> {:error, reason}
        _other -> {:error, :unexpected_cash_flow_shape}
      end
    end
  end

  defp cash_account_ids(posting_account, org_id) do
    posting_account
    |> Ash.Query.filter(org_id == ^org_id and key == :cash)
    |> Ash.read!(authorize?: false)
    |> Enum.map(& &1.account_id)
    |> Enum.uniq()
  end

  defp posting_keys(posting_account, org_id) do
    posting_account
    |> Ash.Query.filter(org_id == ^org_id)
    |> Ash.read!(authorize?: false)
    |> Map.new(&{&1.account_id, &1.key})
  end

  defp entries(line_rows, posting_keys, overrides) do
    line_rows
    |> Enum.group_by(&List.first/1)
    |> Enum.map(fn {entry_id, rows} ->
      lines =
        Enum.map(rows, fn [
                            _entry_id,
                            account_id,
                            code,
                            name,
                            kind,
                            normal_side,
                            debit,
                            credit,
                            is_cash
                          ] ->
          movement = debit - credit
          account_id = load_uuid(account_id)
          key = Map.get(posting_keys, account_id)

          account = %{
            id: account_id,
            code: code,
            name: name,
            kind: kind(kind),
            normal_side: normal_side(normal_side),
            movement_cents: movement
          }

          line = %{
            account_id: account_id,
            code: code,
            name: name,
            kind: account.kind,
            normal_side: account.normal_side,
            movement_cents: movement,
            is_cash: is_cash,
            key: key,
            class: account_class(account, key, overrides)
          }

          line
        end)

      cash_movement =
        lines
        |> Enum.filter(& &1.is_cash)
        |> Enum.reduce(0, &(&1.movement_cents + &2))

      category = category(lines, cash_movement)

      %{
        id: entry_id,
        lines: lines,
        cash_movement_cents: cash_movement,
        category: category
      }
    end)
    |> Enum.sort_by(& &1.id)
  end

  defp category(lines, cash_movement) do
    non_cash = Enum.reject(lines, & &1.is_cash)

    # A non-cash depreciation/amortization entry credits the accumulated contra
    # account; that is an operating addback, not an investing cash flow. The
    # same contra account is investing when a disposal's cash entry carries it.
    classes =
      Enum.map(non_cash, fn line ->
        if cash_movement == 0 and line.key in @contra_keys, do: :operating, else: line.class
      end)

    cond do
      cash_movement == 0 and Enum.any?(non_cash, &(&1.key in @non_cash_keys)) ->
        :operating_adjustment

      :investing in classes ->
        :investing

      :financing in classes ->
        :financing

      true ->
        :operating
    end
  end

  defp sections(entries) do
    net_income =
      entries
      |> Enum.flat_map(& &1.lines)
      |> Enum.filter(&(&1.kind in [:income, :expense]))
      |> Enum.reduce(0, fn line, acc -> acc - line.movement_cents end)

    adjustments =
      entries
      |> Enum.flat_map(fn entry ->
        pnl_reclass =
          if entry.category in [:investing, :financing, :operating_adjustment] do
            entry.lines
            |> Enum.filter(&(&1.kind in [:income, :expense]))
            |> Enum.map(&adjustment(&1, &1.movement_cents, :reclassification))
          else
            []
          end

        non_cash_addback =
          if entry.category == :operating do
            entry.lines
            |> Enum.filter(&(not &1.is_cash and &1.kind == :asset and &1.normal_side == :credit))
            |> Enum.map(&adjustment(&1, -&1.movement_cents, :non_cash))
          else
            []
          end

        pnl_reclass ++ non_cash_addback
      end)
      |> aggregate_adjustments()

    working_capital =
      entries
      |> Enum.filter(&(&1.category == :operating))
      |> Enum.flat_map(fn entry ->
        entry.lines
        |> Enum.filter(fn line ->
          not line.is_cash and line.kind in [:asset, :liability] and
            not (line.kind == :asset and line.normal_side == :credit)
        end)
        |> Enum.map(fn line ->
          %{
            account_id: line.account_id,
            code: line.code,
            name: line.name,
            amount_cents: -line.movement_cents
          }
        end)
      end)
      |> aggregate_working_capital()

    operating_cash =
      entries
      |> Enum.filter(&(&1.category == :operating))
      |> Enum.reduce(0, &(&1.cash_movement_cents + &2))

    operating_net =
      net_income + Enum.reduce(adjustments, 0, &(&1.amount_cents + &2)) +
        Enum.reduce(working_capital, 0, &(&1.amount_cents + &2))

    %{
      operating: %{
        net_income_cents: net_income,
        adjustments: adjustments,
        working_capital: working_capital,
        net_cents: operating_net,
        cash_cents: operating_cash,
        reconciled?: operating_net == operating_cash
      },
      investing: cash_section(entries, :investing),
      financing: cash_section(entries, :financing)
    }
  end

  defp adjustment(line, amount, category) do
    %{
      account_id: line.account_id,
      code: line.code,
      name: line.name,
      amount_cents: amount,
      category: category
    }
  end

  defp aggregate_adjustments(rows) do
    rows
    |> Enum.group_by(&{&1.account_id, &1.category})
    |> Enum.map(fn {{account_id, category}, grouped} ->
      first = hd(grouped)

      %{
        account_id: account_id,
        code: first.code,
        name: first.name,
        amount_cents: Enum.reduce(grouped, 0, &(&1.amount_cents + &2)),
        category: category
      }
    end)
    |> Enum.sort_by(&{&1.category, &1.code || "", &1.account_id})
  end

  defp aggregate_working_capital(rows) do
    rows
    |> Enum.group_by(& &1.account_id)
    |> Enum.map(fn {_account_id, [first | _] = grouped} ->
      %{
        account_id: first.account_id,
        code: first.code,
        name: first.name,
        amount_cents: Enum.reduce(grouped, 0, &(&1.amount_cents + &2))
      }
    end)
    |> Enum.sort_by(&{&1.code || "", &1.account_id})
  end

  defp cash_section(entries, category) do
    rows =
      entries
      |> Enum.filter(&(&1.category == category and &1.cash_movement_cents != 0))
      |> Enum.map(fn entry ->
        primary =
          entry.lines
          |> Enum.reject(& &1.is_cash)
          |> Enum.filter(&(&1.class == category))
          |> Enum.max_by(&abs(&1.movement_cents), fn -> nil end)

        %{
          code: primary && primary.code,
          name: (primary && primary.name) || "Cash movement",
          amount_cents: entry.cash_movement_cents
        }
      end)
      |> Enum.group_by(&{&1.code, &1.name})
      |> Enum.map(fn {{code, name}, grouped} ->
        %{
          code: code,
          name: name,
          amount_cents: Enum.reduce(grouped, 0, &(&1.amount_cents + &2))
        }
      end)
      |> Enum.sort_by(&{&1.code || "", &1.name})

    inflows = Enum.reduce(rows, 0, &(max(&1.amount_cents, 0) + &2))
    outflows = Enum.reduce(rows, 0, &(max(-&1.amount_cents, 0) + &2))

    %{
      inflows_cents: inflows,
      outflows_cents: outflows,
      net_cents: inflows - outflows,
      rows: rows
    }
  end

  defp account_class(account, key, overrides) do
    case override(account, key, overrides) do
      nil -> default_class(account, key)
      class -> class
    end
  end

  defp default_class(%{kind: :equity}, _key), do: :financing

  defp default_class(_account, key) when key in @investing_keys, do: :investing
  defp default_class(_account, _key), do: :operating

  defp override(account, key, overrides) do
    Map.get(overrides, account.id) ||
      Map.get(overrides, account.code) ||
      (key && Map.get(overrides, to_string(key)))
  end

  defp normalize_overrides(raw) when is_map(raw) do
    Enum.reduce_while(raw, {:ok, %{}}, fn {key, value}, {:ok, acc} ->
      case normalize_class(value) do
        nil ->
          {:halt, {:error, {:invalid_cash_flow_classification, key, value}}}

        class ->
          {:cont, {:ok, Map.put(acc, to_string(key), class)}}
      end
    end)
  end

  defp normalize_overrides(raw), do: {:error, {:invalid_cash_flow_classifications, raw}}

  defp normalize_class(value) when value in @classes, do: value
  defp normalize_class("operating"), do: :operating
  defp normalize_class("investing"), do: :investing
  defp normalize_class("financing"), do: :financing
  defp normalize_class(_value), do: nil

  defp statement_sql(line, entry) do
    line_table = ReportColumns.table(line)
    entry_table = ReportColumns.table(entry)

    line_org = ReportColumns.column(line, :org_id)
    line_account = ReportColumns.column(line, :account_id)
    line_entry = ReportColumns.column(line, :entry_id)
    debit = ReportColumns.column(line, :debit_cents)
    credit = ReportColumns.column(line, :credit_cents)

    entry_id = ReportColumns.column(entry, :id)
    entry_org = ReportColumns.column(entry, :org_id)
    entry_status = ReportColumns.column(entry, :status)
    posted_at = ReportColumns.column(entry, :posted_at)

    """
    SELECT
      COALESCE(SUM(CASE WHEN e.#{posted_at} < $2 THEN l.#{debit} - l.#{credit} ELSE 0 END), 0)::bigint,
      COALESCE(SUM(CASE WHEN e.#{posted_at} >= $2 AND e.#{posted_at} <= $3
                        THEN l.#{debit} ELSE 0 END), 0)::bigint,
      COALESCE(SUM(CASE WHEN e.#{posted_at} >= $2 AND e.#{posted_at} <= $3
                        THEN l.#{credit} ELSE 0 END), 0)::bigint,
      COALESCE(SUM(CASE WHEN e.#{posted_at} <= $3 THEN l.#{debit} - l.#{credit} ELSE 0 END), 0)::bigint
    FROM #{line_table} l
    JOIN #{entry_table} e ON e.#{entry_id} = l.#{line_entry}
    WHERE l.#{line_org} = $1
      AND e.#{entry_org} = $1
      AND e.#{entry_status} = 'posted'
      AND l.#{line_account} = ANY($4::uuid[])
    """
  end

  defp lines_sql(line, entry) do
    line_table = ReportColumns.table(line)
    entry_table = ReportColumns.table(entry)

    line_org = ReportColumns.column(line, :org_id)
    line_account = ReportColumns.column(line, :account_id)
    line_entry = ReportColumns.column(line, :entry_id)
    line_id = ReportColumns.column(line, :id)
    debit = ReportColumns.column(line, :debit_cents)
    credit = ReportColumns.column(line, :credit_cents)

    entry_id = ReportColumns.column(entry, :id)
    entry_org = ReportColumns.column(entry, :org_id)
    entry_status = ReportColumns.column(entry, :status)
    posted_at = ReportColumns.column(entry, :posted_at)

    # The account resource is the entry resource's sibling; resolve it from the
    # line's belongs_to relationship rather than hard-coding a host module.
    account = account_resource(line)

    account_table = ReportColumns.table(account)
    account_id = ReportColumns.column(account, :id)
    account_code = ReportColumns.column(account, :code)
    account_name = ReportColumns.column(account, :name)
    account_kind = ReportColumns.column(account, :kind)
    account_side = ReportColumns.column(account, :normal_side)
    account_org = ReportColumns.column(account, :org_id)

    """
    SELECT
      e.#{entry_id} AS entry_id,
      a.#{account_id} AS account_id,
      a.#{account_code} AS code,
      a.#{account_name} AS name,
      a.#{account_kind} AS kind,
      a.#{account_side} AS normal_side,
      l.#{debit} AS debit_cents,
      l.#{credit} AS credit_cents,
      (l.#{line_account} = ANY($4::uuid[])) AS is_cash
    FROM #{line_table} l
    JOIN #{entry_table} e
      ON e.#{entry_id} = l.#{line_entry}
      AND e.#{entry_org} = $1
      AND e.#{entry_status} = 'posted'
    JOIN #{account_table} a
      ON a.#{account_id} = l.#{line_account}
      AND a.#{account_org} = $1
    WHERE l.#{line_org} = $1
      AND e.#{posted_at} >= $2
      AND e.#{posted_at} <= $3
    ORDER BY e.#{posted_at}, e.#{entry_id}, l.#{line_id}
    """
  end

  defp account_resource(line) do
    line
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.type == :belongs_to and &1.name == :account))
    |> Map.fetch!(:destination)
  end

  defp kind("income"), do: :income
  defp kind("expense"), do: :expense
  defp kind("asset"), do: :asset
  defp kind("liability"), do: :liability
  defp kind("equity"), do: :equity
  defp kind(value) when is_atom(value), do: value
  defp kind(_value), do: :unknown

  defp normal_side("debit"), do: :debit
  defp normal_side("credit"), do: :credit
  defp normal_side(value) when is_atom(value), do: value
  defp normal_side(_value), do: :debit

  defp empty_statement do
    %{
      opening_cents: 0,
      inflows_cents: 0,
      outflows_cents: 0,
      net_cents: 0,
      closing_cents: 0,
      cash_account_ids: [],
      mapped?: false,
      reconciled?: true,
      method: :indirect,
      operating: %{
        net_income_cents: 0,
        adjustments: [],
        working_capital: [],
        net_cents: 0,
        cash_cents: 0,
        reconciled?: true
      },
      investing: %{inflows_cents: 0, outflows_cents: 0, net_cents: 0, rows: []},
      financing: %{inflows_cents: 0, outflows_cents: 0, net_cents: 0, rows: []},
      sections_reconciled?: true
    }
  end

  defp load_uuid(id) when is_binary(id) and byte_size(id) == 16, do: Ecto.UUID.load!(id)
  defp load_uuid(id), do: id

  defp dump_uuid(nil), do: nil
  defp dump_uuid(id) when is_binary(id) and byte_size(id) == 16, do: id
  defp dump_uuid(id), do: Ecto.UUID.dump!(id)
end
