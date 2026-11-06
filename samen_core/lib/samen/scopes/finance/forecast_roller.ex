defmodule Samen.Scopes.Finance.ForecastRoller do
  @moduledoc """
  The append-only roll for a `ForecastVersion` (WS-ACCT Phase 14; ADR-054 D11).

  `:roll` is a CREATE action, not an update. It loads one published version,
  writes a new draft with the next `version` number, copies every driver, and
  returns the new row. The source is never written — not its name, dates,
  weights, status, timestamp or drivers — so "rolling appends" is true at the
  database-write level, not merely in the API's intent.

  Only a published version can be rolled. A draft is still being authored; an
  archived draft was abandoned and is not a baseline. The new version starts
  in `:draft`, so the next publication is an explicit act rather than a
  side-effect of copying.
  """

  use Ash.Resource.Change

  require Ash.Query

  @impl true
  def change(changeset, opts, _context) do
    driver_mod = Keyword.fetch!(opts, :driver)
    source_id = Ash.Changeset.get_argument(changeset, :source_version_id)
    org_id = Ash.Changeset.get_attribute(changeset, :org_id)

    case load_source(changeset.resource, source_id, org_id) do
      {:ok, source} ->
        changeset
        |> check_status(source)
        |> copy_attrs(source)
        |> copy_drivers_after(source, driver_mod)

      {:error, message} ->
        Ash.Changeset.add_error(changeset, field: :source_version_id, message: message)
    end
  end

  defp load_source(_version_mod, nil, _org_id), do: {:error, "source_version_id is required"}

  defp load_source(version_mod, source_id, org_id) do
    case version_mod
         |> Ash.Query.filter(id == ^source_id and org_id == ^org_id)
         |> Ash.Query.select([
           :id,
           :name,
           :version,
           :status,
           :starts_on,
           :ends_on,
           :scenario_weights
         ])
         |> Ash.read_one(authorize?: false) do
      {:ok, %{} = source} -> {:ok, source}
      {:ok, nil} -> {:error, "source forecast version #{inspect(source_id)} was not found"}
      {:error, _} -> {:error, "source forecast version #{inspect(source_id)} was not found"}
    end
  end

  defp check_status(changeset, source) do
    if source.status == :published do
      changeset
    else
      Ash.Changeset.add_error(changeset,
        field: :source_version_id,
        message:
          "only a PUBLISHED forecast version can be rolled (this one is #{source.status}); " <>
            "publish the baseline first so the append starts from a signed version"
      )
    end
  end

  defp copy_attrs(changeset, source) do
    changeset
    |> Ash.Changeset.force_change_attribute(:name, source.name)
    |> Ash.Changeset.force_change_attribute(:version, source.version + 1)
    |> Ash.Changeset.force_change_attribute(:starts_on, source.starts_on)
    |> Ash.Changeset.force_change_attribute(:ends_on, source.ends_on)
    |> Ash.Changeset.force_change_attribute(:scenario_weights, source.scenario_weights)
    |> Ash.Changeset.force_change_attribute(:source_version_id, source.id)
    |> Ash.Changeset.force_change_attribute(:status, :draft)
    |> Ash.Changeset.force_change_attribute(:published_at, nil)
  end

  defp copy_drivers_after(changeset, source, driver_mod) do
    Ash.Changeset.after_action(changeset, fn changeset, version ->
      org_id = Ash.Changeset.get_attribute(changeset, :org_id)

      rows =
        source
        |> drivers(driver_mod)
        |> Enum.map(fn driver ->
          %{
            org_id: org_id,
            version_id: version.id,
            driver: driver.driver,
            scenario: driver.scenario,
            category: driver.category,
            period_on: driver.period_on,
            amount_cents: driver.amount_cents,
            memo: driver.memo
          }
        end)

      case bulk_insert(driver_mod, rows) do
        :ok ->
          {:ok, version}

        {:error, reason} ->
          {:error,
           Ash.Error.Changes.InvalidAttribute.exception(
             field: :source_version_id,
             message: "the rolled forecast's drivers failed to copy: #{inspect(reason)}",
             value: source.id
           )}
      end
    end)
  end

  defp drivers(source, driver_mod) do
    driver_mod
    |> Ash.Query.filter(version_id == ^source.id)
    |> Ash.read!(authorize?: false)
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
