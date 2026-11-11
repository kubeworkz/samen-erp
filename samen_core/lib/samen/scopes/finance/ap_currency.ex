defmodule Samen.Scopes.Finance.ApCurrency do
  @moduledoc """
  Resolves an AP bill's currency on create/update.

  A blank currency defaults to the org's functional currency from
  `OrgFxSettings` (USD when no settings row exists). An explicit code must be
  a three-letter ISO-4217 code; invalid input is refused rather than silently
  coerced.
  """

  use Ash.Resource.Change

  alias Samen.Scopes.Finance.ApFx

  @impl true
  def change(changeset, opts, _context) do
    settings = Keyword.fetch!(opts, :org_fx_settings)
    org_id = org_id(changeset)
    current = Ash.Changeset.get_attribute(changeset, :currency)
    base = ApFx.base_currency(settings, org_id)

    currency =
      cond do
        blank?(current) -> base
        true -> ApFx.normalize_currency(current)
      end

    case currency do
      nil ->
        Ash.Changeset.add_error(changeset,
          field: :currency,
          message: "currency must be a three-letter ISO 4217 code"
        )

      code ->
        Ash.Changeset.force_change_attribute(changeset, :currency, code)
    end
  end

  defp org_id(changeset) do
    case Ash.Changeset.get_attribute(changeset, :org_id) do
      %Ash.NotLoaded{} -> Map.get(changeset.data, :org_id)
      value -> value
    end
  end

  defp blank?(nil), do: true
  defp blank?(value) when is_binary(value), do: String.trim(value) == ""
  defp blank?(_value), do: false
end
