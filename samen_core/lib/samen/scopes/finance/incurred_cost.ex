defmodule Samen.Scopes.Finance.IncurredCost do
  @moduledoc """
  The **incurred allowable cost** read (WS-ACCT Phase 6; ADR-054 D5/D8) — the
  number a `:cost_incurred` revenue schedule recognizes against, and (Phase 11)
  the same number R11 compares a grant's recognized revenue and claimed costs
  to. Built once, here, because two invariants hang off one definition.

  What counts as incurred cost for a cost object in a period:

    * a POSTED journal line (a draft is not a fact; a void's reversing pair nets
      out naturally);
    * on an **expense** account (`kind = 'expense'`) — debits increase cost,
      credits (a reversal, a credit note against cost) decrease it;
    * dated inside the period (`entry_date` inclusive of both ends — the
      period's own month, not `posted_at`: a bill entered in February for
      January's work is January's cost);
    * **dimensioned to the cost object**, under ANY axis. The lookup does not
      assume an axis: a grant fund may be named `"fund"`, a programme
      `"project"`; what identifies the cost is the id, which is what keeps the
      dimension seam ids-only (R6).

  The result is clamped at zero: a period whose expense credits exceed its
  debits incurred no cost, and negative incurred cost is not a thing to
  recognize revenue against.
  """

  @doc """
  Σ incurred allowable cost for `cost_object_id` in `{year, month}`, in cents.

  Opts: `:entry_resource`, `:line_resource`, `:account_resource` (required).
  """
  def for_period(org_id, {year, month}, cost_object_id, repo, opts) do
    entry_resource = Keyword.fetch!(opts, :entry_resource)
    line_resource = Keyword.fetch!(opts, :line_resource)
    account_resource = Keyword.fetch!(opts, :account_resource)

    entry_table = AshPostgres.DataLayer.Info.table(entry_resource)
    line_table = AshPostgres.DataLayer.Info.table(line_resource)
    account_table = AshPostgres.DataLayer.Info.table(account_resource)

    entry_id = attr_source(entry_resource, :id)
    entry_org = attr_source(entry_resource, :org_id)
    entry_status = attr_source(entry_resource, :status)
    entry_date = attr_source(entry_resource, :entry_date)

    line_entry_fk = entry_fk_source(line_resource, entry_resource)
    line_account_fk = account_fk_source(line_resource, account_resource)
    line_org = attr_source(line_resource, :org_id)
    line_debit = attr_source(line_resource, :debit_cents)
    line_credit = attr_source(line_resource, :credit_cents)
    line_dims = attr_source(line_resource, :dimension_refs)

    account_id = attr_source(account_resource, :id)
    account_org = attr_source(account_resource, :org_id)
    account_kind = attr_source(account_resource, :kind)

    from_date = Date.new!(year, month, 1)
    to_date = Date.end_of_month(from_date)

    case repo.query(
           """
           SELECT COALESCE(SUM(l.#{line_debit} - l.#{line_credit}), 0)
           FROM #{line_table} l
           JOIN #{entry_table} e
             ON e.#{entry_id} = l.#{line_entry_fk}
            AND e.#{entry_org} = l.#{line_org}
           JOIN #{account_table} a
             ON a.#{account_id} = l.#{line_account_fk}
            AND a.#{account_org} = l.#{line_org}
           WHERE e.#{entry_org} = $1
             AND e.#{entry_status} = 'posted'
             AND e.#{entry_date} >= $2
             AND e.#{entry_date} <= $3
             AND a.#{account_kind} = 'expense'
             AND EXISTS (
               SELECT 1 FROM jsonb_each_text(l.#{line_dims}) d
               WHERE d.value = $4
             )
           """,
           [dump_uuid(org_id), from_date, to_date, to_string(cost_object_id)]
         ) do
      {:ok, %{rows: [[total]]}} -> {:ok, max(to_i(total), 0)}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp attr_source(resource, name) do
    case Ash.Resource.Info.attribute(resource, name) do
      nil -> raise ArgumentError, "no attribute #{inspect(name)} on #{inspect(resource)}"
      attr -> to_string(attr.source || attr.name)
    end
  end

  defp entry_fk_source(line_resource, entry_resource) do
    belongs_to_source(line_resource, entry_resource, :entry)
  end

  defp account_fk_source(line_resource, account_resource) do
    belongs_to_source(line_resource, account_resource, :account)
  end

  defp belongs_to_source(resource, destination, label) do
    resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.type == :belongs_to and &1.destination == destination))
    |> case do
      nil ->
        raise ArgumentError,
              "no belongs_to #{inspect(label)} from #{inspect(resource)} to #{inspect(destination)}"

      rel ->
        to_string(attr_source(resource, rel.source_attribute))
    end
  end

  defp dump_uuid(value) when is_binary(value) and byte_size(value) == 16, do: value

  defp dump_uuid(value) do
    case Ecto.UUID.dump(value) do
      {:ok, bin} -> bin
      :error -> value
    end
  end

  defp to_i(nil), do: 0
  defp to_i(v) when is_integer(v), do: v
  defp to_i(%Decimal{} = d), do: Decimal.to_integer(d)

  defp to_i(bin) when is_binary(bin) do
    case Integer.parse(bin) do
      {i, ""} -> i
      _ -> 0
    end
  end

  defp to_i(_), do: 0
end
