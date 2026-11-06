defmodule Samen.Scopes.Finance.ReportColumns do
  @moduledoc """
  Physical-name resolution for the Finance scope's raw-SQL statement reads
  (WS-ACCT Phase 12).

  `TrialBalance`/`BalanceSheet`/`ProfitLoss` read with SQL because a grouped
  balance is the database's job, but their column names must be the ones that
  actually exist. A host's `Samen.Resource` transformer abbrev-prefixes every
  column (`org_id` → `ecl_org_id`, `account_id` → `ecl_account_id`), so a
  hardcoded `l.account_id` parses in a fixture with unprefixed columns and
  fails on a real host table — and a report that cannot read is worse than no
  report, because the close would sign against it.

  `column/2` reads the resource's own attribute metadata (`attr.source`) — the
  same storage names `Samen.Catalog.fields/1` writes into `fld_field`. It
  raises for an unknown attribute: a report asking for a column the resource
  does not have is a programming error, not a row-level condition, and silence
  would produce a wrongly-empty statement.

  Identifiers come from resource metadata, never from user input.
  """

  @doc "The resource's physical table name."
  @spec table(module()) :: String.t()
  def table(resource), do: AshPostgres.DataLayer.Info.table(resource)

  @doc "The physical column for a logical attribute, quoted for SQL."
  @spec column(module(), atom()) :: String.t()
  def column(resource, attribute) do
    case Ash.Resource.Info.attribute(resource, attribute) do
      nil ->
        raise ArgumentError,
              "#{inspect(resource)} has no attribute #{inspect(attribute)}; " <>
                "the statement read cannot be built against it"

      %{source: source, name: name} ->
        quote_name(to_string(source || name))
    end
  end

  defp quote_name(name), do: "\"" <> String.replace(name, "\"", "\"\"") <> "\""
end
