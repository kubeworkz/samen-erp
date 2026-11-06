defmodule Samen.Scopes.Finance.ForecastDriverWriter do
  @moduledoc """
  Materializes the `drivers` argument of a `ForecastVersion` create into
  `ForecastDriver` rows (WS-ACCT Phase 14; ADR-054 D11).

  The version is the aggregate root: a create that names drivers either lands
  all of them or rolls back the whole version. A half-written forecast is
  worse than a refused one because the reads would present it as complete.

  The writer accepts only the driver's own public fields; `category` is
  derived by `ForecastDriverGuard`, never accepted from this argument.
  """

  use Ash.Resource.Change

  @fields [:driver, :scenario, :period_on, :amount_cents, :memo]

  @impl true
  def change(changeset, opts, _context) do
    driver_mod = Keyword.fetch!(opts, :driver)

    Ash.Changeset.after_action(changeset, fn changeset, version ->
      drivers = Ash.Changeset.get_argument(changeset, :drivers) || []
      org_id = Ash.Changeset.get_attribute(changeset, :org_id)

      rows =
        Enum.map(drivers, fn driver ->
          attrs =
            Map.new(@fields, fn field -> {field, fetch(driver, field)} end)
            |> Map.reject(fn {_key, value} -> is_nil(value) end)

          Map.merge(attrs, %{
            org_id: org_id,
            version_id: version.id,
            category: Samen.Scopes.Finance.ForecastDriverGuard.category(fetch(driver, :driver))
          })
        end)

      case bulk_insert(driver_mod, rows) do
        :ok ->
          {:ok, version}

        {:error, reason} ->
          {:error,
           Ash.Error.Changes.InvalidAttribute.exception(
             field: :drivers,
             message: "the forecast drivers failed to land: #{inspect(reason)}",
             value: nil
           )}
      end
    end)
  end

  defp fetch(map, key) when is_map(map) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, to_string(key))
    end
  end

  defp bulk_insert(_driver_mod, []), do: :ok

  defp bulk_insert(driver_mod, rows) do
    Ash.bulk_create(rows, driver_mod, :system_create,
      authorize?: false,
      return_errors?: true,
      return_records?: false,
      stop_on_error?: true
    )
    |> case do
      %Ash.BulkResult{status: :success} -> :ok
      %Ash.BulkResult{status: :error, errors: errors} -> {:error, errors}
    end
  end
end
