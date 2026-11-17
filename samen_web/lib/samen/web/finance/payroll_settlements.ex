defmodule Samen.Web.Finance.PayrollSettlements do
  @moduledoc """
  The payroll settlement surface's read model and governed commands.

  The close board already knows which imported registers belong to the current
  period. This module answers the next control question for each POSTED
  register, plus any VOIDED register that already has a settlement batch
  (which must remain visible so the void cannot be mistaken for an unposted
  settlement):

    * has a settlement batch been prepared?
    * is it still draft, or posted?
    * does its register -> liability -> cash chain tie out?
    * if the host mounts Banking, has each cash movement been matched to a
      statement line?

  Reads are bounded and org-scoped. The tie-out is the kernel's
  `Samen.Scopes.Finance.PayrollTieOut.report/3`; this module only renders its
  result. If the host has no `PayrollSettlement` resource, or Banking is not
  wired, the surface says so instead of treating the absence as reconciled.

  Writes call the resources' own actions with
  `Samen.Web.TenantRole.attributed_admin_scope/2`:

    * `:prepare` creates draft settlement entries; the kernel validates the
      posted register and the cash account;
    * `:post` posts every entry through the journal's own `:post` action,
      including the batch-total re-check.

  This module never writes with `authorize?: false`.
  """

  require Ash.Query

  alias Samen.Scopes.Finance.PayrollTieOut
  alias Samen.Web.{Mount, TenantRole}

  @account_limit 500
  @row_limit 20

  @type row :: %{
          import: map(),
          settlement: struct() | nil,
          cash_account: map() | nil,
          tie_out: map() | nil,
          status: atom(),
          error: term() | nil
        }

  @type state :: %{
          wired?: boolean(),
          rows: [row()],
          accounts: [map()],
          accounts_error?: boolean(),
          accounts_truncated?: boolean(),
          truncated?: boolean(),
          limit: pos_integer(),
          error: term() | nil
        }

  @doc """
  Load the settlement rows for the posted imports in a `PayrollCloseCheck`
  report, plus any voided register that already has a settlement.

  `payroll` is the report map already computed by the close dashboard. A
  voided register with no settlement is not offered here; the payroll card
  above already shows its void disposition.
  """
  @spec load(Mount.t() | nil, String.t() | nil, map(), keyword()) :: state()
  def load(mount, org_id, payroll, opts \\ [])

  def load(%Mount{} = mount, org_id, payroll, opts) when is_binary(org_id) do
    scope = Keyword.get(opts, :scope) || Mount.scope(mount, org_id)

    with {:ok, settlement_mod} <- resource(mount, :PayrollSettlement),
         {:ok, entry_mod} <- resource(mount, :JournalEntry),
         {:ok, import_mod} <- resource(mount, :PayrollImport),
         {:ok, account_mod} <- resource(mount, :Account) do
      {visible_posted, more_posted?} = Enum.split(posted_imports(payroll), @row_limit)
      remaining = max(@row_limit - length(visible_posted), 0)
      {visible_voided, more_voided?} = Enum.split(voided_imports(payroll), remaining)
      visible = visible_posted ++ visible_voided
      more_registers? = more_posted? != [] or more_voided? != []
      import_ids = Enum.map(visible, & &1.id)

      {accounts, accounts_error?} =
        if visible == [], do: {[], false}, else: read_accounts(account_mod, scope)

      imports_by_id = read_imports(import_mod, scope, import_ids)

      tie_out_opts = [
        import_module: import_mod,
        settlement_module: settlement_mod,
        entry_module: entry_mod,
        match_module: match_module(mount)
      ]

      base = %{
        wired?: true,
        accounts: accounts,
        accounts_error?: accounts_error?,
        accounts_truncated?: length(accounts) == @account_limit,
        truncated?: more_registers?,
        limit: @row_limit
      }

      payroll_error = if payroll_unavailable?(payroll), do: :payroll_unavailable

      case read_settlements(settlement_mod, scope, import_ids) do
        {:ok, settlements} ->
          base
          |> Map.put(
            :rows,
            build_rows(visible, settlements, accounts, imports_by_id, org_id, tie_out_opts)
          )
          |> Map.put(:error, payroll_error)

        {:error, reason} ->
          base
          |> Map.put(:rows, [])
          |> Map.put(:error, {:settlements_unreadable, reason})
      end
    else
      _ -> unwired_state(:finance_not_mounted)
    end
  end

  def load(_mount, _org_id, _payroll, _opts), do: unwired_state(:no_org)

  @doc "Prepare a settlement for one posted payroll import."
  @spec prepare(Mount.t(), String.t(), map()) :: {:ok, struct()} | {:error, term()}
  def prepare(%Mount{} = mount, org_id, params) when is_binary(org_id) and is_map(params) do
    scope = TenantRole.attributed_admin_scope(mount, org_id)

    with {:ok, settlement_mod} <- resource(mount, :PayrollSettlement),
         {:ok, import_id} <- required(params["import_id"], :payroll_import_required),
         {:ok, cash_account_id} <- required(params["cash_account_id"], :cash_account_required),
         {:ok, settlement_date} <- parse_date(params["settlement_date"]) do
      settlement_mod
      |> Ash.Changeset.for_create(
        :prepare,
        %{
          org_id: org_id,
          payroll_import_id: import_id,
          cash_account_id: cash_account_id,
          settlement_date: settlement_date,
          reference: blank_to_nil(params["reference"])
        },
        scope: scope
      )
      |> Ash.create()
    end
  end

  @doc "Post a drafted settlement through the host's own governed action."
  @spec post(Mount.t(), String.t(), String.t()) :: {:ok, struct()} | {:error, term()}
  def post(%Mount{} = mount, org_id, settlement_id)
      when is_binary(org_id) and is_binary(settlement_id) do
    scope = TenantRole.attributed_admin_scope(mount, org_id)

    with {:ok, settlement_mod} <- resource(mount, :PayrollSettlement),
         {:ok, settlement} <- fetch_settlement(settlement_mod, settlement_id, scope) do
      settlement
      |> Ash.Changeset.for_update(:post, %{}, scope: scope)
      |> Ash.update()
    end
  end

  defp posted_imports(%{entries: entries}) when is_list(entries) do
    Enum.filter(entries, fn entry ->
      entry.entry_status == :posted and entry.import_status == :imported
    end)
  end

  defp posted_imports(_payroll), do: []

  defp voided_imports(%{entries: entries}) when is_list(entries) do
    Enum.filter(entries, fn entry ->
      entry.entry_status == :void and entry.import_status == :imported
    end)
  end

  defp voided_imports(_payroll), do: []

  defp payroll_unavailable?(%{status: :unavailable}), do: true
  defp payroll_unavailable?(_payroll), do: false

  defp unwired_state(reason) do
    %{
      wired?: false,
      rows: [],
      accounts: [],
      accounts_error?: false,
      accounts_truncated?: false,
      truncated?: false,
      limit: @row_limit,
      error: reason
    }
  end

  defp read_imports(_import_mod, _scope, []), do: %{}

  defp read_imports(import_mod, scope, import_ids) do
    import_mod
    |> Ash.Query.filter(org_id == ^scope.actor.org_id and id in ^import_ids)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, imports} -> Map.new(imports, &{&1.id, Map.from_struct(&1)})
      {:error, _reason} -> %{}
    end
  rescue
    _ -> %{}
  end

  defp read_settlements(_settlement_mod, _scope, []), do: {:ok, %{}}

  defp read_settlements(settlement_mod, scope, import_ids) do
    settlement_mod
    |> Ash.Query.filter(org_id == ^scope.actor.org_id and payroll_import_id in ^import_ids)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, settlements} -> {:ok, Map.new(settlements, &{&1.payroll_import_id, &1})}
      {:error, reason} -> {:error, reason}
    end
  end

  defp build_rows(imports, settlements, accounts, imports_by_id, org_id, tie_out_opts) do
    accounts_by_id = Map.new(accounts, &{&1.id, &1})

    Enum.flat_map(imports, fn report_import ->
      full_import = Map.get(imports_by_id, report_import.id, %{})

      import =
        %{total_cents: nil, entry_date: nil}
        |> Map.merge(report_import)
        |> Map.merge(full_import)

      case Map.get(settlements, import.id) do
        nil ->
          # A voided register with no settlement has nothing to surface here;
          # the payroll card above already reports its void disposition.
          if import.entry_status == :void do
            []
          else
            [
              %{
                import: import,
                settlement: nil,
                cash_account: nil,
                tie_out: nil,
                status: :unsettled,
                error: nil
              }
            ]
          end

        settlement ->
          tie_out = PayrollTieOut.report(org_id, import.id, tie_out_opts)

          case tie_out do
            {:ok, report} ->
              [
                %{
                  import: import,
                  settlement: settlement,
                  cash_account: Map.get(accounts_by_id, settlement.cash_account_id),
                  tie_out: report,
                  status: report.status,
                  error: nil
                }
              ]

            {:error, reason} ->
              [
                %{
                  import: import,
                  settlement: settlement,
                  cash_account: Map.get(accounts_by_id, settlement.cash_account_id),
                  tie_out: nil,
                  status: :unavailable,
                  error: reason
                }
              ]
          end
      end
    end)
  end

  defp read_accounts(account_mod, scope) do
    account_mod
    |> Ash.Query.filter(
      org_id == ^scope.actor.org_id and kind == :asset and normal_side == :debit
    )
    |> Ash.Query.ensure_selected([:id, :code, :name])
    |> Ash.Query.sort(code: :asc)
    |> Ash.Query.limit(@account_limit)
    |> Ash.read(scope: scope)
    |> case do
      {:ok, accounts} -> {accounts, false}
      {:error, _reason} -> {[], true}
    end
  rescue
    _ -> {[], true}
  end

  defp match_module(%Mount{} = mount) do
    case Mount.label(mount, :banking_namespace, nil) do
      namespace when is_atom(namespace) and not is_nil(namespace) ->
        match = Module.concat(namespace, :Match)
        if Code.ensure_loaded?(match), do: match

      _ ->
        nil
    end
  end

  defp fetch_settlement(settlement_mod, settlement_id, scope) do
    case Ash.get(settlement_mod, settlement_id, scope: scope) do
      {:ok, settlement} -> {:ok, settlement}
      {:error, _reason} -> {:error, :settlement_not_found}
    end
  end

  defp parse_date(value) when is_binary(value) do
    case Date.from_iso8601(value) do
      {:ok, date} -> {:ok, date}
      _ -> {:error, :invalid_settlement_date}
    end
  end

  defp parse_date(_value), do: {:error, :invalid_settlement_date}

  defp required(value, _error) when is_binary(value) and value != "", do: {:ok, value}
  defp required(_value, error), do: {:error, error}

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      text -> text
    end
  end

  defp blank_to_nil(_value), do: nil

  defp resource(mount, name) do
    module = Mount.resource(mount, name)

    if Code.ensure_loaded?(module) do
      {:ok, module}
    else
      {:error, :finance_not_mounted}
    end
  end
end
