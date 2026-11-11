defmodule Samen.Scopes.Finance.ApPaymentPosting do
  @moduledoc """
  The AP payment cascade (the AP lifecycle's missing second half).

  On `ApInvoice.:pay`, settle the liability at the functional amount stamped
  by approval, credit cash at the payment-date rate, and post the difference to
  the org's `fx_gain_loss` account. For a same-currency payment the difference
  is zero and no FX account is required.

  The payment entry is anchored `source_key: "ap_payment"` and the bill flips
  `:approved → :paid` in the same transaction. The original approval entry
  stays linked through `posted_entry_id`; this is a second, separately anchored
  fact. The row lock makes the transition exactly-once.
  """

  use Ash.Resource.Change

  alias Samen.Scopes.Finance.ApFx

  @source_key "ap_payment"

  @impl true
  def change(changeset, opts, _context) do
    entry_resource = Keyword.fetch!(opts, :entry)
    pa_resource = Keyword.fetch!(opts, :posting_account)
    org_fx_settings = Keyword.fetch!(opts, :org_fx_settings)
    exchange_rate = Keyword.fetch!(opts, :exchange_rate)
    repo = Keyword.fetch!(opts, :repo)

    org_id = loaded_org_id(changeset)

    Ash.Changeset.before_action(changeset, fn changeset ->
      do_post(
        changeset,
        org_id,
        entry_resource,
        pa_resource,
        org_fx_settings,
        exchange_rate,
        repo
      )
    end)
  end

  defp do_post(
         changeset,
         org_id,
         entry_resource,
         pa_resource,
         org_fx_settings,
         exchange_rate,
         repo
       ) do
    bill = changeset.data
    currency = bill.currency || ApFx.base_currency(org_fx_settings, org_id)
    base_currency = bill.base_currency || ApFx.base_currency(org_fx_settings, org_id)

    with :ok <- lock_approved(changeset),
         {:ok, payment_date} <- payment_date(changeset),
         {:ok, total} <- total_of(bill),
         {:ok, original_base} <- original_base(bill, total, currency, base_currency),
         {:ok, cash_base, rate} <-
           payment_base(total, currency, base_currency, payment_date, org_id, repo, exchange_rate),
         {:ok, ap_clearing} <- posting_account(pa_resource, org_id, :ap_clearing),
         {:ok, cash} <- posting_account(pa_resource, org_id, :cash),
         {:ok, fx_lines, fx_account} <-
           fx_lines(original_base, cash_base, pa_resource, org_id) do
      entry_attrs = %{
        org_id: org_id,
        entry_date: payment_date,
        memo: memo(bill, changeset, currency, rate),
        source_key: @source_key,
        source_id: bill.id,
        lines:
          [
            %{account_id: ap_clearing.account_id, debit_cents: original_base, credit_cents: 0},
            %{account_id: cash.account_id, debit_cents: 0, credit_cents: cash_base}
          ] ++ fx_lines
      }

      case entry_resource
           |> Ash.Changeset.for_create(:create_reversal, entry_attrs, authorize?: false)
           |> Ash.create(authorize?: false) do
        {:ok, _entry} ->
          _ = fx_account
          Ash.Changeset.force_change_attribute(changeset, :status, :paid)

        {:error, reason} ->
          Ash.Changeset.add_error(changeset,
            field: :base,
            message: "the AP payment entry failed to land: #{inspect(reason)}"
          )
      end
    else
      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :base,
          message: "the AP bill cannot be paid: #{format(reason)}"
        )
    end
  end

  defp original_base(bill, total, currency, base_currency) do
    case bill.base_total_cents do
      amount when is_integer(amount) and amount > 0 ->
        {:ok, amount}

      _ when currency == base_currency ->
        {:ok, total}

      _ ->
        {:error, :missing_base_amount}
    end
  end

  defp payment_base(total, currency, base_currency, payment_date, org_id, repo, exchange_rate) do
    if currency == base_currency do
      {:ok, total, "1.0"}
    else
      case ApFx.convert(total, currency, base_currency, payment_date, org_id, repo, exchange_rate) do
        {:ok, {amount, rate}} -> {:ok, amount, rate}
        {:error, reason} -> {:error, {reason, currency, base_currency}}
      end
    end
  end

  defp fx_lines(original_base, cash_base, pa_resource, org_id) do
    difference = original_base - cash_base

    case difference do
      0 ->
        {:ok, [], nil}

      amount when amount > 0 ->
        with {:ok, account} <- posting_account(pa_resource, org_id, :fx_gain_loss) do
          {:ok, [%{account_id: account.account_id, debit_cents: 0, credit_cents: amount}],
           account}
        end

      amount ->
        with {:ok, account} <- posting_account(pa_resource, org_id, :fx_gain_loss) do
          {:ok, [%{account_id: account.account_id, debit_cents: -amount, credit_cents: 0}],
           account}
        end
    end
  end

  defp loaded_org_id(changeset) do
    case Ash.Changeset.get_attribute(changeset, :org_id) do
      %Ash.NotLoaded{} -> Ash.load!(changeset.data, [:org_id], authorize?: false).org_id
      value -> value
    end
  end

  defp lock_approved(changeset) do
    resource = changeset.resource
    table = AshPostgres.DataLayer.Info.table(resource)
    repo = AshPostgres.DataLayer.Info.repo(resource, :mutate)
    id_col = attr_source(resource, :id)
    status_col = attr_source(resource, :status)

    case repo.query(
           "SELECT #{status_col} FROM #{table} WHERE #{id_col} = $1 FOR UPDATE",
           [dump_uuid(changeset.data.id)]
         ) do
      {:ok, %{rows: [[status]]}} ->
        case to_string(status) do
          "approved" -> :ok
          other -> {:error, {:not_approved, other}}
        end

      {:ok, %{rows: []}} ->
        {:error, :not_found}

      {:error, reason} ->
        {:error, {:lock_failed, reason}}
    end
  end

  defp payment_date(changeset) do
    case Ash.Changeset.get_argument(changeset, :payment_date) do
      %Date{} = date -> {:ok, date}
      nil -> {:error, :missing_payment_date}
      other -> {:error, {:invalid_payment_date, other}}
    end
  end

  defp total_of(bill) do
    case bill.lines do
      lines when is_list(lines) and lines != [] ->
        total = Enum.sum(Enum.map(lines, &line_amount/1))
        if total > 0, do: {:ok, total}, else: {:error, :zero_total}

      _ ->
        {:error, :no_lines}
    end
  end

  defp line_amount(line) when is_map(line),
    do: Map.get(line, :amount_cents) || Map.get(line, "amount_cents") || 0

  defp posting_account(pa_resource, org_id, key) do
    require Ash.Query

    case pa_resource
         |> Ash.Query.filter(org_id == ^org_id and key == ^key)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, {:unmapped_posting_account, key}}
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, reason}
    end
  end

  defp memo(bill, changeset, currency, rate) do
    reference = Ash.Changeset.get_argument(changeset, :reference)
    note = Ash.Changeset.get_argument(changeset, :memo)

    "AP payment #{bill.number}" <>
      if(is_binary(reference) and reference != "", do: " — ref #{reference}", else: "") <>
      if(is_binary(note) and note != "", do: " — #{note}", else: "") <>
      " (#{currency} @ #{rate})"
  end

  defp format({:not_approved, status}),
    do: "the bill is #{inspect(status)} — only an :approved bill can be paid"

  defp format({:not_found}), do: "the bill no longer exists"
  defp format({:missing_payment_date}), do: "payment_date is required"
  defp format({:invalid_payment_date, value}), do: "invalid payment_date: #{inspect(value)}"
  defp format(:no_lines), do: "the bill carries no lines"
  defp format(:zero_total), do: "the bill total is zero"

  defp format(:missing_base_amount),
    do: "the bill has no functional-currency liability; re-approve it"

  defp format({:rate_not_found, _from, _to}),
    do: "no exchange rate is stored for the payment date; store the rate before paying"

  defp format({:unmapped_posting_account, key}),
    do:
      "no PostingAccount row maps `#{key}` for this org (fail-honest — accounts are a " <>
        "host decision; seed the org's posting accounts first)"

  defp format({:lock_failed, reason}), do: "the bill could not be locked: #{inspect(reason)}"
  defp format(reason), do: inspect(reason)

  defp attr_source(resource, name) do
    case Ash.Resource.Info.attribute(resource, name) do
      nil -> raise ArgumentError, "#{inspect(resource)} has no #{inspect(name)} attribute"
      attr -> to_string(attr.source || attr.name)
    end
  end

  defp dump_uuid(value) when is_binary(value) and byte_size(value) == 16, do: value

  defp dump_uuid(value) do
    case Ecto.UUID.dump(value) do
      {:ok, bin} -> bin
      :error -> value
    end
  end
end
