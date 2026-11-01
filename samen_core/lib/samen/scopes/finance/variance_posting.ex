defmodule Samen.Scopes.Finance.VariancePosting do
  @moduledoc """
  The variance posting cascade (WS-ACCT Phase 7; ADR-054 D4, R8): when a
  `CostVariance` row is recorded, land its journal entry in the SAME
  transaction, and **name the accounts on the row**.

  ## The entry

  One entry per variance, anchored `source_key: "cost_variance"`,
  `source_id: <the variance row>` and dated the period's last day:

      unfavourable (amount > 0)   Dr <disposition target>   amount
                                  Cr <variance account>     amount

      favourable   (amount < 0)   Dr <variance account>     |amount|
                                  Cr <disposition target>   |amount|

  Both legs carry the card's `dimension_key => cost_object_id`, so R6 (per
  cost-object balance) holds and a per-chip variance report is a GROUP BY over
  the lines rather than a fifth account.

  The **variance account** comes from the type's family
  (`VarianceDisposition.variance_meaning/1`); the **disposition target** is the
  manual's per-type table (`VarianceDisposition.account_meaning/1`). Both are
  resolved through the org's `PostingAccount` rows and refuse fail-honest when
  a meaning is unmapped — accounts are a host decision, never invented here.

  ## Why the row and the entry are minted together

  The row and its entry reference each other through the ADR-041 anchor, so the
  entry's `source_id` must be the row's id. A `before_action` runs before Ash
  assigns the primary key, so this change mints the id, posts the entry against
  it, and forces it onto the changeset. A failure anywhere adds an error, so
  there is no state in which a variance exists without its entry — the exact
  discipline `RecognitionPosting` established for recognitions.

  Draft first, then the governed `:post`: a create-born-POSTED entry cannot
  insert its own lines (the `PostGuard` marker restore unwinds before
  `EntryLines` materializes them), and going through `:post` means R1, R6 and
  R10 evaluate the variance exactly as they evaluate a human posting.
  """

  use Ash.Resource.Change

  @source_key "cost_variance"

  @doc "The object-ref anchor every variance entry carries."
  def source_key, do: @source_key

  @impl true
  def change(changeset, opts, _context) do
    entry_mod = Keyword.fetch!(opts, :entry)
    pa_mod = Keyword.fetch!(opts, :posting_account)

    org_id = Ash.Changeset.get_attribute(changeset, :org_id)

    Ash.Changeset.before_action(changeset, fn changeset ->
      post(changeset, org_id, entry_mod, pa_mod)
    end)
  end

  defp post(changeset, org_id, entry_mod, pa_mod) do
    type = Ash.Changeset.get_attribute(changeset, :type)
    amount = Ash.Changeset.get_attribute(changeset, :amount_cents)
    period_key = Ash.Changeset.get_attribute(changeset, :period_key)
    standard_id = Ash.Changeset.get_attribute(changeset, :standard_id)
    cost_object_id = Ash.Changeset.get_attribute(changeset, :cost_object_id)
    row = Samen.Scopes.Finance.VarianceDisposition.for_type(type)
    standard_mod = relationship_destination(changeset.resource, :standard)

    with {:ok, standard} <- load_standard(standard_mod, org_id, standard_id),
         {:ok, variance_account} <-
           posting_account(pa_mod, org_id, row.variance_meaning),
         {:ok, target_account} <- posting_account(pa_mod, org_id, row.account_meaning),
         {:ok, entry_date} <- Samen.Scopes.Finance.StandardCard.period_end(period_key) do
      if amount == 0 do
        # A MEASURED zero: the period was priced and the variance was nil. The
        # row is the run's marker (so a retry is a no-op) and names the accounts
        # the policy would use, but nothing posted -- there is no entry to mint.
        names(changeset, nil, nil, variance_account, target_account, row)
      else
        # The variance id is minted so the entry's ADR-041 anchor can name it;
        # the entry keeps its own generated PK, which is what `entry_id` stores.
        id = Ash.UUID.generate()

        case create_entry(
               entry_mod,
               org_id,
               id,
               entry_date,
               period_key,
               type,
               amount,
               variance_account,
               target_account,
               standard.dimension_key,
               cost_object_id
             ) do
          {:ok, entry} -> names(changeset, id, entry.id, variance_account, target_account, row)
          {:error, reason} -> error(changeset, reason)
        end
      end
    else
      {:error, reason} -> error(changeset, reason)
    end
  end

  defp names(changeset, id, entry_id, variance_account, target_account, row) do
    changeset
    |> force_id(id)
    |> Ash.Changeset.force_change_attribute(:entry_id, entry_id)
    |> Ash.Changeset.force_change_attribute(:variance_account_id, variance_account.account_id)
    |> Ash.Changeset.force_change_attribute(:disposition_account_id, target_account.account_id)
    |> Ash.Changeset.force_change_attribute(:disposition, row.disposition)
    |> Ash.Changeset.force_change_attribute(:posted_at, DateTime.utc_now())
  end

  defp force_id(changeset, nil), do: changeset
  defp force_id(changeset, id), do: Ash.Changeset.force_change_attribute(changeset, :id, id)

  defp error(changeset, reason) do
    Ash.Changeset.add_error(changeset,
      field: :base,
      message: "the variance cannot be posted: #{format(reason)}"
    )
  end

  # Read the card PINNED to this org (the system cascade): a card from another
  # tenant is invisible, and its dimension_key is what the entry legs carry.
  defp load_standard(standard_mod, org_id, standard_id) do
    require Ash.Query

    case standard_mod
         |> Ash.Query.filter(id == ^standard_id and org_id == ^org_id)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, {:foreign_standard, standard_id}}
      {:ok, standard} -> {:ok, standard}
      {:error, reason} -> {:error, reason}
    end
  end

  defp posting_account(pa_mod, org_id, key) do
    require Ash.Query

    case pa_mod
         |> Ash.Query.filter(org_id == ^org_id and key == ^key)
         |> Ash.read_one(authorize?: false) do
      {:ok, nil} -> {:error, {:unmapped_posting_account, key}}
      {:ok, row} -> {:ok, row}
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_entry(
         entry_mod,
         org_id,
         id,
         entry_date,
         period_key,
         type,
         amount,
         variance_account,
         target_account,
         dimension_key,
         cost_object_id
       ) do
    dims = %{to_string(dimension_key) => cost_object_id}
    label = Samen.Scopes.Finance.VarianceDisposition.label(type)

    {variance_line, target_line} =
      if amount > 0 do
        {%{
           account_id: variance_account.account_id,
           credit_cents: amount,
           dimension_refs: dims
         },
         %{
           account_id: target_account.account_id,
           debit_cents: amount,
           dimension_refs: dims
         }}
      else
        {%{
           account_id: variance_account.account_id,
           debit_cents: -amount,
           dimension_refs: dims
         },
         %{
           account_id: target_account.account_id,
           credit_cents: -amount,
           dimension_refs: dims
         }}
      end

    memo =
      "#{label} variance #{period_key} " <>
        if(amount > 0, do: "(unfavourable)", else: "(favourable)")

    with {:ok, draft} <-
           entry_mod
           |> Ash.Changeset.for_create(
             :create,
             %{
               org_id: org_id,
               entry_date: entry_date,
               memo: memo,
               source_key: @source_key,
               source_id: id,
               lines: [variance_line, target_line]
             },
             authorize?: false
           )
           |> Ash.create(authorize?: false),
         {:ok, posted} <-
           draft
           |> Ash.Changeset.for_update(:post, %{}, authorize?: false)
           |> Ash.update(authorize?: false) do
      {:ok, posted}
    end
  end

  defp relationship_destination(resource, name) do
    resource
    |> Ash.Resource.Info.relationship(name)
    |> Map.fetch!(:destination)
  end

  defp format({:unmapped_posting_account, key}),
    do:
      "no PostingAccount row maps `#{key}` for this org (fail-honest — accounts are a " <>
        "host decision; seed the org's posting accounts first)"

  defp format({:foreign_standard, id}), do: "standard #{id} does not belong to this org"
  defp format(:bad_period), do: "the period key is not a valid \"YYYY-MM\" month"
  defp format(reason), do: inspect(reason)
end
