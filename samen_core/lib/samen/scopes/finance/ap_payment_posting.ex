defmodule Samen.Scopes.Finance.ApPaymentPosting do
  @moduledoc """
  The AP payment cascade (the AP lifecycle's missing second half).

  On `ApInvoice.:pay`, land a POSTED `JournalEntry` that debits the org's
  `ap_clearing` account for the bill total and credits its `cash` account,
  anchored `source_key: "ap_payment"`, `source_id: <bill id>`; then flip the
  bill from `:approved` to `:paid` in the SAME transaction.

  The bill's approval entry stays linked through `posted_entry_id` — paying a
  bill must not erase the expense+liability fact that approval created. The
  payment entry is the second, separately anchored fact; reads find it by the
  `ap_payment` anchor.

  ## Exactly-once

  The action is a bounded `approved -> paid` transition. It locks the persisted
  bill row with `SELECT ... FOR UPDATE` inside the action transaction, then
  re-checks the stored status. Two concurrent payment attempts serialize; the
  loser sees `:paid` and is refused. The `:pay` action's `ApLines` guard is the
  cheap pre-check, and this row lock is the authoritative one. A duplicate
  payment cannot be created through the sanctioned action even when the caller
  holds a stale `:approved` record.

  ## Accounts

  `ap_clearing` and `cash` resolve from the org's `PostingAccount` rows. An
  unmapped key refuses the payment fail-honest: accounts are a host decision,
  never invented by the scope.
  """

  use Ash.Resource.Change

  @source_key "ap_payment"

  @impl true
  def change(changeset, opts, _context) do
    entry_resource = Keyword.fetch!(opts, :entry)
    pa_resource = Keyword.fetch!(opts, :posting_account)

    org_id =
      case Ash.Changeset.get_attribute(changeset, :org_id) do
        %Ash.NotLoaded{} -> Ash.load!(changeset.data, [:org_id], authorize?: false).org_id
        value -> value
      end

    Ash.Changeset.before_action(changeset, fn changeset ->
      do_post(changeset, org_id, entry_resource, pa_resource)
    end)
  end

  defp do_post(changeset, org_id, entry_resource, pa_resource) do
    bill = changeset.data

    with :ok <- lock_approved(changeset),
         {:ok, payment_date} <- payment_date(changeset),
         {:ok, total} <- total_of(bill),
         {:ok, ap_clearing} <- posting_account(pa_resource, org_id, :ap_clearing),
         {:ok, cash} <- posting_account(pa_resource, org_id, :cash) do
      entry_attrs = %{
        org_id: org_id,
        entry_date: payment_date,
        memo: memo(bill, changeset),
        source_key: @source_key,
        source_id: bill.id,
        lines: [
          %{account_id: ap_clearing.account_id, debit_cents: total, credit_cents: 0},
          %{account_id: cash.account_id, debit_cents: 0, credit_cents: total}
        ]
      }

      case entry_resource
           # The posted-born internal factory: UnbalancedEntry + EntryLines +
           # PostGuard run resource-wide, so the payment lands POSTED and R10
           # applies exactly as it does to every other document posting.
           |> Ash.Changeset.for_create(:create_reversal, entry_attrs, authorize?: false)
           |> Ash.create(authorize?: false) do
        {:ok, _entry} ->
          # The approval anchor (`posted_entry_id`/`posted_at`) is deliberately
          # left intact; the payment is a separate, append-only fact.
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

  # The authoritative exactly-once check: lock the persisted row and read the
  # status the database actually holds. A caller's stale `:approved` struct is
  # not evidence that the bill is still payable.
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
        total =
          Enum.reduce(lines, 0, fn line, sum ->
            sum + (Map.get(line, :amount_cents) || Map.get(line, "amount_cents") || 0)
          end)

        if total > 0, do: {:ok, total}, else: {:error, :zero_total}

      _ ->
        {:error, :no_lines}
    end
  end

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

  defp memo(bill, changeset) do
    reference = Ash.Changeset.get_argument(changeset, :reference)
    note = Ash.Changeset.get_argument(changeset, :memo)

    "AP payment #{bill.number}" <>
      if(is_binary(reference) and reference != "", do: " — ref #{reference}", else: "") <>
      if(is_binary(note) and note != "", do: " — #{note}", else: "")
  end

  defp format({:not_approved, status}),
    do: "the bill is #{inspect(status)} — only an :approved bill can be paid"

  defp format({:not_found}), do: "the bill no longer exists"
  defp format({:missing_payment_date}), do: "payment_date is required"
  defp format({:invalid_payment_date, value}), do: "invalid payment_date: #{inspect(value)}"
  defp format(:no_lines), do: "the bill carries no lines"
  defp format(:zero_total), do: "the bill total is zero"

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
