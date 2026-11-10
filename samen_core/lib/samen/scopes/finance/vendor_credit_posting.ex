defmodule Samen.Scopes.Finance.VendorCreditPosting do
  @moduledoc """
  The AP adjustment posting cascade (WS-ERP E12).

  On `:open`, create the vendor credit's JournalEntry in the same transaction:
  **debit** the org's `ap_clearing` account, **credit** the org's
  `vendor_credit_clearing` account, both by `amount_cents`. The entry is
  anchored `source_key: "vendor_credit"` / `source_id: <credit id>` and born
  POSTED through the journal's `:create_reversal` factory.

  Both posting accounts resolve from the org's `PostingAccount` rows; an
  unmapped meaning refuses the posting fail-honest.
  """

  use Ash.Resource.Change

  @source_key "vendor_credit"

  @impl true
  def change(changeset, opts, _context) do
    entry_resource = Keyword.fetch!(opts, :entry)
    pa_resource = Keyword.fetch!(opts, :posting_account)

    Ash.Changeset.before_action(changeset, fn changeset ->
      post(changeset, entry_resource, pa_resource)
    end)
  end

  defp post(changeset, entry_resource, pa_resource) do
    credit = changeset.data
    org_id = org_id(changeset)

    with :ok <- require_draft(changeset),
         {:ok, amount} <- amount_of(credit),
         {:ok, ap} <- posting_account(pa_resource, org_id, :ap_clearing),
         {:ok, clearing} <- posting_account(pa_resource, org_id, :vendor_credit_clearing),
         {:ok, entry} <- create_entry(entry_resource, credit, org_id, amount, ap, clearing) do
      changeset
      |> Ash.Changeset.force_change_attribute(:status, :open)
      |> Ash.Changeset.force_change_attribute(:entry_id, entry.id)
      |> Ash.Changeset.force_change_attribute(:posted_at, now())
    else
      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          field: :base,
          message: "the vendor credit cannot be opened: #{format(reason)}"
        )
    end
  end

  defp create_entry(entry_resource, credit, org_id, amount, ap, clearing) do
    attrs = %{
      org_id: org_id,
      entry_date: credit.date,
      memo: "Vendor credit #{credit.number}" <> memo_suffix(credit.memo),
      source_key: @source_key,
      source_id: credit.id,
      lines: [
        %{account_id: ap.account_id, debit_cents: amount, credit_cents: 0},
        %{account_id: clearing.account_id, debit_cents: 0, credit_cents: amount}
      ]
    }

    entry_resource
    |> Ash.Changeset.for_create(:create_reversal, attrs, authorize?: false)
    |> Ash.create(authorize?: false)
  end

  defp require_draft(changeset) do
    if changeset.data.status == :draft,
      do: :ok,
      else: {:error, {:not_draft, changeset.data.status}}
  end

  defp amount_of(credit) do
    if is_integer(credit.amount_cents) and credit.amount_cents > 0 do
      {:ok, credit.amount_cents}
    else
      {:error, {:non_positive_amount, credit.amount_cents}}
    end
  end

  defp org_id(changeset) do
    case Ash.Changeset.get_attribute(changeset, :org_id) do
      %Ash.NotLoaded{} -> Ash.load!(changeset.data, [:org_id], authorize?: false).org_id
      value -> value
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

  defp format({:not_draft, status}),
    do: "the credit is #{inspect(status)} — only a draft vendor credit can be opened"

  defp format({:non_positive_amount, amount}),
    do: "amount_cents must be a positive integer — got: #{inspect(amount)}"

  defp format({:unmapped_posting_account, key}),
    do:
      "no PostingAccount row maps `#{key}` for this org (fail-honest — accounts are a host decision; seed the org's posting accounts first)"

  defp format(reason), do: inspect(reason)

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)

  defp memo_suffix(nil), do: ""
  defp memo_suffix(""), do: ""
  defp memo_suffix(memo), do: " — " <> memo
end
