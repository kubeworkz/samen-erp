defmodule Samen.Scopes.Finance.LabourAllocationTieOut do
  @moduledoc """
  Read-only tie-out between a payroll register's salary-expense debit and the
  `LabourAllocation` header that declares the same period's payroll cost
  (WS-ACCT Unit 10.2; ADR-054 D17).

  The allocation model already names the fact this read reconciles:

    * `LabourAllocation.source_account_id` is the payroll expense account the
      posting credits;
    * `period_start` / `period_end` define the payroll period;
    * `total_cents` is the declared payroll total.

  For every live allocation whose period overlaps the fiscal month, the tie-out
  sums the debit lines on that source account from the period's **posted**
  payroll registers. Only `:imported` provenance rows whose linked entry is
  `:posted` count: a draft entry has no ledger debit, while a superseded or
  conflict row must not be counted a second time. The comparison is exact cents;
  no tolerance is applied.

  The report is a read. It never creates an allocation, posts an entry, or
  changes a register. A mismatch is surfaced as `:drift` so the caller can
  refuse the close or show the variance; an unreadable or truncated read is
  `:unavailable`, never silently clear.

  A live allocation with no matching posted register debit is a drift with a
  negative variance. This is deliberate: the header's declared total is not
  tied to a ledger fact, and a missing register is not the same as agreement.
  """

  require Ash.Query

  @limit 500

  @type status :: :clear | :drift | :unavailable

  @type row :: %{
          allocation_id: term(),
          allocation_status: atom(),
          period_start: Date.t(),
          period_end: Date.t(),
          source_account_id: term(),
          source_account_code: String.t() | nil,
          source_account_name: String.t() | nil,
          allocated_cents: integer(),
          register_debit_cents: integer(),
          variance_cents: integer(),
          reconciled?: boolean(),
          import_ids: [term()]
        }

  @type report :: %{
          status: status(),
          clear?: boolean(),
          blocking?: boolean(),
          drift?: boolean(),
          truncated?: boolean(),
          limit: pos_integer(),
          org_id: String.t() | nil,
          period: map() | nil,
          allocations: [row()],
          drift: [row()],
          counts: %{
            total: non_neg_integer(),
            reconciled: non_neg_integer(),
            drift: non_neg_integer()
          },
          exceptions: [term()],
          reason: term() | nil
        }

  @doc """
  Reconcile payroll register debits to labour allocation headers for a fiscal
  month (`%{year: 2026, month: 9}`).

  Options:

    * `:allocation_module` — the host's mounted `LabourAllocation` resource.
    * `:import_module` — the host's mounted `PayrollImport` resource.
    * `:scope` — the tenant actor scope for the org-pinned read. When omitted,
      `:authorize?` defaults to `false` (the kernel guard path).
    * `:authorize?` — use Ash authorization when no `:scope` is supplied.
  """
  @spec report(String.t(), map() | nil, keyword()) :: report()
  def report(org_id, period, opts \\ [])

  def report(org_id, %{year: year, month: month} = period, opts)
      when is_binary(org_id) and is_integer(year) and is_integer(month) do
    with {:ok, allocation_module} <- module_opt(opts, :allocation_module),
         {:ok, import_module} <- module_opt(opts, :import_module) do
      read_report(allocation_module, import_module, org_id, period, opts)
    else
      {:error, reason} -> unavailable(reason, period, org_id)
    end
  end

  def report(_org_id, _period, _opts), do: unavailable(:no_period, nil)

  defp module_opt(opts, key) do
    case Keyword.get(opts, key) do
      nil -> {:error, :"#{key}_not_wired"}
      module when is_atom(module) -> {:ok, module}
      _ -> {:error, :"invalid_#{key}"}
    end
  end

  defp read_report(allocation_module, import_module, org_id, period, opts) do
    from = Date.new!(period.year, period.month, 1)
    to = Date.end_of_month(from)

    with {:ok, allocations} <- read_allocations(allocation_module, org_id, from, to, opts),
         {:ok, imports} <- read_imports(import_module, org_id, from, to, opts) do
      if length(allocations) > @limit or length(imports) > @limit do
        unavailable(:truncated, period, org_id)
      else
        build(allocations, imports, org_id, period, from, to)
      end
    else
      {:error, reason} -> unavailable(reason, period, org_id)
    end
  rescue
    error -> unavailable(error, period, org_id)
  end

  # A header whose period overlaps the fiscal month is part of this report. A
  # discarded proposal is not live and cannot describe payroll cost.
  defp read_allocations(allocation_module, org_id, from, to, opts) do
    allocation_module
    |> Ash.Query.filter(
      org_id == ^org_id and status != :discarded and period_start <= ^to and period_end >= ^from
    )
    |> Ash.Query.sort(period_start: :asc, period_end: :asc, source_account_id: :asc)
    |> Ash.Query.limit(@limit + 1)
    |> Ash.Query.load(:source_account)
    |> read(opts)
  end

  defp read_imports(import_module, org_id, from, to, opts) do
    import_module
    |> Ash.Query.filter(
      org_id == ^org_id and status == :imported and entry_date >= ^from and entry_date <= ^to
    )
    |> Ash.Query.sort(entry_date: :asc, provider: :asc, external_id: :asc)
    |> Ash.Query.limit(@limit + 1)
    |> Ash.Query.load(entry: [:lines])
    |> read(opts)
  end

  defp read(query, opts) do
    case Keyword.get(opts, :scope) do
      nil -> Ash.read(query, authorize?: Keyword.get(opts, :authorize?, false))
      scope -> Ash.read(query, scope: scope)
    end
  end

  defp build(allocations, imports, org_id, period, from, to) do
    rows = Enum.map(allocations, &row(&1, imports))
    drift = Enum.reject(rows, & &1.reconciled?)
    status = if drift == [], do: :clear, else: :drift

    %{
      status: status,
      clear?: status == :clear,
      blocking?: status != :clear,
      drift?: status == :drift,
      truncated?: false,
      limit: @limit,
      org_id: org_id,
      period: %{year: period.year, month: period.month, from: from, to: to},
      allocations: rows,
      drift: drift,
      counts: %{
        total: length(rows),
        reconciled: Enum.count(rows, & &1.reconciled?),
        drift: length(drift)
      },
      exceptions:
        Enum.map(drift, &{:labour_allocation_drift, &1.allocation_id, &1.variance_cents}),
      reason: nil
    }
  end

  defp row(allocation, imports) do
    counted =
      Enum.filter(imports, fn import ->
        posted_import?(import) and in_period?(import.entry_date, allocation) and
          debit_lines(import, allocation.source_account_id) != []
      end)

    register_debit_cents =
      Enum.reduce(counted, 0, fn import, total ->
        total + debit_cents(import, allocation.source_account_id)
      end)

    variance = register_debit_cents - allocation.total_cents
    account = Map.get(allocation, :source_account)

    %{
      allocation_id: allocation.id,
      allocation_status: allocation.status,
      period_start: allocation.period_start,
      period_end: allocation.period_end,
      source_account_id: allocation.source_account_id,
      source_account_code: account && Map.get(account, :code),
      source_account_name: account && Map.get(account, :name),
      allocated_cents: allocation.total_cents,
      register_debit_cents: register_debit_cents,
      variance_cents: variance,
      reconciled?: variance == 0,
      import_ids: counted |> Enum.map(& &1.id) |> Enum.uniq()
    }
  end

  defp posted_import?(%{status: :imported, entry: %{status: :posted}}), do: true
  defp posted_import?(_import), do: false

  defp in_period?(%Date{} = date, allocation) do
    Date.compare(date, allocation.period_start) != :lt and
      Date.compare(date, allocation.period_end) != :gt
  end

  defp in_period?(_date, _allocation), do: false

  defp debit_lines(%{entry: %{lines: lines}}, source_account_id) when is_list(lines) do
    Enum.filter(lines, &(&1.account_id == source_account_id))
  end

  defp debit_lines(_import, _source_account_id), do: []

  defp debit_cents(import, source_account_id) do
    import
    |> debit_lines(source_account_id)
    |> Enum.reduce(0, &((&1.debit_cents || 0) + &2))
  end

  defp unavailable(reason, period, org_id \\ nil) do
    %{
      status: :unavailable,
      clear?: false,
      blocking?: true,
      drift?: false,
      truncated?: reason == :truncated,
      limit: @limit,
      org_id: org_id,
      period: period_view(period),
      allocations: [],
      drift: [],
      counts: %{total: 0, reconciled: 0, drift: 0},
      exceptions: [],
      reason: reason
    }
  end

  defp period_view(%{year: year, month: month}) when is_integer(year) and is_integer(month) do
    with {:ok, from} <- Date.new(year, month, 1) do
      %{year: year, month: month, from: from, to: Date.end_of_month(from)}
    else
      _ -> nil
    end
  end

  defp period_view(_period), do: nil
end
