defmodule Samen.Scopes.Finance.LeaseRegister do
  @moduledoc """
  The derived lease register: every lease, its contract, the payments that
  actually posted, and the liability/ROU balances that follow from the two.

  Nothing here is stored except the `Lease` row and its `LeasePayment` facts.
  The schedule is re-derived (`LeaseSchedule.slices/1`), posted amounts are
  Σ payments, and the remaining liability/ROU are the contract minus those
  facts. There is no stored balance to drift.

  Per lease the read answers:

    * `schedule` — every month, with `paid?` and the payment id;
    * `initial_liability_cents` / `initial_rou_cents`;
    * `liability_cents` / `rou_net_cents` — what remains after the posted
      principal and amortization;
    * `next_open_period` — the first unpaid month, or nil when complete;
    * `fully_paid?` — every month has a payment fact.
  """

  require Ash.Query

  alias Samen.Scopes.Finance.LeaseSchedule

  @doc """
  The register for one org.

  Opts (required): `:lease`, `:payment`.

  Returns `%{org_id:, leases: [...], totals: %{...}}`; a bare org yields empty
  lists and zero totals, not an error.
  """
  def for_org(org_id, opts) do
    lease_mod = Keyword.fetch!(opts, :lease)
    payment_mod = Keyword.fetch!(opts, :payment)

    leases =
      lease_mod
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.Query.sort(code: :asc)
      |> Ash.read!(authorize?: false)

    payments =
      payment_mod
      |> Ash.Query.filter(org_id == ^org_id)
      |> Ash.read!(authorize?: false)

    by_lease = Enum.group_by(payments, & &1.lease_id)

    rows =
      Enum.map(leases, fn lease ->
        row(lease, Map.get(by_lease, lease.id, []))
      end)

    %{
      org_id: org_id,
      leases: rows,
      totals: totals(rows, length(payments))
    }
  end

  defp row(lease, payments) do
    schedule = LeaseSchedule.slices(lease)
    by_key = Map.new(payments, &{&1.period_key, &1})
    initial = LeaseSchedule.initial_liability(lease)

    paid_principal = Enum.reduce(payments, 0, &(&1.principal_cents + &2))
    paid_amortization = Enum.reduce(payments, 0, &(&1.amortization_cents + &2))
    paid_cash = Enum.reduce(payments, 0, &(&1.payment_cents + &2))
    paid_interest = Enum.reduce(payments, 0, &(&1.interest_cents + &2))

    months =
      Enum.map(schedule, fn slice ->
        payment = Map.get(by_key, slice.period_key)

        slice
        |> Map.put(:paid?, not is_nil(payment))
        |> Map.put(:payment_id, payment && payment.id)
      end)

    next_open = Enum.find(months, fn slice -> not slice.paid? end)

    %{
      lease: lease,
      code: lease.code,
      name: lease.name,
      kind: lease.kind,
      start_on: lease.start_on,
      months: lease.months,
      payment_cents: lease.payment_cents,
      annual_rate_bps: lease.annual_rate_bps,
      initial_liability_cents: initial,
      initial_rou_cents: initial,
      paid_cents: paid_cash,
      interest_cents: paid_interest,
      principal_cents: paid_principal,
      amortization_cents: paid_amortization,
      liability_cents: max(initial - paid_principal, 0),
      rou_net_cents: max(initial - paid_amortization, 0),
      fully_paid?: Enum.all?(months, & &1.paid?),
      next_open_period: next_open && next_open.period_key,
      paid_months: map_size(by_key),
      schedule: months
    }
  end

  defp totals(rows, payment_count) do
    %{
      leases: length(rows),
      payments: payment_count,
      initial_liability_cents: Enum.sum(Enum.map(rows, & &1.initial_liability_cents)),
      liability_cents: Enum.sum(Enum.map(rows, & &1.liability_cents)),
      rou_net_cents: Enum.sum(Enum.map(rows, & &1.rou_net_cents)),
      paid_cents: Enum.sum(Enum.map(rows, & &1.paid_cents)),
      interest_cents: Enum.sum(Enum.map(rows, & &1.interest_cents)),
      amortization_cents: Enum.sum(Enum.map(rows, & &1.amortization_cents))
    }
  end
end
