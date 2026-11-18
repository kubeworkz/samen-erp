defmodule Samen.Scopes.Finance.ReconcileAr do
  @moduledoc """
  R12: reconcile the local AR subledger to the `:ar_clearing` GL balance.

  The subledger side is `ArAging`: the outstanding local invoice balance less
  the local on-account cash that has not been applied. The GL side is a bare
  SQL sum over posted `JournalLine` debits minus credits for the org's mapped
  `:ar_clearing` account, read independently of the AR document rows.

  Provider-mirror invoices are deliberately excluded from the local aging.
  They are still counted in `:excluded_provider_invoices` so the exclusion is
  visible rather than silent. A provider-linked receipt, credit note or
  allocation is contamination: it makes `:contaminated?` true and
  `:balanced?` false even when the cents happen to net. The caller can then
  investigate instead of accepting a coincidentally equal number.

  ## Options

    * `:org_id`, `:scope`, `:as_of` — as for `ArAging.for_org/1`
    * `:invoice`, `:receipt` — the AR document resources
    * `:receipt_allocation`, `:credit_note` — optional AR resources
    * `:posting_account`, `:entry`, `:line`, `:repo` — the host GL seam

  The invoice resource may or may not expose `:provider_invoice_ref`; a
  resource without that attribute has zero provider documents. The returned
  `:difference_cents` is `gl_cents - expected_gl_cents`.
  """

  require Ash.Query

  alias Samen.Scopes.Finance.ArAging

  @type report :: %{
          as_of: Date.t(),
          aging_cents: integer(),
          unapplied_cents: integer(),
          expected_gl_cents: integer(),
          gl_cents: integer(),
          difference_cents: integer(),
          balanced?: boolean(),
          excluded_provider_invoices: non_neg_integer(),
          provider_linked_receipts: non_neg_integer(),
          provider_linked_credit_notes: non_neg_integer(),
          provider_linked_allocations: non_neg_integer(),
          contaminated?: boolean()
        }

  @doc """
  Build the R12 reconciliation report for one org at `opts[:as_of]`.

  Returns `{:error, {:unmapped_posting_account, :ar_clearing}}` when the org
  has no AR clearing posting account. Mixed local currencies are refused
  rather than added together.
  """
  @spec for_org(keyword()) :: {:ok, report()} | {:error, term()}
  def for_org(opts) do
    org_id = Keyword.fetch!(opts, :org_id)
    scope = Keyword.fetch!(opts, :scope)
    as_of = Keyword.fetch!(opts, :as_of)

    invoice_resource = Keyword.fetch!(opts, :invoice)
    receipt_resource = Keyword.fetch!(opts, :receipt)

    with {:ok, aging} <- ArAging.for_org(opts),
         {:ok, invoices} <- read_invoices(invoice_resource, org_id, scope),
         {:ok, receipts} <- read_receipts(receipt_resource, org_id, scope),
         {:ok, credit_notes} <- read_credit_notes(opts, org_id, scope),
         {:ok, allocations} <- read_allocations(opts, org_id, scope),
         {:ok, ar_account} <- ar_clearing_account(opts, org_id, scope),
         {:ok, gl_cents} <- ar_clearing_balance(org_id, as_of, ar_account.account_id, opts) do
      provider_ids = provider_invoice_ids(invoices)
      provider_receipt_ids = provider_receipt_ids(receipts, allocations, provider_ids)

      excluded_provider_invoices =
        Enum.count(invoices, fn invoice ->
          provider_ref?(raw_provider_invoice_ref(invoice)) and
            status_in?(invoice, [:open, :paid])
        end)

      provider_linked_receipts =
        Enum.count(receipts, fn receipt ->
          MapSet.member?(provider_ids, value_of(receipt, :invoice_id)) or
            MapSet.member?(provider_receipt_ids, value_of(receipt, :id))
        end)

      provider_linked_credit_notes =
        Enum.count(credit_notes, &MapSet.member?(provider_ids, value_of(&1, :invoice_id)))

      provider_linked_allocations =
        Enum.count(allocations, &MapSet.member?(provider_ids, value_of(&1, :invoice_id)))

      contaminated? =
        provider_linked_receipts > 0 or
          provider_linked_credit_notes > 0 or
          provider_linked_allocations > 0

      with {:ok, aging_cents, unapplied_cents} <-
             local_totals(aging, provider_receipt_ids) do
        expected_gl_cents = aging_cents - unapplied_cents
        difference_cents = gl_cents - expected_gl_cents

        {:ok,
         %{
           as_of: as_of,
           aging_cents: aging_cents,
           unapplied_cents: unapplied_cents,
           expected_gl_cents: expected_gl_cents,
           gl_cents: gl_cents,
           difference_cents: difference_cents,
           balanced?: difference_cents == 0 and not contaminated?,
           excluded_provider_invoices: excluded_provider_invoices,
           provider_linked_receipts: provider_linked_receipts,
           provider_linked_credit_notes: provider_linked_credit_notes,
           provider_linked_allocations: provider_linked_allocations,
           contaminated?: contaminated?
         }}
      end
    end
  end

  @doc "Build the report from an org id and repo, merging them into the options."
  def for_org(org_id, repo, opts) do
    for_org(Keyword.merge(opts, org_id: org_id, repo: repo))
  end

  @doc "Alias for `for_org/1`."
  def reconcile(opts), do: for_org(opts)

  @doc "Alias for `for_org/3`."
  def reconcile(org_id, repo, opts), do: for_org(org_id, repo, opts)

  @doc "Returns `{:ok, balanced?}` while preserving the report errors."
  def reconciled?(opts) do
    case for_org(opts) do
      {:ok, report} -> {:ok, report.balanced?}
      {:error, reason} -> {:error, reason}
    end
  end

  # ── subledger side ─────────────────────────────────────────────────────────

  defp local_totals(aging, provider_receipt_ids) do
    local_invoices =
      Enum.reject(aging.invoices, &provider_ref?(value_of(&1, :provider_invoice_ref)))

    local_cash =
      Enum.reject(
        aging.unapplied_cash,
        &MapSet.member?(provider_receipt_ids, value_of(&1, :receipt_id))
      )

    currencies =
      (Enum.map(local_invoices, & &1.currency) ++ Enum.map(local_cash, & &1.currency))
      |> Enum.uniq()
      |> Enum.sort()

    case currencies do
      [] ->
        {:ok, 0, 0}

      [currency] ->
        aging_cents = Enum.reduce(local_invoices, 0, &(&1.outstanding_cents + &2))

        unapplied_cents =
          local_cash
          |> Enum.filter(&(&1.currency == currency))
          |> Enum.reduce(0, &(&1.unapplied_cents + &2))

        {:ok, aging_cents, unapplied_cents}

      currencies ->
        {:error, {:mixed_currencies, currencies}}
    end
  end

  defp provider_receipt_ids(receipts, allocations, provider_ids) do
    direct =
      receipts
      |> Enum.filter(&MapSet.member?(provider_ids, value_of(&1, :invoice_id)))
      |> Enum.map(&value_of(&1, :id))

    allocated =
      allocations
      |> Enum.filter(&MapSet.member?(provider_ids, value_of(&1, :invoice_id)))
      |> Enum.map(&value_of(&1, :receipt_id))

    MapSet.new(direct ++ allocated)
  end

  defp provider_invoice_ids(invoices) do
    invoices
    |> Enum.filter(&provider_ref?(raw_provider_invoice_ref(&1)))
    |> MapSet.new(&value_of(&1, :id))
  end

  # ── document reads ─────────────────────────────────────────────────────────

  defp read_invoices(resource, org_id, scope) do
    resource
    |> Ash.Query.filter(org_id == ^org_id)
    |> read_all(scope, :invoices)
  end

  defp read_receipts(resource, org_id, scope) do
    resource
    |> Ash.Query.filter(org_id == ^org_id and status == :posted)
    |> read_all(scope, :receipts)
  end

  defp read_credit_notes(opts, org_id, scope) do
    case Keyword.get(opts, :credit_note) do
      nil ->
        {:ok, []}

      resource ->
        resource
        |> Ash.Query.filter(org_id == ^org_id and status in [:open, :applied])
        |> read_all(scope, :credit_notes)
    end
  end

  defp read_allocations(opts, org_id, scope) do
    case Keyword.get(opts, :receipt_allocation) do
      nil ->
        {:ok, []}

      resource ->
        resource
        |> Ash.Query.filter(org_id == ^org_id)
        |> read_all(scope, :receipt_allocations)
    end
  end

  defp read_all(query, scope, label) do
    case Ash.read(query, scope: scope) do
      {:ok, rows} -> {:ok, rows}
      {:error, reason} -> {:error, {label, reason}}
    end
  end

  # ── GL side ────────────────────────────────────────────────────────────────

  defp ar_clearing_account(opts, org_id, scope) do
    resource =
      Keyword.get(opts, :posting_account) || Keyword.fetch!(opts, :posting_account_resource)

    case resource
         |> Ash.Query.filter(org_id == ^org_id and key == :ar_clearing)
         |> Ash.read_one(scope: scope) do
      {:ok, nil} -> {:error, {:unmapped_posting_account, :ar_clearing}}
      {:ok, account} -> {:ok, account}
      {:error, reason} -> {:error, {:posting_account_read_failed, reason}}
    end
  end

  defp ar_clearing_balance(org_id, as_of, account_id, opts) do
    repo = Keyword.fetch!(opts, :repo)
    entry_resource = Keyword.get(opts, :entry) || Keyword.fetch!(opts, :entry_resource)
    line_resource = Keyword.get(opts, :line) || Keyword.fetch!(opts, :line_resource)

    entry_table = AshPostgres.DataLayer.Info.table(entry_resource)
    line_table = AshPostgres.DataLayer.Info.table(line_resource)

    entry_id = attr_source(entry_resource, :id)
    entry_org = attr_source(entry_resource, :org_id)
    entry_status = attr_source(entry_resource, :status)
    entry_date = attr_source(entry_resource, :entry_date)
    line_entry_fk = entry_fk_source(line_resource, entry_resource)
    line_org = attr_source(line_resource, :org_id)
    line_account = attr_source(line_resource, :account_id)
    line_debit = attr_source(line_resource, :debit_cents)
    line_credit = attr_source(line_resource, :credit_cents)

    case repo.query(
           """
           SELECT COALESCE(SUM(l.#{line_debit} - l.#{line_credit}), 0)
           FROM #{line_table} l
           JOIN #{entry_table} e
             ON e.#{entry_id} = l.#{line_entry_fk}
            AND e.#{entry_org} = l.#{line_org}
           WHERE e.#{entry_org} = $1
             AND e.#{entry_status} = 'posted'
             AND e.#{entry_date} <= $2
             AND l.#{line_account} = $3
           """,
           [dump_uuid(org_id), as_of, dump_uuid(account_id)]
         ) do
      {:ok, %{rows: [[total]]}} -> {:ok, to_i(total)}
      {:error, reason} -> {:error, {:gl_read_failed, reason}}
    end
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp raw_provider_invoice_ref(invoice) do
    case Ash.Resource.Info.attribute(invoice.__struct__, :provider_invoice_ref) do
      nil ->
        nil

      _attribute ->
        case Map.get(invoice, :provider_invoice_ref) do
          %Ash.NotLoaded{} -> nil
          ref -> ref
        end
    end
  end

  defp provider_ref?(nil), do: false

  defp provider_ref?(ref) when is_binary(ref), do: String.trim(ref) != ""

  defp provider_ref?(_ref), do: true

  defp status_in?(row, statuses) do
    value = value_of(row, :status)
    value in statuses or to_string(value) in Enum.map(statuses, &to_string/1)
  end

  defp value_of(map, key) when is_map(map) do
    Map.get(map, key) || Map.get(map, Atom.to_string(key))
  end

  defp value_of(_other, _key), do: nil

  defp attr_source(resource, name) do
    case Ash.Resource.Info.attribute(resource, name) do
      nil -> raise ArgumentError, "no attribute #{inspect(name)} on #{inspect(resource)}"
      attr -> to_string(attr.source || attr.name)
    end
  end

  defp entry_fk_source(line_resource, entry_resource) do
    line_resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.type == :belongs_to and &1.destination == entry_resource))
    |> case do
      nil ->
        raise ArgumentError,
              "no belongs_to from #{inspect(line_resource)} to #{inspect(entry_resource)}"

      rel ->
        to_string(attr_source(line_resource, rel.source_attribute))
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
  defp to_i(value) when is_integer(value), do: value
  defp to_i(%Decimal{} = value), do: Decimal.to_integer(value)

  defp to_i(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> integer
      _ -> 0
    end
  end

  defp to_i(_value), do: 0
end
