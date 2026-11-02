defmodule Samen.Scopes.Finance.CostAllocationDrafting do
  @moduledoc """
  The drafting cascade for a cost allocation (WS-ACCT Phase 10; ADR-054
  decision 11).

  Runs on `:draft`'s `before_action`: it loads the AP bill, resolves the ONE
  expense account the allocation reclasses, derives that account's amount from
  the bill's own lines, and splits it across the declared targets with
  `Samen.Scopes.Finance.AllocationMath`. It accepts **no amounts** — a caller
  who wants different cents changes the bill or the drivers, never the split.

  ## The bill must have posted

  Allocation moves cost that is already on the books. A draft bill has no
  posting to reclass, so `:draft` refuses it and names the lifecycle state; a
  void bill is refused for the same reason. The amount is read from the bill's
  LINE for the source account (not from the posted entry), because the lines
  are what the AP cascade paid and what a later reviewer can re-read.

  ## One source account, by declaration or by fact

  A bill may carry several lines. If it names one distinct account, that is the
  source. If it names several, `source_account_id` MUST be passed and MUST be
  one of them: an allocation that credits an account the bill never debited
  would move cost from nowhere.

  ## Exactly one allocation per bill and source

  The table's unique index is the belt; this cascade's pre-read is the
  caller-facing refusal. Re-allocating the same bill's same cost would double
  the reclass, and a correction is a reversing entry — never a second
  allocation of the same fact.

  ## Zero-cent shares are refused

  Largest remainder can produce a zero-cent share when the amount is smaller
  than the number of targets. A zero-cent allocation line is not a fact (and
  the DB belt refuses it), so the whole draft is refused with the arithmetic
  named. An allocation divides cost; it never hands a programme a placeholder.
  """

  use Ash.Resource.Change

  require Ash.Query

  alias Samen.Scopes.Finance.AllocationMath

  @impl true
  def change(changeset, opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      draft(changeset, org_id(changeset), opts)
    end)
  end

  defp draft(changeset, org_id, opts) do
    invoice_mod = Keyword.fetch!(opts, :invoice)
    share_mod = Keyword.fetch!(opts, :share)

    with {:ok, shares} <- shares_argument(changeset),
         :ok <- require_two_targets(shares),
         {:ok, invoice} <- load_invoice(invoice_mod, org_id, changeset),
         :ok <- require_posted(invoice),
         {:ok, source_id, amount} <- resolve_source(changeset, invoice),
         :ok <- require_different_account(changeset, source_id),
         :ok <- require_unallocated(changeset.resource, org_id, invoice.id, source_id),
         {:ok, computed} <- AllocationMath.allocate(amount, shares),
         :ok <- require_positive(computed) do
      changeset
      |> Ash.Changeset.force_change_attribute(:source_account_id, source_id)
      |> Ash.Changeset.force_change_attribute(:amount_cents, amount)
      |> Ash.Changeset.force_change_attribute(:status, :draft)
      |> Ash.Changeset.after_action(fn _changeset, header ->
        materialize(header, org_id, share_mod, computed)
      end)
    else
      {:error, message} when is_binary(message) -> error(changeset, message)
      {:error, reason} -> error(changeset, format(reason))
    end
  end

  # ── inputs ─────────────────────────────────────────────────────────────────

  defp shares_argument(changeset) do
    case Ash.Changeset.get_argument(changeset, :shares) do
      shares when is_list(shares) ->
        {:ok,
         Enum.map(shares, fn share ->
           %{
             cost_object_id:
               Map.get(share, :cost_object_id) || Map.get(share, "cost_object_id"),
             driver: Map.get(share, :driver) || Map.get(share, "driver")
           }
         end)}

      _other ->
        {:error, "an allocation needs a non-empty list of shares"}
    end
  end

  defp require_two_targets(shares) when length(shares) >= 2, do: :ok

  defp require_two_targets(_shares) do
    {:error,
     "an allocation needs at least two cost objects — a single target is a reclass, " <>
       "which an ordinary journal entry already posts"}
  end

  defp load_invoice(invoice_mod, org_id, changeset) do
    invoice_id = Ash.Changeset.get_attribute(changeset, :ap_invoice_id)

    case Ash.get(invoice_mod, invoice_id, authorize?: false) do
      {:ok, invoice} ->
        invoice =
          Ash.load!(invoice, [:org_id, :lines, :posted_entry_id, :status, :number],
            authorize?: false
          )

        if invoice.org_id == org_id do
          {:ok, invoice}
        else
          {:error, "the AP bill does not belong to this org"}
        end

      {:error, _reason} ->
        {:error, "the AP bill does not exist"}
    end
  end

  defp require_posted(%{status: status, posted_entry_id: entry_id})
       when status in [:approved, :paid] and not is_nil(entry_id),
       do: :ok

  defp require_posted(%{status: :draft}) do
    {:error,
     "the AP bill is still a draft — approve it before allocating its cost " <>
       "(there is no posting to reclass yet)"}
  end

  defp require_posted(%{status: :void}) do
    {:error, "the AP bill is void — its cost is no longer on the books, so there is nothing to allocate"}
  end

  defp require_posted(_invoice) do
    {:error, "the AP bill has no posting entry — its cost never reached the ledger"}
  end

  defp resolve_source(changeset, invoice) do
    lines = invoice.lines || []
    accounts = lines |> Enum.map(&line_account/1) |> Enum.reject(&is_nil/1) |> Enum.uniq()

    case Ash.Changeset.get_attribute(changeset, :source_account_id) do
      nil ->
        case accounts do
          [account_id] ->
            {:ok, account_id, amount_for(lines, account_id)}

          [] ->
            {:error, "the AP bill carries no lines — there is no cost to allocate"}

          _several ->
            {:error,
             "the AP bill names #{length(accounts)} expense accounts — pass " <>
               "`source_account_id` to choose the one this allocation reclasses"}
        end

      source_id when is_binary(source_id) ->
        if source_id in accounts do
          {:ok, source_id, amount_for(lines, source_id)}
        else
          {:error,
           "`source_account_id` names an account the AP bill never debited — an " <>
             "allocation cannot credit cost that did not land there"}
        end

      _other ->
        {:error, "`source_account_id` must be an account ID (a UUID)"}
    end
  end

  defp line_account(line), do: Map.get(line, :account_id) || Map.get(line, "account_id")

  defp line_amount(line), do: Map.get(line, :amount_cents) || Map.get(line, "amount_cents")

  defp amount_for(lines, account_id) do
    lines
    |> Enum.filter(&(line_account(&1) == account_id))
    |> Enum.reduce(0, fn line, acc -> acc + (line_amount(line) || 0) end)
  end

  defp require_different_account(changeset, source_id) do
    case Ash.Changeset.get_attribute(changeset, :target_account_id) do
      ^source_id ->
        {:error,
         "`target_account_id` is the source account — a same-account allocation moves " <>
           "nothing and re-dimensions nothing; name the account the cost should land in"}

      _other ->
        :ok
    end
  end

  defp require_unallocated(allocation_mod, org_id, invoice_id, source_id) do
    existing =
      allocation_mod
      |> Ash.Query.filter(
        org_id == ^org_id and ap_invoice_id == ^invoice_id and
          source_account_id == ^source_id
      )
      |> Ash.read_one(authorize?: false)

    case existing do
      {:ok, nil} ->
        :ok

      {:ok, row} ->
        {:error,
         "this bill's cost on that account is already allocated (#{row.status}) — one " <>
           "allocation per bill and source account; a correction is a reversing entry, " <>
           "never a second allocation of the same fact"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp require_positive(computed) do
    zeroes = Enum.count(computed, &(&1.allocated_cents <= 0))

    if zeroes == 0 do
      :ok
    else
      {:error,
       "the amount is too small to allocate across #{length(computed)} cost objects — " <>
         "#{zeroes} share(s) would be zero cents, which is not a fact (raise the bill " <>
         "or reduce the targets)"}
    end
  end

  # ── persistence ────────────────────────────────────────────────────────────

  defp materialize(header, org_id, share_mod, computed) do
    Enum.reduce_while(computed, {:ok, header}, fn share, {:ok, header} ->
      attrs = %{
        org_id: org_id,
        cost_allocation_id: header.id,
        cost_object_id: share.cost_object_id,
        driver: share.driver,
        allocated_cents: share.allocated_cents
      }

      case share_mod
           |> Ash.Changeset.for_create(:materialize, attrs, authorize?: false)
           |> Ash.create(authorize?: false) do
        {:ok, _share} -> {:cont, {:ok, header}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # ── errors / plumbing ──────────────────────────────────────────────────────

  defp format(:too_few_shares) do
    "an allocation needs at least two cost objects — a single target is a reclass, " <>
      "not an allocation"
  end

  defp format(:duplicate_cost_object) do
    "a cost object appears more than once — each target absorbs its own share, never two"
  end

  defp format(:invalid_driver) do
    "every share needs a positive integer driver (die-area units, wafers or effort " <>
      "hours) — a target with no share of the basis cannot absorb cost"
  end

  defp format(:invalid_amount) do
    "the bill's amount for that account is zero — there is nothing to allocate"
  end

  defp format(:allocation_does_not_tie) do
    "the allocation's shares do not sum to the invoice amount — refused rather than " <>
      "posting a split that loses or invents a cent"
  end

  defp format(reason), do: inspect(reason)

  defp error(changeset, message) do
    Ash.Changeset.add_error(changeset, field: :base, message: message)
  end

  defp org_id(changeset) do
    case Ash.Changeset.get_attribute(changeset, :org_id) do
      %Ash.NotLoaded{} -> persisted_org_id(changeset.data)
      nil -> persisted_org_id(changeset.data)
      value -> value
    end
  end

  defp persisted_org_id(record) do
    case record.org_id do
      %Ash.NotLoaded{} -> Ash.load!(record, [:org_id], authorize?: false).org_id
      value -> value
    end
  end
end
