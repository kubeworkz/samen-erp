defmodule Samen.Scopes.Finance.PayrollCloseCheck do
  @moduledoc """
  The read-only close precondition for imported payroll (WS-ERP E7; ADR-054 D7).

  The close checklist names payroll, but a close run is not allowed to omit an
  imported register silently. This read answers one question for a fiscal month:
  is every `PayrollImport` row either

    * backed by a `:posted` journal entry,
    * backed by a `:void` journal entry (the explicit void, with its linked
      reversal already booked), or
    * explicitly held with a named exception?

  Anything else blocks the close: an unposted `:draft`, an unresolved
  `:conflict` provenance row, a missing linked entry, an unreadable check, or a
  result too large to inspect within the bound. A superseded row follows its
  linked entry: the voided original is accepted, while the replacement draft
  blocks until it is posted. The check itself writes nothing; a hold is
  recorded through `PayrollImport.:hold`, and posting or voiding stays on the
  journal's ordinary governed actions.

  ## Fail closed at the read boundary

  The query is org-pinned and bounded to 500 rows plus one sentinel. A read
  error or a truncated result is `:unavailable`/`:blocked`, never `:clear`:
  the close must not be certified after looking at only part of the payroll
  inbox.

  ## Period selection

  `entry_date` is the imported register's date, so the fiscal month it lands in
  is the month this check inspects. The check does not infer a date from the
  linked entry or from the caller's period label.
  """

  require Ash.Query

  @limit 500

  @type disposition ::
          :posted | :voided | :held | :draft | :conflict | :missing | :unknown

  @type entry :: %{
          id: term(),
          provider: String.t(),
          external_id: String.t(),
          entry_id: term(),
          entry_status: :draft | :posted | :void | nil,
          import_status: :imported | :conflict | :superseded | nil,
          disposition: disposition(),
          accepted?: boolean(),
          held?: boolean(),
          held_at: DateTime.t() | nil,
          held_by: String.t() | nil,
          exception: String.t() | nil
        }

  @type report :: %{
          status: :clear | :blocked | :unavailable,
          blocking?: boolean(),
          clear?: boolean(),
          truncated?: boolean(),
          limit: pos_integer(),
          period: map() | nil,
          entries: [entry()],
          unresolved: [entry()],
          held: [entry()],
          counts: map(),
          labour_tie_out: map() | nil,
          reason: term() | nil
        }

  @doc """
  Report the payroll close gate for `org_id` and one `FiscalPeriod` row.

  Options:

    * `:import_module` — the host's mounted `PayrollImport` module (required
      for a readable check; absent is `:unavailable` and therefore blocking).
    * `:labour_allocation_module` — the host's mounted `LabourAllocation`
      module. When supplied, the payroll register's salary-expense debit is
      reconciled to the allocation header for the same period; a drift blocks
      the close. Omit it only for a host that has not mounted the allocation
      resource.
    * `:scope` — the tenant actor scope for the org-pinned read. When omitted,
      `:authorize?` defaults to `false` (the kernel guard path).
    * `:authorize?` — use Ash authorization when no `:scope` is supplied.
  """
  @spec report(String.t(), struct() | nil, keyword()) :: report()
  def report(org_id, period, opts \\ [])

  def report(org_id, %{year: year, month: month} = period, opts)
      when is_binary(org_id) and is_integer(year) and is_integer(month) do
    case Keyword.get(opts, :import_module) do
      nil ->
        unavailable(:payroll_not_wired, period)

      import_module when is_atom(import_module) ->
        read_report(import_module, org_id, period, opts)

      _ ->
        unavailable(:invalid_payroll_import_module, period)
    end
  end

  def report(_org_id, _period, _opts), do: unavailable(:no_period, nil)

  defp read_report(import_module, org_id, period, opts) do
    from = Date.new!(period.year, period.month, 1)
    to = Date.end_of_month(from)

    query =
      import_module
      |> Ash.Query.filter(org_id == ^org_id and entry_date >= ^from and entry_date <= ^to)
      |> Ash.Query.sort(entry_date: :asc, provider: :asc, external_id: :asc)
      |> Ash.Query.limit(@limit + 1)
      |> Ash.Query.load(:entry)

    case read(query, opts) do
      {:ok, rows} ->
        truncated? = length(rows) > @limit
        entries = rows |> Enum.take(@limit) |> Enum.map(&entry_view/1)
        unresolved = Enum.reject(entries, & &1.accepted?)
        held = Enum.filter(entries, &(&1.disposition == :held))
        status = if truncated? or unresolved != [], do: :blocked, else: :clear

        report = %{
          status: status,
          blocking?: status != :clear,
          clear?: status == :clear,
          truncated?: truncated?,
          limit: @limit,
          period: %{year: period.year, month: period.month, from: from, to: to},
          entries: entries,
          unresolved: unresolved,
          held: held,
          counts: counts(entries),
          labour_tie_out: nil,
          reason: if(truncated?, do: :truncated, else: nil)
        }

        attach_labour_tie_out(report, import_module, org_id, period, opts)

      {:error, reason} ->
        unavailable(reason, period)
    end
  rescue
    error -> unavailable(error, period)
  end

  defp read(query, opts) do
    case Keyword.get(opts, :scope) do
      nil -> Ash.read(query, authorize?: Keyword.get(opts, :authorize?, false))
      scope -> Ash.read(query, scope: scope)
    end
  end

  defp attach_labour_tie_out(report, import_module, org_id, period, opts) do
    case Keyword.get(opts, :labour_allocation_module) do
      nil ->
        report

      allocation_module when is_atom(allocation_module) ->
        tie =
          Samen.Scopes.Finance.LabourAllocationTieOut.report(org_id, period,
            allocation_module: allocation_module,
            import_module: import_module,
            scope: Keyword.get(opts, :scope),
            authorize?: Keyword.get(opts, :authorize?, false)
          )

        merge_labour_tie_out(report, tie)

      _invalid ->
        report
    end
  end

  defp merge_labour_tie_out(report, %{status: :drift} = tie) do
    %{
      report
      | status: :blocked,
        blocking?: true,
        clear?: false,
        labour_tie_out: tie,
        reason: :labour_allocation_drift
    }
  end

  defp merge_labour_tie_out(report, %{status: :unavailable} = tie) do
    %{
      report
      | status: :unavailable,
        blocking?: true,
        clear?: false,
        labour_tie_out: tie,
        reason: tie.reason
    }
  end

  defp merge_labour_tie_out(report, tie), do: %{report | labour_tie_out: tie}

  defp entry_view(import) do
    entry_status = entry_status(Map.get(import, :entry))
    held? = held?(import)

    disposition =
      cond do
        held? -> :held
        Map.get(import, :status) == :conflict -> :conflict
        entry_status == :posted -> :posted
        entry_status == :void -> :voided
        entry_status == :draft -> :draft
        is_nil(entry_status) -> :missing
        true -> :unknown
      end

    %{
      id: Map.get(import, :id),
      provider: Map.get(import, :provider),
      external_id: Map.get(import, :external_id),
      entry_id: Map.get(import, :entry_id),
      entry_status: entry_status,
      import_status: Map.get(import, :status),
      disposition: disposition,
      accepted?: disposition in [:posted, :voided, :held],
      held?: held?,
      held_at: Map.get(import, :held_at),
      held_by: Map.get(import, :held_by),
      exception: Map.get(import, :exception)
    }
  end

  defp entry_status(%{status: status}) when status in [:draft, :posted, :void], do: status
  defp entry_status(_entry), do: nil

  defp held?(import) do
    exception = Map.get(import, :exception)
    held_at = Map.get(import, :held_at)
    held_by = Map.get(import, :held_by)

    is_binary(exception) and String.trim(exception) != "" and held_at != nil and
      is_binary(held_by)
  end

  defp counts(entries) do
    base = Map.new([:posted, :voided, :held, :draft, :conflict, :missing, :unknown], &{&1, 0})

    entries
    |> Enum.reduce(Map.put(base, :total, length(entries)), fn entry, acc ->
      Map.update!(acc, entry.disposition, &(&1 + 1))
    end)
  end

  defp unavailable(reason, period) do
    %{
      status: :unavailable,
      blocking?: true,
      clear?: false,
      truncated?: false,
      limit: @limit,
      period: period_view(period),
      entries: [],
      unresolved: [],
      held: [],
      counts: counts([]),
      labour_tie_out: nil,
      reason: reason
    }
  end

  defp period_view(%{year: year, month: month}) when is_integer(year) and is_integer(month) do
    from = Date.new!(year, month, 1)
    %{year: year, month: month, from: from, to: Date.end_of_month(from)}
  end

  defp period_view(_period), do: nil
end
