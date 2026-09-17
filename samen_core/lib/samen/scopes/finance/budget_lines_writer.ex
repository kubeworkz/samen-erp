defmodule Samen.Scopes.Finance.BudgetLinesWriter do
  @moduledoc """
  Materializes the `lines` argument of a `Budget` create into real
  `BudgetLine` rows (WS-ERP E8) — the ONLY writer of budget lines.

  Runs in the budget's `after_action` (inside the action's transaction — the
  `EntryLines` cross-row-cascade discipline): if any line insert fails, the
  whole budget create rolls back (a budget can never end up silently
  line-less or half-materialized).

  Line shape (per the embedded-argument type): `account_id` (uuid, required),
  `planned_cents` (non-negative integer, required), `memo` (optional).
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    line_mod = Keyword.fetch!(opts, :line)

    # Line-shape guard (the ApLines discipline): the embedded-argument type
    # owns the field types (uuid + non-negative cents); this guard owns the
    # business condition the type cannot express — one line per ACCOUNT per
    # budget (the unique_budget_account identity, refused BEFORE any insert).
    changeset =
      Ash.Changeset.before_action(changeset, fn changeset ->
        lines = Ash.Changeset.get_argument(changeset, :lines) || []
        accounts = Enum.map(lines, & &1.account_id)
        dupes = accounts -- Enum.uniq(accounts)

        if dupes == [] do
          changeset
        else
          Ash.Changeset.add_error(
            changeset,
            Ash.Error.Changes.InvalidAttribute.exception(
              field: :lines,
              message: "duplicate account lines are refused (one plan per account per budget)",
              value: hd(dupes)
            )
          )
        end
      end)

    Ash.Changeset.after_action(changeset, fn changeset, budget ->
      lines = Ash.Changeset.get_argument(changeset, :lines) || []

      org_id =
        Ash.Changeset.get_attribute(changeset, :org_id) || budget.org_id

      rows =
        Enum.map(lines, fn line ->
          %{
            org_id: org_id,
            budget_id: budget.id,
            account_id: line.account_id,
            planned_cents: line.planned_cents,
            memo: Map.get(line, :memo)
          }
        end)

      case bulk_insert(line_mod, rows) do
        {:ok, _} ->
          {:ok, budget}

        {:error, reason} ->
          {:error,
           Ash.Error.Changes.InvalidAttribute.exception(
             field: :base,
             message: "the budget lines failed to land: #{inspect(reason)}",
             value: nil
           )}
      end
    end)
  end

  defp bulk_insert(_line_mod, []), do: {:ok, :empty}

  defp bulk_insert(line_mod, rows) do
    Ash.bulk_create(rows, line_mod, :create,
      authorize?: false,
      return_errors?: true,
      return_records?: false,
      stop_on_error?: true
    )
    |> case do
      %Ash.BulkResult{status: :success} = result -> {:ok, result}
      %Ash.BulkResult{status: :error, errors: errors} -> {:error, errors}
    end
  end
end
