defmodule Samen.Scopes.Finance.GrantCompliance do
  @moduledoc """
  The grant compliance reads (WS-ACCT Phase 11; ADR-054 D8, R11).

  Two derived reads, no stored balance and no second ledger:

    * `statement/3` — one grant's award, receipt, recognized revenue, fund
      income movement, deferred balance, approved claims and incurred
      allowable cost, plus the R11 issue list.
    * `personnel/3` — the grant personnel report. It stores only an opaque HR
      employee id and an effort percentage; the NAME is resolved through
      `Samen.Api.PiiResolution` on the caller's plane (tenant clear, operator
      without a grant `••••`). That is the masking watch-list surface; Finance
      never re-declares the person.

  ## R11 — what must agree

  * `recognized_cents` (Σ the grant schedule's recognitions) must equal
    `fund_income_cents` (the income-account movement over posted lines
    dimensioned to the grant's fund). This ties the schedule to the ledger.
  * `claimed_cents` (Σ APPROVED claims only) must equal `recognized_cents`.
    A submitted claim is a proposal, not a fact.
  * `recognized_cents` must never exceed `incurred_cents` (the same
    `IncurredCost` read the recognition run uses, summed across the grant's
    term). Recognizing ahead of cost is the accounting error the whole
    `:cost_incurred` method exists to prevent.

  The deferred balance is reported, not asserted: an award may be opened before
  it is received, and a grant may be closed with a residual. R11 is about the
  three legs above, each independently derived.
  """

  require Ash.Query

  alias Samen.Scopes.Finance.GrantShape
  alias Samen.Scopes.Finance.IncurredCost

  @doc """
  One grant's compliance statement. `opts` must carry the host resources:
  `:entry`, `:line`, `:account`, `:recognition`, `:claim`, `:posting_account`.
  """
  def statement(grant, repo, opts) do
    # A read returned by a host query may not have selected org_id; the
    # statement's SQL pins every leg to it, so load it explicitly.
    grant = Ash.load!(grant, [:org_id], authorize?: false)
    mods = Map.new(opts)
    recognized = recognized_cents(grant, repo, mods)
    income = fund_income_cents(grant, repo, mods)
    deferred = deferred_cents(grant, repo, mods)
    claimed = claimed_cents(grant, mods)
    incurred = incurred_cents(grant, repo, mods)

    issues =
      []
      |> maybe_issue(:fund_income_mismatch, income != recognized)
      |> maybe_issue(:claim_mismatch, claimed != recognized)
      |> maybe_issue(:recognition_ahead_of_cost, recognized > incurred)

    %{
      grant_id: grant.id,
      award_ref: grant.award_ref,
      award_cents: grant.award_cents,
      received_cents: if(grant.received_on, do: grant.award_cents, else: 0),
      recognized_cents: recognized,
      fund_income_cents: income,
      deferred_cents: deferred,
      claimed_cents: claimed,
      incurred_cents: incurred,
      issues: issues,
      balanced?: issues == []
    }
  end

  @doc """
  The grant personnel report. `opts`:

    * `:rows` — the host's `GrantPersonnel` resource (required);
    * `:personnel` — `[resource: Host.Hr.Employee, name_attribute: :full_name]`
      (omit to get `{:error, :personnel_not_wired}`);
    * `:repo` — the vault repo (required for the tenant-clear resolution).
  """
  def personnel(grant, scope, opts) do
    grant = Ash.load!(grant, [:org_id], authorize?: false)

    case Keyword.get(opts, :personnel) do
      nil ->
        {:error, :personnel_not_wired}

      config ->
        rows_mod = Keyword.fetch!(opts, :rows)
        resource = Keyword.fetch!(config, :resource)
        name_attribute = Keyword.get(config, :name_attribute, :full_name)
        repo = Keyword.fetch!(opts, :repo)

        rows =
          rows_mod
          |> Ash.Query.filter(org_id == ^grant.org_id and grant_id == ^grant.id)
          |> Ash.Query.sort(effective_on: :asc)
          |> Ash.read!(authorize?: false)

        records =
          rows
          |> Enum.map(&fetch_person(resource, &1.employee_id, grant.org_id, name_attribute))
          |> Enum.reject(&is_nil/1)

        by_id =
          records
          |> Samen.Api.PiiResolution.resolve(resource, scope.actor, repo: repo)
          |> Map.new(&{&1.id, &1})

        report =
          Enum.map(rows, fn row ->
            person = Map.get(by_id, row.employee_id)

            %{
              employee_id: row.employee_id,
              effort_pct: row.effort_pct,
              effective_on: row.effective_on,
              name: person && Map.get(person, name_attribute)
            }
          end)

        {:ok, report}
    end
  end

  # ── statement legs ─────────────────────────────────────────────────────────

  defp recognized_cents(%{schedule_id: nil}, _repo, _mods), do: 0

  defp recognized_cents(grant, repo, mods) do
    table = table(mods.recognition)
    org = attr(mods.recognition, :org_id)
    schedule = attr(mods.recognition, :schedule_id)
    amount = attr(mods.recognition, :amount_cents)

    scalar(
      repo,
      "SELECT COALESCE(SUM(#{amount}), 0) FROM #{table} WHERE #{org} = $1 AND #{schedule} = $2",
      [dump_uuid(grant.org_id), dump_uuid(grant.schedule_id)]
    )
  end

  defp fund_income_cents(grant, repo, mods) do
    sum_dimensioned_income(grant, repo, mods)
  end

  # The deferred balance is informational. An unmapped grant_deferred account
  # means no receipt has been posted yet; that is a zero balance, not a crash.
  defp deferred_cents(grant, repo, mods) do
    case posting_account(mods.posting_account, grant.org_id, :grant_deferred) do
      {:ok, nil} -> 0
      {:ok, row} -> sum_dimensioned_account(grant, repo, mods, row.account_id)
      {:error, _reason} -> 0
    end
  end

  defp claimed_cents(grant, mods) do
    mods.claim
    |> Ash.Query.filter(org_id == ^grant.org_id and grant_id == ^grant.id and status == :approved)
    |> Ash.read!(authorize?: false)
    |> Enum.reduce(0, &(&1.amount_cents + &2))
  end

  defp incurred_cents(grant, repo, mods) do
    months = GrantShape.months_between(grant.period_start, grant.period_end)

    Enum.reduce(0..(months - 1), 0, fn offset, acc ->
      {year, month} = shift(grant.period_start, offset)

      case IncurredCost.for_period(grant.org_id, {year, month}, grant.fund_cost_object_id, repo,
             entry_resource: mods.entry,
             line_resource: mods.line,
             account_resource: mods.account
           ) do
        {:ok, cents} -> acc + cents
        {:error, _reason} -> acc
      end
    end)
  end

  # ── SQL helpers ────────────────────────────────────────────────────────────

  defp sum_dimensioned_income(grant, repo, mods) do
    line_table = table(mods.line)
    entry_table = table(mods.entry)
    account_table = table(mods.account)

    entry_id = attr(mods.entry, :id)
    entry_org = attr(mods.entry, :org_id)
    entry_status = attr(mods.entry, :status)
    line_entry = belongs_to_attr(mods.line, mods.entry, :entry)
    line_account = belongs_to_attr(mods.line, mods.account, :account)
    line_org = attr(mods.line, :org_id)
    debit = attr(mods.line, :debit_cents)
    credit = attr(mods.line, :credit_cents)
    dims = attr(mods.line, :dimension_refs)
    account_id = attr(mods.account, :id)
    account_org = attr(mods.account, :org_id)
    account_kind = attr(mods.account, :kind)

    scalar(
      repo,
      """
      SELECT COALESCE(SUM(l.#{credit} - l.#{debit}), 0)
      FROM #{line_table} l
      JOIN #{entry_table} e
        ON e.#{entry_id} = l.#{line_entry}
       AND e.#{entry_org} = l.#{line_org}
      JOIN #{account_table} a
        ON a.#{account_id} = l.#{line_account}
       AND a.#{account_org} = l.#{line_org}
      WHERE e.#{entry_org} = $1
        AND e.#{entry_status} = 'posted'
        AND a.#{account_kind} = 'income'
        AND EXISTS (
          SELECT 1 FROM jsonb_each_text(l.#{dims}) d WHERE d.value = $2
        )
      """,
      [dump_uuid(grant.org_id), to_string(grant.fund_cost_object_id)]
    )
  end

  defp sum_dimensioned_account(grant, repo, mods, account_id) do
    line_table = table(mods.line)
    entry_table = table(mods.entry)
    entry_id = attr(mods.entry, :id)
    entry_org = attr(mods.entry, :org_id)
    entry_status = attr(mods.entry, :status)
    line_entry = belongs_to_attr(mods.line, mods.entry, :entry)
    account_fk = belongs_to_attr(mods.line, mods.account, :account)
    line_org = attr(mods.line, :org_id)
    debit = attr(mods.line, :debit_cents)
    credit = attr(mods.line, :credit_cents)
    dims = attr(mods.line, :dimension_refs)

    scalar(
      repo,
      """
      SELECT COALESCE(SUM(l.#{credit} - l.#{debit}), 0)
      FROM #{line_table} l
      JOIN #{entry_table} e
        ON e.#{entry_id} = l.#{line_entry}
       AND e.#{entry_org} = l.#{line_org}
      WHERE e.#{entry_org} = $1
        AND e.#{entry_status} = 'posted'
        AND l.#{account_fk} = $2
        AND EXISTS (
          SELECT 1 FROM jsonb_each_text(l.#{dims}) d WHERE d.value = $3
        )
      """,
      [dump_uuid(grant.org_id), dump_uuid(account_id), to_string(grant.fund_cost_object_id)]
    )
  end

  defp scalar(repo, sql, params) do
    case repo.query(sql, params) do
      {:ok, %{rows: [[value]]}} -> to_i(value)
      {:error, _reason} -> 0
    end
  end

  defp posting_account(pa_mod, org_id, key) do
    pa_mod
    |> Ash.Query.filter(org_id == ^org_id and key == ^key)
    |> Ash.read_one(authorize?: false)
  end

  # The person is read below the scope (the id came from this org's personnel
  # row) and then checked against the grant's org. A foreign or explicitly
  # deleted record cannot contribute a name.
  defp fetch_person(resource, employee_id, org_id, name_attribute) do
    case resource
         |> Ash.Query.filter(id == ^employee_id)
         |> Ash.Query.ensure_selected([:org_id, name_attribute])
         |> Ash.read_one(authorize?: false) do
      {:ok, %{org_id: ^org_id} = person} -> person
      _ -> nil
    end
  end

  defp maybe_issue(issues, issue, true), do: issues ++ [issue]
  defp maybe_issue(issues, _issue, false), do: issues

  defp shift(%Date{year: year, month: month}, offset) do
    total = year * 12 + (month - 1) + offset
    {div(total, 12), rem(total, 12) + 1}
  end

  defp table(resource), do: AshPostgres.DataLayer.Info.table(resource)

  defp attr(resource, name) do
    case Ash.Resource.Info.attribute(resource, name) do
      nil -> raise ArgumentError, "no attribute #{inspect(name)} on #{inspect(resource)}"
      attr -> to_string(attr.source || attr.name)
    end
  end

  defp belongs_to_attr(resource, destination, label) do
    resource
    |> Ash.Resource.Info.relationships()
    |> Enum.find(&(&1.type == :belongs_to and &1.destination == destination))
    |> case do
      nil ->
        raise ArgumentError,
              "no belongs_to #{inspect(label)} from #{inspect(resource)} to #{inspect(destination)}"

      rel ->
        to_string(
          Ash.Resource.Info.attribute(resource, rel.source_attribute).source ||
            rel.source_attribute
        )
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

  defp to_i(bin) when is_binary(bin) do
    case Integer.parse(bin) do
      {value, ""} -> value
      _ -> 0
    end
  end

  defp to_i(_), do: 0
end
