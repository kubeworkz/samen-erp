defmodule Samen.Scopes.Finance.AdjustmentVoid do
  @moduledoc """
  Voids an adjustment without deleting history.

  A draft has no ledger fact, so voiding it only flips the document status. An
  open adjustment has a posted entry, so voiding it first voids that entry
  through the journal's own `:void` action (which creates the linked reversing
  entry) and only then flips the document to `:void`. If the ledger reversal
  fails, the whole document void rolls back.

  An applied adjustment is final at this layer: a correction must be a new
  reversing adjustment, not a silent status rewrite.
  """

  use Ash.Resource.Change

  @impl true
  def change(changeset, opts, _context) do
    entry_resource = Keyword.fetch!(opts, :entry)
    Ash.Changeset.before_action(changeset, &void(&1, entry_resource))
  end

  defp void(changeset, entry_resource) do
    case changeset.data.status do
      :draft ->
        Ash.Changeset.force_change_attribute(changeset, :status, :void)

      :open ->
        case void_entry(changeset.data.entry_id, entry_resource) do
          :ok ->
            Ash.Changeset.force_change_attribute(changeset, :status, :void)

          {:error, reason} ->
            Ash.Changeset.add_error(changeset,
              field: :base,
              message: "the adjustment's ledger entry could not be voided: #{inspect(reason)}"
            )
        end

      :applied ->
        Ash.Changeset.add_error(changeset,
          field: :status,
          message: "an applied adjustment cannot be voided — post a reversing adjustment instead"
        )

      :void ->
        Ash.Changeset.add_error(changeset,
          field: :status,
          message: "this adjustment is already void"
        )
    end
  end

  defp void_entry(entry_id, entry_resource) when is_binary(entry_id) do
    case Ash.get(entry_resource, entry_id, authorize?: false) do
      {:ok, nil} ->
        {:error, :entry_not_found}

      {:error, reason} ->
        {:error, reason}

      {:ok, entry} ->
        entry
        |> Ash.Changeset.for_update(:void, %{}, authorize?: false)
        |> Ash.update(authorize?: false)
        |> case do
          {:ok, _voided} -> :ok
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp void_entry(_entry_id, _entry_resource), do: {:error, :missing_entry}
end
