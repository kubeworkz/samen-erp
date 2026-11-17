defmodule Samen.Scopes.Finance.PayrollSettlementPrepare do
  @moduledoc """
  Prepares one payroll settlement batch from a posted register entry.

  The register entry credits the payroll payable and tax liability accounts;
  this change reads those persisted liability credits and creates ONE ordinary
  draft journal entry per liability account:

      Dr  payroll payable / tax liability   (the register credit)
          Cr  cash / bank account           (the amount disbursed or remitted)

  The entries are created through the journal entry's own `:create` action, so
  they are drafts and can only reach the ledger through the journal's governed
  `:post` action (PostBalance, PeriodGuard, DimensionBalance and any approval
  policy still apply). This module never writes a posted entry and never
  bypasses the journal's posting guards.

  The settlement row is minted before the entries so every generated entry
  carries `source_key: "payroll_settlement"` and the settlement id as
  `source_id`. The unique `{org_id, payroll_import_id}` identity makes a second
  batch for the same register impossible; a failed insert rolls the draft
  entries back with it.
  """

  use Ash.Resource.Change
  require Ash.Query

  @source_key "payroll_settlement"

  @impl true
  def change(changeset, opts, context) do
    import_mod = Keyword.fetch!(opts, :import)
    entry_mod = Keyword.fetch!(opts, :entry)
    account_mod = Keyword.fetch!(opts, :account)

    actor_struct =
      actor_struct(context) || actor_struct(get_in(changeset.context, [:private, :actor]))

    actor_id = actor_id(actor_struct)
    org_id = Ash.Changeset.get_attribute(changeset, :org_id)

    Ash.Changeset.before_action(changeset, fn changeset ->
      prepare(changeset, org_id, actor_struct, actor_id, import_mod, entry_mod, account_mod)
    end)
  end

  defp prepare(changeset, org_id, actor, actor_id, import_mod, entry_mod, account_mod) do
    import_id = Ash.Changeset.get_attribute(changeset, :payroll_import_id)
    cash_id = Ash.Changeset.get_attribute(changeset, :cash_account_id)
    settlement_date = Ash.Changeset.get_attribute(changeset, :settlement_date)
    reference = Ash.Changeset.get_attribute(changeset, :reference)

    with :ok <- require_actor(actor_id),
         {:ok, import} <- load_import(import_mod, org_id, import_id),
         :ok <- ensure_import(import),
         :ok <- ensure_entry(import.entry),
         :ok <- ensure_date(settlement_date, import.entry.entry_date),
         {:ok, cash} <- load_cash(account_mod, org_id, cash_id),
         {:ok, liabilities} <- liabilities(import.entry),
         settlement_id <- Ash.UUID.generate(),
         {:ok, entries} <-
           create_entries(
             entry_mod,
             actor,
             org_id,
             settlement_id,
             settlement_date,
             reference,
             import,
             cash,
             liabilities
           ) do
      total_cents = Enum.reduce(liabilities, 0, &(&1.cents + &2))

      changeset
      |> Ash.Changeset.force_change_attribute(:id, settlement_id)
      |> Ash.Changeset.force_change_attribute(:status, :draft)
      |> Ash.Changeset.force_change_attribute(:total_cents, total_cents)
      |> Ash.Changeset.force_change_attribute(:entry_ids, Enum.map(entries, & &1.id))
      |> Ash.Changeset.force_change_attribute(:payment_count, length(entries))
      |> Ash.Changeset.force_change_attribute(:prepared_by, actor_id)
      |> Ash.Changeset.force_change_attribute(:prepared_at, now())
    else
      {:error, message} when is_binary(message) ->
        Ash.Changeset.add_error(changeset, message: message)

      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          message: "payroll settlement could not be prepared: #{inspect(reason)}"
        )
    end
  end

  defp load_import(import_mod, org_id, import_id) do
    import_mod
    |> Ash.Query.filter(id == ^import_id and org_id == ^org_id)
    |> Ash.Query.load(entry: [lines: :account])
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %{} = import} ->
        {:ok, import}

      {:ok, nil} ->
        {:error, "the payroll import was not found"}

      {:error, reason} ->
        {:error, "the payroll import could not be read: #{inspect(reason)}"}
    end
  end

  defp ensure_import(%{status: :imported}), do: :ok

  defp ensure_import(%{status: status}) do
    {:error, "only an imported payroll register can be settled (status: #{status})"}
  end

  defp ensure_import(_), do: {:error, "the payroll import was not found"}

  defp ensure_entry(%{status: :posted}), do: :ok

  defp ensure_entry(%{status: status}) do
    {:error,
     "the payroll register's journal entry must be posted before settlement (status: #{status})"}
  end

  defp ensure_entry(_), do: {:error, "the payroll import has no linked journal entry"}

  defp ensure_date(%Date{} = settlement_date, %Date{} = entry_date) do
    if Date.compare(settlement_date, entry_date) == :lt do
      {:error, "the settlement date cannot precede the payroll register date"}
    else
      :ok
    end
  end

  defp ensure_date(_, _), do: {:error, "a settlement date is required"}

  defp load_cash(account_mod, org_id, account_id) do
    account_mod
    |> Ash.Query.filter(id == ^account_id and org_id == ^org_id)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %{kind: :asset, normal_side: :debit} = account} ->
        {:ok, account}

      {:ok, %{}} ->
        {:error, "the cash account must be an asset account with a debit normal side"}

      {:ok, nil} ->
        {:error, "the cash account was not found"}

      {:error, reason} ->
        {:error, "the cash account could not be read: #{inspect(reason)}"}
    end
  end

  defp liabilities(entry) do
    rows =
      entry.lines
      |> Enum.filter(&(&1.account && &1.account.kind == :liability))
      |> Enum.reduce(%{}, fn line, acc ->
        cents = line.credit_cents - line.debit_cents

        Map.update(
          acc,
          line.account_id,
          %{account: line.account, cents: cents},
          fn row -> %{row | cents: row.cents + cents} end
        )
      end)
      |> Map.values()
      |> Enum.filter(&(&1.cents > 0))
      |> Enum.sort_by(& &1.account.code)

    case rows do
      [] -> {:error, "the payroll register has no positive payable or tax liability to settle"}
      rows -> {:ok, rows}
    end
  end

  defp create_entries(
         entry_mod,
         actor,
         org_id,
         settlement_id,
         settlement_date,
         reference,
         import,
         cash,
         liabilities
       ) do
    liabilities
    |> Enum.reduce_while({:ok, []}, fn liability, {:ok, entries} ->
      attrs = %{
        org_id: org_id,
        entry_date: settlement_date,
        memo: memo(import, cash, liability, reference),
        source_key: @source_key,
        source_id: settlement_id,
        lines: [
          %{account_id: liability.account.id, debit_cents: liability.cents},
          %{account_id: cash.id, credit_cents: liability.cents}
        ]
      }

      case entry_mod
           |> Ash.Changeset.for_create(:create, attrs, actor: actor)
           |> Ash.create() do
        {:ok, entry} ->
          {:cont, {:ok, [entry | entries]}}

        {:error, reason} ->
          {:halt,
           {:error,
            "the settlement entry for account #{liability.account.code} could not be drafted: #{inspect(reason)}"}}
      end
    end)
    |> case do
      {:ok, entries} -> {:ok, Enum.reverse(entries)}
      {:error, _} = error -> error
    end
  end

  defp memo(import, cash, liability, reference) do
    [
      "Payroll settlement",
      import.provider,
      import.external_id,
      liability.account.code,
      cash.code,
      reference
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" · ")
    |> String.slice(0, 500)
  end

  defp require_actor(actor) when is_binary(actor), do: :ok
  defp require_actor(_), do: {:error, "an authenticated preparer is required"}

  defp actor_struct(%Samen.Scope{actor: actor}), do: actor
  defp actor_struct(%{actor: actor}), do: actor
  defp actor_struct(actor), do: actor

  defp actor_id(%{id: id}) when is_binary(id), do: id
  defp actor_id(id) when is_binary(id), do: id
  defp actor_id(_), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
