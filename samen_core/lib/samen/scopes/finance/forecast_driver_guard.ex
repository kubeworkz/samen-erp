defmodule Samen.Scopes.Finance.ForecastDriverGuard do
  @moduledoc """
  The shape guard for a `ForecastDriver` (WS-ACCT Phase 14; ADR-054 D11).

  A driver row is only meaningful inside a DRAFT version: adding a driver to a
  published forecast would mutate the fact a reader already used, so it is
  refused. The row's `category` is derived here from the closed driver enum
  instead of accepted from the caller; that is what keeps "EDA spend" from
  being silently filed as revenue.

  The driver tree is the doc's bounded set. The mapping is deliberately
  fixed:

    * `slot_price` → revenue
    * `die_yield` → cogs
    * `eda_spend`, `headcount` → operating expense
    * `burn` → cash out
    * `grant_pipeline` → cash in

  No formula evaluator: the row carries the driver's monetary impact for the
  month, and the reads roll the categories up. A driver period must be the
  first day of a month and inside the version's date range, so a read can
  group without guessing which day was meant.
  """

  use Ash.Resource.Change

  @categories %{
    slot_price: :revenue,
    die_yield: :cogs,
    eda_spend: :operating_expense,
    headcount: :operating_expense,
    burn: :cash_out,
    grant_pipeline: :cash_in
  }

  @doc false
  def category(driver), do: Map.get(@categories, driver)

  @impl true
  def change(changeset, opts, _context) do
    version_mod = Keyword.fetch!(opts, :version)
    version_id = Ash.Changeset.get_attribute(changeset, :version_id)
    org_id = Ash.Changeset.get_attribute(changeset, :org_id)
    driver = Ash.Changeset.get_attribute(changeset, :driver)
    period_on = Ash.Changeset.get_attribute(changeset, :period_on)
    amount_cents = Ash.Changeset.get_attribute(changeset, :amount_cents)

    case load_version(version_mod, version_id, org_id) do
      {:ok, version} ->
        changeset
        |> check_status(version)
        |> check_period(version, period_on)
        |> check_amount(amount_cents)
        |> set_category(driver)

      {:error, message} ->
        Ash.Changeset.add_error(changeset, field: :version_id, message: message)
    end
  end

  defp load_version(_version_mod, nil, _org_id), do: {:error, "version_id is required"}

  defp load_version(version_mod, version_id, org_id) do
    case version_mod
         |> Ash.Query.filter(id == ^version_id and org_id == ^org_id)
         |> Ash.Query.select([:status, :starts_on, :ends_on, :scenario_weights])
         |> Ash.read_one(authorize?: false) do
      {:ok, %{} = version} -> {:ok, version}
      {:ok, nil} -> {:error, "forecast version #{inspect(version_id)} was not found"}
      {:error, _} -> {:error, "forecast version #{inspect(version_id)} was not found"}
    end
  end

  defp check_status(changeset, version) do
    if version.status == :draft do
      changeset
    else
      Ash.Changeset.add_error(changeset,
        field: :version_id,
        message:
          "this forecast version is #{version.status} — a published version is immutable, " <>
            "so its drivers cannot be added or changed. Roll a new version instead."
      )
    end
  end

  defp check_period(changeset, version, %Date{} = period_on) do
    cond do
      Date.compare(period_on, Date.beginning_of_month(period_on)) != :eq ->
        period_error(changeset, "period_on must be the first day of a month")

      Date.compare(period_on, version.starts_on) == :lt or
          Date.compare(period_on, version.ends_on) == :gt ->
        period_error(
          changeset,
          "period_on must fall inside the forecast version's range " <>
            "(#{version.starts_on}..#{version.ends_on})"
        )

      true ->
        changeset
    end
  end

  defp check_period(changeset, _version, _period_on) do
    period_error(changeset, "period_on must be a date")
  end

  defp period_error(changeset, message) do
    Ash.Changeset.add_error(changeset, field: :period_on, message: message)
  end

  defp check_amount(changeset, amount) when is_integer(amount) and amount >= 0, do: changeset

  defp check_amount(changeset, _amount) do
    Ash.Changeset.add_error(changeset,
      field: :amount_cents,
      message: "a forecast driver amount must be a non-negative integer number of cents"
    )
  end

  defp set_category(changeset, driver) do
    case category(driver) do
      nil ->
        Ash.Changeset.add_error(changeset,
          field: :driver,
          message:
            "unknown forecast driver #{inspect(driver)} — the bounded tree is " <>
              "slot_price, die_yield, eda_spend, headcount, burn and grant_pipeline"
        )

      category ->
        Ash.Changeset.force_change_attribute(changeset, :category, category)
    end
  end
end
