defmodule Samen.Scopes.Work.TimesheetGuard do
  @moduledoc """
  Timesheet guard (WS-ERP E15).

  Enforces invariants on TimesheetEntry create/update:

  1. **No future entries.** The entry date must not be in the future.
  2. **Positive hours.** Hours must be > 0.
  3. **Max 24h per day.** Total hours for a user on a single day ≤ 24.
  4. **Approved entries are frozen.** An approved entry cannot be edited.
  5. **15-minute precision.** Hours must be a multiple of 0.25.
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.before_action(changeset, fn changeset ->
      with :ok <- validate_not_future(changeset),
           :ok <- validate_positive_hours(changeset),
           :ok <- validate_precision(changeset),
           :ok <- validate_not_approved(changeset) do
        validate_daily_limit(changeset)
      end
    end)
  end

  defp validate_not_future(changeset) do
    date = Ash.Changeset.get_attribute(changeset, :date)

    if date && Date.compare(date, Date.utc_today()) == :gt do
      Ash.Changeset.add_error(changeset,
        field: :date,
        message: "Cannot log time for a future date"
      )
    else
      :ok
    end
  end

  defp validate_positive_hours(changeset) do
    hours = Ash.Changeset.get_attribute(changeset, :hours)

    if is_nil(hours) or hours <= 0 do
      Ash.Changeset.add_error(changeset,
        field: :hours,
        message: "Hours must be positive"
      )
    else
      :ok
    end
  end

  defp validate_precision(changeset) do
    hours = Ash.Changeset.get_attribute(changeset, :hours)

    if hours do
      # Check if hours * 4 is close to an integer (within 0.01)
      multiplied = hours * 4
      nearest_int = round(multiplied)

      if abs(multiplied - nearest_int) > 0.01 do
        Ash.Changeset.add_error(changeset,
          field: :hours,
          message: "Hours must be in 15-minute increments (0.25)"
        )
      else
        :ok
      end
    else
      :ok
    end
  end

  defp validate_not_approved(changeset) do
    # Check if the entry is being updated (not created) and is already approved
    data_approved = Map.get(changeset.data || %{}, :approved, false)
    new_approved = Ash.Changeset.get_attribute(changeset, :approved)

    if data_approved and not is_nil(new_approved) do
      Ash.Changeset.add_error(changeset,
        field: :approved,
        message: "Approved entries cannot be modified"
      )
    else
      :ok
    end
  end

  defp validate_daily_limit(changeset) do
    user_id = Ash.Changeset.get_attribute(changeset, :user_id)
    date = Ash.Changeset.get_attribute(changeset, :date)
    hours = Ash.Changeset.get_attribute(changeset, :hours) || 0
    entry_id = Map.get(changeset.data || %{}, :id)

    if user_id && date do
      table = AshPostgres.DataLayer.Info.table(Samen.Scopes.Work.TimesheetEntry)
      repo = AshPostgres.DataLayer.Info.repo(Samen.Scopes.Work.TimesheetEntry, :mutate)

      # Sum existing hours for this user on this date, excluding current entry
      sql = """
      SELECT COALESCE(SUM(hours), 0) FROM #{table}
      WHERE user_id = $1 AND date = $2 AND id != $3
      """

      case repo.query(sql, [dump_uuid(user_id), date, dump_uuid(entry_id)]) do
        {:ok, %{rows: [[existing_hours]]}} ->
          total = existing_hours + hours

          if total > 24 do
            Ash.Changeset.add_error(changeset,
              field: :hours,
              message: "Daily limit exceeded: #{existing_hours}h already logged, #{hours}h would total #{total}h (max 24)"
            )
          else
            changeset
          end

        _ ->
          changeset
      end
    else
      changeset
    end
  end

  defp dump_uuid(nil), do: "00000000-0000-0000-0000-000000000000"
  defp dump_uuid(id), do: Ecto.UUID.dump!(id)
end
