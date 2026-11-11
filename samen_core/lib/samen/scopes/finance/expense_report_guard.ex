defmodule Samen.Scopes.Finance.ExpenseReportGuard do
  @moduledoc """
  Validates an `ExpenseReport`'s embedded lines against the org's categories
  and corporate cards and stamps the derived total. The guard is attached to
  create/update and again to submit/approve so a stale draft cannot be
  submitted after a category/card policy change.
  """

  use Ash.Resource.Change

  alias Samen.Scopes.Finance.{ApFx, ExpenseLines}

  @impl true
  def change(changeset, opts, _context) do
    category_resource = Keyword.fetch!(opts, :category)
    card_resource = Keyword.fetch!(opts, :card)
    require_lines? = Keyword.get(opts, :require_lines, false)
    org_fx_settings = Keyword.get(opts, :org_fx_settings)
    org_id = org_id(changeset)
    lines = current_attribute(changeset, :lines, [])
    currency = current_attribute(changeset, :currency, nil)
    base_currency = ApFx.base_currency(org_fx_settings, org_id)

    case ExpenseLines.validate(
           lines,
           currency,
           org_id,
           category_resource,
           card_resource,
           require_lines: require_lines?
         ) do
      {:ok, %{total_cents: total_cents, currency: ^base_currency}} ->
        Ash.Changeset.force_change_attribute(changeset, :total_cents, total_cents)

      {:ok, %{currency: normalized_currency}} ->
        Ash.Changeset.add_error(changeset,
          field: :currency,
          message:
            "expense reports are posted in the org functional currency (#{base_currency}); " <>
              "#{normalized_currency} needs a converted claim, which this slice does not support"
        )

      {:error, message} ->
        Ash.Changeset.add_error(changeset, field: :lines, message: message)
    end
  end

  defp org_id(changeset) do
    case Ash.Changeset.get_attribute(changeset, :org_id) do
      %Ash.NotLoaded{} -> data_org_id(changeset.data)
      nil -> data_org_id(changeset.data)
      value -> value
    end
  end

  defp data_org_id(data) do
    case Map.get(data, :org_id) do
      %Ash.NotLoaded{} -> Ash.load!(data, [:org_id], authorize?: false).org_id
      nil -> nil
      value -> value
    end
  end

  defp current_attribute(changeset, field, default) do
    case Ash.Changeset.get_attribute(changeset, field) do
      nil -> Map.get(changeset.data, field, default)
      %Ash.NotLoaded{} -> Map.get(changeset.data, field, default)
      value -> value
    end
  end
end
