defmodule Samen.Scopes.Finance.LeasePaymentRun do
  @moduledoc """
  The monthly lease payment RUN: for one fiscal month, post every active
  lease's derived payment through the ordinary governed `:pay` action.

  ## Exactly once

    * the run's `already_paid?/3` read makes a repeated sweep a clean no-op;
    * the payment table's unique index on `{org, lease, period}` is the belt
      for a racing or regressed caller.

  A period outside the lease term posts nothing. The run never backfills a
  missed month: a skipped period stays visible as `next_open_period` in
  `LeaseRegister`.

  ## Host seam

      config :samen_core, Samen.Scopes.Finance.LeasePaymentRun,
        modules: [
          lease: Samenerp.Erp.Lease,
          payment: Samenerp.Erp.LeasePayment
        ]

  An unconfigured host is a NO-OP that names itself (`:not_configured`), not a
  silent success.
  """

  require Ash.Query

  alias Samen.Scopes.Finance.LeaseSchedule

  @config_key __MODULE__

  @doc "The host's wired lease modules, or nil when the host has not wired them."
  def modules do
    case :samen_core |> Application.get_env(@config_key, []) |> Keyword.get(:modules) do
      nil -> nil
      modules -> Map.new(modules)
    end
  end

  @doc """
  Run the lease sweep for one month. Returns
  `{:ok, %{period: "YYYY-MM", posted: [...], skipped: [{lease_id, reason}]}}`,
  or `{:error, {:lease_payment_failed, [...]}}` naming every lease whose
  payment refused.
  """
  def run(opts \\ []) do
    period =
      Keyword.get_lazy(opts, :period, fn -> LeaseSchedule.previous_month(Date.utc_today()) end)

    key = LeaseSchedule.period_key(period)

    case modules() do
      nil ->
        {:ok, %{period: key, posted: [], skipped: [], state: :not_configured}}

      mods ->
        sweep(mods, period, key)
    end
  end

  defp sweep(mods, period, key) do
    leases =
      mods.lease
      |> Ash.Query.ensure_selected([:org_id])
      |> Ash.Query.sort(start_on: :asc)
      # authz-scope: system sweep — every org's due lease is considered, and each
      # payment's own governed action decides whether it may land.
      |> Ash.read!(authorize?: false)

    results =
      Enum.map(leases, fn lease ->
        case plan(lease, period, key, mods) do
          {:post, paid_on} -> post(mods, lease, key, paid_on)
          {:skip, reason} -> {:skip, {lease.id, reason}}
        end
      end)

    posted = for {:posted, id} <- results, do: id
    skipped = for {:skip, entry} <- results, do: entry
    failed = for {:error, failure} <- results, do: failure

    if failed == [] do
      {:ok, %{period: key, posted: posted, skipped: skipped}}
    else
      {:error, {:lease_payment_failed, failed}}
    end
  end

  defp plan(lease, period, key, mods) do
    case LeaseSchedule.slice(lease, key) do
      :outside_term ->
        {:skip, :outside_term}

      {:error, :bad_period} ->
        {:skip, :bad_period}

      {:ok, _row} ->
        if already_paid?(mods.payment, lease, key) do
          {:skip, :already_paid}
        else
          {:post, LeaseSchedule.period_end(period)}
        end
    end
  end

  defp post(mods, lease, key, paid_on) do
    mods.payment
    |> Ash.Changeset.for_create(
      :pay,
      %{
        org_id: lease.org_id,
        lease_id: lease.id,
        period_key: key,
        paid_on: paid_on
      },
      authorize?: false
    )
    |> Ash.create(authorize?: false)
    |> case do
      {:ok, payment} -> {:posted, payment.id}
      {:error, reason} -> {:error, {lease.id, reason}}
    end
  end

  defp already_paid?(payment_mod, lease, key) do
    payment_mod
    |> Ash.Query.filter(org_id == ^lease.org_id and lease_id == ^lease.id and period_key == ^key)
    |> Ash.read_one(authorize?: false)
    |> case do
      {:ok, nil} -> false
      {:ok, _row} -> true
      {:error, _reason} -> false
    end
  end
end
