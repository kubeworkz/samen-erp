defmodule Samen.Web.Finance.Reconciliation do
  @moduledoc """
  The reconciliation workbench's host seam (WS-ACCT follow-on).

  Resolves the host's mounted Finance resources and composes two core reads:

    * `Samen.Scopes.Finance.ReconciliationWorkbench` for the org balance and
      per-account posted balances, plus the selected account's posted lines;
    * `Samen.Scopes.Finance.FluxRead` for the month-over-month account flux.

  Nothing is written and no reconciliation state is stored. The only durable
  facts are the ledger's posted entries and lines; this module is a projection
  over them at request time.
  """

  alias Samen.Scopes.Finance.{FluxRead, ReconciliationWorkbench}
  alias Samen.Web.Mount

  @type state :: %{
          workbench: map(),
          flux: map(),
          selected_account: map() | nil,
          lines: [map()],
          period: %{year: integer(), month: integer(), from_date: Date.t(), to_date: Date.t()}
        }

  @doc """
  Load the workbench for `mount` + `org_id`.

  Options:

    * `:period` — `"YYYY-MM"` or `{year, month}`; defaults to the current
      calendar month.
    * `:account_id` — a selected account for the posted-line drill-down.

  Returns `{:ok, state}` or `{:error, :no_mount | :no_org |
  :finance_not_mounted | term()}`.
  """
  @spec load(Mount.t() | nil, String.t() | nil, keyword()) :: {:ok, state()} | {:error, term()}
  def load(mount, org_id, opts \\ [])

  def load(%Mount{} = mount, org_id, opts) when is_binary(org_id) do
    with {:ok, account_resource} <- resource(mount, :Account),
         {:ok, line_resource} <- resource(mount, :JournalLine),
         {:ok, entry_resource} <- resource(mount, :JournalEntry) do
      period = parse_period(Keyword.get(opts, :period))

      read_opts = [
        repo: mount.repo,
        account_resource: account_resource,
        line_resource: line_resource,
        entry_resource: entry_resource
      ]

      with {:ok, workbench} <- ReconciliationWorkbench.report(org_id, read_opts),
           {:ok, flux} <-
             FluxRead.report(org_id, period.year, period.month,
               repo: mount.repo,
               account_resource: account_resource,
               line_resource: line_resource,
               entry_resource: entry_resource
             ),
           {:ok, selected_account, lines} <-
             read_selected(org_id, workbench.accounts, Keyword.get(opts, :account_id),
               repo: mount.repo,
               line_resource: line_resource,
               entry_resource: entry_resource
             ) do
        {:ok,
         %{
           workbench: workbench,
           flux: flux,
           selected_account: selected_account,
           lines: lines,
           period: %{
             year: period.year,
             month: period.month,
             from_date: Date.new!(period.year, period.month, 1),
             to_date: Date.end_of_month(Date.new!(period.year, period.month, 1))
           }
         }}
      end
    end
  end

  def load(%Mount{}, _org_id, _opts), do: {:error, :no_org}
  def load(nil, _org_id, _opts), do: {:error, :no_mount}

  @doc """
  Parse a period selector. A missing or malformed value falls back to the
  current calendar month, so a stale link never blanks the workbench.
  """
  def parse_period(nil), do: current_period()

  def parse_period({year, month}) when is_integer(year) and is_integer(month) and month in 1..12,
    do: %{year: year, month: month}

  def parse_period(value) when is_binary(value) do
    case Regex.run(~r/\A(\d{4})-(\d{2})\z/, value) do
      [_, year, month] ->
        year = String.to_integer(year)
        month = String.to_integer(month)

        if month in 1..12, do: %{year: year, month: month}, else: current_period()

      _ ->
        current_period()
    end
  end

  def parse_period(_value), do: current_period()

  defp current_period do
    today = Date.utc_today()
    %{year: today.year, month: today.month}
  end

  defp read_selected(_org_id, _accounts, nil, _opts), do: {:ok, nil, []}

  defp read_selected(org_id, accounts, account_id, opts) when is_binary(account_id) do
    case Enum.find(accounts, &(&1.id == account_id)) do
      nil ->
        {:ok, nil, []}

      account ->
        case ReconciliationWorkbench.lines(org_id, account.id, opts) do
          {:ok, lines} -> {:ok, account, lines}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp read_selected(_org_id, _accounts, _account_id, _opts), do: {:ok, nil, []}

  defp resource(mount, name) do
    module = Mount.resource(mount, name)

    if Code.ensure_loaded?(module) do
      {:ok, module}
    else
      {:error, :finance_not_mounted}
    end
  end
end
