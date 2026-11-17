defmodule Samen.Scopes.Finance.PayrollSettlementPost do
  @moduledoc """
  Posts a prepared payroll settlement by invoking the journal entry's own
  `:post` action for every settlement entry.

  Posting is deliberately not a bulk SQL update. Each entry passes through the
  same `PostBalance`, `PeriodGuard`, `DimensionBalance`, void guard and journal
  approval policy as a hand-entered entry. If any entry is refused, the
  settlement update fails and the surrounding transaction leaves the whole
  batch in draft; the settlement is only marked `:posted` when every entry is
  posted. Posting also locks the linked payroll import row and re-checks that
  it is still `:imported` with a `:posted` register entry, so a settlement
  cannot post cash legs against a register voided by a concurrent amendment.
  """

  use Ash.Resource.Change
  require Ash.Query

  @impl true
  def change(changeset, opts, context) do
    entry_mod = Keyword.fetch!(opts, :entry)
    import_mod = Keyword.fetch!(opts, :import)

    actor_struct =
      actor_struct(context) || actor_struct(get_in(changeset.context, [:private, :actor]))

    actor_id = actor_id(actor_struct)
    org_id = actor_org_id(actor_struct)

    Ash.Changeset.before_action(changeset, fn changeset ->
      post(changeset, entry_mod, import_mod, actor_struct, actor_id, org_id)
    end)
  end

  defp post(changeset, entry_mod, import_mod, actor, actor_id, org_id) do
    settlement = changeset.data

    with :ok <- require_actor(actor_id),
         :ok <- require_org(org_id),
         :ok <- ensure_draft(settlement),
         :ok <- ensure_register_current(import_mod, org_id, settlement),
         :ok <- ensure_entries_present(settlement.entry_ids),
         {:ok, entries} <- load_entries(entry_mod, org_id, settlement.entry_ids),
         :ok <- ensure_all_present(settlement.entry_ids, entries),
         :ok <- ensure_not_voided(entries),
         :ok <- ensure_totals(entries, settlement),
         {:ok, _posted} <- post_entries(entries, actor) do
      changeset
      |> Ash.Changeset.force_change_attribute(:status, :posted)
      |> Ash.Changeset.force_change_attribute(:posted_by, actor_id)
      |> Ash.Changeset.force_change_attribute(:posted_at, now())
    else
      {:error, message} when is_binary(message) ->
        Ash.Changeset.add_error(changeset, message: message)

      {:error, reason} ->
        Ash.Changeset.add_error(changeset,
          message: "payroll settlement could not be posted: #{inspect(reason)}"
        )
    end
  end

  defp ensure_draft(%{status: :draft}), do: :ok

  defp ensure_draft(%{status: status}),
    do: {:error, "only a draft settlement can be posted (status: #{status})"}

  # Lock the same row payroll amendment uses. Whichever action gets the lock
  # first decides the outcome: a committed amendment leaves the import
  # superseded and the entry void, so posting is refused; a committed posting
  # is visible to the amendment guard before it can void the register.
  defp ensure_register_current(import_mod, org_id, settlement) do
    import_mod
    |> Ash.Query.filter(id == ^settlement.payroll_import_id and org_id == ^org_id)
    |> Ash.Query.load(entry: [])
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, %{status: :imported, entry: %{status: :posted}}} ->
        :ok

      {:ok, %{status: import_status, entry: %{status: entry_status}}} ->
        {:error,
         "the payroll register is no longer imported and posted (import: #{import_status}, entry: #{entry_status})"}

      {:ok, _} ->
        {:error, "the payroll register for this settlement was not found"}

      {:error, reason} ->
        {:error, "the payroll register could not be read: #{inspect(reason)}"}
    end
  end

  defp ensure_entries_present(ids) when is_list(ids) and ids != [], do: :ok
  defp ensure_entries_present(_), do: {:error, "the settlement has no journal entries to post"}

  defp load_entries(entry_mod, org_id, ids) do
    entry_mod
    |> Ash.Query.filter(id in ^ids and org_id == ^org_id)
    |> Ash.Query.load(lines: :account)
    |> Ash.read(authorize?: false)
  end

  defp ensure_all_present(ids, entries) do
    found = MapSet.new(entries, & &1.id)

    case Enum.reject(ids, &MapSet.member?(found, &1)) do
      [] ->
        :ok

      missing ->
        {:error, "the settlement entries could not be loaded: #{Enum.join(missing, ", ")}"}
    end
  end

  defp ensure_not_voided(entries) do
    case Enum.filter(entries, &(&1.status == :void)) do
      [] ->
        :ok

      voided ->
        {:error,
         "a voided settlement entry cannot be posted: #{Enum.map_join(voided, ", ", & &1.id)}"}
    end
  end

  # The stored settlement total is the controller's approved batch amount.
  # Re-read the PERSISTED lines immediately before posting: a draft may have
  # been edited after preparation, and neither the register liability debits
  # nor the cash credits may drift from that approved total.
  defp ensure_totals(entries, settlement) do
    cash_id = settlement.cash_account_id
    total_cents = settlement.total_cents
    liability_cents = Enum.reduce(entries, 0, &(liability_debits(&1) + &2))
    cash_cents = Enum.reduce(entries, 0, &(cash_credits(&1, cash_id) + &2))

    cond do
      liability_cents != total_cents ->
        {:error,
         "the settlement entries debit #{liability_cents} cents of liabilities but the stored batch total is #{total_cents} cents"}

      cash_cents != total_cents ->
        {:error,
         "the settlement entries credit #{cash_cents} cents to the settlement cash account but the stored batch total is #{total_cents} cents"}

      Enum.any?(entries, &(liability_debits(&1) != cash_credits(&1, cash_id))) ->
        entry = Enum.find(entries, &(liability_debits(&1) != cash_credits(&1, cash_id)))

        {:error,
         "settlement entry #{entry.id} does not debit its liability by the same amount it credits cash"}

      true ->
        :ok
    end
  end

  defp liability_debits(entry) do
    entry.lines
    |> Enum.filter(&(&1.account && &1.account.kind == :liability))
    |> Enum.reduce(0, &(&1.debit_cents + &2))
  end

  defp cash_credits(entry, cash_id) do
    entry.lines
    |> Enum.filter(&(&1.account_id == cash_id))
    |> Enum.reduce(0, &(&1.credit_cents + &2))
  end

  defp post_entries(entries, actor) do
    entries
    |> Enum.reduce_while({:ok, []}, fn entry, {:ok, posted} ->
      cond do
        entry.status == :posted ->
          {:cont, {:ok, [entry | posted]}}

        entry.status != :draft ->
          {:halt, {:error, "settlement entry #{entry.id} is #{entry.status}, not draft"}}

        true ->
          case entry
               |> Ash.Changeset.for_update(:post, %{}, actor: actor)
               |> Ash.update() do
            {:ok, %{status: :posted} = entry} ->
              {:cont, {:ok, [entry | posted]}}

            {:ok, entry} ->
              {:halt,
               {:error, "settlement entry #{entry.id} did not post (status: #{entry.status})"}}

            {:error, reason} ->
              {:halt,
               {:error, "settlement entry #{entry.id} could not be posted: #{inspect(reason)}"}}
          end
      end
    end)
    |> case do
      {:ok, posted} -> {:ok, Enum.reverse(posted)}
      {:error, _} = error -> error
    end
  end

  defp require_actor(actor) when is_binary(actor), do: :ok
  defp require_actor(_), do: {:error, "an authenticated poster is required"}

  defp require_org(org_id) when is_binary(org_id), do: :ok
  defp require_org(_), do: {:error, "an organization is required to post a settlement"}

  defp actor_struct(%Samen.Scope{actor: actor}), do: actor
  defp actor_struct(%{actor: actor}), do: actor
  defp actor_struct(actor), do: actor

  defp actor_id(%{id: id}) when is_binary(id), do: id
  defp actor_id(id) when is_binary(id), do: id
  defp actor_id(_), do: nil

  defp actor_org_id(%{org_id: org_id}) when is_binary(org_id), do: org_id
  defp actor_org_id(_), do: nil

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second)
end
