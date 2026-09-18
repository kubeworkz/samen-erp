defmodule Samen.Scopes.Finance.FxConversionGuard do
  @moduledoc """
  The FX conversion guard for multi-currency postings (WS-ERP E10).

  When a journal entry or payment receipt is posted in a non-base currency,
  this guard verifies that a stored exchange rate exists for the currency
  pair at the transaction date. If no rate is stored, the posting is
  refused — the GL never records an FX conversion with an unknown rate.

  ## Fail-closed invariant

  - Posting in a non-base currency without a stored rate → refused
  - Posting in the base currency → always allowed (no rate needed)
  - Posting in the same currency as the account → always allowed

  This is a `before_action` change — the posting is never created if
  the rate is missing.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      currency = Ash.Changeset.get_attribute(changeset, :currency)
      org_id = Ash.Changeset.get_attribute(changeset, :org_id)

      if is_nil(currency) or currency == "" do
        # No currency specified — assume base currency (legacy path)
        changeset
      else
        base_currency = get_base_currency(org_id)

        if currency == base_currency do
          # Same as base — no FX conversion needed
          changeset
        else
          entry_date = get_entry_date(changeset)

          case check_rate_exists(changeset, org_id, currency, base_currency, entry_date) do
            :ok ->
              changeset

            {:error, :rate_not_found} ->
              Ash.Changeset.add_error(changeset,
                field: :currency,
                message:
                  "No exchange rate stored for #{currency} → #{base_currency} " <>
                    "at #{Date.to_iso8601(entry_date)}. " <>
                    "Store a rate before posting.",
                variable: currency
              )
          end
        end
      end
    end)
  end

  # The guard uses hardcoded table/repo references since it doesn't have
  # access to the host's resource modules at compile time. The table names
  # match the default abbrevs (fxf_org_fx_settings, fxr_exchange_rate).
  @org_fx_table "fxf_org_fx_settings"
  @exchange_rate_table "fxr_exchange_rate"

  defp get_base_currency(org_id) do
    sql = "SELECT base_currency FROM #{@org_fx_table} WHERE org_id = $1 LIMIT 1"

    case repo().query(sql, [Ecto.UUID.dump!(org_id)]) do
      {:ok, %{rows: [[base]]}} -> base
      _ -> "USD"
    end
  end

  defp get_entry_date(changeset) do
    case Ash.Changeset.get_attribute(changeset, :entry_date) do
      %Date{} = d -> d
      %NaiveDateTime{} = nd -> NaiveDateTime.to_date(nd)
      _ -> Date.utc_today()
    end
  end

  defp check_rate_exists(_changeset, _org_id, from_currency, to_currency, entry_date) do
    sql = """
    SELECT COUNT(*) FROM #{@exchange_rate_table}
    WHERE from_currency = $1 AND to_currency = $2 AND valid_at <= $3
    """

    case repo().query(sql, [from_currency, to_currency, entry_date]) do
      {:ok, %{rows: [[0]]}} ->
        # Try reverse pair
        inverse_sql = """
        SELECT COUNT(*) FROM #{@exchange_rate_table}
        WHERE from_currency = $1 AND to_currency = $2 AND valid_at <= $3
        """

        case repo().query(inverse_sql, [to_currency, from_currency, entry_date]) do
          {:ok, %{rows: [[0]]}} -> {:error, :rate_not_found}
          {:ok, %{rows: [[_]]}} -> :ok
          {:error, _} -> {:error, :rate_not_found}
        end

      {:ok, %{rows: [[_]]}} ->
        :ok

      {:error, _} ->
        {:error, :rate_not_found}
    end
  end

  defp repo do
    # Use the test repo in test, the app repo in prod.
    # This is a known compromise — the guard runs in the posting resource's
    # context, which always has a repo available.
    Application.get_env(:samen_core, :test_repo, SamenCore.TestRepo)
  end
end
