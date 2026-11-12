defmodule Samen.Scopes.Finance.ReconcileRecognition do
  @moduledoc """
  The R9 reconciliation read (WS-ACCT Phase 6; ADR-054 design §3): a schedule's
  released revenue against the GL it actually landed in.

  Two numbers, computed by bare SQL from tables that share only the org id —
  never one from the other:

    * `recognized_cents` — Σ the schedule's recognition rows (the subledger's
      claim about what it released);
    * `released_cents` — Σ `debit − credit` on the schedule's DEFERRED account
      over the POSTED entries anchored to those same recognitions (the GL's
      record of the release).

  R9 says they are equal, for every schedule, always. `remaining_cents` is the
  other half of the invariant: `total − recognized` may reach zero but never go
  negative — a schedule cannot release more revenue than the contract holds,
  and recognizing ahead of cost (the `:cost_incurred` failure mode) shows up
  here as a negative remainder even when the two sums agree.

  ## Why the GL side joins through the anchor

  Each recognition posts exactly one entry anchored
  `source_key: "revenue_recognition"`, `source_id: <recognition id>`. The read
  joins entry → recognition → schedule through that anchor and restricts the
  lines to the schedule's deferred account. A recognition whose entry was never
  posted (a raw-SQL row, a half-cascade) has no GL leg and is reported as a
  divergence rather than quietly counted — the same anti-tautology posture
  `ReconcilePayments` takes for R2.

  `divergences/3` names the schedule and both numbers; `reconciled?/3` is the
  verdict.
  """

  @source_key "revenue_recognition"

  @doc """
  One row per schedule of the org:

      %{schedule_id:, total_cents:, recognized_cents:, released_cents:,
        remaining_cents:, reconciled?:}

  Opts: `:schedule_resource`, `:recognition_resource`, `:entry_resource`,
  `:line_resource`, `:posting_account_resource` (required).
  """
  def schedule_states(org_id, repo, opts) do
    ctx = Map.new(opts)

    case repo.query(sql(ctx), [dump_uuid(org_id)]) do
      {:ok, %{rows: rows}} ->
        {:ok, Enum.map(rows, &row_to_state/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc "Schedules whose recognized ≠ released, or whose remainder went negative."
  def divergences(org_id, repo, opts) do
    with {:ok, states} <- schedule_states(org_id, repo, opts) do
      {:ok, Enum.reject(states, & &1.reconciled?)}
    end
  end

  @doc "True when every schedule reconciles (the org-wide R9 verdict)."
  def reconciled?(org_id, repo, opts) do
    case divergences(org_id, repo, opts) do
      {:ok, []} -> {:ok, true}
      {:ok, rows} -> {:ok, false, rows}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "Σ across the org's schedules: the numbers both legs must preserve."
  def org_totals(org_id, repo, opts) do
    with {:ok, states} <- schedule_states(org_id, repo, opts) do
      {:ok,
       %{
         total_cents: Enum.sum(Enum.map(states, & &1.total_cents)),
         recognized_cents: Enum.sum(Enum.map(states, & &1.recognized_cents)),
         released_cents: Enum.sum(Enum.map(states, & &1.released_cents)),
         remaining_cents: Enum.sum(Enum.map(states, & &1.remaining_cents))
       }}
    end
  end

  # ── SQL ────────────────────────────────────────────────────────────────────

  defp sql(ctx) do
    schedule_table = table(ctx.schedule_resource)
    recognition_table = table(ctx.recognition_resource)
    entry_table = table(ctx.entry_resource)
    line_table = table(ctx.line_resource)
    pa_table = table(ctx.posting_account_resource)

    s_id = attr(ctx.schedule_resource, :id)
    s_org = attr(ctx.schedule_resource, :org_id)
    s_total = attr(ctx.schedule_resource, :total_cents)
    s_key = attr(ctx.schedule_resource, :deferred_key)

    r_id = attr(ctx.recognition_resource, :id)
    r_org = attr(ctx.recognition_resource, :org_id)
    r_amount = attr(ctx.recognition_resource, :amount_cents)
    r_schedule = attr(ctx.recognition_resource, :schedule_id)

    e_id = attr(ctx.entry_resource, :id)
    e_org = attr(ctx.entry_resource, :org_id)
    e_status = attr(ctx.entry_resource, :status)
    e_skey = attr(ctx.entry_resource, :source_key)
    e_source = attr(ctx.entry_resource, :source_id)

    l_entry = attr(ctx.line_resource, :entry_id)
    l_org = attr(ctx.line_resource, :org_id)
    l_account = attr(ctx.line_resource, :account_id)
    l_debit = attr(ctx.line_resource, :debit_cents)
    l_credit = attr(ctx.line_resource, :credit_cents)

    pa_org = attr(ctx.posting_account_resource, :org_id)
    pa_key = attr(ctx.posting_account_resource, :key)
    pa_account = attr(ctx.posting_account_resource, :account_id)

    """
    SELECT s.#{s_id},
           s.#{s_total},
           COALESCE((
             SELECT SUM(r.#{r_amount})
             FROM #{recognition_table} r
             WHERE r.#{r_schedule} = s.#{s_id}
           ), 0) AS recognized,
           COALESCE((
             SELECT SUM(l.#{l_debit} - l.#{l_credit})
             FROM #{line_table} l
             JOIN #{entry_table} e
               ON e.#{e_id} = l.#{l_entry}
              AND e.#{e_org} = l.#{l_org}
             JOIN #{recognition_table} r
               ON r.#{r_id} = e.#{e_source}
              AND r.#{r_org} = s.#{s_org}
             JOIN #{pa_table} pa
               ON pa.#{pa_org} = s.#{s_org}
              AND pa.#{pa_key} = s.#{s_key}
              AND pa.#{pa_account} = l.#{l_account}
             WHERE r.#{r_schedule} = s.#{s_id}
               AND e.#{e_org} = s.#{s_org}
               AND e.#{e_status} = 'posted'
               AND e.#{e_skey} = '#{@source_key}'
               AND l.#{l_org} = s.#{s_org}
           ), 0) AS released
    FROM #{schedule_table} s
    WHERE s.#{s_org} = $1
    ORDER BY s.#{s_id}
    """
  end

  defp row_to_state([schedule_id, total, recognized, released]) do
    recognized = to_i(recognized)
    released = to_i(released)
    remaining = to_i(total) - recognized

    %{
      schedule_id: uuid_to_string(schedule_id),
      total_cents: to_i(total),
      recognized_cents: recognized,
      released_cents: released,
      remaining_cents: remaining,
      reconciled?: recognized == released and remaining >= 0
    }
  end

  # ── helpers ────────────────────────────────────────────────────────────────

  defp table(resource), do: AshPostgres.DataLayer.Info.table(resource)

  defp attr(resource, name) do
    case Ash.Resource.Info.attribute(resource, name) do
      nil -> raise ArgumentError, "no attribute #{inspect(name)} on #{inspect(resource)}"
      attribute -> to_string(attribute.source || attribute.name)
    end
  end

  defp dump_uuid(value) when is_binary(value) and byte_size(value) == 16, do: value

  defp dump_uuid(value) do
    case Ecto.UUID.dump(value) do
      {:ok, bin} -> bin
      :error -> value
    end
  end

  # `repo.query/2` returns uuid columns as 16-byte binaries; the read's callers
  # (and the schedule ids they hold) speak the canonical string form.
  defp uuid_to_string(<<_::128>> = bin), do: Ecto.UUID.load!(bin)
  defp uuid_to_string(value), do: value

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
